import Foundation

func runRingBufferTests() {
    let ring = RingBuffer(capacityFrames: 3, channels: 2)
    let input: [Float] = [1, 10, 2, 20, 3, 30, 4, 40]
    input.withUnsafeBufferPointer { ring.write($0.baseAddress!, count: $0.count) }
    var output = [Float](repeating: -1, count: 6)
    let read = output.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: $0.count) }
    precondition(read == 6 && output == [2, 20, 3, 30, 4, 40],
                 "Overflow must preserve the newest whole stereo frames and channel order")
    output.withUnsafeMutableBufferPointer { ring.read(into: $0.baseAddress!, count: $0.count) }
    precondition(output == Array(repeating: 0, count: 6), "Underruns must be silent")

    for channels in [1, 2, 6] {
        let capacity = 7 * channels
        let wrapped = RingBuffer(capacityFrames: 7, channels: channels)
        var expected: [Float] = []
        for step in 0..<100 {
            let samples = (0..<((step % 11) * channels)).map { Float(step * 100 + $0) }
            samples.withUnsafeBufferPointer {
                if let base = $0.baseAddress { wrapped.write(base, count: $0.count) }
            }
            expected = Array((expected + samples).suffix(capacity))
            var actual = [Float](repeating: -1, count: (step % 5) * channels)
            let count = actual.withUnsafeMutableBufferPointer {
                guard let base = $0.baseAddress else { return 0 }
                return wrapped.read(into: base, count: $0.count)
            }
            let wanted = Array(expected.prefix(actual.count))
            precondition(count == wanted.count)
            precondition(actual == wanted + Array(repeating: 0, count: actual.count - wanted.count))
            expected.removeFirst(wanted.count)
        }
    }
    print("PASS: ring buffer overflow, underrun, capacity, channel order, repeated wraparound (mono/stereo/6-channel)")
}
