import Darwin
import Foundation

private enum IPCSocketError: Error {
    case createFailed(Int32)
    case pathTooLong
    case connectFailed(Int32)
    case closed
    case invalidFrameLength(Int)
    case invalidJSON

    var diagnosticCode: String {
        switch self {
        case .createFailed(let code): return "socket_create_\(code)"
        case .pathTooLong: return "socket_path_too_long"
        case .connectFailed(let code): return "socket_connect_\(code)"
        case .closed: return "connection_closed"
        case .invalidFrameLength: return "invalid_frame_length"
        case .invalidJSON: return "invalid_json"
        }
    }

    var isProtocolIncompatible: Bool {
        switch self {
        case .invalidFrameLength, .invalidJSON:
            return true
        default:
            return false
        }
    }
}

private final class UnixFramedSocket {
    private let writeLock = NSLock()
    private let descriptorLock = NSLock()
    private var descriptor: Int32 = -1

    var isConnected: Bool { currentDescriptor >= 0 }

    func connect(path: String) throws {
        close()
        let socketDescriptor = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
        guard socketDescriptor >= 0 else {
            throw IPCSocketError.createFailed(errno)
        }

        var noSigPipe: Int32 = 1
        setsockopt(
            socketDescriptor,
            SOL_SOCKET,
            SO_NOSIGPIPE,
            &noSigPipe,
            socklen_t(MemoryLayout<Int32>.size)
        )

        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = path.utf8CString.map { UInt8(bitPattern: $0) }
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard pathBytes.count <= capacity else {
            Darwin.close(socketDescriptor)
            throw IPCSocketError.pathTooLong
        }
        withUnsafeMutableBytes(of: &address.sun_path) { buffer in
            buffer.initializeMemory(as: UInt8.self, repeating: 0)
            buffer.copyBytes(from: pathBytes)
        }

        descriptorLock.lock()
        descriptor = socketDescriptor
        descriptorLock.unlock()

        let result = withUnsafePointer(to: &address) { pointer in
            pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(
                    socketDescriptor,
                    $0,
                    socklen_t(MemoryLayout<sockaddr_un>.size)
                )
            }
        }
        guard result == 0 else {
            let code = errno
            close(ifCurrent: socketDescriptor)
            throw IPCSocketError.connectFailed(code)
        }
        guard currentDescriptor == socketDescriptor else {
            throw IPCSocketError.closed
        }
    }

    func close() {
        writeLock.lock()
        defer { writeLock.unlock() }
        descriptorLock.lock()
        let socketDescriptor = descriptor
        descriptor = -1
        descriptorLock.unlock()
        guard socketDescriptor >= 0 else { return }
        Darwin.shutdown(socketDescriptor, SHUT_RDWR)
        Darwin.close(socketDescriptor)
    }

    func send(_ object: [String: Any]) throws {
        let payload = try JSONSerialization.data(withJSONObject: object)
        let length = UInt32(payload.count).littleEndian
        var frame = Data()
        withUnsafeBytes(of: length) { frame.append(contentsOf: $0) }
        frame.append(payload)

        writeLock.lock()
        defer { writeLock.unlock() }
        let socketDescriptor = currentDescriptor
        guard socketDescriptor >= 0 else { throw IPCSocketError.closed }
        try frame.withUnsafeBytes { rawBuffer in
            guard let baseAddress = rawBuffer.baseAddress else { return }
            var offset = 0
            while offset < frame.count {
                let written = Darwin.write(
                    socketDescriptor,
                    baseAddress.advanced(by: offset),
                    frame.count - offset
                )
                guard written > 0 else { throw IPCSocketError.closed }
                offset += written
            }
        }
    }

    func receive() throws -> [String: Any] {
        let header = try readExactly(4)
        let bytes = [UInt8](header)
        let length = Int(
            UInt32(bytes[0]) |
            UInt32(bytes[1]) << 8 |
            UInt32(bytes[2]) << 16 |
            UInt32(bytes[3]) << 24
        )
        guard length > 0 && length <= 128 * 1024 * 1024 else {
            throw IPCSocketError.invalidFrameLength(length)
        }
        let payload = try readExactly(length)
        let value: Any
        do {
            value = try JSONSerialization.jsonObject(with: payload)
        } catch {
            throw IPCSocketError.invalidJSON
        }
        guard let message = value as? [String: Any] else {
            throw IPCSocketError.invalidJSON
        }
        return message
    }

    private func readExactly(_ count: Int) throws -> Data {
        let socketDescriptor = currentDescriptor
        guard socketDescriptor >= 0 else { throw IPCSocketError.closed }
        var bytes = [UInt8](repeating: 0, count: count)
        var offset = 0
        while offset < count {
            let readCount = bytes.withUnsafeMutableBytes { buffer in
                Darwin.read(
                    socketDescriptor,
                    buffer.baseAddress?.advanced(by: offset),
                    count - offset
                )
            }
            guard readCount > 0 else { throw IPCSocketError.closed }
            offset += readCount
        }
        return Data(bytes)
    }

    private var currentDescriptor: Int32 {
        descriptorLock.lock()
        defer { descriptorLock.unlock() }
        return descriptor
    }

    private func close(ifCurrent socketDescriptor: Int32) {
        descriptorLock.lock()
        guard descriptor == socketDescriptor else {
            descriptorLock.unlock()
            return
        }
        descriptor = -1
        descriptorLock.unlock()
        Darwin.shutdown(socketDescriptor, SHUT_RDWR)
        Darwin.close(socketDescriptor)
    }
}

final class CodexIPCClient {
    private let socket = UnixFramedSocket()
    private let statusStore: ThreadStatusStore
    private let threadProvider = RecentThreadProvider()
    private let worker = DispatchQueue(label: "dev.codex.touch-pet.ipc", qos: .userInitiated)
    private let stateLock = NSLock()
    private let retrySignal = DispatchSemaphore(value: 0)

    private var running = false
    private var clientId = "initializing-client"
    private var initializeRequestId: String?
    private var pendingOwnerRequests: [String: String] = [:]
    private var subscriptionOwners: [String: String] = [:]
    private var lastProbeAt: [String: Date] = [:]
    private var sessionGeneration = UUID()
    private var protocolRetryBlocked = false

    init(statusStore: ThreadStatusStore) {
        self.statusStore = statusStore
    }

    func start() {
        stateLock.lock()
        guard !running else {
            stateLock.unlock()
            return
        }
        running = true
        stateLock.unlock()
        worker.async { [weak self] in
            self?.connectionLoop()
        }
    }

    func stop() {
        stateLock.lock()
        running = false
        let subscriptions = subscriptionOwners
        let currentClientId = clientId
        stateLock.unlock()
        retrySignal.signal()

        for (threadId, ownerId) in subscriptions {
            try? sendFollowing(
                threadId: threadId,
                ownerClientId: ownerId,
                enabled: false,
                sourceClientId: currentClientId
            )
        }
        socket.close()
        DispatchQueue.main.async { [weak self] in
            self?.statusStore.markDisconnected(issueCode: "application_stopped")
        }
    }

    func reconnect() {
        stateLock.lock()
        protocolRetryBlocked = false
        sessionGeneration = UUID()
        stateLock.unlock()
        socket.close()
        retrySignal.signal()
    }

    private var shouldRun: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running
    }

    private func connectionLoop() {
        let socketPath = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex/ipc/ipc.sock").path

        while shouldRun {
            do {
                try socket.connect(path: socketPath)
                resetSessionState()
                try sendInitialize()
                while shouldRun && socket.isConnected {
                    let message = try socket.receive()
                    handle(message)
                }
            } catch {
                socket.close()
                let issueCode = Self.diagnosticCode(for: error)
                let incompatible = (error as? IPCSocketError)?.isProtocolIncompatible == true
                let failedGeneration = currentSessionGeneration
                if incompatible {
                    blockProtocolRetries()
                }
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isCurrentGeneration(failedGeneration) else { return }
                    if incompatible {
                        guard self.isProtocolRetryBlocked else { return }
                        self.statusStore.markIncompatible(issueCode: issueCode)
                    } else {
                        self.statusStore.markDisconnected(issueCode: issueCode)
                    }
                }
            }
            guard shouldRun else { break }
            if isProtocolRetryBlocked {
                waitForManualReconnect()
            } else {
                Thread.sleep(forTimeInterval: 2)
            }
        }
    }

    private func resetSessionState() {
        stateLock.lock()
        clientId = "initializing-client"
        initializeRequestId = nil
        pendingOwnerRequests.removeAll()
        subscriptionOwners.removeAll()
        lastProbeAt.removeAll()
        sessionGeneration = UUID()
        stateLock.unlock()
    }

    private func sendInitialize() throws {
        let requestId = UUID().uuidString
        stateLock.lock()
        initializeRequestId = requestId
        stateLock.unlock()
        try socket.send([
            "type": "request",
            "requestId": requestId,
            "sourceClientId": "initializing-client",
            "version": 0,
            "method": "initialize",
            "params": ["clientType": "codex-touch-pet"],
            "timeoutMs": 5000
        ])
    }

    private func handle(_ message: [String: Any]) {
        if message["type"] as? String == "client-discovery-request" {
            rejectDiscovery(message)
            return
        }

        if let requestId = message["requestId"] as? String {
            if requestId == currentInitializeRequestId {
                handleInitializeResponse(message)
                return
            }
            if let threadId = removePendingOwnerRequest(requestId) {
                handleOwnerResponse(message, threadId: threadId)
                return
            }
        }

        guard message["type"] as? String == "broadcast",
              let method = message["method"] as? String else { return }
        switch method {
        case "thread-stream-state-changed":
            handleStreamChange(message)
        case "client-status-changed":
            handleClientStatus(message)
        default:
            break
        }
    }

    private var currentInitializeRequestId: String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return initializeRequestId
    }

    private var currentSessionGeneration: UUID {
        stateLock.lock()
        defer { stateLock.unlock() }
        return sessionGeneration
    }

    private func handleInitializeResponse(_ message: [String: Any]) {
        let generation = currentSessionGeneration
        guard message["resultType"] as? String == "success",
              let result = message["result"] as? [String: Any],
              let resolvedClientId = result["clientId"] as? String else {
            blockProtocolRetries()
            DispatchQueue.main.async { [weak self] in
                guard let self,
                      self.isCurrentGeneration(generation),
                      self.isProtocolRetryBlocked else { return }
                self.statusStore.markIncompatible(issueCode: "initialize_rejected")
            }
            socket.close()
            return
        }
        stateLock.lock()
        clientId = resolvedClientId
        protocolRetryBlocked = false
        stateLock.unlock()

        DispatchQueue.main.async { [weak self] in
            guard let self, self.isCurrentSession(generation) else { return }
            self.statusStore.markConnected()
        }
        scheduleCandidateScan(generation: generation, after: 0)
    }

    private func rejectDiscovery(_ message: [String: Any]) {
        guard let requestId = message["requestId"] as? String else { return }
        try? socket.send([
            "type": "client-discovery-response",
            "requestId": requestId,
            "response": ["canHandle": false]
        ])
    }

    private func scheduleCandidateScan(generation: UUID, after delay: TimeInterval) {
        DispatchQueue.global(qos: .utility).asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.isCurrentSession(generation) else { return }
            let recentThreads = self.threadProvider.recentThreads(limit: 20)
            let filteredInternalCount = self.threadProvider.filteredInternalThreadCount()
            let threadIds = recentThreads.map(\.id)
            self.probeOwners(threadIds)
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrentSession(generation) else { return }
                for thread in recentThreads {
                    self.statusStore.updateTitle(threadId: thread.id, title: thread.title)
                }
                self.statusStore.updateFilteredInternalCount(filteredInternalCount)
                self.statusStore.finishInitialScan()
            }
            self.scheduleCandidateScan(generation: generation, after: 5)
        }
    }

    private func isCurrentSession(_ generation: UUID) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running && socket.isConnected && sessionGeneration == generation
    }

    private func isCurrentGeneration(_ generation: UUID) -> Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return running && sessionGeneration == generation
    }

    private func probeOwners(_ threadIds: [String]) {
        for threadId in threadIds {
            stateLock.lock()
            let alreadySubscribed = subscriptionOwners[threadId] != nil
            let alreadyPending = pendingOwnerRequests.values.contains(threadId)
            let lastProbe = lastProbeAt[threadId]
            let shouldProbe = lastProbe.map { Date().timeIntervalSince($0) >= 10 } ?? true
            let sourceClientId = clientId
            stateLock.unlock()
            guard !alreadySubscribed, !alreadyPending, shouldProbe else { continue }

            let requestId = UUID().uuidString
            stateLock.lock()
            pendingOwnerRequests[requestId] = threadId
            lastProbeAt[threadId] = Date()
            stateLock.unlock()
            do {
                try socket.send([
                    "type": "request",
                    "requestId": requestId,
                    "sourceClientId": sourceClientId,
                    "version": 1,
                    "method": "thread-owner-discovery",
                    "params": ["hostId": "local", "conversationId": threadId],
                    "timeoutMs": 3000
                ])
            } catch {
                _ = removePendingOwnerRequest(requestId)
            }
        }
    }

    private func removePendingOwnerRequest(_ requestId: String) -> String? {
        stateLock.lock()
        defer { stateLock.unlock() }
        return pendingOwnerRequests.removeValue(forKey: requestId)
    }

    private func handleOwnerResponse(_ message: [String: Any], threadId: String) {
        guard message["resultType"] as? String == "success",
              let ownerId = message["handledByClientId"] as? String else { return }
        stateLock.lock()
        subscriptionOwners[threadId] = ownerId
        let sourceClientId = clientId
        stateLock.unlock()
        try? sendFollowing(
            threadId: threadId,
            ownerClientId: ownerId,
            enabled: true,
            sourceClientId: sourceClientId
        )
    }

    private func sendFollowing(
        threadId: String,
        ownerClientId: String,
        enabled: Bool,
        sourceClientId: String
    ) throws {
        try socket.send([
            "type": "broadcast",
            "method": "thread-stream-following-changed",
            "sourceClientId": sourceClientId,
            "targetClientIds": [ownerClientId],
            "params": [
                "conversationId": threadId,
                "hostId": "local",
                "following": enabled
            ],
            "version": 1
        ])
    }

    private func handleStreamChange(_ message: [String: Any]) {
        guard let params = message["params"] as? [String: Any],
              let threadId = params["conversationId"] as? String,
              let change = params["change"] as? [String: Any],
              let changeType = change["type"] as? String else { return }
        let generation = currentSessionGeneration

        if changeType == "snapshot",
           let state = change["conversationState"] as? [String: Any] {
            applySnapshot(state, threadId: threadId, generation: generation)
        } else if changeType == "patches",
                  let patches = change["patches"] as? [[String: Any]] {
            applyPatches(patches, threadId: threadId, generation: generation)
        }
    }

    private func applySnapshot(_ state: [String: Any], threadId: String, generation: UUID) {
        if let runtime = state["threadRuntimeStatus"] as? [String: Any],
           let type = runtime["type"] as? String {
            let flags = runtime["activeFlags"] as? [String] ?? []
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrentSession(generation) else { return }
                self.statusStore.updateRuntime(threadId: threadId, type: type, activeFlags: flags)
            }
        }
        // Snapshot payloads contain historical turn items. Activity labels are
        // only accepted from incremental patches so an old tool call cannot
        // pin the current task to "调用工具" forever.
    }

    private func applyPatches(_ patches: [[String: Any]], threadId: String, generation: UUID) {
        for patch in patches {
            let path = patch["path"] as? [Any] ?? []
            let pathStrings = path.map(String.init(describing:))
            let value = patch["value"]

            if pathStrings == ["threadRuntimeStatus"],
               let runtime = value as? [String: Any],
               let type = runtime["type"] as? String {
                let flags = runtime["activeFlags"] as? [String] ?? []
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isCurrentSession(generation) else { return }
                    self.statusStore.updateRuntime(threadId: threadId, type: type, activeFlags: flags)
                }
                continue
            }

            if Self.isTurnStatusPath(pathStrings), let status = value as? String {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isCurrentSession(generation) else { return }
                    self.statusStore.updateTurn(threadId: threadId, status: status)
                }
                continue
            }

            if let activity = Self.findActivity(in: value, maximumDepth: 4) {
                DispatchQueue.main.async { [weak self] in
                    guard let self, self.isCurrentSession(generation) else { return }
                    self.statusStore.updateActivity(threadId: threadId, activity: activity)
                }
            }
        }
    }

    private static func isTurnStatusPath(_ path: [String]) -> Bool {
        if path.count == 5,
           path.first == "turnHistory",
           path.dropFirst(2).first == "entitiesByKey",
           path.last == "status" {
            return true
        }
        return path.count == 3 && path.first == "turns" && path.last == "status"
    }

    private static func findActivity(in value: Any?, maximumDepth: Int) -> WorkActivity? {
        guard maximumDepth >= 0 else { return nil }
        if let dictionary = value as? [String: Any] {
            if let type = dictionary["type"] as? String,
               let activity = activity(forItemType: type) {
                return activity
            }
            for child in dictionary.values {
                if let activity = findActivity(in: child, maximumDepth: maximumDepth - 1) {
                    return activity
                }
            }
        } else if let array = value as? [Any] {
            for child in array.reversed().prefix(20) {
                if let activity = findActivity(in: child, maximumDepth: maximumDepth - 1) {
                    return activity
                }
            }
        }
        return nil
    }

    private static func activity(forItemType type: String) -> WorkActivity? {
        switch type {
        case "reasoning", "plan", "agentMessage": return .thinking
        case "commandExecution": return .command
        case "fileChange": return .editing
        case "mcpToolCall", "dynamicToolCall", "imageGeneration", "imageView": return .tool
        case "webSearch": return .search
        case "collabAgentToolCall", "subAgentActivity": return .collaboration
        case "contextCompaction": return .compacting
        case "enteredReviewMode", "exitedReviewMode": return .review
        default: return nil
        }
    }

    private static func diagnosticCode(for error: Error) -> String {
        if let error = error as? IPCSocketError {
            return error.diagnosticCode
        }
        return "unknown_ipc_error"
    }

    private var isProtocolRetryBlocked: Bool {
        stateLock.lock()
        defer { stateLock.unlock() }
        return protocolRetryBlocked
    }

    private func blockProtocolRetries() {
        stateLock.lock()
        protocolRetryBlocked = true
        stateLock.unlock()
    }

    private func waitForManualReconnect() {
        while shouldRun && isProtocolRetryBlocked {
            _ = retrySignal.wait(timeout: .now() + 1)
        }
    }

    private func handleClientStatus(_ message: [String: Any]) {
        guard let params = message["params"] as? [String: Any],
              params["status"] as? String == "disconnected",
              let disconnectedClientId = params["clientId"] as? String else { return }
        let generation = currentSessionGeneration
        stateLock.lock()
        let affected = subscriptionOwners.compactMap { threadId, ownerId in
            ownerId == disconnectedClientId ? threadId : nil
        }
        for threadId in affected {
            subscriptionOwners.removeValue(forKey: threadId)
        }
        stateLock.unlock()
        for threadId in affected {
            DispatchQueue.main.async { [weak self] in
                guard let self, self.isCurrentSession(generation) else { return }
                self.statusStore.removeThread(threadId)
            }
        }
    }
}
