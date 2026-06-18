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
/// gain node, summed into a global 10-band EQ, then the master mixer, then routed to the
/// selected output device:
///
///   app tap → ring buffer → sourceNode → appMixer(gain) ─┐
///                                                          ├─▶ eqInputMixer → eq → mainMixer → output
///   app tap → ring buffer → sourceNode → appMixer(gain) ─┘
///
/// The graph is rebuilt whenever the set of tapped apps or the output device changes.
@MainActor
final class AudioController: ObservableObject {
    @Published private(set) var status: String = "Idle"
    @Published private(set) var isRunning = false
    @Published private(set) var inputLevel: Float = 0
    @Published private(set) var outputLevel: Float = 0
    /// Apps currently being tapped, shown in the per-app mixer.
    @Published private(set) var apps: [AudioProcessInfo] = []

    private var engine = AVAudioEngine()
    private var eq = AVAudioUnitEQ(numberOfBands: 10)
    private var eqInputMixer = AVAudioMixerNode()

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
        init(info: AudioProcessMonitor.AudioProcessRef, tap: ProcessTap,
             source: AVAudioSourceNode, renderFormat: AVAudioFormat,
             scratch: UnsafeMutablePointer<Float>, scratchCount: Int,
             volume: Double, isMuted: Bool, eqEnabled: Bool, eqBands: [Double]) {
            self.info = info; self.tap = tap; self.source = source
            self.renderFormat = renderFormat
            self.scratch = scratch; self.scratchCount = scratchCount
            self.volume = volume; self.isMuted = isMuted
            self.eqEnabled = eqEnabled; self.eqBands = eqBands
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

    // MARK: - Tap lifecycle

    /// Reconcile live taps with the given process list. Adds/removes are applied
    /// *incrementally* on the running engine so a transient sound (e.g. a notification
    /// starting/stopping a process) never stops the whole graph and glitches other apps.
    ///
    /// The list is passed in explicitly: @Published delivers its value to subscribers in
    /// `willSet`, so re-reading `monitor.processes` here would return the *previous* value.
    private func syncTaps(with wanted: [AudioProcessMonitor.AudioProcessRef]) {
        guard #available(macOS 14.4, *) else {
            status = AudioControllerError.unsupportedOS.localizedDescription; return
        }
        guard let outputs else { return }
        guard let device = outputs.devices.first(where: { $0.id == outputs.selectedDeviceID })
            ?? outputs.devices.first else {
            status = AudioControllerError.noOutputDevice.localizedDescription; return
        }
        if outputs.selectedDeviceID != device.id { outputs.selectedDeviceID = device.id }

        let wantedIDs = Set(wanted.map(\.objectID))

        // Remove taps whose process stopped producing audio — detach just those nodes
        // from the live engine instead of stopping it.
        for (id, node) in taps where !wantedIDs.contains(id) {
            if engine.isRunning { detachTap(node) }
            node.tap.stop()
            taps[id] = nil
        }

        // Create taps for newly-playing apps.
        var added: [TapNode] = []
        for ref in wanted where taps[ref.objectID] == nil {
            if let node = makeTapNode(ref, clockDeviceUID: device.uid) {
                taps[ref.objectID] = node
                added.append(node)
            }
        }

        if taps.isEmpty {
            // Nothing tapped: untapped apps play natively. No engine needed.
            if engine.isRunning { engine.stop() }
            isRunning = false
            inputLevel = 0; outputLevel = 0
            status = "Idle — no apps playing"
            publishApps()
            return
        }

        if engine.isRunning {
            // Attach only the new taps to the live graph — no global stop/start.
            for node in added { connectTap(node) }
            status = "Running — \(taps.count) app\(taps.count == 1 ? "" : "s") • \(device.name)"
        } else {
            // Cold start (first tap, or after a device change): full build + start.
            buildAndStartEngine(outputDeviceID: device.id, deviceName: device.name)
        }
        publishApps()
    }

    /// Create a tap (capture path) and its render nodes for one process. Does not touch
    /// the engine graph.
    @available(macOS 14.4, *)
    private func makeTapNode(_ ref: AudioProcessMonitor.AudioProcessRef,
                             clockDeviceUID: String) -> TapNode? {
        let tap = ProcessTap()
        do {
            try tap.start(processes: [ref.objectID],
                          clockDeviceUID: clockDeviceUID,
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
            // Deinterleave scratch → planar channel buffers.
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
                       eqEnabled: savedEQOn, eqBands: savedEQ)
    }

    /// Attach one tap's nodes to the current engine and wire them up. Works on a running
    /// engine (incremental add) or while building cold.
    private func connectTap(_ node: TapNode) {
        engine.attach(node.source)
        engine.attach(node.appEQ)
        engine.attach(node.mixer)
        engine.connect(node.source, to: node.appEQ, format: node.renderFormat)
        engine.connect(node.appEQ, to: node.mixer, format: node.renderFormat)
        // When the per-app EQ is on, route straight to master so the global EQ is
        // bypassed for this app; otherwise feed it through the global EQ.
        let destination: AVAudioNode = node.eqEnabled ? engine.mainMixerNode : eqInputMixer
        engine.connect(node.mixer, to: destination, format: node.renderFormat)
        configureAppEQ(node)
        applyAppGain(node)
    }

    /// Detach one tap's nodes from the running engine without disturbing the others.
    private func detachTap(_ node: TapNode) {
        engine.disconnectNodeOutput(node.mixer)
        engine.disconnectNodeOutput(node.appEQ)
        engine.disconnectNodeOutput(node.source)
        engine.detach(node.source)
        engine.detach(node.appEQ)
        engine.detach(node.mixer)
    }

    private func publishApps() {
        apps = taps.values
            .map { node in
                AudioProcessInfo(objectID: node.info.objectID, pid: node.info.pid,
                                 bundleID: node.info.bundleID, name: node.info.name,
                                 symbol: "speaker.wave.2.fill", icon: node.info.icon,
                                 volume: node.volume, isMuted: node.isMuted,
                                 eqEnabled: node.eqEnabled, eqBands: node.eqBands)
            }
            .sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Engine graph

    /// Build a fresh engine on the given device and connect every current tap, then start.
    /// Used for a cold start (first tap) and after a device change — a fresh engine is
    /// required because the output unit only accepts a new CurrentDevice while uninitialized.
    private func buildAndStartEngine(outputDeviceID: AudioDeviceID, deviceName: String) {
        if engine.isRunning { engine.stop() }

        guard !taps.isEmpty else {
            isRunning = false
            inputLevel = 0; outputLevel = 0
            status = "Idle — no apps playing"
            return
        }

        // Fresh engine + nodes so the output unit is uninitialized and accepts the device.
        engine = AVAudioEngine()
        eq = AVAudioUnitEQ(numberOfBands: 10)
        eqInputMixer = AVAudioMixerNode()
        configureEQUnit(with: state?.bands ?? Band.defaultBands())

        guard let outputUnit = engine.outputNode.audioUnit else {
            status = AudioControllerError.noOutputUnit.localizedDescription; return
        }
        var dev = outputDeviceID
        let setErr = AudioUnitSetProperty(
            outputUnit, kAudioOutputUnitProperty_CurrentDevice,
            kAudioUnitScope_Global, 0, &dev, UInt32(MemoryLayout<AudioDeviceID>.size))
        guard setErr == noErr else {
            status = AudioControllerError.setDevice(setErr).localizedDescription; return
        }

        engine.attach(eqInputMixer)
        engine.attach(eq)
        engine.connect(eqInputMixer, to: eq, format: nil)
        engine.connect(eq, to: engine.mainMixerNode, format: nil)

        for node in taps.values { connectTap(node) }

        // Master volume is the hardware device volume (OutputDeviceManager), so the
        // engine's own master stays at unity.
        engine.mainMixerNode.outputVolume = 1.0
        eq.bypass = !(state?.eqEnabled ?? true)

        engine.prepare()
        do {
            try engine.start()
            isRunning = true
            status = "Running — \(taps.count) app\(taps.count == 1 ? "" : "s") • \(deviceName)"
            installMeters()
        } catch {
            isRunning = false
            status = "Error: \(error.localizedDescription)"
        }
    }

    private func installMeters() {
        eqInputMixer.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in
            let rms = Self.rms(buf)
            Task { @MainActor in self?.inputLevel = rms }
        }
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) { [weak self] buf, _ in
            let rms = Self.rms(buf)
            Task { @MainActor in self?.outputLevel = rms }
        }
    }

    private static func rms(_ buffer: AVAudioPCMBuffer) -> Float {
        guard let ch = buffer.floatChannelData, buffer.frameLength > 0 else { return 0 }
        let n = Int(buffer.frameLength)
        var sum: Float = 0
        let data = ch[0]
        for i in 0..<n { let s = data[i]; sum += s * s }
        return (sum / Float(n)).squareRoot()
    }

    private func configureEQUnit(with bands: [Band]) {
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
        for (i, band) in bands.enumerated() where i < eq.bands.count {
            eq.bands[i].gain = Float(band.gain)
        }
    }

    /// Configure a tap's per-app EQ. The node is never bypassed (so the boost in
    /// `globalGain` always applies); when the per-app EQ is off the bands go flat.
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

    /// Boost setting changed: clamp any app above the new max back down and persist.
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
        // Re-point only this app's mixer to its new destination (global EQ in/out of its
        // path); other apps are untouched, so no global rebuild and no glitch on them.
        if engine.isRunning {
            engine.disconnectNodeOutput(node.mixer)
            let destination: AVAudioNode = node.eqEnabled ? engine.mainMixerNode : eqInputMixer
            engine.connect(node.mixer, to: destination, format: node.renderFormat)
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

    /// Apply a preset's gains to one app's EQ, enabling the per-app EQ if needed.
    func applyAppEQPreset(_ gains: [Double], forObjectID id: AudioObjectID) {
        guard let node = taps[id], gains.count == 10 else { return }
        node.eqBands = gains
        state?.setAppEQBands(gains, for: node.info.bundleID)
        if node.eqEnabled {
            configureAppEQ(node)
            publishApps()
        } else {
            // Enabling reconfigures the EQ (using the gains just set) and rebuilds routing.
            setAppEQEnabled(true, forObjectID: id)
        }
    }

    // MARK: - Lifecycle

    func teardown() {
        if engine.isRunning { engine.stop() }
        for node in taps.values { node.tap.stop() }
        taps.removeAll()
        isRunning = false
        if status.hasPrefix("Running") { status = "Stopped" }
    }

    // MARK: - Bindings

    private func bind() {
        guard let state, let outputs, let monitor else { return }

        state.$bands
            .sink { [weak self] bands in self?.applyBands(bands) }
            .store(in: &cancellables)

        state.$eqEnabled
            .sink { [weak self] on in self?.eq.bypass = !on }
            .store(in: &cancellables)

        state.$volumeBoostEnabled
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in self?.applyBoostSetting() }
            .store(in: &cancellables)

        // Process list changes → add/remove taps and rebuild. Use the value Combine
        // delivers (the new list); reading monitor.processes here would see the old one.
        monitor.$processes
            .removeDuplicates()
            .sink { [weak self] procs in self?.syncTaps(with: procs) }
            .store(in: &cancellables)

        // Output device change → rebuild taps (clock device) and graph.
        outputs.$selectedDeviceID
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] _ in self?.restartAllTaps() }
            .store(in: &cancellables)
    }

    /// Output device changed: tear down all taps (their aggregate clocks point at the old
    /// device) and re-create them against the new one.
    private func restartAllTaps() {
        // Full teardown: the new device needs a fresh engine (output unit must be
        // uninitialized to accept the device), and every tap's aggregate clock points at
        // the old device. Stopping the engine first makes clearing the taps safe.
        if engine.isRunning { engine.stop() }
        for node in taps.values { node.tap.stop() }
        taps.removeAll()
        // Not inside a @Published willSet here, so monitor.processes is current.
        syncTaps(with: monitor?.processes ?? [])
    }
}
