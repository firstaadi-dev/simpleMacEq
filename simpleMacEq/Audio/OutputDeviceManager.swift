import Foundation
import CoreAudio
import Combine

struct AudioOutputDevice: Identifiable, Hashable {
    let id: AudioDeviceID
    let name: String
    let uid: String
}

/// Enumerates output-capable audio devices and tracks the system default output.
/// Selecting a device switches the system default output device, and external changes
/// (hot-plug, switching in Sound settings) are reflected live.
///
/// Also exposes the selected device's **hardware** output volume two-way: the Master
/// slider drives `kAudioDevicePropertyVolumeScalar` (moving macOS's own volume), and
/// external changes (media keys, Control Center) flow back into `outputVolume`.
@MainActor
final class OutputDeviceManager: ObservableObject {
    @Published private(set) var devices: [AudioOutputDevice] = []
    @Published var selectedDeviceID: AudioDeviceID = 0

    /// Hardware output volume of the selected device (0...1).
    @Published var outputVolume: Double = 1.0
    /// False when the selected device exposes no settable volume (e.g. some digital outs).
    @Published private(set) var outputVolumeAvailable: Bool = true

    private let system = AudioObjectID(kAudioObjectSystemObject)
    private var cancellables = Set<AnyCancellable>()

    // Volume listener bookkeeping so we can move it when the device changes.
    private var volumeListenerBlock: AudioObjectPropertyListenerBlock?
    private var volumeListenedDevice: AudioDeviceID = 0
    private var applyingExternalVolume = false

    init() {
        refresh()
        selectedDeviceID = Self.defaultOutputDeviceID() ?? devices.first?.id ?? 0
        installListeners()

        // Whenever the selected device changes, move the volume listener and re-read.
        $selectedDeviceID
            .removeDuplicates()
            .sink { [weak self] id in self?.onSelectedDeviceChanged(id) }
            .store(in: &cancellables)
    }

    func select(_ device: AudioOutputDevice) {
        selectedDeviceID = device.id
        Self.setDefaultOutputDevice(device.id)
    }

    func refresh() {
        devices = Self.outputDevices()
        if !devices.contains(where: { $0.id == selectedDeviceID }) {
            selectedDeviceID = Self.defaultOutputDeviceID() ?? devices.first?.id ?? 0
        }
    }

    // MARK: - Hardware volume

    /// Set by the Master slider: writes the device volume (moving the macOS volume too).
    func setOutputVolume(_ value: Double) {
        let clamped = min(max(value, 0), 1)
        outputVolume = clamped
        guard !applyingExternalVolume else { return }
        Self.setDeviceVolume(selectedDeviceID, Float(clamped))
    }

    private func onSelectedDeviceChanged(_ id: AudioDeviceID) {
        installVolumeListener(on: id)
        outputVolumeAvailable = Self.deviceHasVolume(id)
        syncVolumeFromDevice()
    }

    private func syncVolumeFromDevice() {
        guard let v = Self.deviceVolume(selectedDeviceID) else { return }
        if abs(Double(v) - outputVolume) > 0.0005 {
            applyingExternalVolume = true
            outputVolume = Double(v)
            applyingExternalVolume = false
        }
    }

    private func installVolumeListener(on id: AudioDeviceID) {
        // Remove from the previously-listened device.
        if let block = volumeListenerBlock, volumeListenedDevice != 0 {
            for element in Self.volumeElements {
                var addr = Self.volumeAddress(element)
                AudioObjectRemovePropertyListenerBlock(volumeListenedDevice, &addr, DispatchQueue.main, block)
            }
        }
        guard id != 0 else { volumeListenerBlock = nil; volumeListenedDevice = 0; return }

        let block: AudioObjectPropertyListenerBlock = { [weak self] _, _ in
            MainActor.assumeIsolated { self?.syncVolumeFromDevice() }
        }
        for element in Self.volumeElements {
            var addr = Self.volumeAddress(element)
            if AudioObjectHasProperty(id, &addr) {
                AudioObjectAddPropertyListenerBlock(id, &addr, DispatchQueue.main, block)
            }
        }
        volumeListenerBlock = block
        volumeListenedDevice = id
    }

    // MARK: - Property listeners

    private func installListeners() {
        var devicesAddr = Self.address(kAudioHardwarePropertyDevices)
        var defaultAddr = Self.address(kAudioHardwarePropertyDefaultOutputDevice)

        AudioObjectAddPropertyListenerBlock(system, &devicesAddr, DispatchQueue.main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        AudioObjectAddPropertyListenerBlock(system, &defaultAddr, DispatchQueue.main) { [weak self] _, _ in
            MainActor.assumeIsolated {
                if let id = Self.defaultOutputDeviceID() { self?.selectedDeviceID = id }
            }
        }
    }

    // MARK: - Core Audio helpers

    private static func address(_ selector: AudioObjectPropertySelector,
                               scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector, mScope: scope,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    // Volume lives on the main element on most devices, or per-channel (1, 2) on others.
    private static let volumeElements: [AudioObjectPropertyElement] =
        [kAudioObjectPropertyElementMain, 1, 2]

    private static func volumeAddress(_ element: AudioObjectPropertyElement)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: kAudioDevicePropertyVolumeScalar,
                                   mScope: kAudioObjectPropertyScopeOutput,
                                   mElement: element)
    }

    static func deviceHasVolume(_ id: AudioDeviceID) -> Bool {
        guard id != 0 else { return false }
        for element in volumeElements {
            var addr = volumeAddress(element)
            if AudioObjectHasProperty(id, &addr) { return true }
        }
        return false
    }

    /// Reads the device volume, preferring the main element, else averaging channels.
    static func deviceVolume(_ id: AudioDeviceID) -> Float? {
        guard id != 0 else { return nil }
        var mainAddr = volumeAddress(kAudioObjectPropertyElementMain)
        if AudioObjectHasProperty(id, &mainAddr) {
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(id, &mainAddr, 0, nil, &size, &value) == noErr {
                return value
            }
        }
        var sum: Float = 0, n = 0
        for element in [AudioObjectPropertyElement(1), 2] {
            var addr = volumeAddress(element)
            guard AudioObjectHasProperty(id, &addr) else { continue }
            var value: Float32 = 0
            var size = UInt32(MemoryLayout<Float32>.size)
            if AudioObjectGetPropertyData(id, &addr, 0, nil, &size, &value) == noErr {
                sum += value; n += 1
            }
        }
        return n > 0 ? sum / Float(n) : nil
    }

    /// Writes the device volume on whichever elements are settable.
    static func setDeviceVolume(_ id: AudioDeviceID, _ value: Float) {
        guard id != 0 else { return }
        var v = value
        let size = UInt32(MemoryLayout<Float32>.size)

        var mainAddr = volumeAddress(kAudioObjectPropertyElementMain)
        var settable = DarwinBoolean(false)
        if AudioObjectHasProperty(id, &mainAddr),
           AudioObjectIsPropertySettable(id, &mainAddr, &settable) == noErr, settable.boolValue {
            AudioObjectSetPropertyData(id, &mainAddr, 0, nil, size, &v)
            return
        }
        for element in [AudioObjectPropertyElement(1), 2] {
            var addr = volumeAddress(element)
            var chSettable = DarwinBoolean(false)
            if AudioObjectHasProperty(id, &addr),
               AudioObjectIsPropertySettable(id, &addr, &chSettable) == noErr, chSettable.boolValue {
                AudioObjectSetPropertyData(id, &addr, 0, nil, size, &v)
            }
        }
    }

    private static func outputDevices() -> [AudioOutputDevice] {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return [] }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }

        return ids.compactMap { id in
            guard hasOutputStreams(id) else { return nil }
            let name = stringProperty(id, kAudioObjectPropertyName) ?? "Unknown Device"
            let uid = stringProperty(id, kAudioDevicePropertyDeviceUID) ?? ""
            return AudioOutputDevice(id: id, name: name, uid: uid)
        }
    }

    private static func hasOutputStreams(_ id: AudioDeviceID) -> Bool {
        var addr = address(kAudioDevicePropertyStreams, scope: kAudioObjectPropertyScopeOutput)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(id, &addr, 0, nil, &size) == noErr else { return false }
        return size > 0
    }

    private static func stringProperty(_ id: AudioDeviceID,
                                       _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var result: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(id, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let cf = result else { return nil }
        return cf.takeRetainedValue() as String
    }

    static func defaultOutputDeviceID() -> AudioDeviceID? {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var id = AudioDeviceID(0)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        let status = AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                                &addr, 0, nil, &size, &id)
        return status == noErr ? id : nil
    }

    static func setDefaultOutputDevice(_ id: AudioDeviceID) {
        var addr = address(kAudioHardwarePropertyDefaultOutputDevice)
        var dev = id
        let size = UInt32(MemoryLayout<AudioDeviceID>.size)
        AudioObjectSetPropertyData(AudioObjectID(kAudioObjectSystemObject),
                                   &addr, 0, nil, size, &dev)
    }
}
