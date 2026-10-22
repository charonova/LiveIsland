import AppKit
import CoreBluetooth
import CoreAudio
import CoreMediaIO
import IOBluetooth
import IOKit.ps
import LiveIslandCore
import os

private let log = Logger(subsystem: "com.aissam.liveisland", category: "system")

/// Calls, microphone, camera, battery and headphones.
@MainActor
final class SystemMonitor: NSObject {
    struct Snapshot: Equatable {
        /// Apps using the microphone right now (display names).
        var microphoneApps: [String] = []
        var cameraOn = false
        /// The calling app holding the microphone, and since when.
        var call: (app: String, since: Date)?
        var battery: Battery?
        var headphones: Headphones?

        static func == (lhs: Snapshot, rhs: Snapshot) -> Bool {
            lhs.microphoneApps == rhs.microphoneApps && lhs.cameraOn == rhs.cameraOn
                && lhs.call?.app == rhs.call?.app && lhs.call?.since == rhs.call?.since
                && lhs.battery == rhs.battery && lhs.headphones == rhs.headphones
        }
    }

    struct Battery: Equatable {
        var percent: Int
        var isCharging: Bool
        var onPower: Bool
        /// Until empty on battery, or until full while charging; nil while macOS estimates.
        var minutesRemaining: Int? = nil
    }

    struct Headphones: Equatable {
        var name: String
        var left: Int?
        var right: Int?
        var single: Int?
        var caseLevel: Int?
        var connected: Bool

        /// The lowest earbud level, for a single number in the notch.
        var summary: Int? { [left, right, single].compactMap { $0 }.min() }
    }

    var onUpdate: ((Snapshot) -> Void)?
    /// Fires when power is plugged in and when headphones connect.
    var onEvent: ((IslandActivity) -> Void)?
    private(set) var snapshot = Snapshot()

    private var poll: Timer?
    private var powerSource: CFRunLoopSource?
    private var connectNotification: IOBluetoothUserNotification?
    private var disconnectNotifications: [IOBluetoothUserNotification] = []
    private var startedAt = Date()
    private let bluetooth = BluetoothAccess()
    /// When each device was last announced; macOS can report one connection several times.
    private var announced: [String: Date] = [:]

    /// Apps whose microphone use means a call.
    private static let callApps: Set<String> = [
        "com.apple.FaceTime", "com.apple.TelephonyUtilities", "com.apple.avconferenced", "us.zoom.xos",
        "com.microsoft.teams2", "com.microsoft.teams", "com.hnc.Discord", "net.whatsapp.WhatsApp",
        "com.tinyspeck.slackmacgap", "com.skype.skype", "ru.keepcoder.Telegram", "com.cisco.webexmeetingsapp",
    ]
    /// Always-listening system services and audio tools, not someone using the mic.
    private static let ignoredMicrophoneClients: [String] = [
        "com.apple.CoreSpeech", "com.apple.corespeechd", "com.apple.siri", "com.apple.assistant",
        "com.apple.accessibility", "com.apple.SpeechRecognitionCore", "com.aissam.",
    ]

    func start() {
        startedAt = Date()
        refreshDevices()
        poll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshDevices() }
        }
        startPowerMonitoring()
        bluetooth.whenGranted { [weak self] in self?.startWatchingHeadphones() }
    }

    /// Only once Bluetooth access is granted: before that, IOBluetooth's first call waits for
    /// the user's answer to the permission prompt, freezing the whole app.
    private func startWatchingHeadphones() {
        // Devices already connected get reported as they're registered; those aren't news.
        startedAt = Date()
        connectNotification = IOBluetoothDevice.register(forConnectNotifications: self, selector: #selector(bluetoothConnected(_:device:)))
        for device in (IOBluetoothDevice.pairedDevices() as? [IOBluetoothDevice] ?? []) where device.isConnected() && Self.isAudio(device) {
            watchDisconnect(of: device)
            Task { await readHeadphoneBattery(name: device.name ?? "Headphones", announce: false) }
        }
    }

    func stop() {
        poll?.invalidate()
        connectNotification?.unregister()
        disconnectNotifications.forEach { $0.unregister() }
        if let powerSource { CFRunLoopRemoveSource(CFRunLoopGetMain(), powerSource, .defaultMode) }
    }

    // MARK: - Microphone, camera, calls

    private func refreshDevices() {
        var next = snapshot
        let clients = Self.microphoneClients()
        let callClient = clients.first { Self.callApps.contains($0) }
        next.microphoneApps = clients.filter { $0 != callClient }.map(Self.displayName(of:))
        next.cameraOn = Self.isCameraOn()
        if let callClient {
            let app = Self.displayName(of: callClient)
            next.call = snapshot.call?.app == app ? snapshot.call : (app, Date())
        } else {
            next.call = nil
        }
        publish(next)
    }

    /// Whether any device that records is running at all: one cheap question that saves
    /// asking every audio process, nearly every second.
    private static func anyInputRunning() -> Bool {
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyDevices,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return true }
        var devices = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &devices) == noErr else { return true }
        for device in devices {
            var streams = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyStreams,
                                                     mScope: kAudioDevicePropertyScopeInput, mElement: kAudioObjectPropertyElementMain)
            var streamsSize: UInt32 = 0
            guard AudioObjectGetPropertyDataSize(device, &streams, 0, nil, &streamsSize) == noErr, streamsSize > 0 else { continue }
            var running = AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyDeviceIsRunningSomewhere,
                                                     mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            var value: UInt32 = 0
            var valueSize = UInt32(MemoryLayout<UInt32>.size)
            if AudioObjectGetPropertyData(device, &running, 0, nil, &valueSize, &value) == noErr, value != 0 { return true }
        }
        return false
    }

    private static func microphoneClients() -> [String] {
        guard anyInputRunning() else { return [] }
        let system = AudioObjectID(kAudioObjectSystemObject)
        var address = AudioObjectPropertyAddress(mSelector: kAudioHardwarePropertyProcessObjectList,
                                                 mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(system, &address, 0, nil, &size) == noErr, size > 0 else { return [] }
        var processes = [AudioObjectID](repeating: 0, count: Int(size) / MemoryLayout<AudioObjectID>.size)
        guard AudioObjectGetPropertyData(system, &address, 0, nil, &size, &processes) == noErr else { return [] }

        var clients: [String] = []
        for process in processes {
            var running: UInt32 = 0
            var runningSize = UInt32(MemoryLayout<UInt32>.size)
            var runningAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyIsRunningInput,
                                                            mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(process, &runningAddress, 0, nil, &runningSize, &running) == noErr, running != 0 else { continue }
            var bundle: Unmanaged<CFString>?
            var bundleSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var bundleAddress = AudioObjectPropertyAddress(mSelector: kAudioProcessPropertyBundleID,
                                                           mScope: kAudioObjectPropertyScopeGlobal, mElement: kAudioObjectPropertyElementMain)
            guard AudioObjectGetPropertyData(process, &bundleAddress, 0, nil, &bundleSize, &bundle) == noErr,
                  let identifier = bundle?.takeRetainedValue() as String?, !identifier.isEmpty,
                  !ignoredMicrophoneClients.contains(where: { identifier.hasPrefix($0) })
            else { continue }
            clients.append(identifier)
        }
        return clients
    }

    private static func isCameraOn() -> Bool {
        var address = CMIOObjectPropertyAddress(
            mSelector: CMIOObjectPropertySelector(kCMIOHardwarePropertyDevices),
            mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
            mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
        var size: UInt32 = 0
        guard CMIOObjectGetPropertyDataSize(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, &size) == noErr else { return false }
        var devices = [CMIOObjectID](repeating: 0, count: Int(size) / MemoryLayout<CMIOObjectID>.size)
        var used: UInt32 = 0
        guard CMIOObjectGetPropertyData(CMIOObjectID(kCMIOObjectSystemObject), &address, 0, nil, size, &used, &devices) == noErr else {
            return false
        }
        return devices.contains { device in
            var running = CMIOObjectPropertyAddress(
                mSelector: CMIOObjectPropertySelector(kCMIODevicePropertyDeviceIsRunningSomewhere),
                mScope: CMIOObjectPropertyScope(kCMIOObjectPropertyScopeGlobal),
                mElement: CMIOObjectPropertyElement(kCMIOObjectPropertyElementMain))
            var value: UInt32 = 0
            var valueSize: UInt32 = 0
            return CMIOObjectGetPropertyData(device, &running, 0, nil, UInt32(MemoryLayout<UInt32>.size), &valueSize, &value) == noErr && value != 0
        }
    }

    static func displayName(of bundleIdentifier: String) -> String {
        if let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleIdentifier) {
            return FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        }
        switch bundleIdentifier {
        case "com.apple.TelephonyUtilities", "com.apple.avconferenced": return "iPhone Call"
        default: return bundleIdentifier.split(separator: ".").last.map(String.init) ?? bundleIdentifier
        }
    }

    // MARK: - Battery

    private func startPowerMonitoring() {
        readBattery(announce: false)
        let context = Unmanaged.passUnretained(self).toOpaque()
        let callback: IOPowerSourceCallbackType = { context in
            guard let context else { return }
            let monitor = Unmanaged<SystemMonitor>.fromOpaque(context).takeUnretainedValue()
            MainActor.assumeIsolated { monitor.readBattery(announce: true) }
        }
        guard let source = IOPSNotificationCreateRunLoopSource(callback, context)?.takeRetainedValue() else { return }
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .defaultMode)
        powerSource = source
    }

    private func readBattery(announce: Bool) {
        guard let info = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(info)?.takeRetainedValue() as? [CFTypeRef]
        else { return }
        for source in list {
            guard let description = IOPSGetPowerSourceDescription(info, source)?.takeUnretainedValue() as? [String: Any],
                  description[kIOPSTypeKey] as? String == kIOPSInternalBatteryType,
                  let current = description[kIOPSCurrentCapacityKey] as? Int,
                  let max = description[kIOPSMaxCapacityKey] as? Int, max > 0
            else { continue }
            var battery = Battery(
                percent: Int((Double(current) / Double(max) * 100).rounded()),
                isCharging: description[kIOPSIsChargingKey] as? Bool ?? false,
                onPower: description[kIOPSPowerSourceStateKey] as? String == kIOPSACPowerValue)
            let minutes = description[battery.isCharging ? kIOPSTimeToFullChargeKey : kIOPSTimeToEmptyKey] as? Int
            if let minutes, minutes > 0, battery.isCharging || !battery.onPower { battery.minutesRemaining = minutes }
            let pluggedIn = announce && battery.onPower && snapshot.battery?.onPower == false
            var next = snapshot
            next.battery = battery
            publish(next)
            if pluggedIn { onEvent?(.charging(percent: battery.percent)) }
            return
        }
    }

    // MARK: - Headphones

    @objc private func bluetoothConnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard Self.isAudio(device) else { return }
        let name = device.name ?? "Headphones"
        // Devices already connected at launch are reported too; those aren't news.
        guard Date().timeIntervalSince(startedAt) > 8 else { return }
        if let last = announced[name], Date().timeIntervalSince(last) < 15 { return }
        announced[name] = Date()
        watchDisconnect(of: device)
        log.notice("Audio device connected: \(name, privacy: .public)")
        // Battery levels show up a moment after the connection.
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            await readHeadphoneBattery(name: name, announce: true)
        }
    }

    @objc private func bluetoothDisconnected(_ notification: IOBluetoothUserNotification, device: IOBluetoothDevice) {
        guard var headphones = snapshot.headphones, headphones.name == device.name else { return }
        headphones.connected = false
        var next = snapshot
        next.headphones = headphones
        publish(next)
    }

    private func watchDisconnect(of device: IOBluetoothDevice) {
        if let notification = device.register(forDisconnectNotification: self, selector: #selector(bluetoothDisconnected(_:device:))) {
            disconnectNotifications.append(notification)
        }
    }

    /// Battery levels for AirPods and other headphones, from System Information's Bluetooth report.
    private func readHeadphoneBattery(name: String, announce: Bool) async {
        let report = try? await ProcessRunner.output("/usr/sbin/system_profiler", ["SPBluetoothDataType", "-json"])
        var headphones = Headphones(name: name, connected: true)
        if let data = report,
           let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let controllers = root["SPBluetoothDataType"] as? [[String: Any]] {
            for controller in controllers {
                for entry in controller["device_connected"] as? [[String: Any]] ?? [] {
                    guard let info = entry[name] as? [String: Any] else { continue }
                    func level(_ key: String) -> Int? { (info[key] as? String).flatMap { Int($0.replacingOccurrences(of: "%", with: "")) } }
                    headphones.left = level("device_batteryLevelLeft")
                    headphones.right = level("device_batteryLevelRight")
                    headphones.caseLevel = level("device_batteryLevelCase")
                    headphones.single = level("device_batteryLevelMain")
                }
            }
        }
        var next = snapshot
        next.headphones = headphones
        publish(next)
        if announce { onEvent?(.headphonesConnected(name: name, battery: headphones.summary)) }
    }

    private static func isAudio(_ device: IOBluetoothDevice) -> Bool {
        device.deviceClassMajor == kBluetoothDeviceClassMajorAudio
    }

    private func publish(_ next: Snapshot) {
        guard next != snapshot else { return }
        snapshot = next
        onUpdate?(next)
    }
}

/// Asks for Bluetooth access without blocking. CoreBluetooth shows the permission prompt and
/// reports the answer later; IOBluetooth would wait for it on the calling thread.
@MainActor
private final class BluetoothAccess: NSObject, CBCentralManagerDelegate {
    private var manager: CBCentralManager?
    private var onGranted: (() -> Void)?

    func whenGranted(_ action: @escaping () -> Void) {
        switch CBManager.authorization {
        case .allowedAlways:
            action()
        case .notDetermined:
            onGranted = action
            manager = CBCentralManager(delegate: self, queue: .main, options: [CBCentralManagerOptionShowPowerAlertKey: false])
        default:
            log.notice("Bluetooth access is off; headphones won't show")
        }
    }

    nonisolated func centralManagerDidUpdateState(_ central: CBCentralManager) {
        MainActor.assumeIsolated {
            guard CBManager.authorization == .allowedAlways, let action = onGranted else { return }
            onGranted = nil
            manager = nil
            action()
        }
    }
}
