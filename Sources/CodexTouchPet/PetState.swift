import AppKit

enum WorkActivity: String, Equatable {
    case thinking
    case command
    case editing
    case tool
    case search
    case collaboration
    case compacting
    case review

    var label: String {
        switch self {
        case .thinking: return "思考中"
        case .command: return "执行命令"
        case .editing: return "修改文件"
        case .tool: return "调用工具"
        case .search: return "搜索中"
        case .collaboration: return "协作中"
        case .compacting: return "整理上下文"
        case .review: return "审查中"
        }
    }
}

enum PetState: Equatable {
    case disconnected
    case connecting
    case idle
    case working(WorkActivity?)
    case waitingApproval
    case waitingInput
    case completed
    case interrupted
    case failed
    case systemError

    var priority: Int {
        switch self {
        case .systemError: return 100
        case .failed: return 95
        case .waitingApproval: return 90
        case .waitingInput: return 85
        case .completed: return 80
        case .working: return 70
        case .interrupted: return 60
        case .idle: return 50
        case .connecting: return 20
        case .disconnected: return 10
        }
    }

    var label: String {
        switch self {
        case .disconnected: return "Codex 未连接"
        case .connecting: return "正在连接"
        case .idle: return "Codex 空闲"
        case .working: return "Codex 正在工作"
        case .waitingApproval: return "等待你的确认"
        case .waitingInput: return "等待你的回复"
        case .completed: return "任务已完成"
        case .interrupted: return "任务已停止"
        case .failed: return "任务失败"
        case .systemError: return "Codex 系统异常"
        }
    }

    var compactFace: String {
        switch self {
        case .disconnected: return "－ᴥ－"
        case .connecting: return "•ᴥ•…"
        case .idle: return "•ᴥ•"
        case .working: return "•̀ᴥ•́"
        case .waitingApproval: return "•o•!"
        case .waitingInput: return "•ᴥ•?"
        case .completed: return "ᵔᴥᵔ✦"
        case .interrupted: return "－ᴥ－"
        case .failed: return "×ᴥ×"
        case .systemError: return "⚠×ᴥ×"
        }
    }

    var color: NSColor {
        switch self {
        case .disconnected, .interrupted:
            return .secondaryLabelColor
        case .connecting:
            return NSColor(calibratedRed: 0.48, green: 0.62, blue: 0.72, alpha: 1)
        case .idle, .working:
            return NSColor(calibratedRed: 0.30, green: 0.86, blue: 1.00, alpha: 1)
        case .waitingApproval, .waitingInput:
            return .systemOrange
        case .completed:
            return .systemGreen
        case .failed, .systemError:
            return .systemRed
        }
    }

}

struct ThreadPetStatus: Equatable {
    let threadId: String
    var state: PetState
    var updatedAt: Date
}

typealias PetTaskStatus = ThreadPetStatus

struct AggregatePetStatus: Equatable {
    var state: PetState
    var activeCount: Int
    var waitingCount: Int
    var trackedCount: Int
    var tasks: [PetTaskStatus] = []

    var countLabel: String {
        if waitingCount > 0 && activeCount > 0 {
            return "\(waitingCount) 待处理 · \(activeCount) 运行中"
        }
        if waitingCount > 0 {
            return "\(waitingCount) 个待处理"
        }
        if activeCount > 1 {
            return "\(activeCount) 个任务"
        }
        return ""
    }

    /// Human-readable work summary for the Touch Bar. Keep task navigation out
    /// of the primary status so it does not look like a 1/2 pager.
    var activityLabel: String {
        if state == .systemError || state == .failed {
            return state.label
        }
        if activeCount > 1 {
            return waitingCount > 0
                ? "正在处理 \(activeCount) 项工作 · \(waitingCount) 项待处理"
                : "正在处理 \(activeCount) 项工作"
        }
        if activeCount == 1 {
            return waitingCount > 0
                ? "正在处理 1 项工作 · \(waitingCount) 项待处理"
                : "Codex 正在工作"
        }
        if waitingCount > 1 {
            return "\(waitingCount) 项工作等待你的处理"
        }
        if waitingCount == 1 {
            return "1 项工作等待你的处理"
        }
        return state.label
    }

    var carouselTasks: [PetTaskStatus] {
        tasks.filter { task in
            switch task.state {
            case .idle, .connecting, .disconnected:
                return false
            default:
                return true
            }
        }
    }
}

enum PetStatusAggregator {
    static func aggregate(
        _ statuses: [ThreadPetStatus],
        connected: Bool,
        initialScanComplete: Bool = false
    ) -> AggregatePetStatus {
        guard connected else {
            return AggregatePetStatus(
                state: .disconnected,
                activeCount: 0,
                waitingCount: 0,
                trackedCount: 0,
                tasks: []
            )
        }
        guard !statuses.isEmpty else {
            return AggregatePetStatus(
                state: initialScanComplete ? .idle : .connecting,
                activeCount: 0,
                waitingCount: 0,
                trackedCount: 0,
                tasks: []
            )
        }

        let sorted = statuses.sorted { lhs, rhs in
            if lhs.state.priority == rhs.state.priority {
                return lhs.updatedAt > rhs.updatedAt
            }
            return lhs.state.priority > rhs.state.priority
        }
        let activeCount = statuses.filter {
            if case .working = $0.state { return true }
            return false
        }.count
        let waitingCount = statuses.filter {
            $0.state == .waitingApproval || $0.state == .waitingInput
        }.count

        // Runtime snapshots are collected from several recent threads. A
        // historical system error must not hide work that is happening now.
        let highest: PetState
        if activeCount > 0 {
            highest = sorted.first(where: {
                if case .working = $0.state { return true }
                return $0.state == .waitingApproval || $0.state == .waitingInput
            })?.state ?? .working(nil)
        } else {
            highest = sorted.first?.state ?? .idle
        }
        return AggregatePetStatus(
            state: highest,
            activeCount: activeCount,
            waitingCount: waitingCount,
            trackedCount: statuses.count,
            tasks: sorted
        )
    }
}
