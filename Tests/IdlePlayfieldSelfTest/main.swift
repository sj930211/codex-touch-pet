import AppKit
import CoreGraphics
import CoreText
import Darwin
import Foundation
import ImageIO

func expect(_ condition: @autoclosure () -> Bool, _ message: String) {
    guard condition() else { fatalError(message) }
}

let controller = TouchBarController()
var settings = AppSettings()
settings.motionPreference = .staticOnly
controller.applySettings(settings)
let idleStatus = AggregatePetStatus(
    state: .idle, connectionState: .online, activeCount: 0, waitingCount: 0, trackedCount: 0
)
controller.update(idleStatus)
guard let item = controller.touchBar(
    NSTouchBar(), makeItemForIdentifier: NSTouchBarItem.Identifier("dev.codex.touch-pet.content")
) as? NSCustomTouchBarItem else { fatalError("Unable to create the actual Touch Bar content view") }
let view = item.view
view.frame = NSRect(x: 0, y: 0, width: PetActivityLayout.contentWidth, height: 30)
view.layoutSubtreeIfNeeded()
expect(view.subviews.count == 2, "Expanded content must keep pet and status in the same item")
let petView = view.subviews[0]
let statusView = view.subviews[1]
guard let rail = statusView.subviews.compactMap({ $0 as? NSScrollView }).first,
      let connection = statusView.subviews.compactMap({ $0 as? NSTextField }).first else {
    fatalError("Missing task rail or connection status")
}
expect(abs(petView.frame.width - 528) < 0.01, "Idle AppKit layout must actually allocate the wide playfield")
expect(rail.isHidden, "An empty task rail must give its space to idle play")
expect(connection.frame.maxX <= statusView.bounds.width + 0.01, "Connection status must remain inside the idle layout")

let now = Date()
let workingStatus = PetStatusAggregator.aggregate([
    ThreadPetStatus(threadId: "fixture-a", state: .working(nil), updatedAt: now, title: "狐狸动画优化"),
    ThreadPetStatus(threadId: "fixture-b", state: .waitingInput, updatedAt: now, title: "界面截图整理")
], connectionState: .online, initialScanComplete: true)
controller.update(workingStatus)
view.layoutSubtreeIfNeeded()
expect(abs(petView.frame.width - 220) < 0.01, "Active tasks must restore the full task rail")
expect(!rail.isHidden && rail.frame.width >= 300, "Active task capsules must remain visible")
expect((rail.documentView as? NSStackView)?.arrangedSubviews.count == 2, "Both task capsules must remain attached")

var idleWithHistory = idleStatus
idleWithHistory.tasks = [ThreadPetStatus(threadId: "fixture-history", state: .completed, updatedAt: now)]
controller.update(idleWithHistory)
view.layoutSubtreeIfNeeded()
expect(abs(petView.frame.width - 220) < 0.01 && !rail.isHidden, "A visible terminal task must not be covered by idle play")
controller.update(idleStatus)
view.layoutSubtreeIfNeeded()
expect(abs(petView.frame.width - 528) < 0.01, "Wide idle playfield must return when the task rail becomes empty")
print("PET_PLAYFIELD_LAYOUT_OK (idle=528pt, task=220pt, 2 visible capsules)")

// Drive the actual timer selector without registering a modal Touch Bar or
// changing the user's accessibility settings. Clock and system preference are
// injected; layout, pose selection, frame playback and interruption are real.
var playbackTime: TimeInterval = 100
var reduceMotion = false
let playback = TouchBarController(
    animationClock: { playbackTime },
    systemReduceMotion: { reduceMotion },
    idleActivityDirector: PetIdleActivityDirector(seed: 0xC0D3_5EED)
)
var animatedSettings = AppSettings()
animatedSettings.motionPreference = .standard
playback.applySettings(animatedSettings)
playback.update(idleStatus)
guard let playbackItem = playback.touchBar(
    NSTouchBar(), makeItemForIdentifier: NSTouchBarItem.Identifier("dev.codex.touch-pet.content")
) as? NSCustomTouchBarItem else { fatalError("Unable to create playback content") }
let playbackView = playbackItem.view
playbackView.frame = NSRect(x: 0, y: 0, width: 620, height: 30)
let playbackPet = playbackView.subviews[0]
guard let playbackImage = playbackPet.subviews.compactMap({ $0 as? NSImageView }).first else {
    fatalError("Missing real playback image view")
}
let expectedArtwork = PetArtwork()
func tickPlayback() {
    _ = playback.perform(NSSelectorFromString("advanceAnimation"))
    playbackView.layoutSubtreeIfNeeded()
}
func sameFrame(_ actual: NSImage?, _ expected: NSImage?) -> Bool {
    guard let actual, let expected else { return false }
    return actual.tiffRepresentation == expected.tiffRepresentation
}
var oracle = PetIdleActivityDirector(seed: 0xC0D3_5EED)
var previousSegmentID = -1
var replayedJumps = 0
var sleepOffset: TimeInterval = 0
var testedMidJumpPause = false
for sample in 0...7_200 {
    autoreleasepool {
        playbackTime = 100 + Double(sample) / 30 + sleepOffset
        let expected = oracle.motion(at: playbackTime, travel: PetActivityLayout.travel(wideIdle: true), date: now)
        tickPlayback()
        let actualX = playbackImage.frame.midX - playbackPet.bounds.midX
        // Windowless AppKit layout snaps to whole backing pixels (1x here).
        expect(abs(actualX - expected.x) <= 0.51, "Actual controller timer must follow the production idle trajectory within backing-pixel rounding (sample=\(sample), actual=\(actualX), expected=\(expected.x), activity=\(expected.activity))")
        expect(playbackImage.frame.minX >= 0 && playbackImage.frame.maxX <= playbackPet.bounds.width, "Actual image must remain entirely inside its activity area")
        let expectedFrame = Int(expected.elapsed / expected.activity.frameInterval)
        expect(
            sameFrame(
                playbackImage.image,
                expectedArtwork.image(
                    for: .idle,
                    activity: expected.activity,
                    direction: expected.direction,
                    frameIndex: expectedFrame
                )
            ),
            "Actual controller must play every idle action frame from the segment clock"
        )
        if expected.segmentID != previousSegmentID {
            expect(sameFrame(playbackImage.image, expectedArtwork.image(for: .idle, activity: expected.activity, direction: expected.direction, frameIndex: 0)), "Every new action segment must restart its actual image at frame zero")
            if expected.activity == .jump { replayedJumps += 1 }
            previousSegmentID = expected.segmentID
        }
        if !testedMidJumpPause, expected.activity == .jump, expected.elapsed >= 0.5 {
            let beforePause = playbackImage.image
            playbackTime += 120
            sleepOffset += 120
            let resumed = oracle.motion(at: playbackTime, travel: PetActivityLayout.travel(wideIdle: true), date: now)
            tickPlayback()
            expect(abs(resumed.elapsed - expected.elapsed) < 0.001, "Pause must preserve the production jump clock")
            expect(sameFrame(playbackImage.image, beforePause), "Actual playback must resume the exact mid-jump image after suspension")
            testedMidJumpPause = true
        }
    }
}
expect(replayedJumps >= 2 && testedMidJumpPause, "The real playback test must exercise repeated jumps and an in-flight suspension")

let runningStatus = PetStatusAggregator.aggregate([
    ThreadPetStatus(threadId: "fixture-running", state: .working(nil), updatedAt: now)
], connectionState: .online, initialScanComplete: true)
expect(runningStatus.state.animationIdentity == .working, "The working interruption fixture must really be working")
playback.update(runningStatus)
playbackView.layoutSubtreeIfNeeded()
expect(abs(playbackPet.frame.width - 220) < 0.01, "Working must interrupt the wide idle layout immediately")
expect(abs(playbackImage.frame.midX - playbackPet.bounds.midX) < 0.01, "Working must stop idle traversal and recenter immediately")
expect(sameFrame(playbackImage.image, expectedArtwork.image(for: .working(nil), frameIndex: 0)), "Working must replace the idle pose immediately")
tickPlayback()
playbackTime += 0.17
tickPlayback()
expect(sameFrame(playbackImage.image, expectedArtwork.image(for: .working(nil), frameIndex: 1)), "Semantic working animation must continue through the real timer")
let waitingStatus = PetStatusAggregator.aggregate([
    ThreadPetStatus(threadId: "fixture-waiting", state: .waitingApproval, updatedAt: now)
], connectionState: .online, initialScanComplete: true)
playback.update(idleStatus)
var idleWasMovingBeforeWaiting = false
for _ in 0..<600 {
    playbackTime += 1.0 / 30
    tickPlayback()
    idleWasMovingBeforeWaiting = idleWasMovingBeforeWaiting
        || abs(playbackImage.frame.midX - playbackPet.bounds.midX) > 30
}
expect(idleWasMovingBeforeWaiting, "Waiting interruption must start from an active idle routine")
playback.update(waitingStatus)
playbackView.layoutSubtreeIfNeeded()
expect(sameFrame(playbackImage.image, expectedArtwork.image(for: .waitingApproval, frameIndex: 0)), "Waiting must also interrupt idle play and select its semantic animation")
expect(abs(playbackPet.frame.width - 220) < 0.01 && abs(playbackImage.frame.midX - playbackPet.bounds.midX) < 0.01, "Waiting must interrupt idle traversal and restore the task layout immediately")
playback.update(idleStatus)
playbackView.layoutSubtreeIfNeeded()
expect(abs(playbackPet.frame.width - 528) < 0.01 && abs(playbackImage.frame.midX - playbackPet.bounds.midX) < 0.01, "Returning idle must restore a centered wide playfield")

animatedSettings.motionPreference = .staticOnly
playback.applySettings(animatedSettings)
let staticFrame = playbackImage.image
playbackTime += 5
tickPlayback()
expect(sameFrame(playbackImage.image, staticFrame), "Static preference must freeze the actual image")
expect(abs(playbackImage.frame.midX - playbackPet.bounds.midX) < 0.01, "Static preference must stop traversal")
animatedSettings.motionPreference = .standard
playback.applySettings(animatedSettings)
var resumedTravel = false
for _ in 0..<600 {
    playbackTime += 1.0 / 30
    tickPlayback()
    resumedTravel = resumedTravel || abs(playbackImage.frame.midX - playbackPet.bounds.midX) > 30
}
expect(resumedTravel, "Re-enabling animation must restart idle activity")
reduceMotion = true
tickPlayback()
let reducedFrame = playbackImage.image
playbackTime += 5
tickPlayback()
expect(sameFrame(playbackImage.image, reducedFrame) && abs(playbackImage.frame.midX - playbackPet.bounds.midX) < 0.01, "System Reduce Motion must stop both pose animation and travel")
reduceMotion = false
animatedSettings.quietMode = true
playback.applySettings(animatedSettings)
let quietFrame = playbackImage.image
playbackTime += 5
tickPlayback()
expect(sameFrame(playbackImage.image, quietFrame) && abs(playbackImage.frame.midX - playbackPet.bounds.midX) < 0.01, "Quiet mode must stop both pose animation and travel")
print("PET_CONTROLLER_PLAYBACK_OK (repeated jumps, sleep resume, task interruption, static, Reduce Motion, quiet)")

// Offline previews use the production director, timing and artwork loader.
// They are simulated strips, not screenshots of a physical Touch Bar.
let output = URL(fileURLWithPath: FileManager.default.currentDirectoryPath).appendingPathComponent(".build/idle-preview")
try FileManager.default.createDirectory(at: output, withIntermediateDirectories: true)
let artwork = PetArtwork()
let daytime = Calendar.current.date(bySettingHour: 12, minute: 0, second: 0, of: now) ?? now
var director = PetIdleActivityDirector(seed: 0xC0D3_5EED)
var frameCounts: [PetIdleActivityDirector.Routine: Int] = [:]
var completed = Set<PetIdleActivityDirector.Routine>()
var previousRoutine: PetIdleActivityDirector.Routine?

func saveFrame(_ motion: PetIdleActivityDirector.Motion, to url: URL) {
    let index = Int(motion.elapsed / motion.activity.frameInterval)
    guard let image = artwork.image(for: .idle, activity: motion.activity, direction: motion.direction, frameIndex: index),
          let sprite = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
          let context = CGContext(
            data: nil, width: 1240, height: 60, bitsPerComponent: 8, bytesPerRow: 1240 * 4,
            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ) else { fatalError("Unable to render preview frame") }
    context.setFillColor(NSColor.black.cgColor)
    context.fill(CGRect(x: 0, y: 0, width: 1240, height: 60))
    context.scaleBy(x: 2, y: 2)
    let width = CGFloat(sprite.width) * 30 / CGFloat(sprite.height)
    let x = PetActivityLayout.idlePetWidth / 2 + motion.x - width / 2
    context.draw(sprite, in: CGRect(x: x, y: 0, width: width, height: 30))
    let label = NSAttributedString(string: CodexConnectionState.online.label, attributes: [
        .font: NSFont.systemFont(ofSize: 11, weight: .medium),
        .foregroundColor: NSColor.systemGreen
    ])
    context.textPosition = CGPoint(x: 554, y: 10)
    CTLineDraw(CTLineCreateWithAttributedString(label), context)
    guard let rendered = context.makeImage(),
          let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        fatalError("Unable to encode preview")
    }
    CGImageDestinationAddImage(destination, rendered, nil)
    expect(CGImageDestinationFinalize(destination), "Unable to write preview frame")
}

for time in stride(from: 0.0, through: 240.0, by: 1.0 / 30) {
    let motion = director.motion(at: time, travel: PetActivityLayout.travel(wideIdle: true), date: daytime)
    if let previousRoutine, previousRoutine != motion.routine {
        completed.insert(previousRoutine)
    }
    previousRoutine = motion.routine
    guard let routine = motion.routine, !completed.contains(routine) else { continue }
    let directory = output.appendingPathComponent(routine.rawValue)
    if frameCounts[routine] == nil {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    }
    let count = frameCounts[routine, default: 0]
    autoreleasepool {
        saveFrame(motion, to: directory.appendingPathComponent(String(format: "frame-%04d.png", count)))
    }
    frameCounts[routine] = count + 1
    if completed.count == 4 { break }
}
expect(frameCounts.count == 4, "Every routine must have a preview")
for routine in PetIdleActivityDirector.Routine.allCases {
    expect(frameCounts[routine, default: 0] >= 180, "A routine must remain visible for at least six seconds")
}
print("PET_IDLE_PREVIEWS_OK (4 production-timed routines)")
var resourceUsage = rusage()
if getrusage(RUSAGE_SELF, &resourceUsage) == 0 {
    print("PET_IDLE_TEST_PEAK_RSS_MB (\(resourceUsage.ru_maxrss / 1_048_576))")
}
