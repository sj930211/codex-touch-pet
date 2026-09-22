import Foundation

enum MotionPreference: String, CaseIterable, Equatable {
    case followSystem
    case standard
    case staticOnly

    var title: String {
        switch self {
        case .followSystem: return "跟随系统"
        case .standard: return "标准"
        case .staticOnly: return "静态"
        }
    }
}

enum EffectivePetMotion: Equatable {
    case standard
    case staticOnly
}

struct AppSettings: Equatable {
    var autoExpand = true
    var keepCompactPet = true
    var quietMode = false
    var motionPreference: MotionPreference = .followSystem
    var completionAndWaitingPrompts = true

    var shouldAutoExpand: Bool {
        autoExpand && !quietMode
    }

    var shouldPlayCompletionAndWaitingPrompts: Bool {
        completionAndWaitingPrompts && !quietMode
    }

    func effectiveMotion(systemReduceMotion: Bool) -> EffectivePetMotion {
        // Accessibility is a hard ceiling. A user may ask for less motion than
        // the system preference, but never more while Reduce Motion is active.
        guard !quietMode, !systemReduceMotion else { return .staticOnly }
        switch motionPreference {
        case .followSystem:
            return .standard
        case .standard:
            return .standard
        case .staticOnly:
            return .staticOnly
        }
    }
}

final class AppSettingsStore {
    private enum Key {
        static let autoExpand = "settings.autoExpand"
        static let keepCompactPet = "settings.keepCompactPet"
        static let quietMode = "settings.quietMode"
        static let motionPreference = "settings.motionPreference"
        static let completionAndWaitingPrompts = "settings.completionAndWaitingPrompts"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> AppSettings {
        AppSettings(
            autoExpand: bool(forKey: Key.autoExpand, defaultValue: true),
            keepCompactPet: bool(forKey: Key.keepCompactPet, defaultValue: true),
            quietMode: bool(forKey: Key.quietMode, defaultValue: false),
            motionPreference: defaults.string(forKey: Key.motionPreference)
                .flatMap(MotionPreference.init(rawValue:)) ?? .followSystem,
            completionAndWaitingPrompts: bool(
                forKey: Key.completionAndWaitingPrompts,
                defaultValue: true
            )
        )
    }

    func save(_ settings: AppSettings) {
        defaults.set(settings.autoExpand, forKey: Key.autoExpand)
        defaults.set(settings.keepCompactPet, forKey: Key.keepCompactPet)
        defaults.set(settings.quietMode, forKey: Key.quietMode)
        defaults.set(settings.motionPreference.rawValue, forKey: Key.motionPreference)
        defaults.set(
            settings.completionAndWaitingPrompts,
            forKey: Key.completionAndWaitingPrompts
        )
    }

    private func bool(forKey key: String, defaultValue: Bool) -> Bool {
        guard defaults.object(forKey: key) != nil else { return defaultValue }
        return defaults.bool(forKey: key)
    }
}
