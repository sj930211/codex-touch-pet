import AppKit

/// Loads the approved fox artwork without making the artwork responsible for
/// the semantic state. Missing state-specific frames intentionally fall back
/// to the idle fox while the text and color remain authoritative.
final class PetArtwork {
    private struct AnimationSpec {
        let resourceName: String
        let loops: Bool
        let frameCount: Int
        let pingPong: Bool
        /// Optional curated source-frame order for small Touch Bar sizes.
        /// Some generated look-around rows are semantically useful but their
        /// widest head turns read as lateral wobble when reduced to ~30px.
        let frameSequence: [Int]?

        var playbackFrameCount: Int {
            if let frameSequence {
                return frameSequence.count
            }
            guard pingPong, frameCount > 1 else { return frameCount }
            return frameCount * 2 - 2
        }
    }

    private var cache: [String: NSImage] = [:]
    private var frameCache: [String: [NSImage]] = [:]

    private let semanticFrameCount = 6
    private let actionFrameCount = 8

    func image(for state: PetState) -> NSImage? {
        image(for: state, frameIndex: 0)
    }

    func image(for state: PetState, frameIndex: Int) -> NSImage? {
        image(for: state, activity: nil, frameIndex: frameIndex)
    }

    func image(
        for state: PetState,
        activity: PetIdleActivityDirector.Activity?,
        frameIndex: Int
    ) -> NSImage? {
        image(
            for: state,
            activity: activity,
            direction: .right,
            frameIndex: frameIndex
        )
    }

    func image(
        for state: PetState,
        activity: PetIdleActivityDirector.Activity?,
        direction: PetIdleActivityDirector.RunDirection,
        frameIndex: Int
    ) -> NSImage? {
        if let animation = animationSpec(for: state, activity: activity, direction: direction),
           let frame = loadFrame(animation: animation, index: frameIndex) {
            return frame
        }

        let preferredName: String
        switch state {
        case .working:
            preferredName = "fox-working"
        case .waitingApproval:
            preferredName = "fox-waiting-approval"
        case .waitingInput:
            preferredName = "fox-waiting-input"
        case .completed:
            preferredName = "fox-completed"
        case .failed:
            preferredName = "fox-failed"
        case .systemError:
            preferredName = "fox-system-error"
        case .disconnected:
            preferredName = "fox-disconnected"
        case .connecting:
            preferredName = "fox-connecting"
        case .idle:
            preferredName = "fox-idle"
        case .interrupted:
            preferredName = "fox-interrupted"
        }

        return load(named: preferredName) ?? load(named: "fox-idle")
    }

    func hasAnimatedFrames(for state: PetState) -> Bool {
        hasAnimatedFrames(for: state, activity: nil)
    }

    func hasAnimatedFrames(
        for state: PetState,
        activity: PetIdleActivityDirector.Activity?,
        direction: PetIdleActivityDirector.RunDirection = .right
    ) -> Bool {
        guard let animation = animationSpec(for: state, activity: activity, direction: direction) else { return false }
        return loadFrames(named: animation.resourceName, count: animation.frameCount)?.count == animation.frameCount
    }

    func animationFrameCount(for state: PetState) -> Int? {
        animationFrameCount(for: state, activity: nil)
    }

    func animationFrameCount(
        for state: PetState,
        activity: PetIdleActivityDirector.Activity?,
        direction: PetIdleActivityDirector.RunDirection = .right
    ) -> Int? {
        guard let animation = animationSpec(for: state, activity: activity, direction: direction),
              hasAnimatedFrames(for: state, activity: activity, direction: direction) else {
            return nil
        }
        return animation.playbackFrameCount
    }

    func animationLoops(for state: PetState) -> Bool {
        animationLoops(for: state, activity: nil)
    }

    func animationLoops(
        for state: PetState,
        activity: PetIdleActivityDirector.Activity?,
        direction: PetIdleActivityDirector.RunDirection = .right
    ) -> Bool {
        animationSpec(for: state, activity: activity, direction: direction)?.loops == true
    }

    private func animationSpec(
        for state: PetState,
        activity: PetIdleActivityDirector.Activity?,
        direction: PetIdleActivityDirector.RunDirection
    ) -> AnimationSpec? {
        if state == .idle, let activity {
            switch activity {
            case .run:
                let resourceName = direction == .left ? "fox-idle-run-left" : "fox-idle-run-right"
                return AnimationSpec(resourceName: resourceName, loops: true, frameCount: actionFrameCount, pingPong: false, frameSequence: nil)
            case .jump:
                return AnimationSpec(resourceName: "fox-idle-jump", loops: false, frameCount: actionFrameCount, pingPong: false, frameSequence: nil)
            case .play:
                return AnimationSpec(resourceName: "fox-idle-play", loops: false, frameCount: actionFrameCount, pingPong: false, frameSequence: nil)
            case .inspect:
                return AnimationSpec(
                    resourceName: "fox-connecting", loops: true,
                    frameCount: semanticFrameCount, pingPong: false,
                    frameSequence: [0, 0, 3, 3, 5, 5, 3, 3]
                )
            case .stretch:
                return AnimationSpec(
                    resourceName: "fox-completed", loops: false,
                    frameCount: semanticFrameCount, pingPong: false, frameSequence: nil
                )
            case .nap:
                return AnimationSpec(
                    resourceName: "fox-idle", loops: true,
                    frameCount: semanticFrameCount, pingPong: false,
                    frameSequence: [0, 2, 3, 3, 3, 3, 3, 4, 5, 0]
                )
            case .wander:
                break
            }
        }
        switch state {
        case .idle:
            return AnimationSpec(
                resourceName: "fox-idle", loops: true,
                frameCount: semanticFrameCount, pingPong: false,
                frameSequence: [0, 0, 0, 0, 0, 0, 0, 0, 1, 2, 3, 4, 5, 0, 0, 0, 0, 0, 0, 0, 0, 0]
            )
        case .working:
            return AnimationSpec(resourceName: "fox-working", loops: true, frameCount: semanticFrameCount, pingPong: true, frameSequence: nil)
        case .waitingApproval:
            return AnimationSpec(resourceName: "fox-waiting-approval", loops: true, frameCount: semanticFrameCount, pingPong: true, frameSequence: nil)
        case .waitingInput:
            // Keep the centered asking pose and its blink. The outer head-tilt
            // frames are too wide at Touch Bar scale and look like wobble.
            return AnimationSpec(
                resourceName: "fox-waiting-input",
                loops: true,
                frameCount: semanticFrameCount,
                pingPong: false,
                frameSequence: [2, 2, 3, 3, 2, 2]
            )
        case .completed:
            return AnimationSpec(resourceName: "fox-completed", loops: false, frameCount: semanticFrameCount, pingPong: false, frameSequence: nil)
        case .failed:
            return AnimationSpec(resourceName: "fox-failed", loops: false, frameCount: semanticFrameCount, pingPong: false, frameSequence: nil)
        case .systemError:
            return AnimationSpec(resourceName: "fox-system-error", loops: false, frameCount: semanticFrameCount, pingPong: false, frameSequence: nil)
        case .connecting:
            // Retain a restrained scan without visiting the two widest turns.
            return AnimationSpec(
                resourceName: "fox-connecting",
                loops: true,
                frameCount: semanticFrameCount,
                pingPong: false,
                frameSequence: [0, 3, 3, 5, 5, 3]
            )
        case .interrupted:
            return AnimationSpec(resourceName: "fox-interrupted", loops: false, frameCount: semanticFrameCount, pingPong: false, frameSequence: nil)
        case .disconnected:
            // Use the quiet centered poses; the disconnected state should not
            // continuously scan side to side while it is waiting to reconnect.
            return AnimationSpec(
                resourceName: "fox-disconnected",
                loops: true,
                frameCount: semanticFrameCount,
                pingPong: false,
                frameSequence: [0, 1, 1, 4, 5, 5]
            )
        }
    }

    private func loadFrames(named name: String, count: Int) -> [NSImage]? {
        let cacheKey = "\(name)#\(count)"
        if let cachedFrames = frameCache[cacheKey] { return cachedFrames }
        var frames: [NSImage] = []
        for frameIndex in 0..<count {
            guard let url = resourceURL(named: "\(name)-\(String(format: "%02d", frameIndex))"),
                  let image = NSImage(contentsOf: url) else {
                break
            }
            image.isTemplate = false
            frames.append(image)
        }
        guard frames.count == count else { return nil }
        frameCache[cacheKey] = frames
        return frames
    }

    private func loadFrame(animation: AnimationSpec, index: Int) -> NSImage? {
        guard let frames = loadFrames(named: animation.resourceName, count: animation.frameCount), !frames.isEmpty else {
            return nil
        }
        let frameIndex: Int
        if animation.loops {
            let cycleLength = animation.playbackFrameCount
            let position = ((index % cycleLength) + cycleLength) % cycleLength
            if let frameSequence = animation.frameSequence {
                frameIndex = frameSequence[position]
            } else if animation.pingPong, position >= frames.count {
                frameIndex = cycleLength - position
            } else {
                frameIndex = position
            }
        } else {
            frameIndex = min(max(index, 0), frames.count - 1)
        }
        return frames[frameIndex]
    }

    private func load(named name: String) -> NSImage? {
        if let cached = cache[name] {
            return cached
        }

        guard let url = resourceURL(named: name),
              let image = NSImage(contentsOf: url) else {
            return nil
        }

        image.isTemplate = false
        cache[name] = image
        return image
    }

    private func resourceURL(named name: String) -> URL? {
        if let bundled = Bundle.main.url(
            forResource: name,
            withExtension: "png",
            subdirectory: "Fox"
        ) {
            return bundled
        }

        // `run-direct` bypasses LaunchServices for local Touch Bar testing.
        // In that mode Bundle.main is not an app bundle, so load the same
        // approved resources from the project working directory.
        let local = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
            .appendingPathComponent("Resources/Fox")
            .appendingPathComponent("\(name).png")
        return FileManager.default.isReadableFile(atPath: local.path) ? local : nil
    }
}
