import AppKit

guard let instanceGuard = SingleInstanceGuard.acquire() else {
    exit(EXIT_SUCCESS)
}

let application = NSApplication.shared
let delegate = AppDelegate()
application.delegate = delegate
withExtendedLifetime(instanceGuard) {
    application.run()
}
