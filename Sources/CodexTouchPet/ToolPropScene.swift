import AppKit

/// Local application artwork only, loaded once per identity (not per frame).
/// A missing application remains visibly generic rather than claiming a target.
final class ToolPropArtwork {
    private var cache: [ToolPropIdentity: NSImage] = [:]
    private let applicationIcon: (String) -> NSImage?

    init(applicationIcon: @escaping (String) -> NSImage? = { bundleID in
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return nil }
        return NSWorkspace.shared.icon(forFile: url.path)
    }) {
        self.applicationIcon = applicationIcon
    }

    func image(for identity: ToolPropIdentity) -> NSImage? {
        if let cached = cache[identity] { return cached }
        let image: NSImage?
        switch identity {
        case .application(let bundleID):
            image = applicationIcon(bundleID) ?? NSImage(systemSymbolName: "app.dashed", accessibilityDescription: "软件未安装")
        case .browser:
            image = NSImage(systemSymbolName: "globe", accessibilityDescription: identity.label)
        case .computer:
            image = NSImage(systemSymbolName: "desktopcomputer", accessibilityDescription: identity.label)
        case .tool:
            image = NSImage(systemSymbolName: "wrench.and.screwdriver", accessibilityDescription: identity.label)
        }
        let rendered: NSImage?
        if let image, image.isTemplate {
            let tinted = NSImage(size: NSSize(width: 18, height: 18))
            tinted.lockFocus()
            image.draw(in: NSRect(x: 2, y: 2, width: 14, height: 14))
            NSColor(calibratedWhite: 0.9, alpha: 1).setFill()
            NSRect(x: 0, y: 0, width: 18, height: 18).fill(using: .sourceAtop)
            tinted.unlockFocus()
            tinted.isTemplate = false
            rendered = tinted
        } else { rendered = image }
        if let rendered, cache.count < 32 { cache[identity] = rendered }
        return rendered
    }
}

/// One coherent scene: fox walks on the ground, stops beside the next
/// prop, then pushes and draws it back. Props never move before contact.
struct ToolPropChoreography {
    static let cycle: TimeInterval = 3
    static let foxX: CGFloat = 66
    static let pawOffset: CGFloat = 22
    static let walkDuration: TimeInterval = 0.85

    struct Sample {
        let positions: [CGPoint]
        let foxX: CGFloat
        let foxFrame: Int
        let walking: Bool
        let direction: PetIdleActivityDirector.RunDirection
    }

    static func sample(elapsed: TimeInterval, count: Int, animated: Bool) -> Sample {
        let count = min(3, max(0, count))
        var positions = (0..<count).map { CGPoint(x: 94 + CGFloat($0) * 46, y: 12) }
        guard count > 0, animated else {
            return Sample(positions: positions, foxX: count > 0 ? positions[0].x - pawOffset : foxX, foxFrame: 0, walking: false, direction: .right)
        }
        let elapsed = max(0, elapsed)
        let phase = elapsed.truncatingRemainder(dividingBy: cycle)
        let selected = Int(elapsed / cycle) % count
        let parking = positions[selected].x
        let target = parking - pawOffset
        let previous = elapsed < cycle ? foxX : positions[(selected + count - 1) % count].x - pawOffset
        let walking = phase < walkDuration && abs(target - previous) > 0.01
        let fox = previous + (target - previous) * smooth(phase / walkDuration)
        var push: CGFloat = 0
        if phase >= 1.33 && phase < 1.63 { push = 4 * smooth((phase - 1.33) / 0.30) }
        else if phase >= 1.63 && phase < 1.81 { push = 4 }
        else if phase >= 1.81 && phase < 2.13 { push = 4 * (1 - smooth((phase - 1.81) / 0.32)) }
        positions[selected].x += push
        let frame = walking ? Int(phase / (1.0 / 9)) % 8
            : (phase >= walkDuration && phase < 2.13 ? min(7, Int((phase - walkDuration) / 0.16)) : 0)
        return Sample(positions: positions, foxX: fox, foxFrame: frame, walking: walking,
            direction: target < previous ? .left : .right)
    }

    private static func smooth(_ t: Double) -> CGFloat {
        let t = min(1, max(0, t))
        return CGFloat(t * t * (3 - 2 * t))
    }
}

/// Non-interactive decorative props. Tasks and approval actions remain in
/// their original controls, with a separate accessibility label for the scene.
final class ToolPropSceneView: NSView {
    private let artwork: ToolPropArtwork
    private var props: [ToolProp] = []
    private var images: [NSImage?] = []
    private(set) var positions: [CGPoint] = []
    private var overflow = 0

    init(artwork: ToolPropArtwork = ToolPropArtwork()) {
        self.artwork = artwork
        super.init(frame: .zero)
        setAccessibilityElement(true)
        setAccessibilityRole(.image)
    }

    required init?(coder: NSCoder) { fatalError("init(coder:) has not been implemented") }

    override func hitTest(_ point: NSPoint) -> NSView? { nil }

    func update(props: [ToolProp], elapsed: TimeInterval, animated: Bool) {
        if props != self.props {
            self.props = props
            images = props.prefix(3).map { artwork.image(for: $0.identity) }
            overflow = max(0, props.count - 3)
            setAccessibilityLabel(props.isEmpty ? "" : "工具道具：" + props.map { $0.identity.label }.joined(separator: "、"))
            toolTip = props.isEmpty ? nil : "仅展示已观测到的工具；未注册目标使用通用图标"
            needsDisplay = true
        }
        let sample = ToolPropChoreography.sample(elapsed: elapsed, count: props.count, animated: animated)
        guard sample.positions != positions || isHidden != props.isEmpty else { return }
        positions = sample.positions
        isHidden = props.isEmpty
        needsDisplay = true
    }

    override func draw(_ dirtyRect: NSRect) {
        super.draw(dirtyRect)
        for (index, position) in positions.enumerated() {
            let rect = NSRect(x: position.x - 9, y: position.y - 9, width: 18, height: 18)
            let actualApp: Bool
            if case .application = props[index].identity { actualApp = true } else { actualApp = false }
            if !actualApp {
                NSColor(calibratedWhite: 0.16, alpha: 1).setFill()
                NSBezierPath(roundedRect: rect, xRadius: 4, yRadius: 4).fill()
            }
            if let image = images[index] {
                image.draw(in: rect)
            }
        }
        if overflow > 0 {
            NSAttributedString(string: "+\(overflow)", attributes: [
                .font: NSFont.systemFont(ofSize: 10, weight: .medium), .foregroundColor: NSColor.white
            ]).draw(at: CGPoint(x: 206, y: 6))
        }
    }
}
