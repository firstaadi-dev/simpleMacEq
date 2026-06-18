import SwiftUI

@main
struct MacEqualizerApp: App {
    @StateObject private var state = AppState()
    @StateObject private var outputs = OutputDeviceManager()
    @StateObject private var monitor = AudioProcessMonitor()
    @StateObject private var audio = AudioController()

    var body: some Scene {
        MenuBarExtra {
            PanelView()
                .environmentObject(state)
                .environmentObject(outputs)
                .environmentObject(monitor)
                .environmentObject(audio)
                .task { audio.attach(state: state, outputs: outputs, monitor: monitor) }
        } label: {
            Image(systemName: "slider.vertical.3")
        }
        .menuBarExtraStyle(.window)
    }
}
