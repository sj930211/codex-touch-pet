import AppKit

/// Loads the approved fox artwork without making the artwork responsible for
/// the semantic state. Missing state-specific frames intentionally fall back
/// to the idle fox while the text and color remain authoritative.
final class PetArtwork {
    private var cache: [String: NSImage] = [:]

    func image(for state: PetState) -> NSImage? {
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
        case .disconnected, .connecting, .idle, .interrupted:
            preferredName = "fox-idle"
        }

        return load(named: preferredName) ?? load(named: "fox-idle")
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
