import AppKit

private final class SettingsBackgroundView: NSView {
    override func draw(_ dirtyRect: NSRect) {
        NSColor.windowBackgroundColor.setFill()
        dirtyRect.fill()
    }
}

private final class SettingsDocumentView: NSView {
    override var isFlipped: Bool { true }
}

/// Native grouped preferences: approved fox identity, system type and colors,
/// immediate save, with low-frequency help on a second page.
final class SettingsWindowController: NSWindowController {
    private let onSettingsChange: (AppSettings) -> Void
    private let onHelpAction: (PetMenuAction) -> Void
    private var settings: AppSettings
    private let autoExpandSwitch = NSSwitch()
    private let compactSwitch = NSSwitch()
    private let quietSwitch = NSSwitch()
    private let promptsSwitch = NSSwitch()
    private let motionPicker = NSPopUpButton(frame: .zero, pullsDown: false)
    private let tabs = NSSegmentedControl(labels: ["展示与动效", "关于与帮助"], trackingMode: .selectOne, target: nil, action: nil)
    private let pageHost = NSView()
    private let quietNote = NSTextField(wrappingLabelWithString: "")
    private var pages: [NSView] = []

    init(settings: AppSettings, onHelpAction: @escaping (PetMenuAction) -> Void = { _ in }, onSettingsChange: @escaping (AppSettings) -> Void) {
        self.settings = settings
        self.onSettingsChange = onSettingsChange
        self.onHelpAction = onHelpAction
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 620, height: 650), styleMask: [.titled, .closable, .miniaturizable, .resizable], backing: .buffered, defer: false)
        window.title = "Codex Touch Pet 设置"
        window.contentMinSize = NSSize(width: 560, height: 620)
        window.isReleasedWhenClosed = false
        window.contentView = SettingsBackgroundView(frame: NSRect(x: 0, y: 0, width: 620, height: 650))
        super.init(window: window)
        for (control, name) in [(autoExpandSwitch, "自动展开"), (compactSwitch, "保留紧凑宠物"), (quietSwitch, "安静模式"), (promptsSwitch, "完成与等待提示")] {
            control.target = self
            control.action = #selector(settingChanged)
            control.setAccessibilityLabel(name)
            control.identifier = NSUserInterfaceItemIdentifier(name)
        }
        motionPicker.addItems(withTitles: MotionPreference.allCases.map(\.title))
        motionPicker.target = self
        motionPicker.action = #selector(settingChanged)
        motionPicker.setAccessibilityLabel("动效偏好")
        motionPicker.identifier = NSUserInterfaceItemIdentifier("动效偏好")
        tabs.selectedSegment = 0
        tabs.target = self
        tabs.action = #selector(selectPage)
        tabs.setAccessibilityLabel("设置分类")
        buildContent()
        updateControls()
    }

    required init?(coder: NSCoder) { fatalError("Unsupported coder") }

    func present() {
        if window?.isVisible != true { window?.center() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }

    func update(settings: AppSettings) {
        self.settings = settings
        updateControls()
    }

    @objc private func settingChanged() {
        settings.autoExpand = autoExpandSwitch.state == .on
        settings.keepCompactPet = compactSwitch.state == .on
        settings.quietMode = quietSwitch.state == .on
        settings.completionAndWaitingPrompts = promptsSwitch.state == .on
        let index = motionPicker.indexOfSelectedItem
        if MotionPreference.allCases.indices.contains(index) { settings.motionPreference = MotionPreference.allCases[index] }
        updateControls()
        onSettingsChange(settings)
    }

    @objc private func selectPage() {
        for (index, page) in pages.enumerated() { page.isHidden = index != tabs.selectedSegment }
    }

    @objc private func closeWindow() { window?.performClose(nil) }

    @objc private func helpAction(_ sender: NSButton) {
        switch sender.identifier?.rawValue {
        case "diagnostics": onHelpAction(.diagnostics)
        case "usage": onHelpAction(.usage)
        case "source": NSWorkspace.shared.open(AppMetadata.repositoryURL)
        default: break
        }
    }

    private func buildContent() {
        guard let contentView = window?.contentView else { return }
        let icon = NSImageView()
        icon.image = Bundle.main.resourceURL.flatMap { NSImage(contentsOf: $0.appendingPathComponent("AppIcon.png")) }
            ?? NSImage(contentsOfFile: "App/AppIcon.png")
        icon.imageScaling = .scaleProportionallyUpOrDown
        let titles = vertical([text("Codex Touch Pet", size: 21, weight: .semibold), text("让狐狸陪你掌握工作节奏", size: 12, color: .secondaryLabelColor)], spacing: 6)
        let header = NSStackView(views: [icon, titles, NSView()])
        header.orientation = .horizontal
        header.alignment = .centerY
        header.spacing = 14
        icon.widthAnchor.constraint(equalToConstant: 56).isActive = true
        icon.heightAnchor.constraint(equalToConstant: 56).isActive = true
        pages = [makeGeneralPage(), makeAboutPage()]
        for page in pages {
            page.translatesAutoresizingMaskIntoConstraints = false
            pageHost.addSubview(page)
            NSLayoutConstraint.activate([
                page.leadingAnchor.constraint(equalTo: pageHost.leadingAnchor), page.trailingAnchor.constraint(equalTo: pageHost.trailingAnchor),
                page.topAnchor.constraint(equalTo: pageHost.topAnchor), page.bottomAnchor.constraint(equalTo: pageHost.bottomAnchor)
            ])
        }
        selectPage()
        let done = NSButton(title: "完成", target: self, action: #selector(closeWindow))
        done.bezelStyle = .rounded
        done.keyEquivalent = "\r"
        let footer = NSStackView(views: [text("更改会自动保存", size: 11, color: .secondaryLabelColor), NSView(), done])
        footer.orientation = .horizontal
        footer.alignment = .centerY
        let root = vertical([header, tabs, pageHost, footer], spacing: 18)
        fillWidth(root)
        root.translatesAutoresizingMaskIntoConstraints = false
        contentView.addSubview(root)
        NSLayoutConstraint.activate([
            root.leadingAnchor.constraint(equalTo: contentView.leadingAnchor, constant: 24), root.trailingAnchor.constraint(equalTo: contentView.trailingAnchor, constant: -24),
            root.topAnchor.constraint(equalTo: contentView.topAnchor, constant: 20), root.bottomAnchor.constraint(equalTo: contentView.bottomAnchor, constant: -18),
            header.heightAnchor.constraint(equalToConstant: 64), tabs.heightAnchor.constraint(equalToConstant: 28), footer.heightAnchor.constraint(equalToConstant: 28)
        ])
    }

    private func makeGeneralPage() -> NSView {
        let display = group(title: "Touch Bar", rows: [
            row("自动展开", detail: "切到 Codex 时展开，离开后收起。", control: autoExpandSwitch),
            row("保留紧凑宠物", detail: "收起完整面板后，在控制条保留狐狸入口。", control: compactSwitch)
        ])
        let motion = group(title: "陪伴与动效", rows: [
            row("动效偏好", detail: "优先遵循 macOS 的“减少动态效果”。", control: motionPicker),
            row("完成与等待提示", detail: "在状态到来时播放对应的入场动作。", control: promptsSwitch),
            row("安静模式", detail: "暂停自动展开和动画，关闭后恢复原偏好。", control: quietSwitch)
        ])
        quietNote.font = .systemFont(ofSize: 11)
        quietNote.textColor = .secondaryLabelColor
        quietNote.maximumNumberOfLines = 0
        let content = vertical([display, motion, quietNote], spacing: 18)
        fillWidth(content)
        return scrollPage(content)
    }

    private func makeAboutPage() -> NSView {
        let links = NSStackView(views: [helpButton("使用说明", identifier: "usage"), helpButton("连接诊断…", identifier: "diagnostics"), helpButton("GitHub 源码", identifier: "source")])
        links.spacing = 8
        let content = vertical([
            text("版本 \(AppMetadata.version)（\(AppMetadata.build)）", size: 13, weight: .medium),
            text("一只住在 Touch Bar 的狐狸，帮你查看 Codex 工作状态。", size: 13, wrap: true),
            text("任务以胶囊并排显示，可横向滑动。点按胶囊回到对应会话；确认操作和输入仍在 Codex 中完成。", size: 12, color: .secondaryLabelColor, wrap: true),
            text("隐私", size: 12, weight: .semibold),
            text("只在本机处理状态和任务简称。诊断摘要不包含对话、任务标题、命令或文件路径。", size: 12, color: .secondaryLabelColor, wrap: true),
            text("开源与兼容性", size: 12, weight: .semibold),
            text("源码公开于 GitHub。\(AppMetadata.licenseSummary)；当前请勿视为已授予复制、修改或分发许可。", size: 12, color: .secondaryLabelColor, wrap: true),
            text("使用 macOS Touch Bar 私有接口。系统或 Codex 更新可能影响兼容性，遇到问题可查看连接诊断。", size: 12, color: .secondaryLabelColor, wrap: true), links
        ], spacing: 14)
        fillWidth(content)
        return scrollPage(content)
    }

    private func group(title: String, rows: [NSView]) -> NSView {
        let box = NSBox()
        box.boxType = .custom
        box.borderColor = .separatorColor
        box.borderWidth = 0.5
        box.cornerRadius = 10
        box.fillColor = .controlBackgroundColor
        box.contentViewMargins = .zero
        let content = vertical([], spacing: 0)
        for (index, row) in rows.enumerated() {
            if index > 0 { let separator = NSBox(); separator.boxType = .separator; content.addArrangedSubview(separator) }
            content.addArrangedSubview(row)
        }
        fillWidth(content)
        let host = box.contentView!
        content.translatesAutoresizingMaskIntoConstraints = false
        host.addSubview(content)
        NSLayoutConstraint.activate([
            content.leadingAnchor.constraint(equalTo: host.leadingAnchor), content.trailingAnchor.constraint(equalTo: host.trailingAnchor),
            content.topAnchor.constraint(equalTo: host.topAnchor), content.bottomAnchor.constraint(equalTo: host.bottomAnchor)
        ])
        box.heightAnchor.constraint(equalToConstant: CGFloat(rows.count * 62 + rows.count - 1)).isActive = true
        let group = vertical([text(title, size: 12, weight: .semibold), box], spacing: 8)
        fillWidth(group)
        return group
    }

    private func row(_ title: String, detail: String, control: NSControl) -> NSView {
        let labels = vertical([text(title, size: 13, weight: .medium), text(detail, size: 11, color: .secondaryLabelColor, wrap: true)], spacing: 4)
        labels.setContentHuggingPriority(.defaultLow, for: .horizontal)
        labels.setContentCompressionResistancePriority(.defaultLow, for: .horizontal)
        control.setContentHuggingPriority(.required, for: .horizontal)
        control.setContentCompressionResistancePriority(.required, for: .horizontal)
        control.setAccessibilityHelp(detail)
        let row = NSStackView(views: [labels, control])
        row.orientation = .horizontal
        row.distribution = .fill
        row.alignment = .centerY
        row.spacing = 14
        row.edgeInsets = NSEdgeInsets(top: 10, left: 14, bottom: 10, right: 14)
        row.heightAnchor.constraint(equalToConstant: 62).isActive = true
        return row
    }

    private func scrollPage(_ content: NSStackView) -> NSScrollView {
        let scroll = NSScrollView()
        scroll.drawsBackground = false
        scroll.hasVerticalScroller = true
        scroll.autohidesScrollers = true
        scroll.borderType = .noBorder
        let document = SettingsDocumentView()
        scroll.documentView = document
        document.translatesAutoresizingMaskIntoConstraints = false
        content.translatesAutoresizingMaskIntoConstraints = false
        document.addSubview(content)
        NSLayoutConstraint.activate([
            document.leadingAnchor.constraint(equalTo: scroll.contentView.leadingAnchor), document.topAnchor.constraint(equalTo: scroll.contentView.topAnchor),
            document.widthAnchor.constraint(equalTo: scroll.contentView.widthAnchor),
            content.leadingAnchor.constraint(equalTo: document.leadingAnchor), content.trailingAnchor.constraint(equalTo: document.trailingAnchor),
            content.topAnchor.constraint(equalTo: document.topAnchor), content.bottomAnchor.constraint(equalTo: document.bottomAnchor)
        ])
        return scroll
    }

    private func helpButton(_ title: String, identifier: String) -> NSButton {
        let button = NSButton(title: title, target: self, action: #selector(helpAction(_:)))
        button.identifier = NSUserInterfaceItemIdentifier(identifier)
        button.bezelStyle = .rounded
        return button
    }

    private func vertical(_ views: [NSView], spacing: CGFloat) -> NSStackView {
        let stack = NSStackView(views: views)
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = spacing
        return stack
    }

    private func fillWidth(_ stack: NSStackView) {
        stack.alignment = .leading
        for child in stack.arrangedSubviews { child.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true }
    }

    private func text(_ value: String, size: CGFloat, weight: NSFont.Weight = .regular, color: NSColor = .labelColor, wrap: Bool = false) -> NSTextField {
        let label = wrap ? NSTextField(wrappingLabelWithString: value) : NSTextField(labelWithString: value)
        label.font = .systemFont(ofSize: size, weight: weight)
        label.textColor = color
        if wrap { label.maximumNumberOfLines = 0; label.setContentCompressionResistancePriority(.defaultLow, for: .horizontal) }
        return label
    }

    private func updateControls() {
        autoExpandSwitch.state = settings.autoExpand ? .on : .off
        compactSwitch.state = settings.keepCompactPet ? .on : .off
        quietSwitch.state = settings.quietMode ? .on : .off
        promptsSwitch.state = settings.completionAndWaitingPrompts ? .on : .off
        motionPicker.selectItem(at: MotionPreference.allCases.firstIndex(of: settings.motionPreference) ?? 0)
        autoExpandSwitch.isEnabled = !settings.quietMode
        motionPicker.isEnabled = !settings.quietMode
        promptsSwitch.isEnabled = !settings.quietMode
        quietNote.stringValue = settings.quietMode
            ? "安静模式已开启。自动展开和动效偏好已保留，关闭安静模式后恢复。"
            : "狐狸表示任务状态，右侧连接状态独立显示。具体工作内容仍回到 Codex 查看。"
    }
}
