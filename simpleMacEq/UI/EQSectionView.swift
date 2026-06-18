import SwiftUI
import AppKit

struct EQSectionView: View {
    @EnvironmentObject var state: AppState
    @State private var showingSaveField = false
    @State private var newPresetName = ""
    @FocusState private var nameFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("EQ")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Theme.textSecondary)
                Spacer()
                Button("Reset") { state.resetBands() }
                    .buttonStyle(.plain)
                    .font(.system(size: 11))
                    .foregroundStyle(Theme.textSecondary)
                presetMenu
            }

            if showingSaveField { saveField }

            HStack(alignment: .bottom, spacing: 4) {
                ForEach($state.bands) { $band in
                    BandSliderView(band: $band) { state.bandsEdited() }
                }
            }
            .frame(height: 168)
            .opacity(state.eqEnabled ? 1 : 0.35)
            .disabled(!state.eqEnabled)
            .animation(.easeInOut(duration: 0.2), value: state.eqEnabled)
        }
        .padding(14)
        .background(Theme.surface, in: RoundedRectangle(cornerRadius: 12))
    }

    // Inline save field — kept inside the panel window so the MenuBarExtra panel
    // doesn't dismiss (a separate alert/sheet window would steal focus and close it).
    private var saveField: some View {
        HStack(spacing: 8) {
            TextField("Preset name", text: $newPresetName)
                .textFieldStyle(.roundedBorder)
                .font(.system(size: 12))
                .focused($nameFocused)
                .onSubmit(saveAndClose)
            Button("Save", action: saveAndClose)
                .font(.system(size: 11, weight: .medium))
                .disabled(newPresetName.trimmingCharacters(in: .whitespaces).isEmpty)
            Button("Cancel") { closeField() }
                .buttonStyle(.plain)
                .font(.system(size: 11))
                .foregroundStyle(Theme.textSecondary)
        }
        .padding(8)
        .background(Theme.background.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
        .transition(.opacity.combined(with: .move(edge: .top)))
    }

    private func openSaveField() {
        newPresetName = ""
        withAnimation(.easeInOut(duration: 0.15)) { showingSaveField = true }
        // The accessory app must activate for the text field to take keyboard focus.
        NSApp.activate(ignoringOtherApps: true)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { nameFocused = true }
    }

    private func saveAndClose() {
        let trimmed = newPresetName.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return }
        state.saveCustomPreset(named: trimmed)
        closeField()
    }

    private func closeField() {
        nameFocused = false
        newPresetName = ""
        withAnimation(.easeInOut(duration: 0.15)) { showingSaveField = false }
    }

    private var presetMenu: some View {
        Menu {
            ForEach(EQPreset.factory) { preset in
                Button(preset.name) { state.apply(preset: preset) }
            }
            if !state.customPresets.isEmpty {
                Divider()
                ForEach(state.customPresets) { preset in
                    Button {
                        state.apply(preset: preset)
                    } label: {
                        Label(preset.name, systemImage: "person.fill")
                    }
                }
            }
            Divider()
            Button("Save Current as Preset…") { openSaveField() }
            if let selected = state.selectedPreset, !selected.isFactory {
                Button("Delete “\(selected.name)”", role: .destructive) {
                    state.deleteCustomPreset(selected)
                }
            }
        } label: {
            HStack(spacing: 4) {
                Text(state.selectedPreset?.name ?? "Custom")
                    .font(.system(size: 12, weight: .medium))
                Image(systemName: "chevron.up.chevron.down")
                    .font(.system(size: 9))
            }
            .foregroundStyle(Theme.accent)
        }
        .menuStyle(.borderlessButton)
        .fixedSize()
    }
}
