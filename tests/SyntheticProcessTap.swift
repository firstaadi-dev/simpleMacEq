import AVFoundation
import CoreAudio

// An in-memory capture double; the controller and AVAudioEngine remain real.
@available(macOS 14.4, *)
final class ProcessTap {
    static var sampleRate: Double = 48000
    static var starts = 0
    static var stops = 0
    static var failStarts = false
    private(set) var format: AVAudioFormat!
    private(set) var ringBuffer: RingBuffer!
    private var started = false

    static func cleanupStaleAggregates() {}

    func start(processes: [AudioObjectID], clockDeviceUID: String, uidSuffix: String) throws {
        if Self.failStarts {
            throw NSError(domain: "SyntheticCapture", code: 1)
        }
        format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                               sampleRate: Self.sampleRate, channels: 2, interleaved: true)!
        ringBuffer = RingBuffer(capacityFrames: 32768, channels: 2)
        fillBuffer()
        Self.starts += 1
        started = true
    }

    func fillBuffer() {
        let samples = [Float](repeating: 0.125, count: 32768 * 2)
        samples.withUnsafeBufferPointer { ringBuffer.write($0.baseAddress!, count: $0.count) }
    }

    func stop() {
        if started { Self.stops += 1; started = false }
    }

    deinit { stop() }
}
