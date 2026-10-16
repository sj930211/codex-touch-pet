import AppKit

/// Native macOS utility chrome: one recognizable fox, a short live summary,
/// then ordinary keyboard-accessible menu commands. No task titles in the menu.
enum MenuBarIcon {
    static func image(attention: Bool = false) -> NSImage {
        let image = NSImage(size: NSSize(width: 20, height: 20), flipped: false) { _ in
            NSColor.black.setStroke()
            NSColor.black.setFill()
            let outline = NSBezierPath()
            outline.move(to: NSPoint(x: 2.2, y: 17.2))
            outline.line(to: NSPoint(x: 7, y: 14.4))
            outline.curve(to: NSPoint(x: 13, y: 14.4), controlPoint1: NSPoint(x: 9, y: 15.2), controlPoint2: NSPoint(x: 11, y: 15.2))
            outline.line(to: NSPoint(x: 17.8, y: 17.2))
            outline.line(to: NSPoint(x: 17, y: 9))
            outline.curve(to: NSPoint(x: 10, y: 2.3), controlPoint1: NSPoint(x: 16.4, y: 6.6), controlPoint2: NSPoint(x: 12.4, y: 3.5))
            outline.curve(to: NSPoint(x: 3, y: 9), controlPoint1: NSPoint(x: 7.6, y: 3.5), controlPoint2: NSPoint(x: 3.6, y: 6.6))
            outline.close()
            outline.lineWidth = 1.45
            outline.lineJoinStyle = .round
            outline.stroke()
            let cheeks = NSBezierPath()
            cheeks.move(to: NSPoint(x: 3.4, y: 10.6))
            cheeks.curve(to: NSPoint(x: 10, y: 5.2), controlPoint1: NSPoint(x: 6, y: 10.3), controlPoint2: NSPoint(x: 7.1, y: 6.3))
            cheeks.curve(to: NSPoint(x: 16.6, y: 10.6), controlPoint1: NSPoint(x: 12.9, y: 6.3), controlPoint2: NSPoint(x: 14, y: 10.3))
            cheeks.lineWidth = 1.1
            cheeks.stroke()
            for x: CGFloat in [6.5, 12] {
                NSBezierPath(ovalIn: NSRect(x: x, y: 9.4, width: 1.5, height: 1.7)).fill()
            }
            NSBezierPath(ovalIn: NSRect(x: 8.8, y: 5.6, width: 2.4, height: 1.7)).fill()
            if attention {
                // The silhouette stays stable; a small corner marker is only
                // added when the state needs attention, never a flashing loop.
                NSColor.clear.setFill()
                NSRect(x: 15, y: 0, width: 5, height: 5).fill(using: .copy)
                NSColor.black.setFill()
                NSBezierPath(ovalIn: NSRect(x: 16, y: 0.7, width: 3.5, height: 3.5)).fill()
            }
            return true
        }
        image.isTemplate = true
        image.accessibilityDescription = "Codex Touch Pet"
        return image
    }
}

struct MenuBarSummary {
    let title: String
    let detail: String
    let symbol: String
    let color: NSColor
    let needsAttention: Bool

    init(status: AggregatePetStatus, quietMode: Bool) {
        let connection = status.connectionState
        needsAttention = connection == .incompatible || connection == .stale
            || status.state == .failed || status.state == .systemError
            || status.state == .waitingApproval || status.state == .waitingInput || status.waitingCount > 0
        if connection != .online {
            title = connection.diagnosticLabel
            detail = status.activeCount > 0
                ? "最后状态：\(status.activeCount) 项进行中 · 等待连接恢复"
                : "可在“连接与帮助”中查看诊断"
            color = connection.color
            symbol = connection == .incompatible ? "exclamationmark.triangle" : "network"
        } else if quietMode && status.state == .idle {
            title = "安静模式已开启"
            detail = "Codex 已连接 · 动效与自动展开已暂停"
            color = .secondaryLabelColor
            symbol = "moon"
        } else {
            title = status.state == .idle ? "狐狸正在休息" : status.state.label
            detail = status.activeCount > 0 || status.waitingCount > 0
                ? "\(status.activeCount) 项进行中 · \(status.waitingCount) 项待处理\(quietMode ? " · 安静模式" : "")"
                : "Codex 已连接\(quietMode ? " · 安静模式" : "")"
            color = status.state.animationIdentity == .working
                ? .systemBlue : status.state.color
            symbol = needsAttention ? "exclamationmark.circle" : "circle.fill"
        }
    }
}

final class MenuStatusHeaderView: NSView {
    private let titleLabel = NSTextField(labelWithString: "")
    private let detailLabel = NSTextField(labelWithString: "")
    private let stateIcon = NSImageView()

    init() {
        super.init(frame: NSRect(x: 0, y: 0, width: 292, height: 98))
        let name = NSTextField(labelWithString: AppMetadata.name)
        name.font = .systemFont(ofSize: 12, weight: .semibold)
        name.textColor = .secondaryLabelColor
        titleLabel.font = .systemFont(ofSize: 14, weight: .semibold)
        titleLabel.lineBreakMode = .byTruncatingTail
        detailLabel.font = .systemFont(ofSize: 11)
        detailLabel.textColor = .secondaryLabelColor
        detailLabel.lineBreakMode = .byTruncatingTail
        stateIcon.imageScaling = .scaleProportionallyDown
        let statusRow = NSStackView(views: [stateIcon, titleLabel])
        statusRow.spacing = 7
        statusRow.alignment = .centerY
        let stack = NSStackView(views: [name, statusRow, detailLabel])
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 6
        stack.translatesAutoresizingMaskIntoConstraints = false
        addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: leadingAnchor, constant: 18),
            stack.trailingAnchor.constraint(equalTo: trailingAnchor, constant: -18),
            stack.centerYAnchor.constraint(equalTo: centerYAnchor),
            detailLabel.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            statusRow.widthAnchor.constraint(lessThanOrEqualTo: stack.widthAnchor),
            stateIcon.widthAnchor.constraint(equalToConstant: 13),
            stateIcon.heightAnchor.constraint(equalToConstant: 13)
        ])
    }

    required init?(coder: NSCoder) { fatalError("Unsupported coder") }

    func update(_ summary: MenuBarSummary) {
        titleLabel.stringValue = summary.title
        detailLabel.stringValue = summary.detail
        stateIcon.image = NSImage(systemSymbolName: summary.symbol, accessibilityDescription: nil)
        stateIcon.contentTintColor = summary.color
        setAccessibilityLabel("\(AppMetadata.name)，\(summary.title)，\(summary.detail)")
    }
}

enum PetMenuAction: CaseIterable {
    case expand, quiet, settings, reconnect, diagnostics, usage, about, quit
}

final class PetMenuController: NSObject {
    let menu = NSMenu()
    let header = MenuStatusHeaderView()
    private var items: [PetMenuAction: NSMenuItem] = [:]
    private let onAction: (PetMenuAction) -> Void

    init(touchBarAvailable: Bool, onAction: @escaping (PetMenuAction) -> Void) {
        self.onAction = onAction
        super.init()
        menu.autoenablesItems = false
        let summary = NSMenuItem()
        summary.view = header
        menu.addItem(summary)
        menu.addItem(.separator())
        add(.expand, title: "展开 Touch Bar", symbol: "rectangle.bottomthird.inset.filled", to: menu)
        items[.expand]?.isEnabled = touchBarAvailable
        items[.expand]?.toolTip = touchBarAvailable ? nil : "此设备无法使用 Touch Bar，仍可通过菜单栏查看状态。"
        add(.quiet, title: "安静模式", symbol: "moon", to: menu)
        menu.addItem(.separator())
        add(.settings, title: "设置…", symbol: "slider.horizontal.3", key: ",", to: menu)
        let supportItem = NSMenuItem(title: "连接与帮助", action: nil, keyEquivalent: "")
        supportItem.image = NSImage(systemSymbolName: "questionmark.circle", accessibilityDescription: nil)
        let support = NSMenu()
        support.autoenablesItems = false
        add(.reconnect, title: "重新连接 Codex", symbol: "arrow.clockwise", to: support)
        add(.diagnostics, title: "连接诊断…", symbol: "waveform.path.ecg", to: support)
        support.addItem(.separator())
        add(.usage, title: "使用说明", symbol: "book", to: support)
        add(.about, title: "关于 Codex Touch Pet", symbol: "info.circle", to: support)
        supportItem.submenu = support
        menu.addItem(supportItem)
        menu.addItem(.separator())
        add(.quit, title: "退出 Codex Touch Pet", symbol: "power", key: "q", to: menu)
    }

    func update(status: AggregatePetStatus, settings: AppSettings) {
        header.update(MenuBarSummary(status: status, quietMode: settings.quietMode))
        items[.quiet]?.state = settings.quietMode ? .on : .off
    }

    private func add(_ action: PetMenuAction, title: String, symbol: String, key: String = "", to menu: NSMenu) {
        let item = NSMenuItem(title: title, action: #selector(invoke(_:)), keyEquivalent: key)
        item.target = self
        item.representedObject = action
        item.image = NSImage(systemSymbolName: symbol, accessibilityDescription: nil)
        menu.addItem(item)
        items[action] = item
    }

    @objc private func invoke(_ sender: NSMenuItem) {
        guard let action = sender.representedObject as? PetMenuAction else { return }
        onAction(action)
    }
}
