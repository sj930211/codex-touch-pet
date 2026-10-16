import CoreGraphics
import Foundation
import ImageIO

let root = URL(fileURLWithPath: FileManager.default.currentDirectoryPath)
    .appendingPathComponent("design-test/animation-test/fox-motion-v2")
let frameCount = 8
let canvasSize = CGSize(width: 192, height: 208)
let targetHeight: CGFloat = 171
let targetWidth: CGFloat = 182
let baseline: CGFloat = 190

struct Component {
    var pixels: Set<Int>
    var minX = Int.max
    var minY = Int.max
    var maxX = Int.min
    var maxY = Int.min
}

func loadImage(_ url: URL) -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fatalError("Unable to load \(url.path)")
    }
    return image
}

func rgbaBuffer(_ image: CGImage) -> (data: [UInt8], width: Int, height: Int) {
    let width = image.width
    let height = image.height
    var data = [UInt8](repeating: 0, count: width * height * 4)
    guard let context = CGContext(
        data: &data,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: CGColorSpaceCreateDeviceRGB(),
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else { fatalError("Unable to create bitmap context") }
    context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))
    return (data, width, height)
}

func components(in image: CGImage) -> [Component] {
    let buffer = rgbaBuffer(image)
    let width = buffer.width
    let height = buffer.height
    let alpha = buffer.data
    var active = Set<Int>()
    for index in 0..<(width * height) where alpha[index * 4 + 3] > 8 {
        active.insert(index)
    }
    var result: [Component] = []
    while let start = active.first {
        active.remove(start)
        var component = Component(pixels: [start])
        var queue = [start]
        while !queue.isEmpty {
            let index = queue.removeLast()
            let x = index % width
            let y = index / width
            component.minX = min(component.minX, x)
            component.maxX = max(component.maxX, x)
            component.minY = min(component.minY, y)
            component.maxY = max(component.maxY, y)
            for dy in -1...1 {
                for dx in -1...1 where dx != 0 || dy != 0 {
                    let nx = x + dx
                    let ny = y + dy
                    guard nx >= 0, nx < width, ny >= 0, ny < height else { continue }
                    let neighbor = ny * width + nx
                    if active.remove(neighbor) != nil {
                        component.pixels.insert(neighbor)
                        queue.append(neighbor)
                    }
                }
            }
        }
        result.append(component)
    }
    return result.sorted { $0.pixels.count > $1.pixels.count }
}

func equalCellComponents(in image: CGImage) -> [Component] {
    let centers: [Int]
    let halfWindow: Int
    if image.width < 1500 {
        // The left-facing strip is intentionally compact; use overlapping
        // windows so the large tail never gets cut at a cell boundary.
        centers = [80, 218, 356, 494, 632, 770, 908, 1046]
        halfWindow = 86
    } else {
        // The right-facing strip has wider poses and more breathing room.
        centers = [134, 407, 679, 951, 1224, 1496, 1768, 2042]
        halfWindow = 148
    }
    var result: [Component] = []
    for cell in 0..<frameCount {
        let startX = max(0, centers[cell] - halfWindow)
        let endX = min(image.width, centers[cell] + halfWindow)
        guard let crop = image.cropping(to: CGRect(x: startX, y: 0, width: endX - startX, height: image.height)),
              let local = components(in: crop).first(where: { $0.pixels.count > 80 }) else {
            fatalError("empty sprite cell \(cell)")
        }
        var component = local
        component.minX += startX
        component.maxX += startX
        result.append(component)
    }
    return result
}

func savePNG(_ image: CGImage, to url: URL) {
    guard let destination = CGImageDestinationCreateWithURL(url as CFURL, "public.png" as CFString, 1, nil) else {
        fatalError("Unable to create PNG destination")
    }
    CGImageDestinationAddImage(destination, image, nil)
    guard CGImageDestinationFinalize(destination) else { fatalError("Unable to write \(url.path)") }
}

func normalize(direction: String) {
    let stripURL = root.appendingPathComponent("generated/fox-\(direction)-strip.png")
    let image = loadImage(stripURL)
    let ordered = equalCellComponents(in: image)
    let outputDir = root.appendingPathComponent("normalized/\(direction)")
    try? FileManager.default.createDirectory(at: outputDir, withIntermediateDirectories: true)
    for old in (try? FileManager.default.contentsOfDirectory(at: outputDir, includingPropertiesForKeys: nil)) ?? [] where old.pathExtension == "png" {
        try? FileManager.default.removeItem(at: old)
    }
    for (index, component) in ordered.enumerated() {
        let cropRect = CGRect(
            x: component.minX,
            y: component.minY,
            width: component.maxX - component.minX + 1,
            height: component.maxY - component.minY + 1
        )
        guard let cropped = image.cropping(to: cropRect) else { fatalError("Unable to crop frame") }
        let scale = min(targetHeight / CGFloat(cropped.height), targetWidth / CGFloat(cropped.width))
        let scaled = CGSize(width: max(1, round(CGFloat(cropped.width) * scale)), height: max(1, round(CGFloat(cropped.height) * scale)))
        var outputData = [UInt8](repeating: 0, count: Int(canvasSize.width * canvasSize.height * 4))
        guard let context = CGContext(
            data: &outputData,
            width: Int(canvasSize.width),
            height: Int(canvasSize.height),
            bitsPerComponent: 8,
            bytesPerRow: Int(canvasSize.width) * 4,
            space: CGColorSpaceCreateDeviceRGB(),
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { fatalError("Unable to create output context") }
        context.interpolationQuality = .high
        context.draw(cropped, in: CGRect(
            x: round((canvasSize.width - scaled.width) / 2),
            y: baseline - scaled.height,
            width: scaled.width,
            height: scaled.height
        ))
        guard let output = context.makeImage() else { fatalError("Unable to make output image") }
        savePNG(output, to: outputDir.appendingPathComponent(String(format: "%02d.png", index)))
    }
}

normalize(direction: "run-left")
normalize(direction: "run-right")
