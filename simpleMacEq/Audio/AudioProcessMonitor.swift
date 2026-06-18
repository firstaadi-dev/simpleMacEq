import Foundation
import CoreAudio
import AppKit
import Combine
import Darwin

/// Enumerates Core Audio process objects and publishes the subset that are currently
/// producing output. Adds property listeners so the list updates live as apps start
/// and stop playing audio.
@MainActor
final class AudioProcessMonitor: ObservableObject {
    /// Processes currently running output, excluding our own process.
    @Published private(set) var processes: [AudioProcessRef] = []

    private let system = AudioObjectID(kAudioObjectSystemObject)
    private var listenedObjects: Set<AudioObjectID> = []
    private let ownPID = getpid()

    struct AudioProcessRef: Identifiable, Equatable {
        let objectID: AudioObjectID
        let pid: pid_t
        let bundleID: String
        let name: String
        let icon: NSImage?
        var id: AudioObjectID { objectID }

        static func == (lhs: AudioProcessRef, rhs: AudioProcessRef) -> Bool {
            lhs.objectID == rhs.objectID
        }
    }

    private var pollTimer: Timer?

    func start() {
        installProcessListListener()
        refresh()
        // Core Audio's IsRunningOutput/ProcessObjectList notifications are unreliable on
        // some systems, so poll as a safety net. refresh() only republishes (and rebuilds
        // the engine) when the active set actually changes, so this is glitch-free.
        pollTimer = Timer.scheduledTimer(withTimeInterval: 1.0, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refresh() }
        }
    }

    // MARK: - Enumeration

    func refresh() {
        let all = Self.processObjectIDs()

        // Track per-process "is running output" so the list stays live.
        for obj in all where !listenedObjects.contains(obj) {
            var addr = Self.address(kAudioProcessPropertyIsRunningOutput)
            AudioObjectAddPropertyListenerBlock(obj, &addr, DispatchQueue.main) { [weak self] _, _ in
                MainActor.assumeIsolated { self?.refresh() }
            }
            listenedObjects.insert(obj)
        }

        let active = all.compactMap { obj -> AudioProcessRef? in
            guard Self.boolProperty(obj, kAudioProcessPropertyIsRunningOutput) else { return nil }
            let pid = Self.pidProperty(obj)
            guard pid != ownPID else { return nil }
            let caBundleID = Self.stringProperty(obj, kAudioProcessPropertyBundleID) ?? ""

            // Audio often runs in a helper process (e.g. "Google Chrome Helper (Audio)").
            // Walk up the parent chain to the real owning app so we show "Google Chrome"
            // with its icon, and key persisted volume under the app's bundle ID.
            let owner = Self.owningApplication(of: pid)
            let bundleID = owner?.bundleIdentifier ?? caBundleID
            let name = owner?.localizedName
                ?? Self.prettyName(fromBundleID: caBundleID)
                ?? "PID \(pid)"
            return AudioProcessRef(objectID: obj, pid: pid, bundleID: bundleID,
                                   name: name, icon: owner?.icon)
        }

        if active != processes { processes = active }
    }

    private func installProcessListListener() {
        var addr = Self.address(kAudioHardwarePropertyProcessObjectList)
        AudioObjectAddPropertyListenerBlock(system, &addr, DispatchQueue.main) { [weak self] _, _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    // MARK: - Owning-app resolution

    /// Resolve the regular foreground app responsible for `pid`, walking up the parent
    /// process chain past helper/utility processes (Chrome, Electron apps, etc.).
    private static func owningApplication(of pid: pid_t) -> NSRunningApplication? {
        var current = pid
        for _ in 0..<8 {
            if let app = NSRunningApplication(processIdentifier: current),
               app.activationPolicy == .regular, app.bundleIdentifier != nil {
                return app
            }
            guard let parent = parentPID(of: current), parent > 1, parent != current else { break }
            current = parent
        }
        // No regular ancestor found: fall back to whatever the original pid maps to.
        return NSRunningApplication(processIdentifier: pid)
    }

    private static func parentPID(of pid: pid_t) -> pid_t? {
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        let result = mib.withUnsafeMutableBufferPointer { ptr in
            sysctl(ptr.baseAddress, UInt32(ptr.count), &info, &size, nil, 0)
        }
        guard result == 0, size > 0 else { return nil }
        return info.kp_eproc.e_ppid
    }

    /// Last-resort display name from a bundle ID, e.g. "com.apple.Music" → "Music".
    private static func prettyName(fromBundleID bundleID: String) -> String? {
        guard !bundleID.isEmpty else { return nil }
        let last = bundleID.components(separatedBy: ".").last ?? bundleID
        // Skip unhelpful suffixes like "helper".
        if last.caseInsensitiveCompare("helper") == .orderedSame { return bundleID }
        return last.capitalized
    }

    // MARK: - Core Audio helpers

    private static func address(_ selector: AudioObjectPropertySelector)
        -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(mSelector: selector,
                                   mScope: kAudioObjectPropertyScopeGlobal,
                                   mElement: kAudioObjectPropertyElementMain)
    }

    private static func processObjectIDs() -> [AudioObjectID] {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var addr = address(kAudioHardwarePropertyProcessObjectList)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr else { return [] }
        let count = Int(size) / MemoryLayout<AudioObjectID>.size
        guard count > 0 else { return [] }
        var ids = [AudioObjectID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return [] }
        return ids
    }

    private static func boolProperty(_ obj: AudioObjectID,
                                     _ selector: AudioObjectPropertySelector) -> Bool {
        var addr = address(selector)
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr else { return false }
        return value != 0
    }

    private static func pidProperty(_ obj: AudioObjectID) -> pid_t {
        var addr = address(kAudioProcessPropertyPID)
        var value: pid_t = -1
        var size = UInt32(MemoryLayout<pid_t>.size)
        guard AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, &value) == noErr else { return -1 }
        return value
    }

    private static func stringProperty(_ obj: AudioObjectID,
                                       _ selector: AudioObjectPropertySelector) -> String? {
        var addr = address(selector)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var result: Unmanaged<CFString>?
        let status = withUnsafeMutablePointer(to: &result) {
            AudioObjectGetPropertyData(obj, &addr, 0, nil, &size, $0)
        }
        guard status == noErr, let cf = result else { return nil }
        let value = cf.takeRetainedValue() as String
        return value.isEmpty ? nil : value
    }
}
