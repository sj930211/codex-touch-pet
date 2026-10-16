import CoreGraphics

/// Geometry shared by the expanded Touch Bar layout and the idle director.
/// A task rail keeps its full width whenever a navigable task is present;
/// only genuinely empty, online idle time becomes a wide playfield.
enum PetActivityLayout {
    static let contentWidth: CGFloat = 620
    static let itemGap: CGFloat = 8
    static let normalPetWidth: CGFloat = 220
    static let idlePetWidth: CGFloat = 528
    static let spriteWidth: CGFloat = 48
    static let edgeInset: CGFloat = 8

    static func petWidth(wideIdle: Bool) -> CGFloat {
        wideIdle ? idlePetWidth : normalPetWidth
    }

    static func statusWidth(wideIdle: Bool) -> CGFloat {
        contentWidth - itemGap - petWidth(wideIdle: wideIdle)
    }

    static func travel(wideIdle: Bool) -> CGFloat {
        max(0, (petWidth(wideIdle: wideIdle) - spriteWidth) / 2 - edgeInset)
    }
}
