import AppKit
import LiveIslandCore
import SwiftUI

/// The waveform beside a track: bars that move with the real sound, or the animated symbol
/// when LiveIsland can't hear it (turned off, not allowed, or before macOS 14.2).
struct Waveform: View {
    @ObservedObject var meter: AudioLevelMeter
    let style: LevelBarsView.Style
    let color: Color
    let playing: Bool

    var body: some View {
        ZStack {
            if meter.isAvailable {
                // Kept on screen even while the symbol shows, so the meter knows to keep
                // listening and can switch back the moment sound arrives.
                LevelBars(meter: meter, style: style, color: color, live: playing)
                    .opacity(meter.isHearing ? 1 : 0)
            }
            if !meter.isAvailable || !meter.isHearing {
                Image(systemName: "waveform")
                    .font(.system(size: style.symbolSize, weight: .semibold))
                    .foregroundStyle(color)
                    .symbolEffect(.variableColor.iterative.reversing, isActive: playing)
            }
        }
        .frame(width: style.size.width, height: style.size.height)
        .animation(.easeInOut(duration: 0.25), value: meter.isHearing)
    }
}

private struct LevelBars: NSViewRepresentable {
    let meter: AudioLevelMeter
    let style: LevelBarsView.Style
    let color: Color
    let live: Bool

    func makeNSView(context: Context) -> LevelBarsView {
        let view = LevelBarsView(style: style)
        view.meter = meter
        return view
    }

    func updateNSView(_ view: LevelBarsView, context: Context) {
        view.color = NSColor(color)
        view.isLive = live
    }
}

/// Capsules that grow from their middle, bass in the center and treble at the edges, with a
/// soft glow in the artwork's color. The meter sets new heights 30 times a second and Core
/// Animation glides between them, so motion stays smooth at any refresh rate.
final class LevelBarsView: NSView {
    struct Style {
        var bars: Int
        var width: CGFloat
        var gap: CGFloat
        var height: CGFloat
        var glow: CGFloat
        var symbolSize: CGFloat

        /// Beside the notch.
        static let compact = Style(bars: 5, width: 3, gap: 2.2, height: 16, glow: 3, symbolSize: 13)
        /// Next to the track title.
        static let large = Style(bars: 7, width: 3.6, gap: 2.8, height: 24, glow: 5, symbolSize: 18)

        var size: CGSize {
            CGSize(width: CGFloat(bars) * width + CGFloat(bars - 1) * gap, height: height)
        }
    }

    weak var meter: AudioLevelMeter?
    var color: NSColor = .systemPink {
        didSet { if color != oldValue { applyColor() } }
    }
    /// Paused bars settle into dots.
    var isLive = false {
        didSet { if isLive != oldValue, !isLive { rest() } }
    }

    private let style: Style
    private let glow = CALayer()
    private var bars: [CAGradientLayer] = []
    private var heights: [CGFloat]

    init(style: Style) {
        self.style = style
        heights = Array(repeating: style.width, count: style.bars)
        super.init(frame: CGRect(origin: .zero, size: style.size))
        wantsLayer = true
        layer?.masksToBounds = false
        glow.shadowOffset = .zero
        glow.shadowRadius = style.glow
        glow.shadowOpacity = 0.75
        layer?.addSublayer(glow)
        let center = CGFloat(style.bars - 1) / 2
        for index in 0..<style.bars {
            let bar = CAGradientLayer()
            bar.cornerRadius = style.width / 2
            bar.startPoint = CGPoint(x: 0.5, y: 0)
            bar.endPoint = CGPoint(x: 0.5, y: 1)
            bar.locations = [0, 0.5, 1]
            // The middle bars are the brightest.
            bar.opacity = Float(1 - 0.3 * abs(CGFloat(index) - center) / max(center, 1))
            layer?.addSublayer(bar)
            bars.append(bar)
        }
        applyColor()
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        if window != nil { meter?.attach(self) } else { meter?.detach(self) }
    }

    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        let scale = window?.backingScaleFactor ?? 2
        for bar in bars { bar.contentsScale = scale }
    }

    override func layout() {
        super.layout()
        place(duration: 0)
    }

    /// New levels from the meter, bass first.
    func show(_ levels: [Float]) {
        guard isLive else { return }
        let values = AudioLevels.bars(levels, count: style.bars)
        // Playing bars never shrink to dots (those mean paused): the quietest is a short pill.
        let lowest = max(style.width * 1.5, style.height * 0.26)
        heights = values.map { lowest + (style.height - lowest) * CGFloat(pow(Double($0), 0.85)) }
        place(duration: AudioLevelMeter.tick)
    }

    private func rest() {
        heights = Array(repeating: style.width, count: style.bars)
        place(duration: 0.35, timing: .easeInEaseOut)
    }

    private func place(duration: CFTimeInterval, timing: CAMediaTimingFunctionName = .linear) {
        CATransaction.begin()
        if duration > 0 {
            CATransaction.setAnimationDuration(duration)
            CATransaction.setAnimationTimingFunction(CAMediaTimingFunction(name: timing))
        } else {
            CATransaction.setDisableActions(true)
        }
        let originX = (bounds.width - style.size.width) / 2
        let path = CGMutablePath()
        for (index, bar) in bars.enumerated() {
            let height = heights[index]
            let rect = CGRect(x: originX + CGFloat(index) * (style.width + style.gap), y: bounds.midY - height / 2,
                              width: style.width, height: height)
            bar.frame = rect
            path.addRoundedRect(in: rect, cornerWidth: style.width / 2, cornerHeight: style.width / 2)
        }
        glow.frame = bounds
        glow.shadowPath = path
        CATransaction.commit()
    }

    private func applyColor() {
        // A hot, lighter core fading to the artwork's color at both ends, like a lit filament.
        let base = color.usingColorSpace(.sRGB) ?? color
        let core = base.blended(withFraction: 0.55, of: .white) ?? base
        let colors = [base.cgColor, core.cgColor, base.cgColor]
        CATransaction.begin()
        CATransaction.setAnimationDuration(0.4)
        for bar in bars { bar.colors = colors }
        glow.shadowColor = base.cgColor
        CATransaction.commit()
    }
}
