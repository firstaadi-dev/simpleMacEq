import Foundation
import CoreAudio
import AppKit

/// A running app producing audio, shown in the per-app mixer. Populated from Core
/// Audio process taps; `objectID` is the Core Audio process object backing the tap.
struct AudioProcessInfo: Identifiable, Equatable {
    var id: String { bundleID.isEmpty ? "pid-\(pid)" : bundleID }
    let objectID: AudioObjectID
    let pid: pid_t
    let bundleID: String
    let name: String
    let symbol: String          // SF Symbol fallback when no app icon is available
    var icon: NSImage?
    var volume: Double           // 0...2 (above 1.0 = boost)
    var isMuted: Bool = false
    var eqEnabled: Bool = false
    var eqBands: [Double] = Array(repeating: 0, count: 10)   // per-app EQ, dB

    static func == (lhs: AudioProcessInfo, rhs: AudioProcessInfo) -> Bool {
        lhs.objectID == rhs.objectID &&
        lhs.volume == rhs.volume &&
        lhs.isMuted == rhs.isMuted &&
        lhs.eqEnabled == rhs.eqEnabled &&
        lhs.eqBands == rhs.eqBands &&
        lhs.name == rhs.name
    }
}
