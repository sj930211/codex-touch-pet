import Foundation

private func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else {
        fatalError(message)
    }
}

let now = Date()

let disconnected = PetStatusAggregator.aggregate(
    [ThreadPetStatus(threadId: "1", state: .working(nil), updatedAt: now)],
    connected: false
)
expect(disconnected.state == .disconnected, "Disconnected must override cached work")

let idle = PetStatusAggregator.aggregate(
    [],
    connected: true,
    initialScanComplete: true
)
expect(idle.state == .idle, "An empty completed scan should be idle")

let waiting = PetStatusAggregator.aggregate(
    [
        ThreadPetStatus(threadId: "1", state: .working(.command), updatedAt: now),
        ThreadPetStatus(threadId: "2", state: .completed, updatedAt: now),
        ThreadPetStatus(threadId: "3", state: .waitingApproval, updatedAt: now)
    ],
    connected: true
)
expect(waiting.state == .waitingApproval, "Waiting approval must outrank work and completion")
expect(waiting.activeCount == 1, "Active count should include working tasks")
expect(waiting.waitingCount == 1, "Waiting count should include approval tasks")
expect(waiting.countLabel == "1 待处理 · 1 运行中", "Aggregate label mismatch")
expect(waiting.activityLabel == "正在处理 1 项工作 · 1 项待处理", "Activity summary mismatch")

let multipleWorking = PetStatusAggregator.aggregate(
    [
        ThreadPetStatus(threadId: "1", state: .working(nil), updatedAt: now),
        ThreadPetStatus(threadId: "2", state: .working(.tool), updatedAt: now)
    ],
    connected: true
)
expect(multipleWorking.activityLabel == "正在处理 2 项工作", "Multiple-work summary mismatch")

let failedWhileWorking = PetStatusAggregator.aggregate(
    [
        ThreadPetStatus(threadId: "1", state: .working(nil), updatedAt: now),
        ThreadPetStatus(threadId: "2", state: .failed, updatedAt: now)
    ],
    connected: true
)
expect(failedWhileWorking.state == .working(nil), "Historical failure must not hide active work")
expect(failedWhileWorking.activityLabel == "Codex 正在工作", "Active work must keep the primary label")

let staleSystemErrorWhileWorking = PetStatusAggregator.aggregate(
    [
        ThreadPetStatus(threadId: "current", state: .working(nil), updatedAt: now),
        ThreadPetStatus(threadId: "old", state: .systemError, updatedAt: now.addingTimeInterval(-3600))
    ],
    connected: true
)
expect(staleSystemErrorWhileWorking.state == .working(nil), "A stale system error must not hide active work")
expect(staleSystemErrorWhileWorking.activityLabel == "Codex 正在工作", "Stale errors must not replace the work summary")
expect(staleSystemErrorWhileWorking.tasks.contains(where: { $0.state == .systemError }), "Thread errors must remain tracked")

let error = PetStatusAggregator.aggregate(
    [
        ThreadPetStatus(threadId: "1", state: .waitingInput, updatedAt: now),
        ThreadPetStatus(threadId: "2", state: .systemError, updatedAt: now)
    ],
    connected: true
)
expect(error.state == .systemError, "System error must have highest priority")

let workingLabel = PetState.working(.tool).label
expect(workingLabel == "Codex 正在工作", "Activity detail must not replace the primary working state")
expect(!PetState.idle.color.isEqual(PetState.working(nil).color), "Idle and working must use different visual colors")
expect(!PetState.disconnected.color.isEqual(PetState.connecting.color), "Disconnected and connecting must use different visual colors")
expect(!PetState.interrupted.color.isEqual(PetState.failed.color), "Stopped and failed must use different visual colors")
expect(PetState.idle.compactBackgroundColor.alphaComponent == 0, "Idle compact background must be transparent")
expect(PetState.working(nil).compactBackgroundColor.alphaComponent > 0, "Working compact background must be colored")
expect(!PetState.disconnected.compactBackgroundColor.isEqual(PetState.connecting.compactBackgroundColor), "Compact backgrounds must distinguish disconnected and connecting")

let ordered = PetStatusAggregator.aggregate(
    [
        ThreadPetStatus(threadId: "idle", state: .idle, updatedAt: now),
        ThreadPetStatus(threadId: "waiting", state: .waitingInput, updatedAt: now),
        ThreadPetStatus(threadId: "working", state: .working(.tool), updatedAt: now)
    ],
    connected: true
)
expect(ordered.tasks.map(\.threadId) == ["waiting", "working", "idle"], "Tasks must be ordered by state priority")
expect(ordered.carouselTasks.map(\.threadId) == ["waiting", "working"], "Carousel must exclude inactive tasks")

print("PET_STATE_TESTS_OK")
