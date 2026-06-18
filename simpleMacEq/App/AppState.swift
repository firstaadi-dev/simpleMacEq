import SwiftUI
import Combine
import ServiceManagement

/// Root observable store for EQ, master volume, presets, and persisted per-app settings.
/// Loads from `Settings` on launch and writes back (debounced) whenever anything changes.
@MainActor
final class AppState: ObservableObject {
    // EQ
    @Published var eqEnabled: Bool
    @Published var bands: [Band]
    @Published var selectedPreset: EQPreset?

    // Master volume is the hardware device volume, owned by OutputDeviceManager.

    // Presets (factory + user-saved)
    @Published var customPresets: [EQPreset]

    // Allow per-app volume above 100% (default off → sliders cap at 100%).
    @Published var volumeBoostEnabled: Bool

    // Launch at login (Phase 5)
    @Published var launchAtLogin: Bool

    /// All presets the picker should show.
    var allPresets: [EQPreset] { EQPreset.factory + customPresets }

    private var settings: AppSettings
    private var cancellables = Set<AnyCancellable>()

    init() {
        let loaded = AppSettings.load()
        settings = loaded
        eqEnabled = loaded.eqEnabled
        customPresets = loaded.customPresets
        volumeBoostEnabled = loaded.volumeBoostEnabled
        launchAtLogin = loaded.launchAtLogin

        var restored = Band.defaultBands()
        for i in restored.indices where i < loaded.bandGains.count {
            restored[i].gain = loaded.bandGains[i].clamped(to: Band.gainRange)
        }
        bands = restored

        let all = EQPreset.factory + loaded.customPresets
        selectedPreset = all.first { $0.name == loaded.selectedPresetName && $0.matches(restored.map(\.gain)) }
            ?? all.first { $0.matches(restored.map(\.gain)) }

        syncLaunchAtLogin(to: loaded.launchAtLogin, persist: false)
        observe()
    }

    // MARK: - EQ actions

    func apply(preset: EQPreset) {
        selectedPreset = preset
        for i in bands.indices where i < preset.gains.count {
            bands[i].gain = preset.gains[i]
        }
    }

    func resetBands() {
        for i in bands.indices { bands[i].gain = 0 }
        selectedPreset = EQPreset.factory.first
    }

    /// Called by a band slider edit: a manual change means we're no longer on a named
    /// preset unless the gains still happen to match one.
    func bandsEdited() {
        let gains = bands.map(\.gain)
        selectedPreset = allPresets.first { $0.matches(gains) }
    }

    // MARK: - Custom presets

    func saveCustomPreset(named name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              !EQPreset.factory.contains(where: { $0.name == trimmed }) else { return }
        let preset = EQPreset(name: trimmed, gains: bands.map(\.gain), isFactory: false)
        customPresets.removeAll { $0.name == trimmed }
        customPresets.append(preset)
        selectedPreset = preset
    }

    func deleteCustomPreset(_ preset: EQPreset) {
        guard !preset.isFactory else { return }
        customPresets.removeAll { $0.name == preset.name }
        if selectedPreset?.name == preset.name { selectedPreset = nil }
    }

    // MARK: - Per-app persistence (read/written by AudioController)

    func appVolume(for bundleID: String) -> Double {
        guard !bundleID.isEmpty else { return 1.0 }
        return settings.appVolumes[bundleID] ?? 1.0
    }

    func appMuted(for bundleID: String) -> Bool {
        guard !bundleID.isEmpty else { return false }
        return settings.appMutes[bundleID] ?? false
    }

    func setAppVolume(_ volume: Double, for bundleID: String) {
        guard !bundleID.isEmpty else { return }
        settings.appVolumes[bundleID] = volume
        settings.save()
    }

    func setAppMuted(_ muted: Bool, for bundleID: String) {
        guard !bundleID.isEmpty else { return }
        settings.appMutes[bundleID] = muted
        settings.save()
    }

    func appEQBands(for bundleID: String) -> [Double] {
        guard !bundleID.isEmpty, let saved = settings.appEQBands[bundleID], saved.count == 10
        else { return Array(repeating: 0, count: 10) }
        return saved
    }

    func appEQEnabled(for bundleID: String) -> Bool {
        guard !bundleID.isEmpty else { return false }
        return settings.appEQEnabled[bundleID] ?? false
    }

    func setAppEQBands(_ bands: [Double], for bundleID: String) {
        guard !bundleID.isEmpty else { return }
        settings.appEQBands[bundleID] = bands
        settings.save()
    }

    func setAppEQEnabled(_ enabled: Bool, for bundleID: String) {
        guard !bundleID.isEmpty else { return }
        settings.appEQEnabled[bundleID] = enabled
        settings.save()
    }

    // MARK: - Launch at login

    private func syncLaunchAtLogin(to enabled: Bool, persist: Bool) {
        let service = SMAppService.mainApp
        do {
            if enabled, service.status != .enabled {
                try service.register()
            } else if !enabled, service.status == .enabled {
                try service.unregister()
            }
        } catch {
            // Registration can fail when running unsigned from DerivedData; reflect reality.
            if launchAtLogin != (service.status == .enabled) {
                launchAtLogin = (service.status == .enabled)
            }
        }
        if persist {
            settings.launchAtLogin = launchAtLogin
            settings.save()
        }
    }

    // MARK: - Persistence wiring

    private func observe() {
        // Coalesce rapid changes (slider drags) into a single save.
        let trigger = Publishers.MergeMany(
            $eqEnabled.map { _ in () }.eraseToAnyPublisher(),
            $bands.map { _ in () }.eraseToAnyPublisher(),
            $selectedPreset.map { _ in () }.eraseToAnyPublisher(),
            $customPresets.map { _ in () }.eraseToAnyPublisher(),
            $volumeBoostEnabled.map { _ in () }.eraseToAnyPublisher()
        )
        trigger
            .debounce(for: .milliseconds(300), scheduler: RunLoop.main)
            .sink { [weak self] in self?.persist() }
            .store(in: &cancellables)

        $launchAtLogin
            .dropFirst()
            .removeDuplicates()
            .sink { [weak self] enabled in self?.syncLaunchAtLogin(to: enabled, persist: true) }
            .store(in: &cancellables)
    }

    private func persist() {
        settings.eqEnabled = eqEnabled
        settings.bandGains = bands.map(\.gain)
        settings.selectedPresetName = selectedPreset?.name
        settings.customPresets = customPresets
        settings.volumeBoostEnabled = volumeBoostEnabled
        settings.launchAtLogin = launchAtLogin
        settings.save()
    }
}

private extension Comparable {
    func clamped(to range: ClosedRange<Self>) -> Self {
        min(max(self, range.lowerBound), range.upperBound)
    }
}
