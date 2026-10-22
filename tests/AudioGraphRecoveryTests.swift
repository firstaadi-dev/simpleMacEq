
extension AudioController {
    @MainActor
    static func runGraphRecoveryTests() throws {
        let state = AppState()
        let outputs = OutputDeviceManager()
        guard let selected = outputs.devices.first(where: { $0.id == outputs.selectedDeviceID }) else {
            fatalError("Offline graph tests require an enumerated output for route resolution")
        }
        state.prepareGraphRecoveryTest(outputUID: selected.uid)
        let monitor = AudioProcessMonitor()
        let controller = AudioController()
        controller.state = state
        controller.outputs = outputs
        controller.monitor = monitor
        controller.bind()
        guard let device = controller.mainDevice() else {
            fatalError("Offline graph tests require an enumerated output for route resolution")
        }
        let ref = AudioProcessMonitor.AudioProcessRef(
            objectID: 123456, pid: 123456, bundleID: "test.player", name: "Synthetic player", icon: nil)
        var sampleRate: Double = 48000
        var channelCount: AVAudioChannelCount = 2

        // Supply only the hardware boundary: recovery still runs stopAudio, syncTaps,
        // makeTapNode, connectTap and restores settings through the production code.
        func installOfflineEngine() throws {
            let de = DeviceEngine(deviceID: device.id, deviceName: device.name)
            let format = AVAudioFormat(standardFormatWithSampleRate: sampleRate, channels: channelCount)!
            try de.engine.enableManualRenderingMode(.offline, format: format, maximumFrameCount: 1024)
            de.engine.attach(de.eqInputMixer)
            de.engine.attach(de.eq)
            de.engine.connect(de.eqInputMixer, to: de.eq, format: nil)
            de.engine.connect(de.eq, to: de.engine.mainMixerNode, format: nil)
            controller.configureEQUnit(de.eq, with: state.bands)
            de.eq.bypass = !state.eqEnabled
            try de.engine.start()
            controller.engines[device.id] = de
        }

        func assertAudibleOutput() throws {
            let de = controller.engines[device.id]!
            let buffer = AVAudioPCMBuffer(pcmFormat: de.engine.manualRenderingFormat,
                                          frameCapacity: 1024)!
            var peak: Float = 0
            for _ in 0..<4 {
                let result = try de.engine.renderOffline(1024, to: buffer)
                precondition(result == .success, "Recovered graph must render audio")
                for channel in 0..<Int(buffer.format.channelCount) {
                    for frame in 0..<Int(buffer.frameLength) {
                        let value = buffer.floatChannelData![channel][frame]
                        precondition(value.isFinite, "EQ output must remain finite")
                        peak = max(peak, abs(value))
                    }
                }
            }
            precondition(peak > 0.001, "Recovered graph must produce nonzero PCM samples")
            precondition(controller.taps[ref.objectID]?.renderFormat.sampleRate == ProcessTap.sampleRate,
                         "Capture nodes must use the updated tap sample rate")
            let node = controller.taps[ref.objectID]!
            precondition(node.volume == 1.5 && !node.isMuted &&
                         node.eqEnabled == state.appEQEnabled(for: ref.bundleID),
                         "Recovery must preserve volume boost, mute state and per-app EQ mode")
            precondition(node.explicitDeviceUID == device.uid && node.deviceID == device.id,
                         "Recovery must preserve the explicit output route")
            precondition(node.eqBands[2] == 3 && node.appEQ.bands[2].gain == (node.eqEnabled ? 3 : 0),
                         "Recovery must restore the per-app EQ bands")
            precondition(abs(node.appEQ.globalGain - Float(20 * log10(1.5))) < 0.001)
            precondition(de.eq.bands[3].gain == 4 && !de.eq.bypass,
                         "Recovery must restore the global EQ settings")
        }

        try installOfflineEngine()
        monitor.setTestProcesses([ref])
        try assertAudibleOutput()

        // isRunning is published after stopAudio has dropped the old graph and before
        // syncTaps recreates paths, so the test can provide the new offline destination.
        let destination = controller.$isRunning.dropFirst().sink { running in
            if !running && controller.engines.isEmpty { try! installOfflineEngine() }
        }

        for rate in [16000.0, 48000.0, 16000.0, 48000.0] {
            let oldEngine = controller.engines[device.id]!.engine
            let oldTap = controller.taps[ref.objectID]!.tap
            sampleRate = rate
            channelCount = rate == 16000 ? 1 : 2
            ProcessTap.sampleRate = rate
            state.setGraphTestAppEQEnabled(rate == 48000)
            NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: oldEngine)
            RunLoop.main.run(until: Date().addingTimeInterval(0.4))
            precondition(controller.engines[device.id]!.engine !== oldEngine)
            precondition(controller.taps[ref.objectID]!.tap !== oldTap,
                         "Format recovery must recreate capture as well as the output engine")
            try assertAudibleOutput()
        }

        let captureStarts = ProcessTap.starts
        ProcessTap.failStarts = true
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange,
                                        object: controller.engines[device.id]!.engine)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        precondition(controller.taps.isEmpty, "Failed capture must not leave an active muted path")
        precondition(controller.status.hasPrefix("Error:"), "Capture errors must remain visible")
        ProcessTap.failStarts = false
        RunLoop.main.run(until: Date().addingTimeInterval(1.4))
        precondition(ProcessTap.starts == captureStarts + 1,
                     "Capture must retry without the process list changing")
        try assertAudibleOutput()

        destination.cancel()
        controller.teardown()
        precondition(ProcessTap.starts == ProcessTap.stops, "Every synthetic capture must stop")
        print("PASS: real offline graph produces PCM after 48kHz/stereo ↔ 16kHz/mono recovery and failed-start retry; EQ/boost/route restored")
    }
}

@main
struct AudioGraphRegressionTests {
    @MainActor
    static func main() throws {
        try AudioController.runGraphRecoveryTests()
    }
}
