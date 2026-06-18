import Foundation
import CoreAudio
import AVFoundation

enum TapError: LocalizedError {
    case createTap(OSStatus)
    case tapUID(OSStatus)
    case tapFormat(OSStatus)
    case createAggregate(OSStatus)
    case ioProc(OSStatus)

    var errorDescription: String? {
        switch self {
        case .createTap(let s):       return "Create tap failed (\(s)). Grant audio permission?"
        case .tapUID(let s):          return "Read tap UID failed (\(s))."
        case .tapFormat(let s):       return "Read tap format failed (\(s))."
        case .createAggregate(let s): return "Create aggregate failed (\(s))."
        case .ioProc(let s):          return "IO proc failed (\(s))."
        }
    }
}

/// Captures the audio of a single process with a muted process tap, wrapped in a private
/// input-only aggregate device, read via an `AudioDeviceIOProc` into a ring buffer. The
/// original app audio is muted at the OS level so we can re-render it with its own gain.
/// Passing an empty `processes` list taps all output (a global tap).
@available(macOS 14.4, *)
final class ProcessTap {
    private(set) var format: AVAudioFormat!
    private(set) var ringBuffer: RingBuffer!

    /// Stable UID we give our aggregate so launch-time cleanup can find stale ones.
    static let aggregateUIDPrefix = "com.firstaadi.simpleMacEq.capture"

    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioDeviceID = 0
    private var ioProcID: AudioDeviceIOProcID?
    private var channels = 2

    func start(processes: [AudioObjectID], clockDeviceUID: String, uidSuffix: String) throws {
        // 1. Muted tap of the target process(es), excluding ourselves (anti-feedback).
        let desc: CATapDescription
        if processes.isEmpty {
            var excluded: [AudioObjectID] = []
            if let myProc = Self.processObjectID(for: getpid()) { excluded = [myProc] }
            desc = CATapDescription(stereoGlobalTapButExcludeProcesses: excluded)
        } else {
            desc = CATapDescription(stereoMixdownOfProcesses: processes)
        }
        desc.name = "simpleMacEq Tap \(uidSuffix)"
        desc.isPrivate = true
        desc.muteBehavior = .mutedWhenTapped

        var tap: AudioObjectID = 0
        let tErr = AudioHardwareCreateProcessTap(desc, &tap)
        guard tErr == noErr else { throw TapError.createTap(tErr) }
        tapID = tap

        // 2. Tap format → interleaved AVAudioFormat + ring buffer.
        let asbd = try Self.tapFormat(tap)
        channels = max(1, Int(asbd.mChannelsPerFrame))
        let sampleRate = asbd.mSampleRate > 0 ? asbd.mSampleRate : 48000
        guard let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                      sampleRate: sampleRate,
                                      channels: AVAudioChannelCount(channels),
                                      interleaved: true) else {
            throw TapError.tapFormat(-1)
        }
        format = fmt
        ringBuffer = RingBuffer(capacityFrames: Int(sampleRate / 2), channels: channels)

        // 3. Private input-only aggregate containing the tap (clock from output device).
        let tapUID = try Self.tapUID(tap)
        let aggDesc: [String: Any] = [
            kAudioAggregateDeviceNameKey as String: "simpleMacEq Capture \(uidSuffix)",
            kAudioAggregateDeviceUIDKey as String: "\(Self.aggregateUIDPrefix).\(uidSuffix)",
            kAudioAggregateDeviceMainSubDeviceKey as String: clockDeviceUID,
            kAudioAggregateDeviceIsPrivateKey as String: true,
            kAudioAggregateDeviceIsStackedKey as String: false,
            kAudioAggregateDeviceTapAutoStartKey as String: true,
            kAudioAggregateDeviceSubDeviceListKey as String: [],
            kAudioAggregateDeviceTapListKey as String: [
                [
                    kAudioSubTapDriftCompensationKey as String: true,
                    kAudioSubTapUIDKey as String: tapUID,
                ]
            ],
        ]
        var agg: AudioDeviceID = 0
        let aErr = AudioHardwareCreateAggregateDevice(aggDesc as CFDictionary, &agg)
        guard aErr == noErr else { throw TapError.createAggregate(aErr) }
        aggregateID = agg

        // 4. IO proc: copy tapped input into the ring buffer.
        let ioProc: AudioDeviceIOProc = { _, _, inInputData, _, _, _, clientData in
            guard let clientData else { return noErr }
            let me = Unmanaged<ProcessTap>.fromOpaque(clientData).takeUnretainedValue()
            me.handleInput(inInputData)
            return noErr
        }
        var procID: AudioDeviceIOProcID?
        let pErr = AudioDeviceCreateIOProcID(agg, ioProc,
                                             Unmanaged.passUnretained(self).toOpaque(), &procID)
        guard pErr == noErr, let procID else { throw TapError.ioProc(pErr) }
        ioProcID = procID
        let sErr = AudioDeviceStart(agg, procID)
        guard sErr == noErr else { throw TapError.ioProc(sErr) }
    }

    private func handleInput(_ ablPtr: UnsafePointer<AudioBufferList>) {
        let abl = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: ablPtr))
        guard abl.count > 0 else { return }

        if abl.count == 1 {
            let b = abl[0]
            let count = Int(b.mDataByteSize) / MemoryLayout<Float>.size
            if count > 0, let p = b.mData?.assumingMemoryBound(to: Float.self) {
                ringBuffer.write(p, count: count)
            }
        } else {
            // Non-interleaved planar → interleave.
            let ch = abl.count
            let frames = Int(abl[0].mDataByteSize) / MemoryLayout<Float>.size
            guard frames > 0 else { return }
            var scratch = [Float](repeating: 0, count: frames * ch)
            for c in 0..<ch {
                guard let p = abl[c].mData?.assumingMemoryBound(to: Float.self) else { continue }
                for f in 0..<frames { scratch[f * ch + c] = p[f] }
            }
            scratch.withUnsafeBufferPointer { ptr in
                if let base = ptr.baseAddress { ringBuffer.write(base, count: frames * ch) }
            }
        }
    }

    func stop() {
        if aggregateID != 0, let procID = ioProcID {
            AudioDeviceStop(aggregateID, procID)
            AudioDeviceDestroyIOProcID(aggregateID, procID)
            ioProcID = nil
        }
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
            aggregateID = 0
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
            tapID = 0
        }
    }

    deinit { stop() }

    /// Destroy any aggregate devices we leaked on a previous crash (matched by UID prefix).
    static func cleanupStaleAggregates() {
        let sys = AudioObjectID(kAudioObjectSystemObject)
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyDevices,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(sys, &addr, 0, nil, &size) == noErr else { return }
        let count = Int(size) / MemoryLayout<AudioDeviceID>.size
        guard count > 0 else { return }
        var ids = [AudioDeviceID](repeating: 0, count: count)
        guard AudioObjectGetPropertyData(sys, &addr, 0, nil, &size, &ids) == noErr else { return }

        for id in ids {
            var uidAddr = AudioObjectPropertyAddress(
                mSelector: kAudioDevicePropertyDeviceUID,
                mScope: kAudioObjectPropertyScopeGlobal,
                mElement: kAudioObjectPropertyElementMain)
            var uidSize = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
            var uidRef: Unmanaged<CFString>?
            let err = withUnsafeMutablePointer(to: &uidRef) {
                AudioObjectGetPropertyData(id, &uidAddr, 0, nil, &uidSize, $0)
            }
            guard err == noErr, let uidRef else { continue }
            let uid = uidRef.takeRetainedValue() as String
            if uid.hasPrefix(aggregateUIDPrefix) {
                AudioHardwareDestroyAggregateDevice(id)
            }
        }
    }

    // MARK: - Property helpers

    private static func processObjectID(for pid: pid_t) -> AudioObjectID? {
        var pidVar = pid
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var obj = AudioObjectID(0)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let err = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject), &addr,
            UInt32(MemoryLayout<pid_t>.size), &pidVar, &size, &obj)
        return err == noErr ? obj : nil
    }

    private static func tapUID(_ tap: AudioObjectID) throws -> String {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyUID,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        var uid: Unmanaged<CFString>?
        let err = withUnsafeMutablePointer(to: &uid) {
            AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, $0)
        }
        guard err == noErr, let u = uid else { throw TapError.tapUID(err) }
        return u.takeRetainedValue() as String
    }

    private static func tapFormat(_ tap: AudioObjectID) throws -> AudioStreamBasicDescription {
        var addr = AudioObjectPropertyAddress(
            mSelector: kAudioTapPropertyFormat,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        let err = AudioObjectGetPropertyData(tap, &addr, 0, nil, &size, &asbd)
        guard err == noErr else { throw TapError.tapFormat(err) }
        return asbd
    }
}
