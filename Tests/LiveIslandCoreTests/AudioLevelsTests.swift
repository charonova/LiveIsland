import Foundation
import Testing
@testable import LiveIslandCore

@Suite("Audio levels")
struct AudioLevelsTests {
    let rate = 48_000.0

    /// One analysis block of a sine, continuing from `start` so blocks join without a click.
    func sine(_ frequency: Double, amplitude: Float, start: Int = 0) -> [Float] {
        (0..<AudioLevels.fftSize).map { amplitude * Float(sin(2 * .pi * frequency * Double(start + $0) / rate)) }
    }

    func analyze(_ analyzer: AudioLevels, _ samples: [Float], times: Int = 1) -> [Float] {
        var levels: [Float] = []
        for _ in 0..<times { levels = samples.withUnsafeBufferPointer { analyzer.analyze($0.baseAddress!, sampleRate: rate) } }
        return levels
    }

    @Test func bassLightsTheBassBands() {
        let levels = analyze(AudioLevels(), sine(80, amplitude: 0.5), times: 4)
        #expect(levels.firstIndex(of: levels.max()!)! <= 1)
        #expect(levels[0...1].max()! > 0.3, "a steady tone rests mid-height")
        #expect(levels.last! < 0.1)
    }

    @Test func trebleLightsTheTrebleBand() {
        let levels = analyze(AudioLevels(), sine(8_000, amplitude: 0.5), times: 4)
        #expect(levels.firstIndex(of: levels.max()!)! == levels.count - 1)
        #expect(levels[0] < 0.1)
    }

    @Test func silenceAndHissStayFlat() {
        #expect(analyze(AudioLevels(), [Float](repeating: 0, count: AudioLevels.fftSize), times: 4).allSatisfy { $0 == 0 })
        let hiss = (0..<AudioLevels.fftSize).map { _ in Float.random(in: -1e-5...1e-5) }
        #expect(analyze(AudioLevels(), hiss, times: 4).allSatisfy { $0 < 0.05 })
    }

    /// A 200 Hz tone that pulses like a beat: loud for 6 analyses (200 ms), 12 dB softer for 6.
    /// Returns the levels at the end of the last loud and soft stretches.
    func pulses(_ analyzer: AudioLevels, amplitude: Float, beats: Int) -> (loud: Float, soft: Float) {
        var loud: Float = 0, soft: Float = 0
        var start = 0
        for _ in 0..<beats {
            for _ in 0..<6 {
                loud = analyze(analyzer, sine(200, amplitude: amplitude, start: start)).max()!
                start += AudioLevels.fftSize
            }
            for _ in 0..<6 {
                soft = analyze(analyzer, sine(200, amplitude: amplitude / 4, start: start)).max()!
                start += AudioLevels.fftSize
            }
        }
        return (loud, soft)
    }

    @Test func theBeatShowsAsMovement() {
        let levels = pulses(AudioLevels(), amplitude: 0.5, beats: 20)
        #expect(levels.loud > 0.75)
        #expect(levels.loud - levels.soft > 0.35)
    }

    @Test func aQuietTrackMovesLikeALoudOne() {
        let loud = pulses(AudioLevels(), amplitude: 0.5, beats: 20)
        let quiet = pulses(AudioLevels(), amplitude: 0.016, beats: 20)   // 30 dB down
        #expect(abs(loud.loud - quiet.loud) < 0.05)
        #expect(abs(loud.soft - quiet.soft) < 0.05)
    }

    @Test func barsFallBackSmoothlyWhenTheSoundStops() {
        let analyzer = AudioLevels()
        let loud = analyze(analyzer, sine(200, amplitude: 0.5), times: 4)
        let peak = loud.max()!
        var previous = peak
        let silence = [Float](repeating: 0, count: AudioLevels.fftSize)
        var fallen: [Float] = []
        for _ in 0..<20 {
            let level = analyze(analyzer, silence).max()!
            #expect(level <= previous)
            fallen.append(level)
            previous = level
        }
        #expect(fallen[0] > 0.5 * peak, "the first step down is gentle")
        #expect(fallen.last! < 0.05, "and it reaches rest within a second")
    }

    @Test func resetForgetsTheLastTrack() {
        let analyzer = AudioLevels()
        _ = analyze(analyzer, sine(200, amplitude: 0.9), times: 4)
        analyzer.reset()
        #expect(analyze(analyzer, sine(200, amplitude: 0.01), times: 4).max()! > 0.35, "not gated by the loud track")
    }

    @Test func barsPutTheBassInTheMiddle() {
        let levels: [Float] = [1, 0.9, 0.7, 0.6, 0.5, 0.4, 0.2, 0.1]
        let five = AudioLevels.bars(levels, count: 5)
        #expect(five.count == 5)
        #expect(five[2] == 1, "bass in the center")
        #expect(five[0] == 0.2, "treble at the edge")
        #expect(five[3] == 0.9 && five[1] == 0.6)
        #expect(AudioLevels.bars(levels, count: 4) == [0.2, 0.5, 1, 0.7])
        #expect(AudioLevels.bars(levels, count: 7).count == 7)
        #expect(AudioLevels.bars([], count: 3) == [0, 0, 0])
    }
}
