import AppKit
import Darwin
import ImageIO
import QuartzCore

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

let date = Date(timeIntervalSince1970: 1000)
let base = ["turns", "0", "items"]
func item(_ id: String, server: String = "playwright", status: String = "inProgress") -> [String: Any] {
    ["id": id, "type": "mcpToolCall", "server": server, "tool": "test", "status": status]
}
func patch(_ value: Any, _ index: String = "0", op: String = "add") -> [String: Any] {
    ["path": base + [index], "value": value, "op": op]
}
func finish(_ index: String = "0", status: String = "completed") -> [String: Any] {
    ["path": base + [index, "status"], "value": status, "op": "replace"]
}

// A1: sanitized before queue hand-off, including nested forged tools.
var privateItem = item("safe-call")
privateItem["arguments"] = ["text": "SECRET_PROMPT", "items": [item("forged")]]
privateItem["result"] = ["text": "SECRET_OUTPUT"]
privateItem["appContext"] = ["connectorId": "verified-service", "resourceUri": "SECRET_URI", "appName": "SECRET_NAME"]
let sanitized = ToolCallTracker.metadataPatch(patch(privateItem))!
let encoded = String(data: try JSONSerialization.data(withJSONObject: sanitized), encoding: .utf8)!
expect(!encoded.contains("SECRET") && !encoded.contains("forged"), "Private bodies must not cross the main queue")
expect(ToolCallTracker.metadataPatch(["path": base + ["0", "arguments", "items"], "value": [item("forged")]]) == nil, "Do not parse tool-shaped arguments")
var tracker = ToolCallTracker(registry: .init())
tracker.apply(patch: sanitized, thread: "a", at: date)
expect(tracker.props() == [ToolProp(identity: .browser, callCount: 1)], "Unknown browser targets must be generic")
tracker.apply(patch: finish(), thread: "a", at: date)
expect(tracker.props().isEmpty, "A completed call must disappear")

// A2/A3: ID isolation, shared software refcounts, duplicate and reordered end.
let registry = ToolApplicationRegistry(servers: ["browser-a": "com.google.Chrome", "browser-b": "com.apple.Safari"])
tracker = ToolCallTracker(registry: registry)
tracker.apply(patch: patch(item("one", server: "browser-a")), thread: "a", at: date)
tracker.apply(patch: patch(item("two", server: "browser-a"), "1"), thread: "a", at: date)
tracker.apply(patch: patch(item("one", server: "browser-b")), thread: "b", at: date)
expect(tracker.props().count == 2 && tracker.props()[0].callCount == 2, "Same software shares a prop, threads and IDs stay isolated")
tracker.apply(patch: finish(), thread: "a", at: date)
expect(tracker.props()[0].callCount == 1, "First end must not remove shared software")
tracker.apply(patch: finish("1", status: "failed"), thread: "a", at: date)
expect(tracker.props() == [ToolProp(identity: .application("com.apple.Safari"), callCount: 1)], "A failed call must end independently")
tracker.apply(patch: patch(item("one", server: "browser-a")), thread: "a", at: date)
expect(tracker.props().count == 1, "Late start must not resurrect a finished ID")
tracker.apply(patch: finish("2", status: "cancelled"), thread: "a", at: date)
tracker.apply(patch: patch(item("reordered"), "2"), thread: "a", at: date)
expect(tracker.props().count == 1, "A status arriving before identity must stay terminal")
tracker.apply(patch: ["path": base + ["0"], "op": "remove"], thread: "b", at: date)
expect(tracker.props().isEmpty, "Item deletion must end the call")
tracker.apply(patch: patch(item("history")), thread: "c", at: date, historical: true)
tracker.apply(patch: patch(item("history")), thread: "c", at: date)
expect(tracker.props().isEmpty, "Historical items must never animate")
tracker.apply(patch: patch(item("replace"), "3"), thread: "a", at: date)
tracker.apply(patch: ["path": base, "op": "replace", "value": []], thread: "a", at: date)
expect(tracker.props().isEmpty, "Replacing an items collection must clear absent calls")
tracker.reset()
tracker.apply(patch: patch(item("first")), thread: "a", at: date)
tracker.apply(patch: patch(item("second"), "1"), thread: "a", at: date)
tracker.apply(patch: ["path": base + ["0"], "op": "remove"], thread: "a", at: date)
expect(tracker.props().first?.callCount == 1, "Deleting first item must leave the second active")
tracker.apply(patch: finish(), thread: "a", at: date)
expect(tracker.props().isEmpty, "The second item's shifted index must still end the correct ID")
tracker.reset()
tracker.apply(patch: patch(item("existing")), thread: "a", at: date)
tracker.apply(patch: patch(item("inserted")), thread: "a", at: date)
expect(tracker.props().first?.callCount == 2, "Array insertion must not cancel the original item")
tracker.apply(patch: finish("1"), thread: "a", at: date)
tracker.apply(patch: finish(), thread: "a", at: date)
expect(tracker.props().isEmpty, "Both inserted and shifted calls must end")
tracker.reset()
tracker.apply(patch: ["path": base + ["0", "server"], "value": "browser-a"], thread: "a", at: date)
tracker.apply(patch: patch(["id": "identity-last", "type": "mcpToolCall", "status": "inProgress"]), thread: "a", at: date)
expect(tracker.props().first?.identity == .application("com.google.Chrome"), "Metadata arriving before ID must preserve the explicit registration")
tracker.reset()
tracker.apply(patch: patch(item("old-turn")), thread: "a", at: date)
tracker.apply(patch: ["path": ["turns", "0"], "op": "add", "value": ["id": "new-turn", "items": [item("new-turn-call")]]], thread: "a", at: date)
expect(tracker.props().first?.callCount == 2, "Inserting a turn must shift its entire old item subtree")
tracker.apply(patch: ["path": ["turns", "1", "items", "0", "status"], "value": "completed"], thread: "a", at: date)
expect(tracker.props().first?.callCount == 1, "An old turn's shifted call must still end")
tracker.reset()
tracker.apply(patch: patch(item("old-item")), thread: "a", at: date)
tracker.apply(patch: patch(["type": "mcpToolCall"]), thread: "a", at: date)
tracker.apply(patch: ["path": base + ["0", "id"], "value": "partial-insert"], thread: "a", at: date)
tracker.apply(patch: finish(status: "inProgress"), thread: "a", at: date)
expect(tracker.props().reduce(0, { $0 + $1.callCount }) == 2, "A partial item insertion must not cancel its shifted sibling")
let connectorRegistry = ToolApplicationRegistry(connectors: ["verified": "com.apple.Safari"])
var connectorTracker = ToolCallTracker(registry: connectorRegistry)
connectorTracker.apply(patch: patch(item("context")), thread: "a", at: date)
let contextPatch: [String: Any] = ["path": base + ["0", "appContext"], "value": ["connectorId": "verified", "appName": "SECRET"]]
connectorTracker.apply(patch: ToolCallTracker.metadataPatch(contextPatch)!, thread: "a", at: date)
expect(connectorTracker.props().first?.identity == .application("com.apple.Safari"), "An appContext object patch must update registered identity")
connectorTracker.apply(patch: ["path": base + ["0", "appContext"], "op": "remove"], thread: "a", at: date)
expect(connectorTracker.props().first?.identity == .browser, "Removing appContext must not retain a stale app mapping")

// Observed normalized-map shape and partial metadata updates.
tracker.reset()
let mappedPath = ["turnHistory", "v1", "entitiesByKey", "turn-1", "items", "entitiesByKey", "call-1"]
tracker.apply(patch: ["path": mappedPath, "value": item("mapped")], thread: "a", at: date)
expect(tracker.props().count == 1, "Normalized entity-map paths must resolve")
tracker.apply(patch: ["path": mappedPath + ["status"], "value": "interrupted"], thread: "a", at: date)
expect(tracker.props().isEmpty, "Map status patches must match the original call")
tracker.apply(patch: patch(["id": "partial", "type": "dynamicToolCall"]), thread: "a", at: date)
tracker.apply(patch: finish(status: "inProgress"), thread: "a", at: date)
expect(tracker.props().count == 1, "A later status can complete metadata without reading arguments")
tracker.expire(at: date.addingTimeInterval(301))
expect(tracker.props().isEmpty, "Missing end must fail closed at 300 seconds")
var bounded = ToolCallTracker(capacity: 4)
for index in 0..<20 { bounded.apply(patch: patch(item("id-\(index)"), "\(index)"), thread: "a", at: date) }
expect(bounded.saturated && bounded.retainedCount <= 4 && bounded.props().isEmpty, "Memory saturation must be bounded and fail closed")
bounded.reset()
expect(!bounded.saturated && bounded.retainedCount == 0, "A new connection resets the bounded ledger")

// A4/A5: actual store delivery and scheduled expiry, not just a pure reducer.
var now = date
var scheduled: [(TimeInterval, () -> Void)] = []
let store = ThreadStatusStore(now: { now }, toolRegistry: registry, schedule: { scheduled.append(($0, $1)) })
var current: AggregatePetStatus!
store.onChange = { current = $0 }
store.markConnected()
store.updateRuntime(threadId: "a", type: "active")
let startedAt = current.tasks.first?.startedAt
store.applyToolPatch(patch(item("store")), threadId: "a")
expect(current.toolProps.count == 1 && current.tasks.first?.startedAt == startedAt, "Tool props must not reset task duration")
store.markDisconnected(issueCode: "fixture")
expect(current.toolProps.isEmpty, "Props must clear immediately, not after the reconnect grace")
store.markConnected()
store.updateRuntime(threadId: "a", type: "active")
store.applyToolPatch(patch(item("new-session")), threadId: "a")
store.resetToolSnapshot(threadId: "a")
expect(current.toolProps.isEmpty, "Snapshot replacement must stop old interactions")
store.applyToolPatch(patch(item("waiting"), "1"), threadId: "a")
store.updateRuntime(threadId: "a", type: "active", activeFlags: ["waitingOnApproval"])
expect(current.toolProps.isEmpty, "Waiting is not software manipulation")
store.updateTurn(threadId: "a", status: "inProgress")
store.applyToolPatch(patch(item("expiry"), "2"), threadId: "a")
now = date.addingTimeInterval(301)
let pending = scheduled; scheduled.removeAll()
for (_, action) in pending { action() }
expect(current.toolProps.isEmpty, "The real scheduled path must clear expired props without a new tool event")
store.applyToolPatch(patch(item("ending"), "3"), threadId: "a")
store.updateTurn(threadId: "a", status: "completed")
expect(current.toolProps.isEmpty, "Turn completion must clear props")
store.applyToolPatch(patch(item("late"), "4"), threadId: "a")
expect(current.toolProps.isEmpty, "A late call after a terminal turn must not restart interaction")
print("PET_TOOL_LIFECYCLE_OK (privacy, reference counts, reorder, maps, deletion, snapshots, connection, TTL, bounds)")

// A6/A7: drive the real native controller at 30Hz with injected metadata.
let app = NSApplication.shared
app.setActivationPolicy(.prohibited)
var time: TimeInterval = 100
var reduceMotion = false
let controller = TouchBarController(animationClock: { time }, systemReduceMotion: { reduceMotion })
var settings = AppSettings()
settings.motionPreference = .standard
controller.applySettings(settings)
var display = PetStatusAggregator.aggregate([
    ThreadPetStatus(threadId: "fixture-a", state: .working(nil), updatedAt: date, title: "工具图标联动"),
    ThreadPetStatus(threadId: "fixture-b", state: .working(nil), updatedAt: date, title: "狐狸动画优化")
], connectionState: .online, initialScanComplete: true)
display.toolProps = [
    ToolProp(identity: .browser, callCount: 2), ToolProp(identity: .computer, callCount: 1),
    ToolProp(identity: .tool, callCount: 1), ToolProp(identity: .application("fixture.uninstalled"), callCount: 1)
]
controller.update(display)
let content = controller.touchBar(NSTouchBar(), makeItemForIdentifier: .init("dev.codex.touch-pet.content")) as! NSCustomTouchBarItem
let view = content.view
view.frame = NSRect(x: 0, y: 0, width: 620, height: 30)
let pet = view.subviews[0]
let sprite = pet.subviews.compactMap { $0 as? NSImageView }.first!
let scene = pet.subviews.compactMap { $0 as? ToolPropSceneView }.first!
let rail = view.subviews[1].subviews.compactMap { $0 as? NSScrollView }.first!
func tick() { controller.perform(NSSelectorFromString("advanceAnimation")); view.layoutSubtreeIfNeeded() }
let window = NSWindow(contentRect: view.frame, styleMask: [.borderless], backing: .buffered, defer: false)
window.appearance = NSAppearance(named: .darkAqua)
window.contentView = view
tick()
// RebuildTaskRail schedules one main-queue resize after initial layout, as
// it does in the real application's run loop. Let that callback run before
// treating an offscreen frame as visual evidence.
RunLoop.main.run(until: Date().addingTimeInterval(0.01))
tick()
expect(!scene.isHidden && scene.positions.count == 3, "Show three props with overflow, never replace the task rail")
var repeatedPoseWrites = 0
let poseObservation = sprite.observe(\.image, options: [.new]) { _, _ in repeatedPoseWrites += 1 }
for _ in 0..<120 { tick() }
poseObservation.invalidate()
expect(repeatedPoseWrites == 0, "Tool scenes must commit only the final changed pose, not working-then-tool images on every tick")
let fixedLayoutConstants = pet.constraints.map(\.constant)
expect((rail.documentView as? NSStackView)?.arrangedSubviews.count == 2 && rail.frame.width >= 300, "Both capsules remain accessible")
expect(abs(sprite.frame.midY - 15) < 0.01, "The fox stays on the ground")
let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/tool-props-preview")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
var lastPositions: [CGPoint] = []
var largestDelta: CGFloat = 0
var largestFoxDelta: CGFloat = 0
var previousFoxX = sprite.frame.midX
var frameImages = Set<Data>()
for frame in 0..<360 {
    autoreleasepool {
        time = 100 + Double(frame) / 30
        tick()
        expect(pet.constraints.map(\.constant) == fixedLayoutConstants, "Tool walking must not mutate playfield Auto Layout constraints")
        expect(sprite.frame.size == NSSize(width: 48, height: 30), "Tool pose changes must preserve the fixed-size sprite")
        for (point, last) in zip(scene.positions, lastPositions) { largestDelta = max(largestDelta, abs(point.x - last.x)) }
        lastPositions = scene.positions
        if let data = sprite.image?.tiffRepresentation { frameImages.insert(data) }
        expect(scene.positions.allSatisfy { $0.x >= 9 && $0.x <= 211 && $0.y >= 9 && $0.y <= 21 }, "Props stay inside the 220x30 scene")
        let sample = ToolPropChoreography.sample(elapsed: Double(frame) / 30, count: 4, animated: true)
        largestFoxDelta = max(largestFoxDelta, abs(sprite.frame.midX - previousFoxX))
        previousFoxX = sprite.frame.midX
        // AppKit snaps NSLayoutConstraint geometry to the backing pixel grid;
        // compare with that physical tolerance, not subpixel mathematical x.
        let pixel = 1 / window.backingScaleFactor
        expect(abs(sprite.frame.midX - sample.foxX) <= pixel && abs(sprite.frame.midY - 15) < 0.01, "Only ground walking may move the fox; frame=\(frame), actual=\(sprite.frame.midX)/\(sprite.frame.midY), expected=\(sample.foxX)")
        guard let bitmap = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { fatalError("No native capture") }
        window.appearance!.performAsCurrentDrawingAppearance {
            CATransaction.flush()
            view.cacheDisplay(in: view.bounds, to: bitmap)
        }
        // Touch Bar provides an opaque black surface. Offscreen AppKit
        // captures do not, so compose the native rendering onto that surface.
        let source = bitmap.cgImage!
        let context = CGContext(data: nil, width: source.width, height: source.height,
            bitsPerComponent: 8, bytesPerRow: source.width * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        let rect = CGRect(x: 0, y: 0, width: source.width, height: source.height)
        context.setFillColor(CGColor(gray: 0, alpha: 1)); context.fill(rect)
        context.draw(source, in: rect)
        let target = output.appendingPathComponent(String(format: "frame-%04d.png", frame))
        let destination = CGImageDestinationCreateWithURL(target as CFURL, "public.png" as CFString, 1, nil)!
        CGImageDestinationAddImage(destination, context.makeImage()!, nil)
        expect(CGImageDestinationFinalize(destination), "Unable to save native capture")
    }
}
print("PET_TOOL_SCENE_METRICS (propDelta=\(largestDelta), foxDelta=\(largestFoxDelta), poses=\(frameImages.count))")
expect(largestDelta < 1 && largestFoxDelta < 7 && frameImages.count >= 6, "Motion must be continuous with real walking and paw poses")
for elapsed in stride(from: 0.0, through: 1.33, by: 1.0 / 30) {
    expect(ToolPropChoreography.sample(elapsed: elapsed, count: 3, animated: true).positions[0].x == 94, "Prop cannot move itself before paw contact")
}
let afterContact = ToolPropChoreography.sample(elapsed: 1.63, count: 3, animated: true)
expect(afterContact.positions[0].x == 98, "Prop moves exactly four points after contact")
reduceMotion = true; tick()
let still = scene.positions
time += 1; tick()
expect(scene.positions == still && !scene.isHidden, "Reduce Motion preserves icons, removes movement")
reduceMotion = false; settings.motionPreference = .staticOnly; controller.applySettings(settings); tick()
time += 1; tick()
expect(scene.positions == still, "Static mode must keep parked icons")
settings.motionPreference = .standard; settings.quietMode = true; controller.applySettings(settings); tick()
time += 1; tick()
expect(scene.positions == still, "Quiet mode must keep parked icons")
display.state = .waitingApproval; display.waitingCount = 1
controller.update(display); tick()
expect(!scene.isHidden && scene.positions == still, "A waiting sibling cannot hide active software; park props while preserving the waiting fox")
display.connectionState = .reconnecting; controller.update(display); tick()
expect(scene.isHidden, "The real view must clear props during reconnect")
print("PET_TOOL_SCENE_OK (3 props + overflow, 2 capsules, grounded walking, contact timing, 12s continuous animation including reverse return, accessibility modes)")

// Registered app icons: injected identity is separate from target detection.
var iconLoads = 0
let artwork = ToolPropArtwork(applicationIcon: { _ in iconLoads += 1; return NSImage(size: NSSize(width: 32, height: 32)) })
for _ in 0..<100 { _ = artwork.image(for: .application("com.google.Chrome")) }
expect(iconLoads == 1, "An installed icon must not reload every animation frame")
var usage = rusage()
if getrusage(RUSAGE_SELF, &usage) == 0 { print("PET_TOOL_TEST_PEAK_RSS_MB (\(usage.ru_maxrss / 1_048_576))") }
