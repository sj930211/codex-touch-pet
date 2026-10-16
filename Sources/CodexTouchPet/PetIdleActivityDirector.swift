import CoreGraphics
import Foundation

/// Selects grounded idle routines from existing fox poses. Only running moves
/// the horizontal anchor; gestures stay at the place where the fox arrived.
struct PetIdleActivityDirector {
    enum RunDirection: Hashable {
        case left
        case right
    }

    enum Activity: Hashable {
        case wander
        case inspect
        case stretch
        case nap
        case run
        case jump
        case play

        var frameInterval: TimeInterval {
            switch self {
            case .run: return 0.12
            case .jump, .play, .wander: return 0.18
            case .inspect, .stretch: return 0.24
            case .nap: return 0.28
            }
        }
    }

    enum Routine: String, CaseIterable {
        case explore
        case shuttle
        case hopAndPlay
        case tailGame
    }

    struct Motion: Equatable {
        let activity: Activity
        let x: CGFloat
        let y: CGFloat
        let rotation: CGFloat
        let scale: CGFloat
        let direction: RunDirection
        let segmentID: Int
        let routine: Routine?
        let routineID: Int
        let elapsed: TimeInterval

        init(
            activity: Activity,
            x: CGFloat,
            y: CGFloat,
            rotation: CGFloat,
            scale: CGFloat,
            direction: RunDirection = .right,
            segmentID: Int = 0,
            routine: Routine? = nil,
            routineID: Int = 0,
            elapsed: TimeInterval = 0
        ) {
            self.activity = activity
            self.x = x
            self.y = y
            self.rotation = rotation
            self.scale = scale
            self.direction = direction
            self.segmentID = segmentID
            self.routine = routine
            self.routineID = routineID
            self.elapsed = elapsed
        }
    }

    private struct Segment {
        let activity: Activity
        let destination: CGFloat?
        let duration: TimeInterval

        static func run(to destination: CGFloat) -> Segment {
            Segment(activity: .run, destination: destination, duration: 0)
        }

        static func hold(_ activity: Activity, for duration: TimeInterval) -> Segment {
            Segment(activity: activity, destination: nil, duration: duration)
        }
    }

    private var seed: UInt64
    private var currentX: CGFloat = 0
    private var targetX: CGFloat = 0
    private var lastOffset: CGFloat = 0
    private var currentActivity: Activity = .wander
    private var runDirection: RunDirection = .right
    private var currentRoutine: Routine?
    private var pendingSegments: [Segment] = []
    private var segmentID = 0
    private var routineID = 0
    private var segmentStartedAt: TimeInterval?
    private var segmentDuration: TimeInterval = 2.4
    private var lastSampleAt: TimeInterval?
    private let restScale: TimeInterval

    init(actionThresholdScale: TimeInterval? = nil, seed: UInt64? = nil) {
        let demoEnabled = ProcessInfo.processInfo.environment["CODEX_TOUCH_PET_ACTIONS_FAST"] == "1"
        restScale = max(0.25, actionThresholdScale ?? (demoEnabled ? 0.5 : 1))
        self.seed = max(1, seed ?? UInt64.random(in: 1...UInt64.max))
    }

    mutating func reset() {
        currentX = 0
        targetX = 0
        lastOffset = 0
        currentActivity = .wander
        runDirection = .right
        currentRoutine = nil
        pendingSegments.removeAll(keepingCapacity: true)
        segmentID = 0
        routineID = 0
        segmentStartedAt = nil
        segmentDuration = 2.4
        lastSampleAt = nil
    }

    mutating func motion(at time: TimeInterval, travel: CGFloat, date: Date = Date()) -> Motion {
        let hour = Calendar.current.component(.hour, from: date)
        let night = hour < 7 || hour >= 22
        let x = offset(at: time, travel: travel, nightBias: night)
        // Jump/play sprites already contain vertical pose changes. Translating
        // the image view again would make the fox float or clip.
        return Motion(
            activity: currentActivity,
            x: x,
            y: 0,
            rotation: 0,
            scale: 1,
            direction: runDirection,
            segmentID: segmentID,
            routine: currentRoutine,
            routineID: routineID,
            elapsed: max(0, time - (segmentStartedAt ?? time))
        )
    }

    mutating func offset(at time: TimeInterval, travel: CGFloat, nightBias: Bool = false) -> CGFloat {
        guard travel > 0 else { return 0 }
        if segmentStartedAt == nil {
            segmentStartedAt = time
            segmentDuration = 2.4 * restScale
        }

        if let lastSampleAt, time - lastSampleAt > 0.5 {
            // Freeze the whole segment clock, not just its position. This
            // preserves a mid-jump pose instead of replaying the takeoff.
            segmentStartedAt = (segmentStartedAt ?? time) + time - lastSampleAt
        }
        lastSampleAt = time

        if time >= (segmentStartedAt ?? time) + segmentDuration {
            currentX = targetX
            if pendingSegments.isEmpty {
                pendingSegments = nextRoutine(nightBias: nightBias)
            }
            let next = pendingSegments.removeFirst()
            currentActivity = next.activity
            targetX = next.destination.map { min(travel, max(-travel, $0 * travel)) } ?? currentX
            runDirection = targetX < currentX ? .left : .right
            segmentDuration = next.activity == .run
                ? runDuration(nightBias: nightBias)
                : next.duration
            segmentStartedAt = time
            segmentID += 1
        }

        let progress = min(1, max(0, (time - (segmentStartedAt ?? time)) / max(0.01, segmentDuration)))
        let eased = progress * progress * (3 - 2 * progress)
        lastOffset = currentX + (targetX - currentX) * CGFloat(eased)
        return lastOffset
    }

    private func runDuration(nightBias: Bool) -> TimeInterval {
        let speed: CGFloat = nightBias ? 75 : 110
        // Larger playfields receive longer runs rather than faster sprites.
        return max(1.6, Double(abs(targetX - currentX) / speed))
    }

    private mutating func nextRoutine(nightBias: Bool) -> [Segment] {
        let candidates = Routine.allCases.filter { $0 != currentRoutine }
        let index = min(candidates.count - 1, Int(nextUnit() * Double(candidates.count)))
        let routine = candidates[index]
        currentRoutine = routine
        routineID += 1
        let side: CGFloat = nextUnit() < 0.5 ? -1 : 1
        let rest = (2.2 + nextUnit() * 2.0) * restScale * (nightBias ? 1.7 : 1)
        switch routine {
        case .explore:
            return [
                .run(to: side * 0.94),
                .hold(.inspect, for: 1.8),
                .run(to: -side * 0.94),
                .hold(.stretch, for: 1.8),
                .hold(.wander, for: rest)
            ]
        case .shuttle:
            return [
                .run(to: side * 0.90),
                .hold(.inspect, for: 1.4),
                .run(to: -side * 0.90),
                .hold(.inspect, for: 1.4),
                .run(to: 0),
                .hold(.nap, for: rest)
            ]
        case .hopAndPlay:
            return [
                .run(to: side * 0.70),
                .hold(.jump, for: 1.6),
                .hold(.wander, for: 0.5),
                .hold(.jump, for: 1.6),
                .run(to: -side * 0.35),
                .hold(.play, for: 1.8),
                .hold(.wander, for: rest)
            ]
        case .tailGame:
            return [
                .run(to: side * 0.84),
                .hold(.play, for: 1.8),
                .hold(.inspect, for: 1.4),
                .run(to: -side * 0.72),
                .hold(.play, for: 1.8),
                .hold(.nap, for: rest)
            ]
        }
    }

    private mutating func nextUnit() -> Double {
        // xorshift64*: tiny state and reproducible with an injected test seed.
        seed ^= seed >> 12
        seed ^= seed << 25
        seed ^= seed >> 27
        let value = seed &* 2_685_821_657_736_338_717
        return Double(value >> 11) / Double(UInt64.max >> 11)
    }
}
