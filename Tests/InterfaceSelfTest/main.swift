import AppKit
import Foundation
import ImageIO

func expect(_ value: @autoclosure () -> Bool, _ message: String) {
    if !value() { fatalError(message) }
}

func descendants(_ view: NSView) -> [NSView] {
    [view] + view.subviews.flatMap(descendants)
}

func save(_ view: NSView, to url: URL) {
    view.layoutSubtreeIfNeeded()
    guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("Missing bitmap") }
    view.cacheDisplay(in: view.bounds, to: bitmap)
    // NSMenu supplies its own material in production. An offscreen capture
    // needs an opaque background so template icons and black text are visible.
    guard let source = bitmap.cgImage,
          let context = CGContext(data: nil, width: source.width, height: source.height,
            bitsPerComponent: 8, bytesPerRow: source.width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { fatalError("Cannot compose preview") }
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    let rect = CGRect(x: 0, y: 0, width: source.width, height: source.height)
    context.fill(rect)
    context.draw(source, in: rect)
    guard let rendered = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else { fatalError("Cannot encode PNG") }
    CGImageDestinationAddImage(destination, rendered, nil)
    expect(CGImageDestinationFinalize(destination), "Cannot save preview")
}

let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent("design-test/menu-settings-v1")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
var latest = AppSettings()
var callbackCount = 0
var helpActions: [PetMenuAction] = []
let settings = SettingsWindowController(settings: latest, onHelpAction: { helpActions.append($0) }) { value in
    latest = value
    callbackCount += 1
}
let window = settings.window!
let view = window.contentView!
let controls = descendants(view)
func control<T: NSControl>(_ name: String, type: T.Type) -> T {
    guard let control = controls.first(where: { $0.identifier?.rawValue == name }) as? T else { fatalError("Missing control \(name)") }
    return control
}
func send(_ control: NSControl) {
    expect(control.sendAction(control.action, to: control.target), "Actual setting action must dispatch")
}
let auto = control("自动展开", type: NSSwitch.self)
let compact = control("保留紧凑宠物", type: NSSwitch.self)
let quiet = control("安静模式", type: NSSwitch.self)
let prompts = control("完成与等待提示", type: NSSwitch.self)
let motion = control("动效偏好", type: NSPopUpButton.self)
auto.state = .off; send(auto)
compact.state = .off; send(compact)
prompts.state = .off; send(prompts)
motion.selectItem(at: MotionPreference.allCases.firstIndex(of: .staticOnly)!); send(motion)
expect(!latest.autoExpand && !latest.keepCompactPet && !latest.completionAndWaitingPrompts && latest.motionPreference == .staticOnly, "All four ordinary settings must reach the actual callback")
quiet.state = .on; send(quiet)
expect(latest.quietMode && !auto.isEnabled && !prompts.isEnabled && !motion.isEnabled && compact.isEnabled, "Quiet mode must disable only the overridden controls")
quiet.state = .off; send(quiet)
expect(!latest.quietMode && !latest.autoExpand && !latest.completionAndWaitingPrompts && latest.motionPreference == .staticOnly, "Quiet mode must preserve prior preferences")
expect(auto.isEnabled && prompts.isEnabled && motion.isEnabled && callbackCount == 6, "Quiet mode restoration must restore control availability")
settings.update(settings: AppSettings())
expect(auto.state == .on && compact.state == .on && prompts.state == .on && motion.indexOfSelectedItem == 0, "External settings changes must synchronize controls")
expect(callbackCount == 6, "External synchronization must not recursively save settings")
let tabs = controls.compactMap { $0 as? NSSegmentedControl }.first!
tabs.selectedSegment = 1; send(tabs)
for name in ["usage", "diagnostics"] {
    let button = control(name, type: NSButton.self)
    send(button)
}
expect(helpActions == [.usage, .diagnostics], "Settings help links must dispatch the actual help routes")
tabs.selectedSegment = 0; send(tabs)

func snapshotSettings(appearance: NSAppearance.Name, suffix: String, size: NSSize) {
    window.appearance = NSAppearance(named: appearance)
    window.setContentSize(size)
    window.contentView!.layoutSubtreeIfNeeded()
    window.appearance!.performAsCurrentDrawingAppearance {
        save(view, to: output.appendingPathComponent("settings-\(suffix).png"))
    }
    for item in [auto, compact, quiet, prompts] {
        let rect = item.convert(item.bounds, to: view)
        expect(rect.minX >= 0 && rect.maxX <= view.bounds.width, "Switch \(item.identifier?.rawValue ?? "") must remain inside the resized settings window: \(rect), window=\(view.bounds)")
    }
}
for (appearance, name) in [(NSAppearance.Name.aqua, "light"), (.darkAqua, "dark")] {
    snapshotSettings(appearance: appearance, suffix: name, size: NSSize(width: 620, height: 650))
    snapshotSettings(appearance: appearance, suffix: "\(name)-minimum", size: NSSize(width: 560, height: 620))
    tabs.selectedSegment = 1; send(tabs)
    snapshotSettings(appearance: appearance, suffix: "\(name)-about", size: NSSize(width: 620, height: 650))
    tabs.selectedSegment = 0; send(tabs)
}
var quietSettings = AppSettings(); quietSettings.quietMode = true
settings.update(settings: quietSettings)
snapshotSettings(appearance: .aqua, suffix: "quiet", size: NSSize(width: 620, height: 650))
expect(descendants(view).compactMap { $0 as? NSTextField }.contains { $0.stringValue.contains("原偏好已保留") || $0.stringValue.contains("动效偏好已保留") }, "Quiet mode must explain retained settings")
print("PET_SETTINGS_INTERFACE_OK (5 controls, immediate save, external sync, quiet restoration, help routes, light/dark/minimum)")

let now = Date()
let onlineIdle = AggregatePetStatus(state: .idle, connectionState: .online, activeCount: 0, waitingCount: 0, trackedCount: 0)
let running = PetStatusAggregator.aggregate([ThreadPetStatus(threadId: "fixture", state: .working(nil), updatedAt: now)], connectionState: .online, initialScanComplete: true)
let waiting = PetStatusAggregator.aggregate([ThreadPetStatus(threadId: "fixture", state: .waitingApproval, updatedAt: now)], connectionState: .online, initialScanComplete: true)
let failed = AggregatePetStatus(state: .failed, connectionState: .online, activeCount: 0, waitingCount: 0, trackedCount: 1)
let offline = AggregatePetStatus(state: .idle, connectionState: .disconnected, activeCount: 0, waitingCount: 0, trackedCount: 0)
let reconnecting = AggregatePetStatus(state: .working(nil), connectionState: .reconnecting, activeCount: 2, waitingCount: 0, trackedCount: 2)
expect(MenuBarSummary(status: waiting, quietMode: true).title == PetState.waitingApproval.label, "Quiet mode must not hide waiting")
expect(MenuBarSummary(status: failed, quietMode: true).title == PetState.failed.label, "Quiet mode must not hide errors")
expect(MenuBarSummary(status: offline, quietMode: false).title == CodexConnectionState.disconnected.diagnosticLabel, "A disconnected snapshot must not claim to be resting online")
expect(MenuBarSummary(status: reconnecting, quietMode: false).detail.contains("最后状态"), "Reconnecting counts must be labelled as the last known state")
var actions: [PetMenuAction] = []
let menu = PetMenuController(touchBarAvailable: true) { actions.append($0) }
menu.update(status: waiting, settings: quietSettings)
func invokeItems(_ menu: NSMenu) {
    for (index, item) in menu.items.enumerated() {
        if let submenu = item.submenu { invokeItems(submenu) }
        else if item.action != nil { menu.performActionForItem(at: index) }
    }
}
invokeItems(menu.menu)
expect(Set(actions) == Set(PetMenuAction.allCases) && actions.count == 8, "Every native menu action must dispatch exactly once")
expect(menu.menu.items.first(where: { $0.title == "安静模式" })?.state == .on, "Menu checkmark must synchronize quiet mode")
let fallback = PetMenuController(touchBarAvailable: false) { _ in }
expect(fallback.menu.items.first(where: { $0.title == "展开 Touch Bar" })?.isEnabled == false, "Unsupported Touch Bar action must be disabled")
expect(MenuBarIcon.image().isTemplate && MenuBarIcon.image().size == NSSize(width: 20, height: 20), "Menu icon must be a fixed-size system template")
let headerWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 292, height: 98), styleMask: .borderless, backing: .buffered, defer: false)
headerWindow.contentView = menu.header
for (name, status) in [("idle", onlineIdle), ("working", running), ("waiting", waiting), ("failed", failed), ("offline", offline), ("reconnecting", reconnecting)] {
    menu.update(status: status, settings: AppSettings())
    headerWindow.appearance = NSAppearance(named: .aqua)
    headerWindow.appearance!.performAsCurrentDrawingAppearance { save(menu.header, to: output.appendingPathComponent("menu-summary-\(name).png")) }
}
let iconView = NSImageView(frame: NSRect(x: 0, y: 0, width: 40, height: 40))
iconView.image = MenuBarIcon.image()
iconView.contentTintColor = .black
iconView.imageScaling = .scaleProportionallyUpOrDown
save(iconView, to: output.appendingPathComponent("menubar-fox.png"))
print("PET_MENU_INTERFACE_OK (8 actions, attention states, quiet sync, unsupported device, native template)")
print("PET_INTERFACE_PREVIEWS_OK (native AppKit view captures; not an OS menu screenshot)")
