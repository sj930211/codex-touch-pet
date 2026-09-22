import CoreGraphics
import Foundation

/// A bounded local behavior director for the idle pet.
///
/// This is intentionally not an LLM call. It gives the pet an organic,
/// interruptible wander while idle without adding network traffic, latency,
/// or an unbounded animation loop. A future AI policy can replace the choice
/// of targets while keeping this motion/guardrail layer intact.
struct PetIdleActivityDirector {
    enum Activity: Hashable {
        case wander
        case inspect
        case stretch
        case nap
    }

    struct Motion: Equatable {
        let activity: Activity
        let x: CGFloat
        let y: CGFloat
        let rotation: CGFloat
        let scale: CGFloat
    }

    private var seed: UInt64 = 0xC0D3_5EED
    private var currentX: CGFloat = 0
    private var targetX: CGFloat = 0
    private var currentActivity: Activity = .wander
    private var segmentStartedAt: TimeInterval?
    private var segmentDuration: TimeInterval = 2.4

    mutating func reset() {
        currentX = 0
        targetX = 0
        currentActivity = .wander
        segmentStartedAt = nil
        segmentDuration = 2.4
    }

    mutating func motion(at time: TimeInterval, travel: CGFloat, date: Date = Date()) -> Motion {
        let hour = Calendar.current.component(.hour, from: date)
        let night = hour < 7 || hour >= 22
        let offset = self.offset(at: time, travel: travel, nightBias: night)
        let phase = segmentPhase(at: time)
        let activity = currentActivity
        switch activity {
        case .wander:
            return Motion(activity: activity, x: offset, y: 0, rotation: 0, scale: 1.08)
        case .inspect:
            return Motion(
                activity: activity,
                x: offset * 0.65,
                y: -0.8 * CGFloat(sin(phase * .pi * 2)),
                rotation: CGFloat(sin(phase * .pi * 2)) * 1.5,
                scale: 1.10
            )
        case .stretch:
            return Motion(
                activity: activity,
                x: offset * 0.35,
                y: CGFloat(sin(phase * .pi)) * 1.4,
                rotation: CGFloat(sin(phase * .pi * 2)) * 1.0,
                scale: 1.08 + CGFloat(sin(phase * .pi)) * 0.04
            )
        case .nap:
            let breathing = CGFloat(sin(phase * .pi * 2))
            return Motion(activity: activity, x: offset * 0.15, y: breathing * 0.5, rotation: 0, scale: night ? 1.06 : 1.08)
        }
    }

    mutating func offset(at time: TimeInterval, travel: CGFloat, nightBias: Bool = false) -> CGFloat {
        guard travel > 0 else { return 0 }
        if segmentStartedAt == nil {
            segmentStartedAt = time
            segmentDuration = 1.8 + nextUnit() * 2.4
        }

        let segmentStart = segmentStartedAt ?? time
        if time >= segmentStart + segmentDuration {
            currentX = targetX
            // Keep the center clear most of the time, but let the pet make
            // short, non-repeating excursions into the available blank area.
            targetX = CGFloat(nextUnit() * 2 - 1) * travel
            currentActivity = nextActivity(nightBias: nightBias)
            segmentStartedAt = time
            segmentDuration = 1.8 + nextUnit() * 2.4
        }

        let elapsed = min(segmentDuration, max(0, time - (segmentStartedAt ?? time)))
        let progress = min(1, elapsed / max(0.01, segmentDuration))
        let eased = progress * progress * (3 - 2 * progress)
        // Rebase the segment when a target is chosen so movement remains
        // continuous instead of snapping when the next idle activity starts.
        return currentX + (targetX - currentX) * CGFloat(eased)
    }

    private func segmentPhase(at time: TimeInterval) -> Double {
        guard let segmentStartedAt else { return 0 }
        return min(1, max(0, (time - segmentStartedAt) / max(0.01, segmentDuration)))
    }

    private mutating func nextActivity(nightBias: Bool) -> Activity {
        let value = nextUnit()
        if nightBias { return value < 0.70 ? .nap : .inspect }
        if value < 0.45 { return .wander }
        if value < 0.70 { return .inspect }
        if value < 0.88 { return .stretch }
        return .nap
    }

    private mutating func nextUnit() -> Double {
        // xorshift64*: deterministic, allocation-free, and sufficient for a
        // small visual behavior director. It is not used for security.
        seed ^= seed >> 12
        seed ^= seed << 25
        seed ^= seed >> 27
        let value = seed &* 2_685_821_657_736_338_717
        return Double(value >> 11) / Double(UInt64.max >> 11)
    }
}
