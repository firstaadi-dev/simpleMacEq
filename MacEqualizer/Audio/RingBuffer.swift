import Foundation
import os

/// Single-producer / single-consumer interleaved Float ring buffer bridging the
/// capture IO proc (producer) and the AVAudioSourceNode render block (consumer).
/// Guarded by os_unfair_lock — tiny critical sections, no allocation on the audio path.
final class RingBuffer {
    private let storage: UnsafeMutablePointer<Float>
    private let capacity: Int          // total floats
    private var readIndex = 0
    private var writeIndex = 0
    private var lock = os_unfair_lock_s()

    init(capacityFrames: Int, channels: Int) {
        capacity = max(1, capacityFrames * channels)
        storage = .allocate(capacity: capacity)
        storage.initialize(repeating: 0, count: capacity)
    }

    deinit { storage.deallocate() }

    /// Producer: append `count` floats, overwriting the oldest if full.
    func write(_ src: UnsafePointer<Float>, count: Int) {
        os_unfair_lock_lock(&lock)
        var w = writeIndex
        var r = readIndex
        for i in 0..<count {
            storage[w] = src[i]
            w += 1; if w == capacity { w = 0 }
            if w == r { r += 1; if r == capacity { r = 0 } }   // drop oldest
        }
        writeIndex = w
        readIndex = r
        os_unfair_lock_unlock(&lock)
    }

    /// Consumer: fill `count` floats; zero-pads whatever isn't available.
    @discardableResult
    func read(into dst: UnsafeMutablePointer<Float>, count: Int) -> Int {
        os_unfair_lock_lock(&lock)
        var rd = 0
        var r = readIndex
        let w = writeIndex
        while rd < count && r != w {
            dst[rd] = storage[r]
            r += 1; if r == capacity { r = 0 }
            rd += 1
        }
        readIndex = r
        os_unfair_lock_unlock(&lock)
        if rd < count {
            for i in rd..<count { dst[i] = 0 }
        }
        return rd
    }
}
