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
        case .disconnected: return "未连接"
        case .connecting: return "连接中"
        case .idle: return "空闲"
        case .working: return "工作中"
        case .waitingApproval: return "待确认"
        case .waitingInput: return "待回复"
        case .completed: return "已完成"
        case .interrupted: return "已停止"
        case .failed: return "失败"
        case .systemError: return "系统异常"
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
        case .disconnected:
            // A disconnected client is not an error in the current task. Use a
            // muted indigo so it is distinct from both a stopped task and a
            // transient connection attempt.
            return NSColor(calibratedRed: 0.58, green: 0.50, blue: 0.74, alpha: 1)
        case .interrupted:
            return .secondaryLabelColor
        case .connecting:
            // Amber communicates "in progress" without borrowing the red
            // reserved for an actual failure.
            return NSColor(calibratedRed: 0.95, green: 0.70, blue: 0.24, alpha: 1)
        case .idle:
            // Idle is intentionally neutral; blue is reserved for active work.
            return .labelColor
        case .working:
            return NSColor(calibratedRed: 0.30, green: 0.86, blue: 1.00, alpha: 1)
        case .waitingApproval, .waitingInput:
            return .systemOrange
        case .completed:
            return .systemGreen
        case .failed, .systemError:
            return .systemRed
        }
    }

    /// Background color for the compact Control Strip entry. The approved fox
    /// artwork stays full-color; only its surrounding button communicates the
    /// semantic state color.
    var compactBackgroundColor: NSColor {
        switch self {
        case .idle:
            return .clear
        case .working:
            return NSColor(calibratedRed: 0.08, green: 0.52, blue: 0.66, alpha: 0.72)
        case .connecting:
            return NSColor(calibratedRed: 0.63, green: 0.40, blue: 0.05, alpha: 0.72)
        case .disconnected:
            return NSColor(calibratedRed: 0.35, green: 0.27, blue: 0.52, alpha: 0.72)
        case .waitingApproval, .waitingInput:
            return NSColor(calibratedRed: 0.70, green: 0.35, blue: 0.04, alpha: 0.72)
        case .completed:
            return NSColor(calibratedRed: 0.08, green: 0.48, blue: 0.24, alpha: 0.72)
        case .interrupted:
            return NSColor(calibratedWhite: 0.28, alpha: 0.72)
        case .failed, .systemError:
            return NSColor(calibratedRed: 0.65, green: 0.10, blue: 0.12, alpha: 0.78)
        }
    }

}

enum PetAnimationIdentity: Equatable {
    case disconnected
    case connecting
    case idle
    case working
    case waitingApproval
    case waitingInput
    case completed
    case interrupted
    case failed
    case systemError
}

extension PetState {
    var animationIdentity: PetAnimationIdentity {
        switch self {
        case .disconnected: return .disconnected
        case .connecting: return .connecting
        case .idle: return .idle
        case .working: return .working
        case .waitingApproval: return .waitingApproval
        case .waitingInput: return .waitingInput
        case .completed: return .completed
        case .interrupted: return .interrupted
        case .failed: return .failed
        case .systemError: return .systemError
        }
    }
}

enum CodexConnectionState: Equatable {
    case disconnected
    case connecting
    case reconnecting
    case stale
    case incompatible
    case online

    var label: String {
        switch self {
        case .disconnected: return "● 未连接"
        case .connecting: return "● 连接中"
        case .reconnecting: return "● 重连中"
        case .stale: return "● 已过期"
        case .incompatible: return "● 不兼容"
        case .online: return "● 在线"
        }
    }

    var color: NSColor {
        switch self {
        case .disconnected: return PetState.disconnected.color
        case .connecting: return PetState.connecting.color
        case .reconnecting: return PetState.connecting.color
        case .stale: return .secondaryLabelColor
        case .incompatible: return PetState.disconnected.color
        case .online: return .systemGreen
        }
    }

    var diagnosticLabel: String {
        switch self {
        case .disconnected: return "未连接"
        case .connecting: return "连接中"
        case .reconnecting: return "重连中"
        case .stale: return "状态已过期"
        case .incompatible: return "IPC 不兼容"
        case .online: return "正常"
        }
    }

    var compactBackgroundColor: NSColor? {
        switch self {
        case .reconnecting:
            return NSColor(calibratedRed: 0.63, green: 0.40, blue: 0.05, alpha: 0.72)
        case .stale:
            return NSColor(calibratedWhite: 0.28, alpha: 0.72)
        case .incompatible:
            return NSColor(calibratedRed: 0.35, green: 0.27, blue: 0.52, alpha: 0.72)
        case .disconnected, .connecting, .online:
            return nil
        }
    }
}

struct ThreadPetStatus: Equatable {
    let threadId: String
    var state: PetState
    var updatedAt: Date
    var title: String = ""
    var startedAt: Date? = nil

    var displayTitle: String {
        let normalized = title
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return normalized.isEmpty ? "未命名任务" : normalized
    }

    /// Produces a short, deterministic label for the Touch Bar. The label is
    /// deliberately semantic rather than a raw prefix: conversation titles
    /// are often full user prompts, so the first seven characters can be
    /// meaningless (for example, "为什么我的电脑上的…").
    func abbreviatedTitle(maxCharacters: Int = 12) -> String {
        let normalized = Self.cleanTitle(displayTitle)
        guard !normalized.isEmpty else { return "未命名任务" }
        let latinTokens = Self.matches("[A-Za-z][A-Za-z0-9._-]{2,}", in: normalized)
            .filter { !Self.titleStopWords.contains($0.lowercased()) }
        let numberTokens = Self.matches("\\d{2,}", in: normalized)
        let cjkChunks = Self.matches("[\\p{Han}]{2,}", in: normalized)
            .filter { !Self.cjkStopWords.contains($0) }

        let issue = Self.issueLabel(in: normalized)
        let action = Self.actionLabel(in: normalized)
        let project = latinTokens.first.map(Self.displayLatinToken)
        let numberedRequirement = Self.requirementLabel(
            cjkChunks: cjkChunks,
            numbers: numberTokens
        )

        let candidate: String
        if let numberedRequirement {
            candidate = numberedRequirement
        } else if let project, let issue {
            candidate = "\(project) \(issue)"
        } else if let project, let action {
            candidate = "\(action) \(project)"
        } else if let project {
            candidate = project
        } else if let action, let object = cjkChunks.first {
            candidate = object.contains(action) ? object : "\(action)\(object)"
        } else if let object = cjkChunks.max(by: { $0.count < $1.count }) {
            candidate = object
        } else if let issue {
            candidate = issue
        } else {
            candidate = normalized
        }

        return Self.fit(candidate, maxCharacters: maxCharacters)
    }

    private static let titleStopWords: Set<String> = [
        "the", "this", "that", "with", "from", "into", "about", "please",
        "touch", "bar", "macos", "mac", "codex", "chatgpt", "html", "svg"
    ]

    private static let cjkStopWords: Set<String> = [
        "为什么", "怎么", "如何", "一下", "现在", "已经", "还是", "可以", "需要",
        "帮我", "请你", "请帮我", "我想", "我需要", "这个项目", "这个问题", "有没有",
        "能够", "能不能", "是否", "的话", "然后", "继续", "再试试"
    ]

    private static func cleanTitle(_ title: String) -> String {
        var value = title
        value = value.replacingOccurrences(
            of: "\\[([^\\]]+)\\]\\([^\\)]+\\)",
            with: "$1",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: "https?://[^\\s)]+",
            with: " ",
            options: .regularExpression
        )
        value = value.components(separatedBy: .newlines).first ?? value
        value = value.replacingOccurrences(
            of: "^\\s*(?:帮我|请帮我|请你|请|麻烦|能不能|可以帮我|我想|我需要|继续|再试试|先|现在|然后|接下来|查看一下|阅读一下|检查一下|排查一下|分析一下|实现一下|创建一个|创建|开发一个|开发|写一个|写)\\s*",
            with: "",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: "[，。！？；：,!?;:()（）【】\\[\\]<>《》]+",
            with: " ",
            options: .regularExpression
        )
        value = value.replacingOccurrences(
            of: "\\s+",
            with: " ",
            options: .regularExpression
        )
        return value.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func matches(_ pattern: String, in value: String) -> [String] {
        guard let expression = try? NSRegularExpression(pattern: pattern) else { return [] }
        let range = NSRange(value.startIndex..<value.endIndex, in: value)
        return expression.matches(in: value, range: range).compactMap { match in
            guard let matchRange = Range(match.range, in: value) else { return nil }
            return String(value[matchRange])
        }
    }

    private static func issueLabel(in value: String) -> String? {
        if value.range(of: "网络|连接|域名|DNS", options: .regularExpression) != nil,
           value.range(of: "失败|错误|异常|无法|不能|报错", options: .regularExpression) != nil {
            return "网络错误"
        }
        if value.range(of: "卡顿|卡住|延迟|慢", options: .regularExpression) != nil {
            return "卡顿"
        }
        if value.range(of: "显示|展示|界面", options: .regularExpression) != nil,
           value.range(of: "没有|无|异常|错误|失败|不见|看不到|无法", options: .regularExpression) != nil {
            return "显示异常"
        }
        if value.range(of: "报错|错误|异常|失败|崩溃", options: .regularExpression) != nil {
            return "错误"
        }
        if value.range(of: "动画", options: .regularExpression) != nil {
            return "动画"
        }
        return nil
    }

    private static func actionLabel(in value: String) -> String? {
        if value.range(of: "拆分|拆解|迁移", options: .regularExpression) != nil { return "拆分" }
        if value.range(of: "修复|解决", options: .regularExpression) != nil { return "修复" }
        if value.range(of: "排查|诊断|检查", options: .regularExpression) != nil { return "排查" }
        if value.range(of: "创建|开发|编写|写", options: .regularExpression) != nil { return "创建" }
        if value.range(of: "设计|规划|优化", options: .regularExpression) != nil { return "优化" }
        return nil
    }

    private static func requirementLabel(cjkChunks: [String], numbers: [String]) -> String? {
        guard let number = numbers.first,
              cjkChunks.contains(where: { $0.contains("需求") || $0.contains("禅道") }) else {
            return nil
        }
        return "禅道需求 \(number)"
    }

    private static func displayLatinToken(_ token: String) -> String {
        guard !token.contains("-") && !token.contains("_") && !token.contains(".") else {
            return token
        }
        guard let first = token.first else { return token }
        return String(first).uppercased() + String(token.dropFirst())
    }

    private static func fit(_ value: String, maxCharacters: Int) -> String {
        let compact = value.trimmingCharacters(in: .whitespacesAndNewlines)
        guard maxCharacters > 1, compact.count > maxCharacters else { return compact }
        let limit = maxCharacters - 1
        return String(compact.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }
}

typealias PetTaskStatus = ThreadPetStatus

struct AggregatePetStatus: Equatable {
    var state: PetState
    var connectionState: CodexConnectionState
    var lastSuccessfulUpdateAt: Date? = nil
    var lastDisconnectAt: Date? = nil
    var connectionIssueCode: String? = nil
    var filteredInternalCount: Int? = nil
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
                : "工作中"
        }
        if waitingCount > 1 {
            return "\(waitingCount) 项工作等待你的处理"
        }
        if waitingCount == 1 {
            return "1 项工作等待你的处理"
        }
        return state.label
    }

    var touchBarTasks: [PetTaskStatus] {
        tasks.filter { task in
            switch task.state {
            case .idle, .connecting, .disconnected:
                return false
            default:
                return true
            }
        }
    }

    // Compatibility for the previous summary implementation. New Touch Bar
    // UI should use touchBarTasks, which is a manually scrollable task rail.
    var carouselTasks: [PetTaskStatus] { touchBarTasks }
}

enum PetStatusAggregator {
    static func aggregate(
        _ statuses: [ThreadPetStatus],
        connectionState: CodexConnectionState,
        lastSuccessfulUpdateAt: Date? = nil,
        lastDisconnectAt: Date? = nil,
        connectionIssueCode: String? = nil,
        filteredInternalCount: Int? = nil,
        initialScanComplete: Bool = false
    ) -> AggregatePetStatus {
        if connectionState == .disconnected {
            return AggregatePetStatus(
                state: .disconnected,
                connectionState: .disconnected,
                lastSuccessfulUpdateAt: lastSuccessfulUpdateAt,
                lastDisconnectAt: lastDisconnectAt,
                connectionIssueCode: connectionIssueCode,
                filteredInternalCount: filteredInternalCount,
                activeCount: 0,
                waitingCount: 0,
                trackedCount: 0,
                tasks: []
            )
        }
        if statuses.isEmpty, connectionState != .online {
            return AggregatePetStatus(
                state: connectionState == .connecting ? .connecting : .disconnected,
                connectionState: connectionState,
                lastSuccessfulUpdateAt: lastSuccessfulUpdateAt,
                lastDisconnectAt: lastDisconnectAt,
                connectionIssueCode: connectionIssueCode,
                filteredInternalCount: filteredInternalCount,
                activeCount: 0,
                waitingCount: 0,
                trackedCount: 0,
                tasks: []
            )
        }
        guard !statuses.isEmpty else {
            return AggregatePetStatus(
                state: initialScanComplete ? .idle : .connecting,
                connectionState: connectionState,
                lastSuccessfulUpdateAt: lastSuccessfulUpdateAt,
                lastDisconnectAt: lastDisconnectAt,
                connectionIssueCode: connectionIssueCode,
                filteredInternalCount: filteredInternalCount,
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
            connectionState: connectionState,
            lastSuccessfulUpdateAt: lastSuccessfulUpdateAt,
            lastDisconnectAt: lastDisconnectAt,
            connectionIssueCode: connectionIssueCode,
            filteredInternalCount: filteredInternalCount,
            activeCount: activeCount,
            waitingCount: waitingCount,
            trackedCount: statuses.count,
            tasks: sorted
        )
    }

    static func aggregate(
        _ statuses: [ThreadPetStatus],
        connected: Bool,
        initialScanComplete: Bool = false
    ) -> AggregatePetStatus {
        aggregate(
            statuses,
            connectionState: connected ? .online : .disconnected,
            initialScanComplete: initialScanComplete
        )
    }
}
