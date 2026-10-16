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
expect(failedWhileWorking.activityLabel == "工作中", "Active work must keep the primary label")

let staleSystemErrorWhileWorking = PetStatusAggregator.aggregate(
    [
        ThreadPetStatus(threadId: "current", state: .working(nil), updatedAt: now),
        ThreadPetStatus(threadId: "old", state: .systemError, updatedAt: now.addingTimeInterval(-3600))
    ],
    connected: true
)
expect(staleSystemErrorWhileWorking.state == .working(nil), "A stale system error must not hide active work")
expect(staleSystemErrorWhileWorking.activityLabel == "工作中", "Stale errors must not replace the work summary")
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
expect(workingLabel == "工作中", "Activity detail must not replace the primary working state")
expect(PetState.idle.label == "空闲", "Idle label must stay concise")
expect(PetState.waitingApproval.label == "待确认", "Approval label must stay concise")
expect(PetState.waitingInput.label == "待回复", "Input label must stay concise")
expect(PetState.completed.label == "已完成", "Completed label must stay concise")
expect(PetState.interrupted.label == "已停止", "Interrupted label must stay concise")
expect(PetState.failed.label == "失败", "Failure label must stay concise")
expect(PetState.systemError.label == "系统异常", "System-error label must stay concise")
expect(PetState.connecting.label == "连接中", "Connecting label must stay concise")
expect(PetState.disconnected.label == "未连接", "Disconnected label must stay concise")
expect(!PetState.idle.color.isEqual(PetState.working(nil).color), "Idle and working must use different visual colors")
expect(!PetState.disconnected.color.isEqual(PetState.connecting.color), "Disconnected and connecting must use different visual colors")
expect(!PetState.interrupted.color.isEqual(PetState.failed.color), "Stopped and failed must use different visual colors")
expect(PetState.idle.compactBackgroundColor.alphaComponent == 0, "Idle compact background must be transparent")
expect(PetState.working(nil).compactBackgroundColor.alphaComponent > 0, "Working compact background must be colored")
expect(!PetState.disconnected.compactBackgroundColor.isEqual(PetState.connecting.compactBackgroundColor), "Compact backgrounds must distinguish disconnected and connecting")
expect(!CodexConnectionState.online.color.isEqual(PetState.working(nil).color), "Online and working must use independent colors")

let defaultSettings = AppSettings()
expect(defaultSettings.shouldAutoExpand, "Auto-expand must be enabled by default")
expect(defaultSettings.keepCompactPet, "Compact pet must be retained by default")
expect(
    defaultSettings.effectiveMotion(systemReduceMotion: false) == .standard,
    "Follow-system motion must animate when Reduce Motion is off"
)
expect(
    defaultSettings.effectiveMotion(systemReduceMotion: true) == .staticOnly,
    "Follow-system motion must become static when Reduce Motion is on"
)
var standardMotionSettings = defaultSettings
standardMotionSettings.motionPreference = .standard
expect(
    standardMotionSettings.effectiveMotion(systemReduceMotion: true) == .staticOnly,
    "System Reduce Motion must override the standard animation preference"
)

var quietSettings = defaultSettings
quietSettings.quietMode = true
expect(!quietSettings.shouldAutoExpand, "Quiet mode must suppress auto-expand")
expect(
    quietSettings.effectiveMotion(systemReduceMotion: false) == .staticOnly,
    "Quiet mode must suppress pet motion"
)
expect(
    !quietSettings.shouldPlayCompletionAndWaitingPrompts,
    "Quiet mode must suppress completion and waiting prompts"
)

let defaultsSuite = "CodexTouchPetTests.\(UUID().uuidString)"
guard let testDefaults = UserDefaults(suiteName: defaultsSuite) else {
    fputs("FAIL: Unable to create isolated UserDefaults suite\n", stderr)
    exit(1)
}
defer { testDefaults.removePersistentDomain(forName: defaultsSuite) }
let settingsStore = AppSettingsStore(defaults: testDefaults)
expect(settingsStore.load() == defaultSettings, "Missing preferences must load product defaults")
let persistedSettings = AppSettings(
    autoExpand: false,
    keepCompactPet: false,
    quietMode: true,
    motionPreference: .staticOnly,
    completionAndWaitingPrompts: false
)
settingsStore.save(persistedSettings)
expect(settingsStore.load() == persistedSettings, "All settings must survive a UserDefaults round trip")

let ordered = PetStatusAggregator.aggregate(
    [
        ThreadPetStatus(threadId: "idle", state: .idle, updatedAt: now),
        ThreadPetStatus(threadId: "waiting", state: .waitingInput, updatedAt: now),
        ThreadPetStatus(threadId: "working", state: .working(.tool), updatedAt: now)
    ],
    connected: true
)
expect(ordered.tasks.map(\.threadId) == ["waiting", "working", "idle"], "Tasks must be ordered by state priority")
expect(ordered.touchBarTasks.map(\.threadId) == ["waiting", "working"], "Task rail must exclude inactive tasks")
expect(ordered.connectionState == .online, "Task state must not replace an established online connection")

let titledTask = ThreadPetStatus(
    threadId: "precise-thread-id",
    state: .working(nil),
    updatedAt: now,
    title: "  Touch   Bar 狐狸动画优化  "
)
expect(titledTask.displayTitle == "Touch Bar 狐狸动画优化", "Task titles must normalize whitespace")
expect(titledTask.abbreviatedTitle() == "狐狸动画优化", "Task chips must use a semantic display title")
expect(
    ThreadPetStatus(
        threadId: "hub",
        state: .working(nil),
        updatedAt: now,
        title: "为什么我的电脑上的 hub 没有东西展示了"
    ).abbreviatedTitle() == "Hub 显示异常",
    "Task chips must keep the semantic object and issue"
)
expect(
    ThreadPetStatus(
        threadId: "zentao",
        state: .working(nil),
        updatedAt: now,
        title: "阅读一下禅道需求2322"
    ).abbreviatedTitle() == "禅道需求 2322",
    "Task chips must preserve requirement identifiers"
)
expect(
    ThreadPetStatus(threadId: "untitled", state: .working(nil), updatedAt: now).displayTitle == "未命名任务",
    "A missing title must not pretend to be the current task"
)
expect(
    CodexThreadLink.url(threadID: " precise-thread-id ")?.absoluteString
        == "codex://threads/precise-thread-id?hostId=local",
    "Task links must preserve the exact thread identity"
)
expect(CodexThreadLink.url(threadID: "  ") == nil, "Blank thread IDs must not create links")

let onlineConnectingTask = PetStatusAggregator.aggregate(
    [ThreadPetStatus(threadId: "loading", state: .connecting, updatedAt: now)],
    connected: true,
    initialScanComplete: true
)
expect(
    onlineConnectingTask.connectionState == .online,
    "A loading task must not downgrade an established online connection"
)

let idleWithFilteredInternals = PetStatusAggregator.aggregate(
    [],
    connectionState: .online,
    filteredInternalCount: 3,
    initialScanComplete: true
)
expect(
    idleWithFilteredInternals.filteredInternalCount == 3,
    "Idle diagnostics must retain the anonymous filtered-internal count"
)

let daytime = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: now) ?? now
let nighttime = Calendar.current.date(bySettingHour: 23, minute: 0, second: 0, of: now) ?? now
let idleTravel = PetActivityLayout.travel(wideIdle: true)
expect(PetActivityLayout.statusWidth(wideIdle: true) >= 82, "Online status must remain visible beside wide idle playfield")
expect(PetActivityLayout.statusWidth(wideIdle: false) >= 390, "Task rail must retain its usable width")
expect(idleTravel >= 230, "The empty idle layout must provide a wide playfield")

var wideRangeDirector = PetIdleActivityDirector(seed: 0xC0D3_5EED)
let wideRangeMotions = stride(from: 0.0, through: 240.0, by: 1.0 / 30).map { time in
    wideRangeDirector.motion(at: time, travel: idleTravel, date: daytime)
}
let visitedX = wideRangeMotions.map(\.x)
let visitedSpan = (visitedX.max() ?? 0) - (visitedX.min() ?? 0)
expect(visitedSpan >= 400, "Idle pet must traverse most of the empty expanded Touch Bar")
expect(
    wideRangeMotions.prefix(60).allSatisfy { abs($0.x) < 0.01 },
    "Idle entry must settle briefly before the first routine"
)
expect(
    wideRangeMotions.prefix(240).contains { abs($0.x) > 30 },
    "The first visible excursion must start within eight seconds"
)
expect(
    Set(wideRangeMotions.compactMap(\.routine)).count == 4,
    "An idle session must show all four activity routines"
)
expect(
    Set(wideRangeMotions.map(\.activity)).isSuperset(of: [.run, .jump, .play, .inspect, .stretch, .nap]),
    "Routines must include running, jumping, tail play, inspection and recovery"
)

var seenRoutines: [PetIdleActivityDirector.Routine] = []
var lastRoutineID = 0
var jumpSegments = Set<Int>()
for (previous, motion) in zip(wideRangeMotions, wideRangeMotions.dropFirst()) {
    expect(abs(motion.x) <= idleTravel + 0.001, "Idle motion must stay inside its playfield")
    expect(abs(motion.x - previous.x) <= 5.6, "Idle position must remain continuous at 30Hz")
    expect(motion.y == 0 && motion.rotation == 0, "Sprite actions must not receive a second floating transform")
    if previous.segmentID == motion.segmentID {
        let delta = motion.x - previous.x
        if motion.activity == .run, abs(delta) > 0.001 {
            expect(
                (delta < 0 && motion.direction == .left) || (delta > 0 && motion.direction == .right),
                "Running artwork must face the direction of travel"
            )
        } else if motion.activity != .run {
            expect(abs(delta) < 0.001, "Gestures must stay grounded at their arrival position")
        }
    }
    if let routine = motion.routine, motion.routineID != lastRoutineID {
        seenRoutines.append(routine)
        lastRoutineID = motion.routineID
    }
    if motion.activity == .jump { jumpSegments.insert(motion.segmentID) }
}
expect(jumpSegments.count >= 2, "Repeated jump actions must be separate replayable segments")
expect(seenRoutines.count >= 8, "Idle play must continue after the first round")
expect(
    zip(seenRoutines, seenRoutines.dropFirst()).allSatisfy { $0 != $1 },
    "The dispatcher must not immediately repeat the same routine"
)

for seed in 1...8 {
    var director = PetIdleActivityDirector(seed: UInt64(seed))
    var previous = director.motion(at: 0, travel: idleTravel, date: daytime)
    for time in stride(from: 1.0 / 30, through: 180.0, by: 1.0 / 30) {
        let motion = director.motion(at: time, travel: idleTravel, date: seed % 2 == 0 ? nighttime : daytime)
        expect(abs(motion.x) <= idleTravel + 0.001, "Seeded day/night routines must remain bounded")
        expect(abs(motion.x - previous.x) <= 5.6, "Random routine boundaries must not teleport")
        previous = motion
    }
}

var resumedDirector = PetIdleActivityDirector(seed: 9)
var lastVisible = resumedDirector.motion(at: 0, travel: idleTravel, date: daytime)
for time in stride(from: 1.0 / 30, through: 4.0, by: 1.0 / 30) {
    lastVisible = resumedDirector.motion(at: time, travel: idleTravel, date: daytime)
}
let resumed = resumedDirector.motion(at: 124, travel: idleTravel, date: daytime)
expect(abs(resumed.x - lastVisible.x) < 0.001, "A suspended timer must resume at the last visible position")
expect(resumed.segmentID == lastVisible.segmentID && abs(resumed.elapsed - lastVisible.elapsed) < 0.001, "Suspension must preserve the running segment clock")
resumedDirector.reset()
let resetMotion = resumedDirector.motion(at: 125, travel: idleTravel, date: daytime)
expect(resetMotion.x == 0 && resetMotion.activity == .wander, "Task interruption/reset must restore the centered idle entry")

var jumpResumeDirector = PetIdleActivityDirector(seed: 0xC0D3_5EED)
var sampledMidJump = false
for time in stride(from: 0.0, through: 120.0, by: 1.0 / 30) {
    let motion = jumpResumeDirector.motion(at: time, travel: idleTravel, date: daytime)
    guard motion.activity == .jump, motion.elapsed >= 0.5 else { continue }
    let afterSleep = jumpResumeDirector.motion(at: time + 120, travel: idleTravel, date: daytime)
    expect(afterSleep.activity == .jump && afterSleep.segmentID == motion.segmentID, "Sleep must not restart or discard an in-flight jump")
    expect(abs(afterSleep.elapsed - motion.elapsed) < 0.001 && abs(afterSleep.x - motion.x) < 0.001, "Sleep must preserve both jump pose time and anchor")
    sampledMidJump = true
    break
}
expect(sampledMidJump, "The suspension regression must actually sample an in-flight jump")
print("PET_IDLE_ROUTINES_OK (4 routines, span=\(Int(visitedSpan))pt, 8 day/night seeds)")

var healthClock = now
var scheduledHealthActions: [() -> Void] = []
var healthStatus: AggregatePetStatus?
let healthStore = ThreadStatusStore(
    now: { healthClock },
    reconnectGracePeriod: 8,
    schedule: { _, action in scheduledHealthActions.append(action) }
)
healthStore.onChange = { healthStatus = $0 }
healthStore.markConnected()
healthStore.updateTurn(threadId: "health", status: "inProgress")
healthClock = now.addingTimeInterval(3)
healthStore.markDisconnected(issueCode: "connection_closed")
expect(healthStatus?.connectionState == .reconnecting, "A recent disconnect must enter reconnecting")
expect(healthStatus?.activeCount == 1, "Reconnect grace must preserve the last task snapshot")
expect(scheduledHealthActions.count == 1, "A disconnect after a successful update must schedule staleness")
healthClock = now.addingTimeInterval(5)
healthStore.markDisconnected(issueCode: "socket_connect_2")
expect(scheduledHealthActions.count == 1, "Repeated retries must not extend the reconnect grace period")
scheduledHealthActions.removeFirst()()
expect(healthStatus?.connectionState == .stale, "Reconnect grace expiry must mark the snapshot stale")
healthStore.beginManualReconnect()
expect(healthStatus?.connectionState == .reconnecting, "Manual reconnect from stale must show reconnecting")
healthClock = now.addingTimeInterval(9)
healthStore.markConnected()
expect(healthStatus?.connectionState == .online, "A successful reconnect must restore online health")
expect(healthStatus?.activeCount == 1, "Reconnect recovery must preserve tracked task state")

let neverConnectedStore = ThreadStatusStore(
    now: { now },
    schedule: { _, _ in fatalError("Initial disconnect must not schedule a stale transition") }
)
var neverConnectedStatus: AggregatePetStatus?
neverConnectedStore.onChange = { neverConnectedStatus = $0 }
neverConnectedStore.beginConnecting()
expect(neverConnectedStatus?.connectionState == .connecting, "Startup must publish a connecting state")
neverConnectedStore.markDisconnected(issueCode: "socket_connect_2")
expect(neverConnectedStatus?.connectionState == .disconnected, "Initial connection failure must be disconnected")
neverConnectedStore.markIncompatible(issueCode: "initialize_rejected")
expect(neverConnectedStatus?.connectionState == .incompatible, "Protocol rejection must be incompatible")

var clock = now
var latestStatus: AggregatePetStatus?
let runtimeStore = ThreadStatusStore(now: { clock })
runtimeStore.onChange = { latestStatus = $0 }
runtimeStore.setConnected(true)
runtimeStore.updateTurn(threadId: "runtime", status: "inProgress")
let firstTurnStart = latestStatus?.tasks.first?.startedAt
expect(firstTurnStart == now, "A turn must start timing when processing begins")

clock = now.addingTimeInterval(12)
runtimeStore.updateActivity(threadId: "runtime", activity: .tool)
expect(latestStatus?.tasks.first?.startedAt == firstTurnStart, "Tool activity must not reset the turn timer")

clock = now.addingTimeInterval(24)
runtimeStore.updateRuntime(threadId: "runtime", type: "active", activeFlags: ["waitingOnApproval"])
expect(latestStatus?.tasks.first?.startedAt == firstTurnStart, "Waiting for approval must preserve the turn timer")

clock = now.addingTimeInterval(36)
runtimeStore.updateRuntime(threadId: "runtime", type: "active")
expect(latestStatus?.tasks.first?.startedAt == firstTurnStart, "Resuming the same turn must preserve its original timer")

clock = now.addingTimeInterval(48)
runtimeStore.updateTurn(threadId: "runtime", status: "completed")
expect(latestStatus?.tasks.first?.startedAt == nil, "A completed turn must stop its timer")
let completionState = latestStatus?.state
runtimeStore.updateTurn(threadId: "runtime", status: "completed")
expect(latestStatus?.state == completionState, "Repeated terminal events must not replay completion state")

clock = now.addingTimeInterval(60)
runtimeStore.updateTurn(threadId: "runtime", status: "inProgress")
expect(latestStatus?.tasks.first?.startedAt == clock, "A new turn must receive a new start time")

print("PET_STATE_TESTS_OK")
