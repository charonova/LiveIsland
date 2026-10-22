import AudioToolbox
import CoreAudio
import os

private let log = Logger(subsystem: "com.aissam.liveisland", category: "volume")

/// The system output: which device it is, its volume and mute, kept current with Core Audio
/// listeners and settable from the island.
@MainActor
final class OutputVolume {
    struct State: Equatable {
        var device: String
        var isBluetooth: Bool
        var isBuiltIn: Bool
        var volume: Float
        var muted: Bool
        /// Some outputs (HDMI, many interfaces) have no software volume.
        var canSetVolume: Bool
    }

    var onChange: ((State?) -> Void)?
    private(set) var state: State?

    private var device = AudioObjectID(kAudioObjectUnknown)
    private var deviceListeners: [(AudioObjectPropertyAddress, AudioObjectPropertyListenerBlock)] = []
    private var defaultDeviceListener: AudioObjectPropertyListenerBlock?

    private static var defaultOutput = AudioObjectPropertyAddress(
        mSelector: kAudioHardwarePropertyDefaultOutputDevice, mScope: kAudioObjectPropertyScopeGlobal,
        mElement: kAudioObjectPropertyElementMain)
    private static var volume = AudioObjectPropertyAddress(
        mSelector: kAudioHardwareServiceDeviceProperty_VirtualMainVolume, mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)
    private static var mute = AudioObjectPropertyAddress(
        mSelector: kAudioDevicePropertyMute, mScope: kAudioDevicePropertyScopeOutput,
        mElement: kAudioObjectPropertyElementMain)

    func start() {
        let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.attach() }
        }
        AudioObjectAddPropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutput, .main, listener)
        defaultDeviceListener = listener
        attach()
    }

    func stop() {
        detach()
        if let listener = defaultDeviceListener {
            AudioObjectRemovePropertyListenerBlock(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutput, .main, listener)
        }
        defaultDeviceListener = nil
    }

    func setVolume(_ value: Float) {
        guard device != kAudioObjectUnknown else { return }
        var volume = Float32(min(max(value, 0), 1))
        let status = AudioObjectSetPropertyData(device, &Self.volume, 0, nil, UInt32(MemoryLayout<Float32>.size), &volume)
        if status != noErr { log.error("Couldn't set the volume: \(status)") }
        // Turning the volume up unmutes, like the keyboard keys do.
        if volume > 0, state?.muted == true { setMuted(false) }
        read()
    }

    func toggleMute() {
        setMuted(!(state?.muted ?? false))
    }

    private func setMuted(_ muted: Bool) {
        guard device != kAudioObjectUnknown else { return }
        var value: UInt32 = muted ? 1 : 0
        AudioObjectSetPropertyData(device, &Self.mute, 0, nil, UInt32(MemoryLayout<UInt32>.size), &value)
        read()
    }

    /// Follows the default output, and listens to its volume and mute.
    private func attach() {
        detach()
        var id = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &Self.defaultOutput, 0, nil, &size, &id)
        device = id
        guard id != kAudioObjectUnknown else { return publish(nil) }
        for address in [Self.volume, Self.mute] {
            var address = address
            guard AudioObjectHasProperty(id, &address) else { continue }
            let listener: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
                MainActor.assumeIsolated { self?.read() }
            }
            AudioObjectAddPropertyListenerBlock(id, &address, .main, listener)
            deviceListeners.append((address, listener))
        }
        read()
    }

    private func detach() {
        for (address, listener) in deviceListeners {
            var address = address
            AudioObjectRemovePropertyListenerBlock(device, &address, .main, listener)
        }
        deviceListeners = []
    }

    private func read() {
        guard device != kAudioObjectUnknown else { return publish(nil) }
        var volume: Float32 = 1
        var size = UInt32(MemoryLayout<Float32>.size)
        let hasVolume = AudioObjectHasProperty(device, &Self.volume)
            && AudioObjectGetPropertyData(device, &Self.volume, 0, nil, &size, &volume) == noErr
        var settable: DarwinBoolean = false
        if hasVolume { AudioObjectIsPropertySettable(device, &Self.volume, &settable) }
        var muted: UInt32 = 0
        size = UInt32(MemoryLayout<UInt32>.size)
        if AudioObjectHasProperty(device, &Self.mute) { AudioObjectGetPropertyData(device, &Self.mute, 0, nil, &size, &muted) }
        let transport = Self.transport(of: device)
        publish(State(device: Self.name(of: device) ?? "Output",
                      isBluetooth: transport == kAudioDeviceTransportTypeBluetooth || transport == kAudioDeviceTransportTypeBluetoothLE,
                      isBuiltIn: transport == kAudioDeviceTransportTypeBuiltIn,
                      volume: hasVolume ? volume : 1, muted: muted != 0, canSetVolume: settable.boolValue))
    }

    private func publish(_ next: State?) {
        guard next != state else { return }
        state = next
        onChange?(next)
    }

    private static func name(of device: AudioObjectID) -> String? {
        var address = AudioObjectPropertyAddress(mSelector: kAudioObjectPropertyName, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var name: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(device, &address, 0, nil, &size, &name) == noErr else { return nil }
        return name?.takeRetainedValue() as String?
    }

    private static func transport(of device: AudioObjectID) -> UInt32 {
        var address = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyTransportType, mScope: kAudioObjectPropertyScopeGlobal,
                                                 mElement: kAudioObjectPropertyElementMain)
        var transport: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        AudioObjectGetPropertyData(device, &address, 0, nil, &size, &transport)
        return transport
    }
}
