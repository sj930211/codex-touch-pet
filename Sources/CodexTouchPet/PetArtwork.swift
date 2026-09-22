import AppKit

/// Loads the approved fox artwork without making the artwork responsible for
/// the semantic state. Missing state-specific frames intentionally fall back
/// to the idle fox while the text and color remain authoritative.
final class PetArtwork {
    private struct AnimationSpec {
        let resourceName: String
        let loops: Bool
    }

    private var cache: [String: NSImage] = [:]
    private var frameCache: [String: [NSImage]] = [:]

    private let animatedFrameCount = 6

    func image(for state: PetState) -> NSImage? {
        image(for: state, frameIndex: 0)
    }

    func image(for state: PetState, frameIndex: Int) -> NSImage? {
        if let animation = animationSpec(for: state),
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
        guard let animation = animationSpec(for: state) else { return false }
        return loadFrames(named: animation.resourceName)?.count == animatedFrameCount
    }

    func animationFrameCount(for state: PetState) -> Int? {
        hasAnimatedFrames(for: state) ? animatedFrameCount : nil
    }

    func animationLoops(for state: PetState) -> Bool {
        animationSpec(for: state)?.loops == true
    }

    private func animationSpec(for state: PetState) -> AnimationSpec? {
        switch state {
        case .idle:
            return AnimationSpec(resourceName: "fox-idle", loops: true)
        case .working:
            return AnimationSpec(resourceName: "fox-working", loops: true)
        case .waitingApproval:
            return AnimationSpec(resourceName: "fox-waiting-approval", loops: true)
        case .waitingInput:
            return AnimationSpec(resourceName: "fox-waiting-input", loops: true)
        case .completed:
            return AnimationSpec(resourceName: "fox-completed", loops: false)
        case .failed:
            return AnimationSpec(resourceName: "fox-failed", loops: false)
        case .systemError:
            return AnimationSpec(resourceName: "fox-system-error", loops: false)
        case .connecting:
            return AnimationSpec(resourceName: "fox-connecting", loops: true)
        case .interrupted:
            return AnimationSpec(resourceName: "fox-interrupted", loops: false)
        case .disconnected:
            return AnimationSpec(resourceName: "fox-disconnected", loops: true)
        }
    }

    private func loadFrames(named name: String) -> [NSImage]? {
        if let cachedFrames = frameCache[name] { return cachedFrames }
        var frames: [NSImage] = []
        for frameIndex in 0..<animatedFrameCount {
            guard let url = resourceURL(named: "\(name)-\(String(format: "%02d", frameIndex))"),
                  let image = NSImage(contentsOf: url) else {
                break
            }
            image.isTemplate = false
            frames.append(image)
        }
        guard frames.count == animatedFrameCount else { return nil }
        frameCache[name] = frames
        return frames
    }

    private func loadFrame(animation: AnimationSpec, index: Int) -> NSImage? {
        guard let frames = loadFrames(named: animation.resourceName), !frames.isEmpty else {
            return nil
        }
        let frameIndex: Int
        if animation.loops {
            frameIndex = ((index % frames.count) + frames.count) % frames.count
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
