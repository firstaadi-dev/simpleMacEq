import SwiftUI
import AppKit

struct PanelView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        VStack(spacing: 0) {
            HeaderView()
            Divider().overlay(Theme.surfaceStroke)

            // Content sizes to fit; a ScrollView here would collapse to zero height
            // inside the MenuBarExtra window. The mixer list gets its own scroll later.
            VStack(spacing: 14) {
                EQSectionView()
                MasterVolumeView()
                AppMixerView()
            }
            .padding(14)
            .fixedSize(horizontal: false, vertical: true)

            Divider().overlay(Theme.surfaceStroke)
            FooterView()
        }
        .frame(width: 320)
        .background(Theme.background)
        .foregroundStyle(Theme.textPrimary)
    }
}

private struct HeaderView: View {
    @EnvironmentObject var state: AppState
    @EnvironmentObject var audio: AudioController

    var body: some View {
        VStack(spacing: 10) {
            HStack(spacing: 10) {
                Image(systemName: "slider.vertical.3")
                    .foregroundStyle(Theme.accent)
                Text("Equalizer")
                    .font(.system(size: 14, weight: .semibold))
                Spacer()
                Toggle("", isOn: $state.eqEnabled)
                    .toggleStyle(.switch)
                    .tint(Theme.accent)
                    .labelsHidden()
            }
            OutputSelectorView()
            HStack(spacing: 6) {
                Circle()
                    .fill(audio.isRunning ? Color.green : Theme.textSecondary)
                    .frame(width: 6, height: 6)
                Text(audio.status)
                    .font(.system(size: 10))
                    .foregroundStyle(Theme.textSecondary)
                    .lineLimit(1)
                Spacer()
            }
            HStack(spacing: 8) {
                meter("in", audio.inputLevel)
                meter("out", audio.outputLevel)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    private func meter(_ label: String, _ level: Float) -> some View {
        HStack(spacing: 4) {
            Text(label)
                .font(.system(size: 9, weight: .medium))
                .foregroundStyle(Theme.textSecondary)
                .frame(width: 18, alignment: .leading)
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(Theme.trackInactive)
                    Capsule().fill(Theme.accent)
                        .frame(width: geo.size.width * CGFloat(min(1, level * 4)))
                }
            }
            .frame(height: 4)
        }
    }
}

private struct FooterView: View {
    @EnvironmentObject var state: AppState

    var body: some View {
        HStack {
            Toggle(isOn: $state.launchAtLogin) {
                Text("Launch at login")
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
            }
            .toggleStyle(.checkbox)
            .controlSize(.mini)
            Spacer()
            Button("Quit") { NSApplication.shared.terminate(nil) }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 8)
    }
}
