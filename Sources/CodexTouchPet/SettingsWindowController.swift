import AppKit

final class SettingsWindowController: NSWindowController {
    private let onQuietModeChange: (Bool) -> Void
    private let quietModeButton: NSButton

    init(quietMode: Bool, onQuietModeChange: @escaping (Bool) -> Void) {
        self.onQuietModeChange = onQuietModeChange
        self.quietModeButton = NSButton(checkboxWithTitle: "安静模式（不自动展开完整 Touch Bar）", target: nil, action: nil)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 480, height: 286),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Codex Touch Pet 设置"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        quietModeButton.target = self
        quietModeButton.action = #selector(quietModeChanged)
        quietModeButton.state = quietMode ? .on : .off
        buildContent()
    }

    required init?(coder: NSCoder) {
        fatalError("SettingsWindowController does not support NSCoder initialization")
    }

    func present() {
        window?.center()
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    @objc private func quietModeChanged() {
        onQuietModeChange(quietModeButton.state == .on)
    }

    @objc private func closeWindow() {
        window?.performClose(nil)
    }

    private func buildContent() {
        guard let contentView = window?.contentView else { return }

        let title = NSTextField(labelWithString: "Touch Bar 展示")
        title.font = .systemFont(ofSize: 18, weight: .semibold)

        let description = NSTextField(
            wrappingLabelWithString: "Codex 在前台时自动展开完整面板；切到其他应用后保留窄宠物入口。多个活动任务只在摘要区轮播，不替代 Codex 详情页。"
        )
        description.font = .systemFont(ofSize: 13)
        description.textColor = .secondaryLabelColor
        description.maximumNumberOfLines = 0
        description.preferredMaxLayoutWidth = 420

        let carousel = NSTextField(labelWithString: "任务摘要轮播：每 5 秒切换当前活动任务")
        carousel.font = .systemFont(ofSize: 13)
        carousel.textColor = .secondaryLabelColor

        let version = NSTextField(labelWithString: "版本 \(AppMetadata.version)（\(AppMetadata.build)）")
        version.font = .systemFont(ofSize: 12)
        version.textColor = .tertiaryLabelColor

        let done = NSButton(title: "完成", target: self, action: #selector(closeWindow))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"

        let stack = NSStackView(views: [title, description, quietModeButton, carousel, version, done])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
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
