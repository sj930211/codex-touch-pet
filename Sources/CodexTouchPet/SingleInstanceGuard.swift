import Darwin
import Foundation

/// Keeps only one Touch Bar owner alive for the current macOS user.
/// Multiple owners register duplicate timers, IPC subscriptions, and private
/// Touch Bar items, so later launches exit before AppKit is initialized.
final class SingleInstanceGuard {
    private let descriptor: Int32

    private init(descriptor: Int32) {
        self.descriptor = descriptor
    }

    static func acquire(identifier: String = "dev.codex.touch-pet") -> SingleInstanceGuard? {
        let lockURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(identifier).lock", isDirectory: false)
        let descriptor = Darwin.open(lockURL.path, O_CREAT | O_RDWR, S_IRUSR | S_IWUSR)
        guard descriptor >= 0 else { return nil }
        guard Darwin.lockf(descriptor, F_TLOCK, 0) == 0 else {
            Darwin.close(descriptor)
            return nil
        }
        return SingleInstanceGuard(descriptor: descriptor)
    }

    deinit {
        _ = Darwin.lockf(descriptor, F_ULOCK, 0)
        Darwin.close(descriptor)
    }
}
