import Foundation

final class ThreadStatusStore {
    var onChange: ((AggregatePetStatus) -> Void)?

    private var statuses: [String: ThreadPetStatus] = [:]
    private var transientGeneration: [String: UUID] = [:]
    private var activityGeneration: [String: UUID] = [:]
    private var connected = false
    private var initialScanComplete = false

    func setConnected(_ value: Bool) {
        dispatchPrecondition(condition: .onQueue(.main))
        connected = value
        if !value {
            statuses.removeAll()
            transientGeneration.removeAll()
            activityGeneration.removeAll()
            initialScanComplete = false
        }
        publish()
    }

    func finishInitialScan() {
        dispatchPrecondition(condition: .onQueue(.main))
        initialScanComplete = true
        publish()
    }

    func removeThread(_ threadId: String) {
        dispatchPrecondition(condition: .onQueue(.main))
        statuses.removeValue(forKey: threadId)
        transientGeneration.removeValue(forKey: threadId)
        activityGeneration.removeValue(forKey: threadId)
        publish()
    }

    func updateRuntime(threadId: String, type: String, activeFlags: [String] = []) {
        dispatchPrecondition(condition: .onQueue(.main))
        transientGeneration.removeValue(forKey: threadId)
        activityGeneration.removeValue(forKey: threadId)
        let state: PetState
        switch type {
        case "notLoaded":
            state = .connecting
        case "idle":
            state = .idle
        case "systemError":
            state = .systemError
        case "active":
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
        activityGeneration.removeValue(forKey: threadId)
        switch status {
        case "inProgress":
            setState(.working(nil), threadId: threadId)
        case "completed":
            setTransient(.completed, fallback: .idle, threadId: threadId, delay: 3)
        case "interrupted":
            setTransient(.interrupted, fallback: .idle, threadId: threadId, delay: 2)
        case "failed":
            transientGeneration.removeValue(forKey: threadId)
            setState(.failed, threadId: threadId)
        default:
            break
        }
    }

    func updateActivity(threadId: String, activity: WorkActivity) {
        dispatchPrecondition(condition: .onQueue(.main))
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
        statuses[threadId] = ThreadPetStatus(
            threadId: threadId,
            state: state,
            updatedAt: Date()
        )
        publish()
    }

    private func publish() {
        let value = PetStatusAggregator.aggregate(
            Array(statuses.values),
            connected: connected,
            initialScanComplete: initialScanComplete
        )
        onChange?(value)
    }
}
