import Darwin
import Foundation

// Exercise the production client's long-lived receive work item. The private
// fixture socket never initializes a session, so no real IPC or database is read.
private enum FixtureError: Error {
    case syscall(String, Int32)
    case invalidResponse
    case assertion(String)
}

private func require(_ condition: Bool, _ message: String) throws {
    guard condition else { throw FixtureError.assertion(message) }
}

private func physicalFootprint() throws -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<natural_t>.size)
    let result = withUnsafeMutablePointer(to: &info) { pointer in
        pointer.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count)
        }
    }
    guard result == KERN_SUCCESS else { throw FixtureError.syscall("task_info", result) }
    return info.phys_footprint
}

private func framed(_ message: [String: Any]) throws -> Data {
    let payload = try JSONSerialization.data(withJSONObject: message)
    var length = UInt32(payload.count).littleEndian
    var result = Data()
    withUnsafeBytes(of: &length) { result.append(contentsOf: $0) }
    result.append(payload)
    return result
}

private final class FixturePeer {
    let descriptor: Int32

    init(descriptor: Int32) throws {
        self.descriptor = descriptor
        var noSigPipe: Int32 = 1
        var timeout = timeval(tv_sec: 10, tv_usec: 0)
        guard setsockopt(descriptor, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe,
                         socklen_t(MemoryLayout.size(ofValue: noSigPipe))) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_RCVTIMEO, &timeout,
                         socklen_t(MemoryLayout.size(ofValue: timeout))) == 0,
              setsockopt(descriptor, SOL_SOCKET, SO_SNDTIMEO, &timeout,
                         socklen_t(MemoryLayout.size(ofValue: timeout))) == 0 else {
            let code = errno
            Darwin.close(descriptor)
            throw FixtureError.syscall("setsockopt", code)
        }
    }

    deinit { Darwin.close(descriptor) }

    func send(_ frame: Data) throws {
        try frame.withUnsafeBytes { bytes in
            var offset = 0
            while offset < frame.count {
                let count = Darwin.write(descriptor, bytes.baseAddress!.advanced(by: offset), frame.count - offset)
                if count < 0 && errno == EINTR { continue }
                guard count > 0 else { throw FixtureError.syscall("write", errno) }
                offset += count
            }
        }
    }

    func receive() throws -> [String: Any] {
        let header = [UInt8](try readExactly(4))
        let count = Int(UInt32(header[0]) | UInt32(header[1]) << 8 |
                        UInt32(header[2]) << 16 | UInt32(header[3]) << 24)
        guard count > 0 && count < 65_536,
              let message = try JSONSerialization.jsonObject(with: readExactly(count)) as? [String: Any] else {
            throw FixtureError.invalidResponse
        }
        return message
    }

    private func readExactly(_ count: Int) throws -> Data {
        var result = Data(count: count)
        try result.withUnsafeMutableBytes { (bytes: UnsafeMutableRawBufferPointer) in
            var offset = 0
            while offset < count {
                let received = Darwin.read(descriptor, bytes.baseAddress!.advanced(by: offset), count - offset)
                if received < 0 && errno == EINTR { continue }
                guard received > 0 else { throw FixtureError.syscall("read", errno) }
                offset += received
            }
        }
        return result
    }

    // This normal protocol response proves every preceding message was handled.
    // Keep the connection open while sampling: ending the worker would drain its
    // outer autorelease pool and hide the regression.
    func barrier(_ index: Int) throws {
        let requestId = "synthetic-barrier-\(index)"
        try send(framed(["type": "client-discovery-request", "requestId": requestId]))
        let response = try receive()
        try require(response["type"] as? String == "client-discovery-response" &&
                response["requestId"] as? String == requestId &&
                (response["response"] as? [String: Any])?["canHandle"] as? Bool == false,
                "discovery response must reject handling")
    }
}

private func runRegression() throws {
    let directory = "/tmp/cpet-ipc-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: directory, withIntermediateDirectories: false,
                                          attributes: [.posixPermissions: 0o700])
    let path = directory + "/ipc.sock"
    defer {
        Darwin.unlink(path)
        Darwin.rmdir(directory)
    }
    let listener = Darwin.socket(AF_UNIX, SOCK_STREAM, 0)
    guard listener >= 0 else { throw FixtureError.syscall("socket", errno) }
    defer { Darwin.close(listener) }
    var address = sockaddr_un()
    address.sun_family = sa_family_t(AF_UNIX)
    address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
    let pathBytes = path.utf8CString.map { UInt8(bitPattern: $0) }
    try require(pathBytes.count <= MemoryLayout.size(ofValue: address.sun_path), "fixture socket path too long")
    withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: pathBytes) }
    let bound = withUnsafePointer(to: &address) { pointer in
        pointer.withMemoryRebound(to: sockaddr.self, capacity: 1) {
            Darwin.bind(listener, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
        }
    }
    guard bound == 0, Darwin.listen(listener, 1) == 0 else { throw FixtureError.syscall("bind/listen", errno) }

    let store = ThreadStatusStore()
    let client = CodexIPCClient(statusStore: store, socketPath: path)
    defer { client.stop() }
    client.start()
    var ready = pollfd(fd: listener, events: Int16(POLLIN), revents: 0)
    guard Darwin.poll(&ready, 1, 10_000) == 1 else { throw FixtureError.syscall("accept timeout", errno) }
    let accepted = Darwin.accept(listener, nil, nil)
    guard accepted >= 0 else { throw FixtureError.syscall("accept", errno) }
    let peer = try FixturePeer(descriptor: accepted)
    try autoreleasepool {
        let initialize = try peer.receive()
        try require(initialize["method"] as? String == "initialize" && initialize["type"] as? String == "request",
                "production initialization request missing")
        // Deliberately no initialize response: no candidate scanning of real data.
        try peer.barrier(0)
    }
    let frame = try autoreleasepool {
        try framed(["type": "broadcast", "method": "unrelated-synthetic",
                    "params": ["items": (0..<256).map { _ in
                        ["body": String(repeating: "x", count: 64), "status": "synthetic"]
                    }]])
    }
    let messages = CommandLine.arguments.contains("--stress") ? 12_000 : 4_000
    let baseline = try physicalFootprint()
    var peakGrowth: UInt64 = 0
    print("IPC_MEMORY_BASELINE footprint_MiB=\(baseline / 1_048_576) frame_bytes=\(frame.count)")
    for batch in 1...(messages / 200) {
        try autoreleasepool {
            for _ in 0..<200 { try peer.send(frame) }
            try peer.barrier(batch)
        }
        let current = try physicalFootprint()
        let growth = current > baseline ? current - baseline : 0
        peakGrowth = max(peakGrowth, growth)
        print("IPC_MEMORY_SAMPLE messages=\(batch * 200) footprint_MiB=\(current / 1_048_576) growth_KiB=\(growth / 1024)")
        fflush(stdout)
        try require(growth <= 192 * 1_048_576, "hard safety budget exceeded")
    }
    try require(peakGrowth <= 64 * 1_048_576, "physical footprint grew more than 64 MiB on one live connection")
    print("IPC_MEMORY_TESTS_OK messages=\(messages) peak_growth_KiB=\(peakGrowth / 1024)")

    // A throwing receive must still follow the existing incompatibility path,
    // publish on the main queue, block automatic retry and allow manual recovery.
    var observedIssue: String?
    var publishedOnMain = false
    store.onChange = { status in
        if status.connectionState == .incompatible {
            observedIssue = status.connectionIssueCode
            publishedOnMain = Thread.isMainThread
        }
    }
    try peer.send(Data([1, 0, 0, 0, 0x21])) // One-byte invalid JSON, not user data.
    let deadline = Date().addingTimeInterval(3)
    while observedIssue == nil && Date() < deadline {
        RunLoop.main.run(until: Date().addingTimeInterval(0.01))
    }
    try require(observedIssue == "invalid_json" && publishedOnMain,
                "parse error must publish invalid_json incompatibility on main")
    ready.revents = 0
    try require(Darwin.poll(&ready, 1, 2_200) == 0, "incompatible protocol must not auto-reconnect")
    client.reconnect()
    ready.revents = 0
    try require(Darwin.poll(&ready, 1, 10_000) == 1, "manual reconnect must reach fixture")
    let reconnected = Darwin.accept(listener, nil, nil)
    guard reconnected >= 0 else { throw FixtureError.syscall("re-accept", errno) }
    let resumedPeer = try FixturePeer(descriptor: reconnected)
    try autoreleasepool {
        let initialize = try resumedPeer.receive()
        try require(initialize["method"] as? String == "initialize", "manual reconnect must reinitialize")
        try resumedPeer.barrier(-1)
    }
    client.stop()
    var byte: UInt8 = 0
    try require(Darwin.read(resumedPeer.descriptor, &byte, 1) == 0,
                "stop must close a client blocked in receive")
    print("IPC_ERROR_RECONNECT_TESTS_OK")
}

// Bound all hangs, including a production-worker regression or broken barrier.
let watchdog = DispatchSource.makeTimerSource(queue: .global())
watchdog.schedule(deadline: .now() + 60)
watchdog.setEventHandler {
    fputs("IPC_MEMORY_TEST_FAILED: 60-second test timeout\n", stderr)
    exit(1)
}
watchdog.resume()
defer { watchdog.cancel() }
do {
    try autoreleasepool { try runRegression() }
} catch {
    fputs("IPC_MEMORY_TEST_FAILED: \(error)\n", stderr)
    exit(1)
}
