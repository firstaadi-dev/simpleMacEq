import SwiftUI
import CoreAudio

struct OutputSelectorView: View {
    @EnvironmentObject var outputs: OutputDeviceManager

    private var selection: Binding<AudioDeviceID> {
        Binding(
            get: { outputs.selectedDeviceID },
            set: { newID in
                if let device = outputs.devices.first(where: { $0.id == newID }) {
                    outputs.select(device)
                }
            }
        )
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "hifispeaker.fill")
                .font(.system(size: 12))
                .foregroundStyle(Theme.textSecondary)
            Picker("", selection: selection) {
                ForEach(outputs.devices) { device in
                    Text(device.name).tag(device.id)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            .tint(Theme.textPrimary)
            Spacer()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 8))
    }
}
