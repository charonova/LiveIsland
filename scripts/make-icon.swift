// Draws the LiveIsland icon: a glowing Dynamic Island with album art and a waveform,
// on Apple's macOS icon grid (an 824 pt body centered on a 1024 pt canvas).
//
//   swift scripts/make-icon.swift <output.png>
import AppKit

let size: CGFloat = 1024
let body = CGRect(x: 100, y: 100, width: 824, height: 824)
let cornerRadius: CGFloat = 185

func color(_ hex: UInt32, _ alpha: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
}

func gradient(_ stops: [(UInt32, CGFloat, CGFloat)]) -> CGGradient {
    CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB),
               colors: stops.map { color($0.0, $0.1) } as CFArray, locations: stops.map(\.2))!
}

let context = CGContext(
    data: nil, width: Int(size), height: Int(size), bitsPerComponent: 8, bytesPerRow: 0,
    space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
let bodyPath = CGPath(roundedRect: body, cornerWidth: cornerRadius, cornerHeight: cornerRadius, transform: nil)

context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -12), blur: 30, color: color(0x000000, 0.35))
context.addPath(bodyPath)
context.setFillColor(color(0x0E1024))
context.fillPath()
context.restoreGState()

context.saveGState()
context.addPath(bodyPath)
context.clip()
// Twilight background with a warm glow rising from below.
context.drawLinearGradient(gradient([(0x2B2F6B, 1, 0), (0x15173A, 1, 0.5), (0x07080F, 1, 1)]),
                           start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: body.minY), options: [])
context.drawRadialGradient(gradient([(0xFF5C8A, 0.45, 0), (0x8A5CFF, 0.2, 0.5), (0x8A5CFF, 0, 1)]),
                           startCenter: CGPoint(x: 512, y: 470), startRadius: 0,
                           endCenter: CGPoint(x: 512, y: 470), endRadius: 430, options: [])

// The island.
let island = CGRect(x: 192, y: 452, width: 640, height: 200)
let islandPath = CGPath(roundedRect: island, cornerWidth: 100, cornerHeight: 100, transform: nil)
context.saveGState()
context.setShadow(offset: CGSize(width: 0, height: -14), blur: 46, color: color(0xB45CFF, 0.65))
context.addPath(islandPath)
context.setFillColor(color(0x000000))
context.fillPath()
context.restoreGState()
context.addPath(islandPath)
context.setStrokeColor(color(0xFFFFFF, 0.14))
context.setLineWidth(3)
context.strokePath()

// Album art on the left.
let art = CGRect(x: 238, y: 494, width: 116, height: 116)
context.saveGState()
context.addPath(CGPath(roundedRect: art, cornerWidth: 30, cornerHeight: 30, transform: nil))
context.clip()
context.drawLinearGradient(gradient([(0xFF8A3D, 1, 0), (0xFF3D7F, 1, 0.55), (0x8A3DFF, 1, 1)]),
                           start: CGPoint(x: art.minX, y: art.maxY), end: CGPoint(x: art.maxX, y: art.minY), options: [])
context.restoreGState()

// A waveform on the right.
let heights: [CGFloat] = [46, 92, 132, 76, 112, 58]
for (index, height) in heights.enumerated() {
    let x = 548 + CGFloat(index) * 40
    let bar = CGRect(x: x, y: 552 - height / 2, width: 20, height: height)
    context.saveGState()
    context.addPath(CGPath(roundedRect: bar, cornerWidth: 10, cornerHeight: 10, transform: nil))
    context.clip()
    context.drawLinearGradient(gradient([(0xFF5CA8, 1, 0), (0xFFB13D, 1, 1)]),
                               start: CGPoint(x: 548, y: 0), end: CGPoint(x: 788, y: 0), options: [])
    context.restoreGState()
}

// Glass sheen and edge.
context.drawLinearGradient(gradient([(0xFFFFFF, 0.14, 0), (0xFFFFFF, 0, 1)]),
                           start: CGPoint(x: 0, y: body.maxY), end: CGPoint(x: 0, y: 600), options: [])
context.restoreGState()
context.addPath(bodyPath)
context.setStrokeColor(color(0xFFFFFF, 0.16))
context.setLineWidth(3)
context.strokePath()

let output = URL(fileURLWithPath: CommandLine.arguments.dropFirst().first ?? "icon.png")
let destination = CGImageDestinationCreateWithURL(output as CFURL, "public.png" as CFString, 1, nil)!
CGImageDestinationAddImage(destination, context.makeImage()!, nil)
guard CGImageDestinationFinalize(destination) else { fatalError("Couldn't write \(output.path)") }
print("Wrote \(output.path)")
