import CoreGraphics
import Foundation
import ImageIO

struct AnimationSet {
    let name: String
    let frameCount: Int
    let loops: Bool
    let stablePlaybackFrames: [Int]?
}

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("Resources/Fox")
let sets = [
    AnimationSet(name: "fox-idle", frameCount: 6, loops: true, stablePlaybackFrames: nil),
    AnimationSet(name: "fox-working", frameCount: 6, loops: true, stablePlaybackFrames: nil),
    AnimationSet(name: "fox-waiting-approval", frameCount: 6, loops: true, stablePlaybackFrames: nil),
    AnimationSet(name: "fox-waiting-input", frameCount: 6, loops: true, stablePlaybackFrames: [2, 2, 3, 3, 2, 2]),
    AnimationSet(name: "fox-completed", frameCount: 6, loops: false, stablePlaybackFrames: nil),
    AnimationSet(name: "fox-failed", frameCount: 6, loops: false, stablePlaybackFrames: nil),
    AnimationSet(name: "fox-system-error", frameCount: 6, loops: false, stablePlaybackFrames: nil),
    AnimationSet(name: "fox-connecting", frameCount: 6, loops: true, stablePlaybackFrames: [0, 3, 3, 5, 5, 3]),
    AnimationSet(name: "fox-disconnected", frameCount: 6, loops: true, stablePlaybackFrames: [0, 1, 1, 4, 5, 5]),
    AnimationSet(name: "fox-interrupted", frameCount: 6, loops: false, stablePlaybackFrames: nil),
    AnimationSet(name: "fox-idle-run-left", frameCount: 8, loops: true, stablePlaybackFrames: nil),
    AnimationSet(name: "fox-idle-run-right", frameCount: 8, loops: true, stablePlaybackFrames: nil),
    AnimationSet(name: "fox-idle-jump", frameCount: 8, loops: false, stablePlaybackFrames: nil),
    AnimationSet(name: "fox-idle-play", frameCount: 8, loops: false, stablePlaybackFrames: nil)
]

func load(_ url: URL) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fatalError("Unable to decode \(url.path)")
    }
    return image
}

func pixels(_ image: CGImage) -> [UInt8] {
    var data = [UInt8](repeating: 0, count: image.width * image.height * 4)
    guard let context = CGContext(
        data: &data,
        width: image.width,
        height: image.height,
        bitsPerComponent: 8,
        bytesPerRow: image.width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        fatalError("Unable to create pixel buffer")
    }
    context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    return data
}

func nonTransparentPixelCount(_ data: [UInt8]) -> Int {
    stride(from: 3, to: data.count, by: 4).reduce(into: 0) { count, index in
        if data[index] > 8 { count += 1 }
    }
}

func difference(_ lhs: [UInt8], _ rhs: [UInt8]) -> Int {
    stride(from: 0, to: min(lhs.count, rhs.count), by: 4).reduce(into: 0) { count, index in
        let colorDelta = abs(Int(lhs[index]) - Int(rhs[index]))
            + abs(Int(lhs[index + 1]) - Int(rhs[index + 1]))
            + abs(Int(lhs[index + 2]) - Int(rhs[index + 2]))
        let alphaDelta = abs(Int(lhs[index + 3]) - Int(rhs[index + 3]))
        if colorDelta + alphaDelta >= 12 { count += 1 }
    }
}

/// Measures the torso anchor rather than expressive ears, eyes, or tail.
func torsoCentroidX(_ data: [UInt8]) -> Double {
    var weightedX = 0.0
    var alphaWeight = 0.0
    for y in 155..<185 {
        for x in 55..<125 {
            let alpha = Double(data[(y * 192 + x) * 4 + 3])
            guard alpha > 16 else { continue }
            weightedX += Double(x) * alpha
            alphaWeight += alpha
        }
    }
    return weightedX / alphaWeight
}

func upperBodyCentroidX(_ data: [UInt8]) -> Double {
    var weightedX = 0.0
    var alphaWeight = 0.0
    for y in 15..<125 {
        for x in 0..<192 {
            let alpha = Double(data[(y * 192 + x) * 4 + 3])
            guard alpha > 16 else { continue }
            weightedX += Double(x) * alpha
            alphaWeight += alpha
        }
    }
    return weightedX / alphaWeight
}

for set in sets {
    var frames: [[UInt8]] = []
    for index in 0..<set.frameCount {
        let url = root.appendingPathComponent("\(set.name)-\(String(format: "%02d", index)).png")
        guard FileManager.default.isReadableFile(atPath: url.path) else {
            fatalError("Missing frame: \(url.path)")
        }
        let image = load(url)
        guard image.width == 192, image.height == 208 else {
            fatalError("Unexpected canvas for \(url.lastPathComponent): \(image.width)x\(image.height)")
        }
        let data = pixels(image)
        guard nonTransparentPixelCount(data) > 200 else {
            fatalError("Frame is effectively empty: \(url.lastPathComponent)")
        }
        frames.append(data)
    }

    var changedPairs = 0
    for index in 0..<(frames.count - 1) where difference(frames[index], frames[index + 1]) > 30 {
        changedPairs += 1
    }
    if set.loops, difference(frames[frames.count - 1], frames[0]) > 30 {
        changedPairs += 1
    }
    guard changedPairs >= 2 else {
        fatalError("Animation has too few changing transitions: \(set.name) (\(changedPairs))")
    }

    if set.loops, set.frameCount == 6 {
        let anchors = frames.map(torsoCentroidX)
        guard let minimum = anchors.min(), let maximum = anchors.max() else {
            fatalError("Unable to measure stable anchor: \(set.name)")
        }
        let drift = maximum - minimum
        guard drift <= 3.0 else {
            fatalError(
                "Torso anchor drifts horizontally: \(set.name) (\(String(format: "%.1f", drift))px; max 3.0px)"
            )
        }
    }

    if let stablePlaybackFrames = set.stablePlaybackFrames {
        let upperBody = stablePlaybackFrames.map { upperBodyCentroidX(frames[$0]) }
        guard let minimum = upperBody.min(), let maximum = upperBody.max() else {
            fatalError("Unable to measure curated playback: \(set.name)")
        }
        let drift = maximum - minimum
        guard drift <= 4.5 else {
            fatalError(
                "Curated playback still swings horizontally: \(set.name) (\(String(format: "%.1f", drift))px; max 4.5px)"
            )
        }
    }
}

print("FOX_ASSET_TEST_OK (\(sets.count) animation sets)")
