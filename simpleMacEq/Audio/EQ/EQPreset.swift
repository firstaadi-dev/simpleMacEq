import Foundation

/// A named set of the 10 band gains. Factory presets ship with the app;
/// custom presets are saved by the user and persisted via `Settings`.
struct EQPreset: Identifiable, Hashable, Codable {
    var id: String { name }
    let name: String
    let gains: [Double]   // exactly 10 values, dB
    var isFactory: Bool = false

    static let factory: [EQPreset] = [
        EQPreset(name: "Flat",       gains: Array(repeating: 0, count: 10), isFactory: true),
        EQPreset(name: "Bass Boost", gains: [6, 5, 4, 2, 0, 0, 0, 0, 0, 0], isFactory: true),
        EQPreset(name: "Treble",     gains: [0, 0, 0, 0, 0, 1, 2, 4, 5, 6], isFactory: true),
        EQPreset(name: "Vocal",      gains: [-2, -1, 0, 2, 4, 4, 3, 1, 0, -1], isFactory: true),
        EQPreset(name: "Loudness",   gains: [5, 4, 2, 0, -1, -1, 0, 2, 4, 5], isFactory: true),
    ]

    /// True when these gains exactly match the preset's stored gains.
    func matches(_ values: [Double]) -> Bool {
        guard values.count == gains.count else { return false }
        return zip(values, gains).allSatisfy { abs($0 - $1) < 0.01 }
    }
}
