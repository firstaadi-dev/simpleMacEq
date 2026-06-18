import SwiftUI

struct AppMixerView: View {
    @EnvironmentObject var audio: AudioController
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Apps")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Toggle(isOn: $state.volumeBoostEnabled) {
                    Text("Boost")
                        .font(.system(size: 11))
                        .foregroundStyle(state.volumeBoostEnabled ? .orange : Theme.textSecondary)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(.orange)
            }

            if audio.apps.isEmpty {
                Text("No apps playing audio")
                    .font(.system(size: 12))
                    .foregroundStyle(Theme.textSecondary)
                    .frame(maxWidth: .infinity, alignment: .center)
                    .padding(.vertical, 10)
            } else {
                ForEach(audio.apps) { app in
                    AppMixerRowView(app: app)
                }
            }
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }
}

struct AppMixerRowView: View {
    let app: AudioProcessInfo
    @EnvironmentObject var audio: AudioController
    @EnvironmentObject var state: AppState
    @State private var expanded = false

    private var volume: Binding<Double> {
        Binding(
            get: { app.volume },
            set: { audio.setVolume($0, forObjectID: app.objectID) }
        )
    }

    var body: some View {
        VStack(spacing: 8) {
            HStack(spacing: 10) {
                icon

                VStack(alignment: .leading, spacing: 3) {
                    Text(app.name)
                        .font(.system(size: 12, weight: .medium))
                        .lineLimit(1)
                    // Max 100% by default; up to 200% when Volume Boost is on.
                    Slider(value: volume, in: 0...(state.volumeBoostEnabled ? 2 : 1))
                        .tint(app.volume > 1.0 ? .orange : Theme.accent)
                        .controlSize(.mini)
                        .disabled(app.isMuted)
                }

                muteButton

                Button {
                    withAnimation(.easeInOut(duration: 0.18)) { expanded.toggle() }
                } label: {
                    Image(systemName: "slider.vertical.3")
                        .font(.system(size: 11))
                        .foregroundStyle(expanded || app.eqEnabled ? Theme.accent : Theme.textSecondary)
                }
                .buttonStyle(.plain)
                .frame(width: 18)

                Text("\(Int(app.volume * 100))")
                    .font(.system(size: 10))
                    .monospacedDigit()
                    .foregroundStyle(app.volume > 1.0 ? .orange : Theme.textSecondary)
                    .frame(width: 30, alignment: .trailing)
            }

            if expanded {
                VStack(spacing: 8) {
                    OutputRoutePicker(app: app)
                    PerAppEQView(app: app)
                }
                .transition(.opacity.combined(with: .move(edge: .top)))
            }
        }
    }

    private var muteButton: some View {
        Button {
            audio.setMuted(!app.isMuted, forObjectID: app.objectID)
        } label: {
            Image(systemName: app.isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill")
                .font(.system(size: 11))
                .foregroundStyle(app.isMuted ? Theme.accent : Theme.textSecondary)
        }
        .buttonStyle(.plain)
        .frame(width: 18)
    }

    @ViewBuilder
    private var icon: some View {
        if let nsImage = app.icon {
            Image(nsImage: nsImage)
                .resizable()
                .interpolation(.high)
                .frame(width: 26, height: 26)
                .clipShape(RoundedRectangle(cornerRadius: 6))
        } else {
            Image(systemName: app.symbol)
                .font(.system(size: 14))
                .foregroundStyle(Theme.accent)
                .frame(width: 26, height: 26)
                .background(Theme.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 6))
        }
    }
}

/// Per-app output device routing — send one app's audio to a different device.
private struct OutputRoutePicker: View {
    let app: AudioProcessInfo
    @EnvironmentObject var audio: AudioController
    @EnvironmentObject var outputs: OutputDeviceManager

    private var currentLabel: String {
        if let uid = app.explicitOutputUID,
           let device = outputs.devices.first(where: { $0.uid == uid }) {
            return device.name
        }
        return "System Default"
    }

    var body: some View {
        HStack(spacing: 8) {
            Image(systemName: "hifispeaker")
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
            Text("Output")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
            Spacer()
            Menu {
                Button {
                    audio.setAppOutputDevice(nil, forObjectID: app.objectID)
                } label: {
                    if app.explicitOutputUID == nil { Label("System Default", systemImage: "checkmark") }
                    else { Text("System Default") }
                }
                Divider()
                ForEach(outputs.devices) { device in
                    Button {
                        audio.setAppOutputDevice(device.uid, forObjectID: app.objectID)
                    } label: {
                        if app.explicitOutputUID == device.uid { Label(device.name, systemImage: "checkmark") }
                        else { Text(device.name) }
                    }
                }
            } label: {
                HStack(spacing: 3) {
                    Text(currentLabel)
                        .font(.system(size: 11, weight: .medium))
                        .lineLimit(1)
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8))
                }
                .foregroundStyle(Theme.accent)
            }
            .menuStyle(.borderlessButton)
            .fixedSize()
        }
        .padding(10)
        .background(Theme.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Compact per-app 10-band EQ revealed under a mixer row.
private struct PerAppEQView: View {
    let app: AudioProcessInfo
    @EnvironmentObject var audio: AudioController
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Toggle(isOn: Binding(
                    get: { app.eqEnabled },
                    set: { audio.setAppEQEnabled($0, forObjectID: app.objectID) }
                )) {
                    Text("App EQ")
                        .font(.system(size: 11, weight: .medium))
                        .foregroundStyle(Theme.textSecondary)
                }
                .toggleStyle(.switch)
                .controlSize(.mini)
                .tint(Theme.accent)
                Spacer()
                presetMenu
                Button("Reset") { audio.resetAppEQ(forObjectID: app.objectID) }
                    .buttonStyle(.plain)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)
            }

            HStack(alignment: .bottom, spacing: 3) {
                ForEach(0..<10, id: \.self) { i in
                    MiniBandSlider(
                        gain: Binding(
                            get: { app.eqBands.indices.contains(i) ? app.eqBands[i] : 0 },
                            set: { audio.setAppEQBand($0, bandIndex: i, forObjectID: app.objectID) }
                        ),
                        label: Self.label(forBand: i)
                    )
                }
            }
            .frame(height: 110)
            .opacity(app.eqEnabled ? 1 : 0.35)
            .disabled(!app.eqEnabled)
        }
        .padding(10)
        .background(Theme.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    private var presetMenu: some View {
        Menu {
            ForEach(EQPreset.factory) { preset in
                Button(preset.name) {
                    audio.applyAppEQPreset(preset.gains, forObjectID: app.objectID)
                }
            }
            if !state.customPresets.isEmpty {
                Divider()
                ForEach(state.customPresets) { preset in
                    Button {
                        audio.applyAppEQPreset(preset.gains, forObjectID: app.objectID)
                    } label: {
                        Label(preset.name, systemImage: "person.fill")
                    }
                }
            }
        } label: {
            HStack(spacing: 3) {
                Text("Preset")
                    .font(.system(size: 10))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 8))
            }
            .foregroundStyle(Theme.accent)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }

    private static func label(forBand i: Int) -> String {
        let f = Band.isoCenters[i]
        return f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))"
    }
}

/// A small vertical EQ slider for the per-app EQ (mirrors BandSliderView, compact).
private struct MiniBandSlider: View {
    @Binding var gain: Double
    let label: String

    var body: some View {
        VStack(spacing: 4) {
            GeometryReader { geo in
                let range = Band.gainRange
                let span = range.upperBound - range.lowerBound
                let h = geo.size.height
                let frac = (gain - range.lowerBound) / span
                let thumbY = h * (1 - frac)

                ZStack(alignment: .bottom) {
                    Capsule().fill(Theme.trackInactive).frame(width: 3)
                    Capsule().fill(Theme.accent).frame(width: 3, height: max(0, h * frac))
                    Circle()
                        .fill(Theme.accent)
                        .frame(width: 10, height: 10)
                        .position(x: geo.size.width / 2, y: thumbY)
                }
                .contentShape(Rectangle())
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let f = max(0, min(1, 1 - value.location.y / h))
                            gain = (range.lowerBound + f * span).rounded()
                        }
                )
            }
            .frame(maxWidth: .infinity)

            Text(label)
                .font(.system(size: 8, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
        }
    }
}
