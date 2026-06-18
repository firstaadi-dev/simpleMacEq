import SwiftUI

struct MasterVolumeView: View {
    @EnvironmentObject var outputs: OutputDeviceManager

    /// Two-way binding to the device's hardware volume (moves the macOS volume too).
    private var volume: Binding<Double> {
        Binding(
            get: { outputs.outputVolume },
            set: { outputs.setOutputVolume($0) }
        )
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Master")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Text("\(Int(outputs.outputVolume * 100))%")
                    .font(.system(size: 12, weight: .medium))
                    .monospacedDigit()
                    .foregroundStyle(Theme.textSecondary)
            }
            HStack(spacing: 10) {
                Image(systemName: "speaker.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                Slider(value: volume, in: 0...1)
                    .tint(Theme.accent)
                    .disabled(!outputs.outputVolumeAvailable)
                Image(systemName: "speaker.wave.3.fill")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }
            if !outputs.outputVolumeAvailable {
                Text("This output device has a fixed volume.")
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}
