import AppKit
import CoreAudio
import LiveIslandCore
import os

private let log = Logger(subsystem: "com.aissam.liveisland", category: "levels")

/// The real waveform: listens to what the Mac plays and moves the island's bars to it.
///
/// It only listens while music plays and bars are on screen, and stops a few seconds after.
/// The bars are Core Animation layers that it updates directly, 30 times a second, so SwiftUI
/// redraws nothing. When the tap hears only silence while a player says it's playing (macOS
/// didn't allow the capture), the island falls back to the animated symbol.
@MainActor
final class AudioLevelMeter: ObservableObject {
    static let tick: TimeInterval = 1.0 / 30

    /// False when turned off in Settings, before macOS 14.2, or when the tap couldn't start.
    @Published private(set) var isAvailable = true
    /// False once playback stayed silent to the tap; true again as soon as it hears something.
    @Published private(set) var isHearing = true

    var isEnabled = true {
        didSet { if isEnabled != oldValue { failed = false; refresh() } }
    }
    /// Whether any player is playing.
    var isPlaying = false {
        didSet {
            guard isPlaying != oldValue else { return }
            if isPlaying { failed = false }
            refresh()
        }
    }

    private let views = NSHashTable<LevelBarsView>.weakObjects()
    private let analyzer = AudioLevels(bandCount: 8)
    private var samples = [Float](repeating: 0, count: AudioLevels.fftSize)
    private var tap: AnyObject?
    private var timer: Timer?
    private var closeWork: DispatchWorkItem?
    private var failed = false
    private var listeningSince = Date()
    private var lastHeard: Date?
    private var outputListener: AudioObjectPropertyListenerBlock?
    private static var defaultOutput = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)

    func attach(_ view: LevelBarsView) {
        views.add(view)
        refresh()
    }

    func detach(_ view: LevelBarsView) {
        views.remove(view)
        refresh()
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        closeTap()
    }

    private func refresh() {
        var supported = false
        if #available(macOS 14.2, *) { supported = true }
        let available = isEnabled && supported && !failed
        if isAvailable != available { isAvailable = available }

        if available, isPlaying, !views.allObjects.isEmpty {
            closeWork?.cancel()
            closeWork = nil
            if tap == nil { openTap() }
            guard tap != nil, timer == nil else { return }
            listeningSince = Date()
            lastHeard = nil
            let timer = Timer(timeInterval: Self.tick, repeats: true) { [weak self] _ in
                MainActor.assumeIsolated { self?.sample() }
            }
            RunLoop.main.add(timer, forMode: .common)
            self.timer = timer
        } else {
            timer?.invalidate()
            timer = nil
            analyzer.reset()
            // Pausing for a moment, or a view replacing another, shouldn't rebuild the tap.
            if tap != nil, closeWork == nil {
                let work = DispatchWorkItem { [weak self] in MainActor.assumeIsolated { self?.closeTap() } }
                closeWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
            }
        }
    }

    private func sample() {
        guard #available(macOS 14.2, *), let tap = tap as? SystemAudioTap else { return }
        let heard = samples.withUnsafeMutableBufferPointer { tap.ring.copyLatest(into: $0.baseAddress!, count: $0.count) }
        let now = Date()
        if heard {
            lastHeard = now
            if !isHearing { isHearing = true }
        } else if isHearing, now.timeIntervalSince(lastHeard ?? listeningSince) > 2.5 {
            log.notice("Playing, but the tap hears nothing: showing the symbol")
            isHearing = false
        }
        let levels = samples.withUnsafeBufferPointer { analyzer.analyze($0.baseAddress!, sampleRate: tap.sampleRate) }
        for view in views.allObjects { view.show(levels) }
    }

    private func openTap() {
        guard #available(macOS 14.2, *) else { return }
        do {
            tap = try SystemAudioTap()
            // The tap is tied to the output device: follow it when it changes (AirPods connecting).
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated {
                    guard let self, self.tap != nil else { return }
                    log.notice("Output device changed: listening again")
                    self.closeTap()
                    self.timer?.invalidate()
                    self.timer = nil
                    self.refresh()
                }
            }
            AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutput, .main, listener)
            outputListener = listener
        } catch {
            log.error("Couldn't listen: \(error.localizedDescription, privacy: .public)")
            failed = true
            refresh()
        }
    }

    private func closeTap() {
        closeWork?.cancel()
        closeWork = nil
        if let listener = outputListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutput, .main, listener)
        }
        outputListener = nil
        if #available(macOS 14.2, *) { (tap as? SystemAudioTap)?.stop() }
        tap = nil
    }
}

// MARK: - The tap

/// A listen-only tap on everything the Mac plays, except LiveIsland itself.
///
/// Core Audio only delivers a tap's audio through a device, so a private aggregate device pairs
/// it with the current output, the way LiveEQ does. LiveIsland never changes the sound: the tap
/// is unmuted, and the aggregate's own output is silence.
@available(macOS 14.2, *)
final class SystemAudioTap {
    let ring = SampleRing()
    private(set) var sampleRate: Double = 48_000
    private var tapID = AudioObjectID(kAudioObjectUnknown)
    private var aggregateID = AudioObjectID(kAudioObjectUnknown)
    private var procID: AudioDeviceIOProcID?
    private static let queue = DispatchQueue(label: "com.aissam.liveisland.levels", qos: .userInteractive)

    init() throws {
        do {
            try build()
        } catch {
            stop()
            throw error
        }
    }

    private func build() throws {
        let output: AudioObjectID = try HAL.value(HAL.system, kAudioHardwarePropertyDefaultOutputDevice)
        guard output != kAudioObjectUnknown else { throw HAL.Failure(action: "find the output device", status: -1) }
        let outputUID = try HAL.string(output, kAudioDevicePropertyDeviceUID)

        let description = CATapDescription(monoGlobalTapButExcludeProcesses: HAL.processObject(for: getpid()).map { [$0] } ?? [])
        description.name = "LiveIsland levels"
        description.uuid = UUID()
        description.isPrivate = true
        description.muteBehavior = .unmuted
        try HAL.check(AudioHardwareCreateProcessTap(description, &tapID), "create the tap")
        let format: AudioStreamBasicDescription = try HAL.value(tapID, kAudioTapPropertyFormat)
        guard format.mFormatID == kAudioFormatLinearPCM, format.mFormatFlags & kAudioFormatFlagIsFloat != 0,
              format.mBitsPerChannel == 32
        else { throw HAL.Failure(action: "read the tap's format", status: -1) }
        if format.mSampleRate > 0 { sampleRate = format.mSampleRate }

        let aggregate: [String: Any] = [
            kAudioAggregateDeviceNameKey: "LiveIsland levels",
            kAudioAggregateDeviceUIDKey: "com.aissam.liveisland.levels.\(UUID().uuidString)",
            kAudioAggregateDeviceMainSubDeviceKey: outputUID,
            kAudioAggregateDeviceIsPrivateKey: true,
            kAudioAggregateDeviceIsStackedKey: false,
            kAudioAggregateDeviceTapAutoStartKey: true,
            kAudioAggregateDeviceSubDeviceListKey: [[kAudioSubDeviceUIDKey: outputUID]],
            kAudioAggregateDeviceTapListKey: [[
                kAudioSubTapUIDKey: description.uuid.uuidString,
                kAudioSubTapDriftCompensationKey: true,
            ]],
        ]
        try HAL.check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggregateID), "create the listening device")

        // The output device's own input streams, if any, come before the tap's.
        let tapIndex = HAL.streamCount(output, scope: kAudioObjectPropertyScopeInput)
        try HAL.check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggregateID, Self.queue, Self.ioBlock(ring: ring, tapIndex: tapIndex)),
                      "start listening")
        try HAL.check(AudioDeviceStart(aggregateID, procID), "start listening")
        log.notice("Listening at \(self.sampleRate) Hz")
    }

    /// Built outside any actor: Core Audio calls it on its real-time thread.
    private static func ioBlock(ring: SampleRing, tapIndex: Int) -> AudioDeviceIOBlock {
        { _, input, _, output, _ in
            for buffer in UnsafeMutableAudioBufferListPointer(output) {
                if let data = buffer.mData { memset(data, 0, Int(buffer.mDataByteSize)) }
            }
            let inputs = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: input))
            guard tapIndex < inputs.count, let data = inputs[tapIndex].mData?.assumingMemoryBound(to: Float.self) else { return }
            let channels = max(1, Int(inputs[tapIndex].mNumberChannels))
            ring.write(data, frames: Int(inputs[tapIndex].mDataByteSize) / (MemoryLayout<Float>.size * channels), channels: channels)
        }
    }

    func stop() {
        if let procID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
        }
        procID = nil
        if aggregateID != kAudioObjectUnknown { AudioHardwareDestroyAggregateDevice(aggregateID) }
        aggregateID = AudioObjectID(kAudioObjectUnknown)
        if tapID != kAudioObjectUnknown { AudioHardwareDestroyProcessTap(tapID) }
        tapID = AudioObjectID(kAudioObjectUnknown)
    }
}

/// The latest samples, written on Core Audio's real-time thread and read on the main thread.
/// The writer never waits: if the reader holds the lock, that block is skipped.
final class SampleRing: @unchecked Sendable {
    private static let capacity = 4096
    private let lock = UnsafeMutablePointer<os_unfair_lock>.allocate(capacity: 1)
    private let buffer = UnsafeMutablePointer<Float>.allocate(capacity: capacity)
    private var writeIndex = 0
    private var written = 0
    private var peak: Float = 0

    init() {
        lock.initialize(to: os_unfair_lock())
        buffer.initialize(repeating: 0, count: Self.capacity)
    }

    deinit {
        lock.deallocate()
        buffer.deallocate()
    }

    /// Mixes interleaved channels down to one and appends them.
    func write(_ data: UnsafePointer<Float>, frames: Int, channels: Int) {
        guard os_unfair_lock_trylock(lock) else { return }
        let mask = Self.capacity - 1
        let scale = 1 / Float(channels)
        for frame in 0..<frames {
            var sum: Float = 0
            for channel in 0..<channels { sum += data[frame * channels + channel] }
            let sample = sum * scale
            buffer[writeIndex] = sample
            writeIndex = (writeIndex + 1) & mask
            peak = max(peak, abs(sample))
        }
        written += frames
        os_unfair_lock_unlock(lock)
    }

    /// Copies the latest `count` samples, oldest first, or silence if nothing new arrived.
    /// Returns whether any sound arrived since the last copy.
    func copyLatest(into destination: UnsafeMutablePointer<Float>, count: Int) -> Bool {
        os_unfair_lock_lock(lock)
        defer { os_unfair_lock_unlock(lock) }
        let heard = peak > 1e-5
        let fresh = written > 0
        peak = 0
        written = 0
        guard fresh else {
            destination.update(repeating: 0, count: count)
            return false
        }
        let mask = Self.capacity - 1
        var read = (writeIndex - min(count, Self.capacity)) & mask
        for index in 0..<count {
            destination[index] = buffer[read]
            read = (read + 1) & mask
        }
        return heard
    }
}

/// The few Core Audio property reads the tap needs.
private enum HAL {
    static let system = AudioObjectID(kAudioObjectSystemObject)

    struct Failure: LocalizedError {
        let action: String
        let status: OSStatus
        var errorDescription: String? { "Couldn't \(action) (error \(status))" }
    }

    static func check(_ status: OSStatus, _ action: String) throws {
        guard status == noErr else { throw Failure(action: action, status: status) }
    }

    static func address(_ selector: AudioObjectPropertySelector,
                        scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope, mElement: kAudioObjectPropertyElementMain)
    }

    static func value<T>(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> T {
        var address = address(selector)
        var size = UInt32(MemoryLayout<T>.size)
        let pointer = UnsafeMutablePointer<T>.allocate(capacity: 1)
        defer { pointer.deallocate() }
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, pointer), "read a property")
        return pointer.pointee
    }

    static func string(_ object: AudioObjectID, _ selector: AudioObjectPropertySelector) throws -> String {
        var address = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var value: Unmanaged<CFString>?
        try check(AudioObjectGetPropertyData(object, &address, 0, nil, &size, &value), "read a name")
        guard let value else { throw Failure(action: "read a name", status: -1) }
        return value.takeRetainedValue() as String
    }

    static func streamCount(_ device: AudioObjectID, scope: AudioObjectPropertyScope) -> Int {
        var address = address(kAudioDevicePropertyStreams, scope: scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(device, &address, 0, nil, &size) == noErr else { return 0 }
        return Int(size) / MemoryLayout<AudioStreamID>.size
    }

    /// LiveIsland's own audio (the agent sounds), kept out of its waveform.
    static func processObject(for pid: pid_t) -> AudioObjectID? {
        var pid = pid
        var address = address(kAudioHardwarePropertyTranslatePIDToProcessObject)
        var object = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(system, &address, UInt32(MemoryLayout<pid_t>.size), &pid, &size, &object)
        return status == noErr && object != kAudioObjectUnknown ? object : nil
    }
}
