import AppKit

final class SettingsWindowController: NSWindowController {
    private let onSettingsChange: (AppSettings) -> Void
    private var settings: AppSettings
    private let autoExpandButton: NSButton
    private let keepCompactPetButton: NSButton
    private let quietModeButton: NSButton
    private let motionPopUpButton: NSPopUpButton
    private let promptsButton: NSButton

    init(settings: AppSettings, onSettingsChange: @escaping (AppSettings) -> Void) {
        self.settings = settings
        self.onSettingsChange = onSettingsChange
        self.autoExpandButton = NSButton(checkboxWithTitle: "Codex 在前台时自动展开", target: nil, action: nil)
        self.keepCompactPetButton = NSButton(checkboxWithTitle: "收起后保留 Touch Bar 紧凑宠物", target: nil, action: nil)
        self.quietModeButton = NSButton(checkboxWithTitle: "安静模式（临时停用自动展开和宠物动画）", target: nil, action: nil)
        self.motionPopUpButton = NSPopUpButton(frame: .zero, pullsDown: false)
        self.promptsButton = NSButton(checkboxWithTitle: "播放完成与等待入场提示", target: nil, action: nil)

        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 520, height: 390),
            styleMask: [.titled, .closable],
            backing: .buffered,
            defer: false
        )
        window.title = "Codex Touch Pet 设置"
        window.isReleasedWhenClosed = false
        super.init(window: window)

        for button in [autoExpandButton, keepCompactPetButton, quietModeButton, promptsButton] {
            button.target = self
            button.action = #selector(settingChanged)
        }
        motionPopUpButton.addItems(withTitles: MotionPreference.allCases.map(\.title))
        motionPopUpButton.target = self
        motionPopUpButton.action = #selector(settingChanged)
        updateControls()
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

    func update(settings: AppSettings) {
        self.settings = settings
        updateControls()
    }

    @objc private func settingChanged() {
        settings.autoExpand = autoExpandButton.state == .on
        settings.keepCompactPet = keepCompactPetButton.state == .on
        settings.quietMode = quietModeButton.state == .on
        settings.motionPreference = MotionPreference.allCases[motionPopUpButton.indexOfSelectedItem]
        settings.completionAndWaitingPrompts = promptsButton.state == .on
        onSettingsChange(settings)
    }

    @objc private func closeWindow() {
        window?.performClose(nil)
    }

    private func buildContent() {
        guard let contentView = window?.contentView else { return }

        let title = NSTextField(labelWithString: "Touch Bar 展示")
        title.font = .systemFont(ofSize: 18, weight: .semibold)

        let description = NSTextField(
            wrappingLabelWithString: "Touch Bar 只显示状态汇总，不在此执行审批或输入。安静模式会临时覆盖自动展开和动效设置，关闭后恢复原偏好。"
        )
        description.font = .systemFont(ofSize: 13)
        description.textColor = .secondaryLabelColor
        description.maximumNumberOfLines = 0
        description.preferredMaxLayoutWidth = 420

        let motionLabel = NSTextField(labelWithString: "动效强度")
        motionLabel.font = .systemFont(ofSize: 13, weight: .medium)
        let motionRow = NSStackView(views: [motionLabel, motionPopUpButton])
        motionRow.orientation = .horizontal
        motionRow.alignment = .centerY
        motionRow.spacing = 12

        let systemMotionHelp = NSTextField(
            wrappingLabelWithString: "macOS “减少动态效果”对所有选项优先；“静态”仍保留颜色、文字和短淡变反馈。"
        )
        systemMotionHelp.font = .systemFont(ofSize: 12)
        systemMotionHelp.textColor = .tertiaryLabelColor
        systemMotionHelp.maximumNumberOfLines = 0
        systemMotionHelp.preferredMaxLayoutWidth = 460

        let version = NSTextField(labelWithString: "版本 \(AppMetadata.version)（\(AppMetadata.build)）")
        version.font = .systemFont(ofSize: 12)
        version.textColor = .tertiaryLabelColor

        let done = NSButton(title: "完成", target: self, action: #selector(closeWindow))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"

        let stack = NSStackView(views: [
            title,
            description,
            autoExpandButton,
            keepCompactPetButton,
            quietModeButton,
            motionRow,
            systemMotionHelp,
            promptsButton,
            version,
            done
        ])
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

    private func updateControls() {
        autoExpandButton.state = settings.autoExpand ? .on : .off
        keepCompactPetButton.state = settings.keepCompactPet ? .on : .off
        quietModeButton.state = settings.quietMode ? .on : .off
        promptsButton.state = settings.completionAndWaitingPrompts ? .on : .off
        let index = MotionPreference.allCases.firstIndex(of: settings.motionPreference) ?? 0
        motionPopUpButton.selectItem(at: index)
    }
}
