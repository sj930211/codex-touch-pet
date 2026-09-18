import XCTest
@testable import CodexTouchPet

final class PetStateTests: XCTestCase {
    func testDisconnectedWinsWhenIPCIsUnavailable() {
        let status = PetStatusAggregator.aggregate(
            [ThreadPetStatus(threadId: "1", state: .working(nil), updatedAt: Date())],
            connected: false
        )
        XCTAssertEqual(status.state, .disconnected)
    }

    func testIdleAfterInitialScanWithNoActiveThreads() {
        let status = PetStatusAggregator.aggregate(
            [],
            connected: true,
            initialScanComplete: true
        )
        XCTAssertEqual(status.state, .idle)
    }

    func testWaitingApprovalOutranksWorkingAndCompleted() {
        let now = Date()
        let status = PetStatusAggregator.aggregate(
            [
                ThreadPetStatus(threadId: "1", state: .working(.command), updatedAt: now),
                ThreadPetStatus(threadId: "2", state: .completed, updatedAt: now),
                ThreadPetStatus(threadId: "3", state: .waitingApproval, updatedAt: now)
            ],
            connected: true
        )
        XCTAssertEqual(status.state, .waitingApproval)
        XCTAssertEqual(status.activeCount, 1)
        XCTAssertEqual(status.waitingCount, 1)
        XCTAssertEqual(status.countLabel, "1 待处理 · 1 运行中")
        XCTAssertEqual(status.activityLabel, "正在处理 1 项工作 · 1 项待处理")
    }

    func testMultipleWorkingTasksUseSummaryInsteadOfPager() {
        let now = Date()
        let status = PetStatusAggregator.aggregate(
            [
                ThreadPetStatus(threadId: "1", state: .working(nil), updatedAt: now),
                ThreadPetStatus(threadId: "2", state: .working(.tool), updatedAt: now)
            ],
            connected: true
        )
        XCTAssertEqual(status.activityLabel, "正在处理 2 项工作")
    }

    func testHistoricalFailureDoesNotHideActiveWork() {
        let now = Date()
        let status = PetStatusAggregator.aggregate(
            [
                ThreadPetStatus(threadId: "1", state: .working(nil), updatedAt: now),
                ThreadPetStatus(threadId: "2", state: .failed, updatedAt: now)
            ],
            connected: true
        )
        XCTAssertEqual(status.state, .working(nil))
        XCTAssertEqual(status.activityLabel, "Codex 正在工作")
    }

    func testSystemErrorHasHighestPriority() {
        let now = Date()
        let status = PetStatusAggregator.aggregate(
            [
                ThreadPetStatus(threadId: "1", state: .waitingInput, updatedAt: now),
                ThreadPetStatus(threadId: "2", state: .systemError, updatedAt: now)
            ],
            connected: true
        )
        XCTAssertEqual(status.state, .systemError)
    }

    func testStaleSystemErrorDoesNotHideActiveWork() {
        let now = Date()
        let status = PetStatusAggregator.aggregate(
            [
                ThreadPetStatus(threadId: "current", state: .working(nil), updatedAt: now),
                ThreadPetStatus(threadId: "old", state: .systemError, updatedAt: now.addingTimeInterval(-3600))
            ],
            connected: true
        )
        XCTAssertEqual(status.state, .working(nil))
        XCTAssertEqual(status.activityLabel, "Codex 正在工作")
        XCTAssertTrue(status.tasks.contains(where: { $0.state == .systemError }))
    }

    func testWorkingLabelDoesNotExposeActivityAsPrimaryState() {
        XCTAssertEqual(PetState.working(.tool).label, "Codex 正在工作")
    }

    func testTasksAreOrderedForCarousel() {
        let now = Date()
        let status = PetStatusAggregator.aggregate(
            [
                ThreadPetStatus(threadId: "idle", state: .idle, updatedAt: now),
                ThreadPetStatus(threadId: "waiting", state: .waitingInput, updatedAt: now),
                ThreadPetStatus(threadId: "working", state: .working(.tool), updatedAt: now)
            ],
            connected: true
        )
        XCTAssertEqual(status.tasks.map(\.threadId), ["waiting", "working", "idle"])
        XCTAssertEqual(status.carouselTasks.map(\.threadId), ["waiting", "working"])
    }
}
