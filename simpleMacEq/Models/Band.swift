import Foundation

/// One of the 10 fixed graphic-EQ controls (ISO center frequency + gain in dB).
struct Band: Identifiable, Equatable {
    let id = UUID()
    let frequency: Double   // Hz
    var gain: Double        // dB, clamped to gainRange

    static let gainRange: ClosedRange<Double> = -12...12

    /// Short axis label, e.g. "500" or "16k".
    var label: String {
        frequency >= 1000 ? "\(Int(frequency / 1000))k" : "\(Int(frequency))"
    }

    static let isoCenters: [Double] = [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]

    // ponytail: shared label helper (was duplicated in PerAppEQView)
    static func label(forIndex i: Int) -> String {
        let f = isoCenters[i]
        return f >= 1000 ? "\(Int(f / 1000))k" : "\(Int(f))"
    }

    static func defaultBands() -> [Band] {
        isoCenters.map { Band(frequency: $0, gain: 0) }
    }
}
