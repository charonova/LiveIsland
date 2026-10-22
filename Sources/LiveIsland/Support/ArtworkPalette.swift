import AppKit

/// The color of a track's artwork, for the glow and accents around it.
enum ArtworkPalette {
    /// The most vivid color in the artwork, brightened enough to read on black. Grey artwork
    /// gives a soft white.
    static func accent(of image: NSImage) -> NSColor {
        let side = 16
        guard let cgImage = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
              let context = CGContext(data: nil, width: side, height: side, bitsPerComponent: 8, bytesPerRow: side * 4,
                                      space: CGColorSpaceCreateDeviceRGB(),
                                      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue),
              let pixels = context.data?.assumingMemoryBound(to: UInt8.self)
        else { return fallback }
        context.interpolationQuality = .medium
        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: side, height: side))

        var samples: [(color: NSColor, score: CGFloat)] = []
        for index in 0..<(side * side) {
            let offset = index * 4
            let color = NSColor(deviceRed: CGFloat(pixels[offset]) / 255, green: CGFloat(pixels[offset + 1]) / 255,
                                blue: CGFloat(pixels[offset + 2]) / 255, alpha: 1)
            let score = color.saturationComponent * (0.3 + color.brightnessComponent)
            samples.append((color, score))
        }
        // Average the most vivid quarter, so one stray pixel doesn't decide.
        let vivid = samples.sorted { $0.score > $1.score }.prefix(samples.count / 4)
        guard let best = vivid.first, best.score > 0.12 else { return fallback }
        var hue: CGFloat = 0, saturation: CGFloat = 0, brightness: CGFloat = 0
        var weight: CGFloat = 0
        // Hue wraps around, so average it as a direction.
        var x: CGFloat = 0, y: CGFloat = 0
        for sample in vivid {
            let w = sample.score
            x += cos(sample.color.hueComponent * 2 * .pi) * w
            y += sin(sample.color.hueComponent * 2 * .pi) * w
            saturation += sample.color.saturationComponent * w
            brightness += sample.color.brightnessComponent * w
            weight += w
        }
        hue = atan2(y, x) / (2 * .pi)
        if hue < 0 { hue += 1 }
        saturation /= weight
        brightness /= weight
        return NSColor(deviceHue: hue, saturation: min(max(saturation, 0.45), 0.85),
                       brightness: min(max(brightness, 0.8), 1), alpha: 1)
    }

    static let fallback = NSColor(deviceWhite: 0.85, alpha: 1)
}
