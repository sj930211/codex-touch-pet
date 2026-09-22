import Foundation

final class ThreadStatusStore {
    var onChange: ((AggregatePetStatus) -> Void)?

    private let now: () -> Date
    private let schedule: (TimeInterval, @escaping () -> Void) -> Void
    private let reconnectGracePeriod: TimeInterval
    private var statuses: [String: ThreadPetStatus] = [:]
    private var titles: [String: String] = [:]
    private var turnStartedAt: [String: Date] = [:]
    private var transientGeneration: [String: UUID] = [:]
    private var activityGeneration: [String: UUID] = [:]
    private var connectionState: CodexConnectionState = .connecting
    private var lastSuccessfulUpdateAt: Date?
    private var lastDisconnectAt: Date?
    private var connectionIssueCode: String?
    private var filteredInternalCount: Int?
    private var staleGeneration: UUID?
    private var initialScanComplete = false

    init(
        now: @escaping () -> Date = Date.init,
        reconnectGracePeriod: TimeInterval = 8,
        schedule: @escaping (TimeInterval, @escaping () -> Void) -> Void = { delay, action in
            DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: action)
        }
    ) {
        self.now = now
        self.reconnectGracePeriod = reconnectGracePeriod
        self.schedule = schedule
    }

    func setConnected(_ value: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        if value {
            markConnected()
        } else {
            markDisconnected(issueCode: "connection_closed")
        }
    }

    func beginConnecting() {
        dispatchPrecondition(condition: .onQueue(.main))
        guard lastSuccessfulUpdateAt == nil else { return }
        connectionState = .connecting
        connectionIssueCode = nil
        publish()
    }

    func markConnected() {
        dispatchPrecondition(condition: .onQueue(.main))
        staleGeneration = nil
        connectionState = .online
        connectionIssueCode = nil
        lastSuccessfulUpdateAt = now()
        publish()
    }

    func markDisconnected(issueCode: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        guard connectionState != .incompatible else { return }
        connectionIssueCode = issueCode
        if lastSuccessfulUpdateAt == nil {
            connectionState = .disconnected
            if lastDisconnectAt == nil {
                lastDisconnectAt = now()
            }
            publish()
            return
        }
        if connectionState == .reconnecting || connectionState == .stale {
            publish()
            return
        }
        lastDisconnectAt = now()
        connectionState = .reconnecting
        let generation = UUID()
        staleGeneration = generation
        publish()
        schedule(reconnectGracePeriod) { [weak self] in
            guard let self, self.staleGeneration == generation else { return }
            self.connectionState = .stale
            self.publish()
        }
    }

    func beginManualReconnect() {
        dispatchPrecondition(condition: .onQueue(.main))
        if connectionState == .online {
            markDisconnected(issueCode: "manual_reconnect")
            return
        }
        connectionIssueCode = "manual_reconnect"
        if lastSuccessfulUpdateAt == nil {
            connectionState = .connecting
        } else {
            connectionState = .reconnecting
        }
        publish()
    }

    func markIncompatible(issueCode: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        staleGeneration = nil
        connectionState = .incompatible
        connectionIssueCode = issueCode
        lastDisconnectAt = now()
        publish()
    }

    func finishInitialScan() {
        dispatchPrecondition(condition: .onQueue(.main))
        initialScanComplete = true
        recordSuccessfulUpdate()
        publish()
    }

    func updateFilteredInternalCount(_ count: Int?) {
        dispatchPrecondition(condition: .onQueue(.main))
        filteredInternalCount = count
        publish()
    }

    func removeThread(_ threadId: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        statuses.removeValue(forKey: threadId)
        titles.removeValue(forKey: threadId)
        turnStartedAt.removeValue(forKey: threadId)
        transientGeneration.removeValue(forKey: threadId)
        activityGeneration.removeValue(forKey: threadId)
        publish()
    }

    func updateTitle(threadId: String, title: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        let normalizedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedTitle.isEmpty else { return }
        titles[threadId] = normalizedTitle
        guard let current = statuses[threadId], current.title != normalizedTitle else {
            return
        }
        statuses[threadId] = ThreadPetStatus(
            threadId: current.threadId,
            state: current.state,
            updatedAt: current.updatedAt,
            title: normalizedTitle,
            startedAt: current.startedAt
        )
        publish()
    }

    func updateRuntime(threadId: String, type: String, activeFlags: [String] = []) {
        dispatchPrecondition(condition: .onQueue(.main))
        recordSuccessfulUpdate()
        transientGeneration.removeValue(forKey: threadId)
        activityGeneration.removeValue(forKey: threadId)
        let state: PetState
        switch type {
        case "notLoaded":
            endTurn(threadId: threadId)
            state = .connecting
        case "idle":
            endTurn(threadId: threadId)
            state = .idle
        case "systemError":
            endTurn(threadId: threadId)
            state = .systemError
        case "active":
            beginTurnIfNeeded(threadId: threadId)
            if activeFlags.contains("waitingOnApproval") {
                state = .waitingApproval
            } else if activeFlags.contains("waitingOnUserInput") {
                state = .waitingInput
            } else {
                state = .working(nil)
            }
        default:
            state = .connecting
        }
        setState(state, threadId: threadId)
    }

    func updateTurn(threadId: String, status: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        recordSuccessfulUpdate()
        activityGeneration.removeValue(forKey: threadId)
        switch status {
        case "inProgress":
            transientGeneration.removeValue(forKey: threadId)
            beginTurnIfNeeded(threadId: threadId)
            setState(.working(nil), threadId: threadId)
        case "completed":
            endTurn(threadId: threadId)
            setTransient(.completed, fallback: .idle, threadId: threadId, delay: 3)
        case "interrupted":
            endTurn(threadId: threadId)
            setTransient(.interrupted, fallback: .idle, threadId: threadId, delay: 2)
        case "failed":
            endTurn(threadId: threadId)
            transientGeneration.removeValue(forKey: threadId)
            setState(.failed, threadId: threadId)
        default:
            break
        }
    }

    func updateActivity(threadId: String, activity: WorkActivity) {
        dispatchPrecondition(condition: .onQueue(.main))
        recordSuccessfulUpdate()
        guard let current = statuses[threadId]?.state else { return }
        switch current {
        case .working:
            let generation = UUID()
            activityGeneration[threadId] = generation
            setState(.working(activity), threadId: threadId)
            DispatchQueue.main.asyncAfter(deadline: .now() + 3) { [weak self] in
                guard let self, self.activityGeneration[threadId] == generation else { return }
                self.activityGeneration.removeValue(forKey: threadId)
                if case .working = self.statuses[threadId]?.state {
                    self.setState(.working(nil), threadId: threadId)
                }
            }
        default:
            break
        }
    }

    private func setTransient(
        _ state: PetState,
        fallback: PetState,
        threadId: String,
        delay: TimeInterval
    ) {
        let generation = UUID()
        transientGeneration[threadId] = generation
        activityGeneration.removeValue(forKey: threadId)
        setState(state, threadId: threadId)
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.transientGeneration[threadId] == generation else { return }
            self.transientGeneration.removeValue(forKey: threadId)
            self.setState(fallback, threadId: threadId)
        }
    }

    private func setState(_ state: PetState, threadId: String) {
        let previous = statuses[threadId]
        let timestamp = now()
        statuses[threadId] = ThreadPetStatus(
            threadId: threadId,
            state: state,
            updatedAt: timestamp,
            title: previous?.title ?? titles[threadId] ?? "",
            startedAt: turnStartedAt[threadId]
        )
        publish()
    }

    private func beginTurnIfNeeded(threadId: String) {
        if turnStartedAt[threadId] == nil {
            turnStartedAt[threadId] = now()
        }
    }

    private func endTurn(threadId: String) {
        turnStartedAt.removeValue(forKey: threadId)
    }

    private func recordSuccessfulUpdate() {
        lastSuccessfulUpdateAt = now()
        if connectionState != .incompatible {
            connectionState = .online
            connectionIssueCode = nil
            staleGeneration = nil
        }
    }

    private func publish() {
        let value = PetStatusAggregator.aggregate(
            Array(statuses.values),
            connectionState: connectionState,
            lastSuccessfulUpdateAt: lastSuccessfulUpdateAt,
            lastDisconnectAt: lastDisconnectAt,
            connectionIssueCode: connectionIssueCode,
            filteredInternalCount: filteredInternalCount,
            initialScanComplete: initialScanComplete
        )
        onChange?(value)
    }
}
