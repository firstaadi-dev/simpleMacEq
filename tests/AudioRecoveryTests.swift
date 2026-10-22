
// Appended to AudioController.swift by run.sh to exercise the real private bindings.
extension AudioController {
    @MainActor
    static func runRecoveryTests() {
        let state = AppState()
        let outputs = OutputDeviceManager()
        let selected = outputs.selectedDeviceID
        if let expected = OutputDeviceManager.deviceVolume(selected) {
            outputs.selectedDeviceID = 0
            outputs.outputVolume = -1
            outputs.selectedDeviceID = selected
            precondition(abs(outputs.outputVolume - Double(expected)) < 0.001,
                         "The volume slider must read the newly selected device, not the previous ID")
            print("PASS: selected output volume uses the new device ID")
        } else {
            print("SKIP: selected output exposes no readable hardware volume")
        }
        let monitor = AudioProcessMonitor()
        let controller = AudioController()
        controller.state = state
        controller.outputs = outputs
        controller.monitor = monitor
        controller.bind()

        let deviceID: AudioDeviceID = 987654
        let original = DeviceEngine(deviceID: deviceID, deviceName: "Test output")
        controller.engines[deviceID] = original

        let unrelated = AVAudioEngine()
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: unrelated)
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        precondition(controller.engines[deviceID] === original,
                     "Unrelated engine notifications must not rebuild our graph")

        var runningUpdates = 0
        let observation = controller.$isRunning.dropFirst().sink { _ in runningUpdates += 1 }
        DispatchQueue.global().async {
            for _ in 0..<3 {
                NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: original.engine)
            }
        }
        precondition(controller.engines[deviceID] === original,
                     "Never tear down the engine inside its configuration notification")
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        precondition(controller.engines.isEmpty,
                     "A format change on the same device must rebuild the stopped graph")
        precondition(runningUpdates == 2, "A burst must stop and sync the graph only once")
        observation.cancel()

        let replacement = DeviceEngine(deviceID: deviceID, deviceName: "Replacement output")
        controller.engines[deviceID] = replacement
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: original.engine)
        RunLoop.main.run(until: Date().addingTimeInterval(0.1))
        precondition(controller.engines[deviceID] === replacement,
                     "An old engine must not schedule another rebuild")

        controller.engines[deviceID] = original
        outputs.selectedDeviceID = deviceID
        precondition(controller.engines[deviceID] === original,
                     "Output rebuilds must wait until @Published has committed the new device")
        RunLoop.main.run(until: Date().addingTimeInterval(0.4))
        precondition(controller.engines.isEmpty, "Output changes must rebuild after publication")

        controller.engines[deviceID] = original
        RunLoop.main.run(until: Date().addingTimeInterval(1.4))
        precondition(controller.engines.isEmpty,
                     "A stopped engine must recover even if the process list never changes")

        controller.outputs = nil
        monitor.setTestProcesses([
            .init(objectID: 123456, pid: 123456, bundleID: "test.player", name: "Test", icon: nil)
        ])
        controller.status = "Waiting for retry"
        RunLoop.main.run(until: Date().addingTimeInterval(1.4))
        precondition(controller.status == AudioControllerError.noOutputDevice.localizedDescription,
                     "Missing taps must retry with an unchanged process list, even without an engine")
        monitor.setTestProcesses([])

        controller.teardown()
        controller.engines[deviceID] = original
        NotificationCenter.default.post(name: .AVAudioEngineConfigurationChange, object: original.engine)
        RunLoop.main.run(until: Date().addingTimeInterval(1.4))
        precondition(controller.engines[deviceID] === original, "Teardown must cancel recovery work")
        controller.teardown()
        print("PASS: audio configuration recovery, coalescing, deferred output changes, watchdog, retry, teardown")
    }
}

@main
struct AudioRegressionTests {
    @MainActor
    static func main() {
        AudioController.runRecoveryTests()
        runRingBufferTests()
    }
}
