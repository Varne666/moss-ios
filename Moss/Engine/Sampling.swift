import Foundation

/// The published MOSS nearest-training-grid Euler schedule. CPU Float operations are intentional.
enum MossSchedule {
    static func linspace(_ start: Float, _ end: Float, _ count: Int) -> [Float] {
        if count == 1 { return [start] }
        let step = (end - start) / Float(count - 1)
        return (0..<count).map { i in
            i < count / 2 ? Float(Double(start) + Double(step) * Double(i))
                : Float(Double(end) - Double(step) * Double(count - i - 1))
        }
    }
    static func sigmas(steps: Int, shift: Float) -> [Float] {
        func grid(_ count: Int, _ s: Float) -> [Float] {
            let lower = Float(Double(s) / (1000 + Double(s) - 1))
            return linspace(1, lower, count).map { (s * $0) / (1 + (s - 1) * $0) }
        }
        let training = Array(grid(1000, 1).reversed())
        var result: [Float] = []
        for v in grid(steps, shift) {
            var lo = 0, hi = 999
            while lo < hi { let mid = (lo + hi) / 2; if training[mid] < v { lo = mid + 1 } else { hi = mid } }
            let lower = max(0, lo - 1)
            let chosen = abs(v - training[lower]) <= abs(training[lo] - v) ? training[lower] : training[lo]
            if result.last != chosen { result.append(chosen) }
        }
        return result + [0]
    }
}

/// MT19937 and the CPU PyTorch float32 normal-fill convention (128-channel latents are divisible by 16).
struct MossNoise {
    private var state = [UInt32](repeating: 0, count: 624)
    private var cursor = 624
    init(seed: UInt32) {
        state[0] = seed
        for i in 1..<624 { state[i] = 1812433253 &* (state[i-1] ^ (state[i-1] >> 30)) &+ UInt32(i) }
    }
    mutating func next() -> UInt32 {
        if cursor >= 624 {
            for i in 0..<624 {
                let y = (state[i] & 0x80000000) | (state[(i+1)%624] & 0x7fffffff)
                state[i] = state[(i+397)%624] ^ (y >> 1) ^ ((y & 1) == 0 ? 0 : 0x9908b0df)
            }
            cursor = 0
        }
        var y = state[cursor]; cursor += 1
        y ^= y >> 11; y ^= (y << 7) & 0x9d2c5680; y ^= (y << 15) & 0xefc60000; y ^= y >> 18
        return y
    }
    mutating func normal(count: Int) -> [Float] {
        precondition(count % 16 == 0)
        var out = [Float](repeating: 0, count: count)
        for base in stride(from: 0, to: count, by: 16) {
            let u = (0..<16).map { _ in Float(next() & 0xffffff) / 16777216 }
            for j in 0..<8 {
                let radius = sqrtf(-2 * logf(1 - u[j]))
                let theta = Float(2 * Double.pi) * u[j+8]
                out[base+j] = radius * cosf(theta); out[base+j+8] = radius * sinf(theta)
            }
        }
        return out
    }
}
