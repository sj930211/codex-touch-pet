import AppKit

struct DiagnosticSnapshot: Equatable {
    let codexRunning: Bool
    let connectionState: CodexConnectionState
    let lastSuccessfulUpdateAt: Date?
    let activeCount: Int
    let waitingCount: Int
    let trackedCount: Int
    let filteredInternalCount: Int?
    let touchBarAvailable: Bool
    let lastConnectionIssueAt: Date?
    let connectionIssueCode: String?

    var fallbackMode: String {
        touchBarAvailable ? "Touch Bar + 菜单栏" : "仅菜单栏"
    }

    var privacySafeSummary: String {
        let formatter = ISO8601DateFormatter()
        func dateText(_ date: Date?) -> String {
            date.map(formatter.string(from:)) ?? "none"
        }
        return [
            "app=\(AppMetadata.name)",
            "version=\(AppMetadata.version) (\(AppMetadata.build))",
            "codex_running=\(codexRunning)",
            "connection=\(connectionState.diagnosticLabel)",
            "last_success=\(dateText(lastSuccessfulUpdateAt))",
            "active_count=\(activeCount)",
            "waiting_count=\(waitingCount)",
            "tracked_count=\(trackedCount)",
            "filtered_internal_count=\(filteredInternalCount.map(String.init) ?? "unknown")",
            "touch_bar_available=\(touchBarAvailable)",
            "fallback_mode=\(fallbackMode)",
            "last_issue_at=\(dateText(lastConnectionIssueAt))",
            "issue_code=\(connectionIssueCode ?? "none")"
        ].joined(separator: "\n")
    }
}

final class DiagnosticsWindowController: NSWindowController {
    private let onReconnect: () -> Void
    private var snapshot: DiagnosticSnapshot
    private var valueLabels: [String: NSTextField] = [:]
    private weak var copyButton: NSButton?

    init(snapshot: DiagnosticSnapshot, onReconnect: @escaping () -> Void) {
        self.snapshot = snapshot
        self.onReconnect = onReconnect
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 430),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Codex Touch Pet 诊断"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        buildContent()
        update(snapshot: snapshot)
    }

    required init?(coder: NSCoder) {
        fatalError("DiagnosticsWindowController does not support NSCoder initialization")
    }

    func present() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func update(snapshot: DiagnosticSnapshot) {
        self.snapshot = snapshot
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .medium
        let dateText: (Date?) -> String = { date in
            date.map(formatter.string(from:)) ?? "暂无"
        }
        valueLabels["codex"]?.stringValue = snapshot.codexRunning ? "正在运行" : "未运行"
        valueLabels["connection"]?.stringValue = snapshot.connectionState.diagnosticLabel
        valueLabels["lastUpdate"]?.stringValue = dateText(snapshot.lastSuccessfulUpdateAt)
        valueLabels["tasks"]?.stringValue = "\(snapshot.activeCount) 运行中 · \(snapshot.waitingCount) 待处理 · \(snapshot.trackedCount) 已跟踪"
        valueLabels["filtered"]?.stringValue = snapshot.filteredInternalCount.map(String.init) ?? "未统计"
        valueLabels["touchBar"]?.stringValue = snapshot.touchBarAvailable ? "兼容" : "不可用"
        valueLabels["fallback"]?.stringValue = snapshot.fallbackMode
        valueLabels["lastIssue"]?.stringValue = dateText(snapshot.lastConnectionIssueAt)
        valueLabels["issueCode"]?.stringValue = snapshot.connectionIssueCode ?? "无"
    }

    @objc private func reconnect() {
        onReconnect()
    }

    @objc private func copySummary() {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(snapshot.privacySafeSummary, forType: .string)
        copyButton?.title = "已复制"
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.2) { [weak self] in
            self?.copyButton?.title = "复制诊断摘要"
        }
    }

    @objc private func closeWindow() {
        window?.performClose(nil)
    }

    private func buildContent() {
        guard let contentView = window?.contentView else { return }

        let title = NSTextField(labelWithString: "连接与兼容性")
        title.font = .systemFont(ofSize: 18, weight: .semibold)
        let description = NSTextField(
            wrappingLabelWithString: "诊断信息只包含状态、时间和匿名计数，不包含对话、任务标题、命令、文件路径或令牌。"
        )
        description.textColor = .secondaryLabelColor
        description.maximumNumberOfLines = 0
        description.preferredMaxLayoutWidth = 472

        let rows: [(String, String)] = [
            ("Codex 进程", "codex"),
            ("IPC 连接", "connection"),
            ("最后成功更新", "lastUpdate"),
            ("任务汇总", "tasks"),
            ("已过滤内部任务", "filtered"),
            ("Touch Bar 接口", "touchBar"),
            ("当前模式", "fallback"),
            ("最近连接问题", "lastIssue"),
            ("问题代码", "issueCode")
        ]
        let gridRows = rows.map { title, key -> [NSView] in
            let label = NSTextField(labelWithString: title)
            label.textColor = .secondaryLabelColor
            let value = NSTextField(labelWithString: "-")
            value.lineBreakMode = .byTruncatingMiddle
            value.toolTip = ""
            valueLabels[key] = value
            return [label, value]
        }
        let grid = NSGridView(views: gridRows)
        grid.rowSpacing = 9
        grid.columnSpacing = 18
        grid.column(at: 0).xPlacement = .trailing
        grid.column(at: 1).xPlacement = .leading

        let reconnectButton = NSButton(title: "重新连接", target: self, action: #selector(reconnect))
        let copyButton = NSButton(title: "复制诊断摘要", target: self, action: #selector(copySummary))
        self.copyButton = copyButton
        let doneButton = NSButton(title: "完成", target: self, action: #selector(closeWindow))
        doneButton.keyEquivalent = "\r"
        let actions = NSStackView(views: [reconnectButton, copyButton, doneButton])
        actions.orientation = .horizontal
        actions.spacing = 8

        let stack = NSStackView(views: [title, description, grid, actions])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            stack.topAnchor.constraint(equalTo: contentView.topAnchor),
            stack.bottomAnchor.constraint(equalTo: contentView.bottomAnchor)
        ])
    }
}
