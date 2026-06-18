import Foundation
import AVFoundation
import CoreAudio
import Combine
import AppKit

enum AudioControllerError: LocalizedError {
    case unsupportedOS
    case noOutputDevice
    case noOutputUnit
    case setDevice(OSStatus)
    case invalidFormat

    var errorDescription: String? {
        switch self {
        case .unsupportedOS:    return "Requires macOS 14.4 or later."
        case .noOutputDevice:   return "No output device available."
        case .noOutputUnit:     return "Could not access the engine output unit."
        case .setDevice(let s): return "Could not route engine to device (\(s))."
        case .invalidFormat:    return "Tap delivered an invalid audio format."
        }
    }
}

/// Owns the audio graph and the lifecycle of per-process taps.
///
/// Each audio-producing app is muted at the OS level and re-rendered through its own
/// per-app EQ + gain node, summed into a global 10-band EQ, then routed to that app's
/// chosen output device. Apps can be routed to *different* output devices simultaneously
/// (like SoundSource), so we keep **one AVAudioEngine per output device in use** and the
/// global EQ settings are mirrored onto every engine:
///
///   app tap → sourceNode → appEQ(+boost) → appMixer(vol) ─┐
///                                                           ├▶ eqInputMixer → eq → mainMixer → device A
///   app tap → sourceNode → appEQ(+boost) → appMixer(vol) ─┘
///   app tap → sourceNode → appEQ(+boost) → appMixer(vol) ──▶ eqInputMixer → eq → mainMixer → device B
@MainActor
final class AudioController: ObservableObject {
    @Published private(set) var status: String = "Idle"
    @Published private(set) var isRunning = false
    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var outputLevel: Float = 0
    /// Apps currently being tapped, shown in the per-app mixer.
    @Published private(set) var apps: [AudioProcessInfo] = []

    /// One engine per output device that at least one app is routed to.
    private final class DeviceEngine {
        let deviceID: AudioDeviceID
        let deviceName: String
        let engine = AVAudioEngine()
        let eq = AVAudioUnitEQ(numberOfBands: 10)
        let eqInputMixer = AVAudioMixerNode()
        init(deviceID: AudioDeviceID, deviceName: String) {
            self.deviceID = deviceID; self.deviceName = deviceName
        }
    }
    private var engines: [AudioDeviceID: DeviceEngine] = [:]
    private var engineLevels: [AudioDeviceID: (inLvl: Float, outLvl: Float)] = [:]

    /// One live capture + render path per tapped process, keyed by Core Audio object ID.
    private final class TapNode {
        let info: AudioProcessMonitor.AudioProcessRef
        let tap: ProcessTap
        let source: AVAudioSourceNode
        let renderFormat: AVAudioFormat   // non-interleaved; what the engine graph uses
        let appEQ = AVAudioUnitEQ(numberOfBands: 10)   // per-app EQ + boost (globalGain)
        let mixer = AVAudioMixerNode()
        let scratch: UnsafeMutablePointer<Float>   // deinterleave buffer, freed on deinit
        let scratchCount: Int
        var volume: Double          // 0...2 (above 1.0 = boost)
        var isMuted: Bool
        var eqEnabled: Bool
        var eqBands: [Double]       // 10 gains, dB
        var deviceID: AudioDeviceID         // output device / engine this tap is attached to
        var explicitDeviceUID: String?      // nil = follow the system output device
        init(info: AudioProcessMonitor.AudioProcessRef, tap: ProcessTap,
             source: AVAudioSourceNode, renderFormat: AVAudioFormat,
             scratch: UnsafeMutablePointer<Float>, scratchCount: Int,
             volume: Double, isMuted: Bool, eqEnabled: Bool, eqBands: [Double],
             deviceID: AudioDeviceID, explicitDeviceUID: String?) {
            self.info = info; self.tap = tap; self.source = source
            self.renderFormat = renderFormat
            self.scratch = scratch; self.scratchCount = scratchCount
            self.volume = volume; self.isMuted = isMuted
            self.eqEnabled = eqEnabled; self.eqBands = eqBands
            self.deviceID = deviceID; self.explicitDeviceUID = explicitDeviceUID
        }
        deinit { scratch.deallocate() }
    }
    private var taps: [AudioObjectID: TapNode] = [:]

    private weak var state: AppState?
    private weak var outputs: OutputDeviceManager?
    private weak var monitor: AudioProcessMonitor?
    private var cancellables = Set<AnyCancellable>()
    private var didAttach = false

    func attach(state: AppState, outputs: OutputDeviceManager, monitor: AudioProcessMonitor) {
        guard !didAttach else { return }
        didAttach = true
        self.state = state
        self.outputs = outputs
        self.monitor = monitor

        if #available(macOS 14.4, *) {
            ProcessTap.cleanupStaleAggregates()
        }
        monitor.start()
        bind()   // subscribing to monitor.$processes fires syncTaps() with the current list

        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.teardown() }
        }
    }

    // MARK: - Device resolution

    private func mainDevice() -> AudioOutputDevice? {
        guard let outputs else { return nil }
        return outputs.devices.first(where: { $0.id == outputs.selectedDeviceID })
            ?? outputs.devices.first
    }

    /// Resolve an app's effective output device: its explicit choice if that device exists,
    /// otherwise the system output device.
    private func resolveDevice(explicitUID: String?) -> AudioOutputDevice? {
        if let uid = explicitUID, !uid.isEmpty,
           let device = outputs?.devices.first(where: { $0.uid == uid }) {
            return device
        }
        return mainDevice()
    }

    // MARK: - Engine management

    /// Get (or create + start) the engine routed to a device.
    private func engine(for device: AudioOutputDevice) -> DeviceEngine? {
        if let existing = engines[device.id] { return existing }

        let de = DeviceEngine(deviceID: device.id, deviceName: device.name)
        guard let outputUnit = de.engine.outputNode.audioUnit else {
            status = AudioControllerError.noOutputUnit.localizedDescription; return nil
        }
        var dev = device.id
        let setErr = AudioUnitSetProperty(
            outputUnit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard setErr == noErr else {
            status = AudioControllerError.setDevice(setErr).localizedDescription; return nil
        }

        de.engine.attach(de.eqInputMixer)
        de.engine.attach(de.eq)
        de.engine.connect(de.eqInputMixer, to: de.eq, format: nil)
        de.engine.connect(de.eq, to: de.engine.mainMixerNode, format: nil)
        configureEQUnit(de.eq, with: state?.bands ?? Band.defaultBands())
        de.engine.mainMixerNode.outputVolume = 1.0          // master = hardware device volume
        de.eq.bypass = !(state?.eqEnabled ?? true)

        de.engine.prepare()
        do {
            try de.engine.start()
        } catch {
            status = "Error: \(error.localizedDescription)"
            return nil
        }
        installMeters(on: de)
        engines[device.id] = de
        return de
    }

    /// Stop and drop a device's engine once no tap routes to it anymore.
    private func destroyEngineIfEmpty(_ deviceID: AudioDeviceID) {
        guard let de = engines[deviceID] else { return }
        guard !taps.values.contains(where: { $0.deviceID == deviceID }) else { return }
        if de.engine.isRunning { de.engine.stop() }
        engines[deviceID] = nil
        engineLevels[deviceID] = nil
    }

    // MARK: - Tap lifecycle

    /// Reconcile live taps with the given process list. Adds/removes are applied
    /// *incrementally* so a transient sound (e.g. a notification) never disturbs other apps.
    ///
    /// The list is passed in explicitly: @Published delivers its value to subscribers in
    /// `willSet`, so re-reading `monitor.processes` here would return the *previous* value.
    private func syncTaps(with wanted: [AudioProcessMonitor.AudioProcessRef]) {
        guard #available(macOS 14.4, *) else {
            status = AudioControllerError.unsupportedOS.localizedDescription; return
        }
        guard let main = mainDevice() else {
            status = AudioControllerError.noOutputDevice.localizedDescription; return
        }
        if outputs?.selectedDeviceID != main.id { outputs?.selectedDeviceID = main.id }

        let wantedIDs = Set(wanted.map(\.objectID))

        // Remove taps whose process stopped producing audio.
        for (id, node) in taps where !wantedIDs.contains(id) {
            detachTap(node)
            node.tap.stop()
            let dev = node.deviceID
            taps[id] = nil
            destroyEngineIfEmpty(dev)
        }

        // Add taps for newly-playing apps, each on its resolved output device.
        for ref in wanted where taps[ref.objectID] == nil {
            let explicit = state?.appOutputDeviceUID(for: ref.bundleID)
            guard let device = resolveDevice(explicitUID: explicit),
                  let node = makeTapNode(ref, device: device, explicitUID: explicit),
                  let de = engine(for: device) else { continue }
            taps[ref.objectID] = node
            connectTap(node, into: de)
        }

        updateRunningState()
        publishApps()
    }

    /// Create a tap (capture path) and its render nodes for one process on `device`.
    @available(macOS 14.4, *)
    private func makeTapNode(_ ref: AudioProcessMonitor.AudioProcessRef,
                             device: AudioOutputDevice,
                             explicitUID: String?) -> TapNode? {
        let tap = ProcessTap()
        do {
            try tap.start(processes: [ref.objectID],
                          clockDeviceUID: device.uid,
                          uidSuffix: "\(ref.objectID)")
        } catch {
            status = "Error: \(error.localizedDescription)"
            return nil
        }
        guard let fmt = tap.format, let ring = tap.ringBuffer else { return nil }
        let channels = Int(fmt.channelCount)

        // The capture ring buffer is interleaved, but AVAudioEngine node connections
        // require a non-interleaved (standard) format. Render into a standard format,
        // deinterleaving from the ring in the pull callback.
        guard let renderFormat = AVAudioFormat(standardFormatWithSampleRate: fmt.sampleRate,
                                               channels: fmt.channelCount) else { return nil }

        // Pre-allocated scratch so the realtime render block never allocates.
        let maxFrames = 16384
        let scratch = UnsafeMutablePointer<Float>.allocate(capacity: maxFrames * channels)
        scratch.initialize(repeating: 0, count: maxFrames * channels)

        let source = AVAudioSourceNode(format: renderFormat) { _, _, frameCount, ablPtr in
            let frames = Int(frameCount)
            let n = min(frames, maxFrames)
            ring.read(into: scratch, count: n * channels)
            let abl = UnsafeMutableAudioBufferListPointer(ablPtr)
            for (c, buffer) in abl.enumerated() where c < channels {
                guard let out = buffer.mData?.assumingMemoryBound(to: Float.self) else { continue }
                for f in 0..<n { out[f] = scratch[f * channels + c] }
                if n < frames { for f in n..<frames { out[f] = 0 } }
            }
            return noErr
        }
        let savedVol = min(state?.appVolume(for: ref.bundleID) ?? 1.0, maxVolume)
        let savedMute = state?.appMuted(for: ref.bundleID) ?? false
        let savedEQOn = state?.appEQEnabled(for: ref.bundleID) ?? false
        let savedEQ = state?.appEQBands(for: ref.bundleID) ?? Array(repeating: 0, count: 10)
        return TapNode(info: ref, tap: tap, source: source,
                       renderFormat: renderFormat,
                       scratch: scratch, scratchCount: maxFrames * channels,
                       volume: savedVol, isMuted: savedMute,
                       eqEnabled: savedEQOn, eqBands: savedEQ,
                       deviceID: device.id, explicitDeviceUID: explicitUID)
    }

    /// Attach one tap's nodes into a device engine and wire them up.
    private func connectTap(_ node: TapNode, into de: DeviceEngine) {
        node.deviceID = de.deviceID
        de.engine.attach(node.source)
        de.engine.attach(node.appEQ)
        de.engine.attach(node.mixer)
        de.engine.connect(node.source, to: node.appEQ, format: node.renderFormat)
        de.engine.connect(node.appEQ, to: node.mixer, format: node.renderFormat)
        // Per-app EQ on → route straight to master (bypass the global EQ for this app);
        // otherwise feed it through the global EQ.
        let destination: AVAudioNode = node.eqEnabled ? de.engine.mainMixerNode : de.eqInputMixer
        de.engine.connect(node.mixer, to: destination, format: node.renderFormat)
        configureAppEQ(node)
        applyAppGain(node)
    }

    /// Detach one tap's nodes from its current device engine without disturbing others.
    private func detachTap(_ node: TapNode) {
        guard let de = engines[node.deviceID] else { return }
        de.engine.disconnectNodeOutput(node.mixer)
        de.engine.disconnectNodeOutput(node.appEQ)
        de.engine.disconnectNodeOutput(node.source)
        de.engine.detach(node.source)
        de.engine.detach(node.appEQ)
        de.engine.detach(node.mixer)
    }

    private func updateRunningState() {
        if taps.isEmpty {
            isRunning = false
            inputLevel = 0; outputLevel = 0
            status = "Idle — no apps playing"
            return
        }
        isRunning = engines.values.contains { $0.engine.isRunning }
        let deviceCount = Set(taps.values.map(\.deviceID)).count
        let appWord = taps.count == 1 ? "app" : "apps"
        status = deviceCount <= 1
            ? "Running — \(taps.count) \(appWord) • \(mainDevice()?.name ?? "")"
            : "Running — \(taps.count) \(appWord) • \(deviceCount) outputs"
    }

    private func publishApps() {
        apps = taps.values
            .map { node in
                AudioProcessInfo(objectID: node.info.objectID, pid: node.info.pid,
                                 bundleID: node.info.bundleID, name: node.info.name,
                                 icon: node.info.icon,
                                 volume: node.volume, isMuted: node.isMuted,
                                 eqEnabled: node.eqEnabled, eqBands: node.eqBands,
                                 outputDeviceID: node.deviceID,
                                 explicitOutputUID: node.explicitDeviceUID)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Metering

    private func installMeters(on de: DeviceEngine) {
        let id = de.deviceID
        de.eqInputMixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in
            let rms = Self.rms(buf)
            Task { @MainActor in self?.updateLevel(deviceID: id, input: rms) }
        }
        de.engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in
            let rms = Self.rms(buf)
            Task { @MainActor in self?.updateLevel(deviceID: id, output: rms) }
        }
    }

    private func updateLevel(deviceID: AudioDeviceID, input: Float? = nil, output: Float? = nil) {
        var entry = engineLevels[deviceID] ?? (0, 0)
        if let input { entry.inLvl = input }
        if let output { entry.outLvl = output }
        engineLevels[deviceID] = entry
        inputLevel = engineLevels.values.map(\.inLvl).max() ?? 0
        outputLevel = engineLevels.values.map(\.outLvl).max() ?? 0
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        let data = ch[0]
        for i in 0..<n { let s = data[i]; sum += s * s }
        return (sum / Float(n)).squareRoot()
    }

    // MARK: - Global EQ

    private func configureEQUnit(_ eq: AVAudioUnitEQ, with bands: [Band]) {
        eq.globalGain = 0
        for (i, band) in bands.enumerated() where i < eq.bands.count {
            let p = eq.bands[i]
            p.filterType = .parametric
            p.frequency = Float(band.frequency)
            p.bandwidth = 1.0
            p.gain = Float(band.gain)
            p.bypass = false
        }
    }

    private func applyBands(_ bands: [Band]) {
        for de in engines.values {
            for (i, band) in bands.enumerated() where i < de.eq.bands.count {
                de.eq.bands[i].gain = Float(band.gain)
            }
        }
    }

    private func applyGlobalBypass(_ enabled: Bool) {
        for de in engines.values { de.eq.bypass = !enabled }
    }

    // MARK: - Per-app EQ + gain helpers

    /// Configure a tap's per-app EQ. Never bypassed (so the boost in `globalGain` always
    /// applies); when the per-app EQ is off the bands go flat.
    private func configureAppEQ(_ node: TapNode) {
        node.appEQ.bypass = false
        let gains = node.eqEnabled ? node.eqBands : Array(repeating: 0.0, count: 10)
        for i in 0..<node.appEQ.bands.count where i < gains.count {
            let p = node.appEQ.bands[i]
            p.filterType = .parametric
            p.frequency = Float(Band.isoCenters[i])
            p.bandwidth = 1.0
            p.gain = Float(gains[i])
            p.bypass = false
        }
    }

    /// Max per-app volume: 200% when Volume Boost is on, otherwise 100%.
    private var maxVolume: Double { state?.volumeBoostEnabled == true ? 2.0 : 1.0 }

    /// Apply per-app volume + boost: 0...1 rides the mixer; 1...2 adds dB to the EQ's
    /// global gain (AVAudioMixerNode.outputVolume is clamped to 1.0).
    private func applyAppGain(_ node: TapNode) {
        let v = node.isMuted ? 0 : node.volume
        node.mixer.outputVolume = Float(min(v, 1.0))
        node.appEQ.globalGain = v > 1.0 ? Float(20 * log10(v)) : 0
    }

    private func applyBoostSetting() {
        let cap = maxVolume
        for node in taps.values where node.volume > cap {
            node.volume = cap
            applyAppGain(node)
            state?.setAppVolume(node.volume, for: node.info.bundleID)
        }
        publishApps()
    }

    // MARK: - Per-app control (called from the mixer UI)

    func setVolume(_ volume: Double, forObjectID id: AudioObjectID) {
        guard let node = taps[id] else { return }
        node.volume = min(max(volume, 0), maxVolume)
        applyAppGain(node)
        state?.setAppVolume(node.volume, for: node.info.bundleID)
        publishApps()
    }

    func setMuted(_ muted: Bool, forObjectID id: AudioObjectID) {
        guard let node = taps[id] else { return }
        node.isMuted = muted
        applyAppGain(node)
        state?.setAppMuted(muted, for: node.info.bundleID)
        publishApps()
    }

    func setAppEQEnabled(_ enabled: Bool, forObjectID id: AudioObjectID) {
        guard let node = taps[id] else { return }
        node.eqEnabled = enabled
        state?.setAppEQEnabled(enabled, for: node.info.bundleID)
        // Re-point only this app's mixer to its new destination within its own engine.
        if let de = engines[node.deviceID] {
            de.engine.disconnectNodeOutput(node.mixer)
            let destination: AVAudioNode = node.eqEnabled ? de.engine.mainMixerNode : de.eqInputMixer
            de.engine.connect(node.mixer, to: destination, format: node.renderFormat)
            configureAppEQ(node)
        }
        publishApps()
    }

    func setAppEQBand(_ gain: Double, bandIndex: Int, forObjectID id: AudioObjectID) {
        guard let node = taps[id], node.eqBands.indices.contains(bandIndex) else { return }
        node.eqBands[bandIndex] = gain
        if node.eqEnabled, node.appEQ.bands.indices.contains(bandIndex) {
            node.appEQ.bands[bandIndex].gain = Float(gain)
        }
        state?.setAppEQBands(node.eqBands, for: node.info.bundleID)
        publishApps()
    }

    func resetAppEQ(forObjectID id: AudioObjectID) {
        guard let node = taps[id] else { return }
        node.eqBands = Array(repeating: 0, count: 10)
        configureAppEQ(node)
        state?.setAppEQBands(node.eqBands, for: node.info.bundleID)
        publishApps()
    }

    func applyAppEQPreset(_ gains: [Double], forObjectID id: AudioObjectID) {
        guard let node = taps[id], gains.count == 10 else { return }
        node.eqBands = gains
        state?.setAppEQBands(gains, for: node.info.bundleID)
        if node.eqEnabled {
            configureAppEQ(node)
            publishApps()
        } else {
            setAppEQEnabled(true, forObjectID: id)
        }
    }

    /// Route an app to a specific output device (`uid`), or nil to follow the system output.
    /// Rehomes the tap to the matching engine; its capture clock is recreated for the new
    /// device to avoid drift.
    func setAppOutputDevice(_ uid: String?, forObjectID id: AudioObjectID) {
        guard #available(macOS 14.4, *), let node = taps[id] else { return }
        state?.setAppOutputDeviceUID(uid, for: node.info.bundleID)
        node.explicitDeviceUID = uid

        guard let device = resolveDevice(explicitUID: uid) else { publishApps(); return }
        if device.id == node.deviceID { publishApps(); return }   // already there

        let oldDeviceID = node.deviceID
        detachTap(node)
        node.tap.stop()

        // Recreate the capture+render path clocked to the new device, then attach.
        guard let newNode = makeTapNode(node.info, device: device, explicitUID: uid),
              let de = engine(for: device) else {
            taps[id] = nil
            destroyEngineIfEmpty(oldDeviceID)
            updateRunningState(); publishApps()
            return
        }
        taps[id] = newNode          // replaces & deallocates the old node (frees its scratch)
        connectTap(newNode, into: de)
        destroyEngineIfEmpty(oldDeviceID)
        updateRunningState()
        publishApps()
    }

    // MARK: - Lifecycle

    func teardown() {
        for de in engines.values where de.engine.isRunning { de.engine.stop() }
        engines.removeAll()
        engineLevels.removeAll()
        for node in taps.values { node.tap.stop() }
        taps.removeAll()
        isRunning = false
        if status.hasPrefix("Running") { status = "Stopped" }
    }

    /// Tear down every engine and tap, then re-sync from scratch. Used when the system
    /// output device or the device list changes (apps following the system output move;
    /// explicitly-routed apps re-resolve, falling back to the system output if their
    /// device disappeared).
    // ponytail: rebuildEverything reuses teardown() instead of duplicating it
    private func rebuildEverything() {
        teardown()
        syncTaps(with: monitor?.processes ?? [])
    }

    // MARK: - Bindings

    private func bind() {
        guard let state, let outputs, let monitor else { return }

        state.$bands
            .sink { [weak self] bands in self?.applyBands(bands) }
            .store(in: &cancellables)

        state.$eqEnabled
            .sink { [weak self] on in self?.applyGlobalBypass(on) }
            .store(in: &cancellables)

        state.$volumeBoostEnabled
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in self?.applyBoostSetting() }
            .store(in: &cancellables)

        // Process list changes → add/remove taps incrementally. Use the value Combine
        // delivers (the new list); reading monitor.processes here would see the old one.
        monitor.$processes
            .removeDuplicates()
            .sink { [weak self] procs in self?.syncTaps(with: procs) }
            .store(in: &cancellables)

        // System output device changed → re-resolve routes and rebuild.
        outputs.$selectedDeviceID
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in self?.rebuildEverything() }
            .store(in: &cancellables)

        // Device list changed (hot-plug/unplug) → re-resolve routes (a removed device an
        // app was pinned to falls back to the system output).
        outputs.$devices
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in self?.rebuildEverything() }
            .store(in: &cancellables)
    }
}
