import Foundation

/// Codable snapshot of everything the app persists across launches, stored as a
/// single JSON blob in `UserDefaults`. Per-app volumes/mutes are keyed by bundle ID
/// so they re-apply whenever that app starts producing audio again.
struct AppSettings: Codable, Equatable {
    var eqEnabled: Bool = true
    var bandGains: [Double] = Array(repeating: 0, count: 10)
    var selectedPresetName: String? = "Flat"
    var customPresets: [EQPreset] = []
    var appVolumes: [String: Double] = [:]
    var appMutes: [String: Bool] = [:]
    var appEQBands: [String: [Double]] = [:]   // per-app 10-band gains, keyed by bundle ID
    var appEQEnabled: [String: Bool] = [:]
    var appOutputDeviceUID: [String: String] = [:]  // per-app output device UID (absent = follow system)
    var volumeBoostEnabled: Bool = false       // allow per-app volume above 100%
    var launchAtLogin: Bool = false

    private static let key = "simpleMacEq.Settings.v1"

    static func load() -> AppSettings {
        guard let data = UserDefaults.standard.data(forKey: key),
              let decoded = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return decoded
    }

    func save() {
        guard let data = try? JSONEncoder().encode(self) else { return }
        UserDefaults.standard.set(data, forKey: Self.key)
    }
}
