import Accelerate
import Foundation

/// Turns the sound that's playing into the island's waveform: a few bands from bass to treble,
/// each 0…1. Bars rise at once and fall back smoothly. Each band is measured against its own
/// recent average, so bars dance to the beat at any volume, while silence stays flat.
public final class AudioLevels {
    public static let fftSize = 1024
    public let bandCount: Int

    private let log2n = vDSP_Length(10)
    private let setup: FFTSetup
    private var window: [Float]
    private var windowed: [Float]
    private var real: [Float]
    private var imaginary: [Float]
    private var magnitudes: [Float]
    private var levels: [Float]
    /// Band edges, in Hz: log-spaced, so each band is about an octave.
    private let edges: [Double]

    /// Each band is measured against its own running average: a steady sound rests at
    /// `restingLevel`, and the bar reaches the top this many dB above the average. So bars show
    /// the beat rather than the mix, and a dense, loud master doesn't pin them all at the top.
    private let rangeDB: Float = 14
    private let restingLevel: Float = 0.42
    /// How quickly the average follows, per analysis (about 1.3 s at 30 per second).
    private let averaging: Float = 0.025
    /// Bands this far below the loudest one fade out, so near-silent treble stays flat.
    private let presenceDB: Float = 42
    /// The loudest band's level relaxes this much per analysis after a loud passage.
    private let relaxDB: Float = 0.13
    /// The loudest level never counts as lower than this, so near-silence isn't blown up into bars.
    private let quietestReferenceDB: Float = -45
    private var referenceDB: Float = -.infinity
    private var averageDB: [Float]

    public init(bandCount: Int = 8, lowest: Double = 45, highest: Double = 12_000) {
        let n = Self.fftSize
        self.bandCount = bandCount
        setup = vDSP_create_fftsetup(log2n, FFTRadix(kFFTRadix2))!
        window = [Float](repeating: 0, count: n)
        vDSP_hann_window(&window, vDSP_Length(n), Int32(vDSP_HANN_NORM))
        windowed = [Float](repeating: 0, count: n)
        real = [Float](repeating: 0, count: n / 2)
        imaginary = [Float](repeating: 0, count: n / 2)
        magnitudes = [Float](repeating: 0, count: n / 2)
        levels = [Float](repeating: 0, count: bandCount)
        averageDB = [Float](repeating: -.infinity, count: bandCount)
        edges = (0...bandCount).map { lowest * pow(highest / lowest, Double($0) / Double(bandCount)) }
    }

    deinit {
        vDSP_destroy_fftsetup(setup)
    }

    /// Analyzes the latest `fftSize` samples (mono) and returns a 0…1 level per band, bass first.
    public func analyze(_ samples: UnsafePointer<Float>, sampleRate: Double) -> [Float] {
        let n = Self.fftSize
        vDSP_vmul(samples, 1, window, 1, &windowed, 1, vDSP_Length(n))
        real.withUnsafeMutableBufferPointer { realBuffer in
            imaginary.withUnsafeMutableBufferPointer { imaginaryBuffer in
                var split = DSPSplitComplex(realp: realBuffer.baseAddress!, imagp: imaginaryBuffer.baseAddress!)
                windowed.withUnsafeBufferPointer { input in
                    input.baseAddress!.withMemoryRebound(to: DSPComplex.self, capacity: n / 2) { complex in
                        vDSP_ctoz(complex, 2, &split, 1, vDSP_Length(n / 2))
                    }
                }
                vDSP_fft_zrip(setup, &split, 1, log2n, FFTDirection(FFT_FORWARD))
                vDSP_zvmags(&split, 1, &magnitudes, 1, vDSP_Length(n / 2))
            }
        }

        // A full-scale sine gives a squared magnitude of about n²/4 in its bin. Summing a band's
        // bins measures its energy, which for most music is similar from octave to octave.
        let scale = 4 / Float(n * n)
        let binWidth = sampleRate / Double(n)
        var bandDB = [Float](repeating: 0, count: bandCount)
        for band in 0..<bandCount {
            let first = max(1, min(n / 2 - 1, Int((edges[band] / binWidth).rounded())))
            let last = max(first, min(n / 2 - 1, Int((edges[band + 1] / binWidth).rounded()) - 1))
            var energy: Float = 0
            for bin in first...last { energy += magnitudes[bin] }
            bandDB[band] = 10 * log10(energy * scale + 1e-12)
        }

        let loudest = bandDB.max() ?? -.infinity
        referenceDB = max(loudest, referenceDB - relaxDB, quietestReferenceDB)
        for band in 0..<bandCount {
            let db = bandDB[band]
            // After a quiet stretch the average catches up at once, so the next sound doesn't pin the bar.
            if averageDB[band].isInfinite { averageDB[band] = db }
            averageDB[band] = max(averageDB[band] + (db - averageDB[band]) * averaging, db - rangeDB)
            let local = restingLevel + (db - averageDB[band]) / rangeDB
            let presence = (db - (referenceDB - presenceDB)) / (presenceDB / 3)
            let target = min(max(local, 0), 1) * min(max(presence, 0), 1)
            let current = levels[band]
            levels[band] = target > current ? current + (target - current) * 0.8 : max(target, current * 0.78)
        }
        return levels
    }

    /// Starts over: bars at rest, and the scale forgets the last track.
    public func reset() {
        levels = [Float](repeating: 0, count: bandCount)
        averageDB = [Float](repeating: -.infinity, count: bandCount)
        referenceDB = -.infinity
    }

    /// Gathers bands into `count` bars, arranged from the middle out: bass in the center,
    /// treble at the edges, so the waveform pulses from its heart like the iPhone's.
    public static func bars(_ levels: [Float], count: Int) -> [Float] {
        guard count > 0, !levels.isEmpty else { return [Float](repeating: 0, count: max(count, 0)) }
        var groups = [Float](repeating: 0, count: count)
        for group in 0..<count {
            let first = group * levels.count / count
            let last = max(first + 1, (group + 1) * levels.count / count)
            groups[group] = levels[min(first, levels.count - 1)..<min(last, levels.count)].max() ?? 0
        }
        // Positions from the center out: center, right of it, left of it, two to the right…
        let center = count / 2
        var order = [center]
        var step = 1
        while order.count < count {
            if center + step < count { order.append(center + step) }
            if order.count < count, center - step >= 0 { order.append(center - step) }
            step += 1
        }
        var bars = [Float](repeating: 0, count: count)
        for (position, value) in zip(order, groups) { bars[position] = value }
        return bars
    }
}
