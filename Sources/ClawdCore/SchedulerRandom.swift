import Foundation

/// One random source drives every scheduler choice (spec 6.7). With a fixed seed the whole schedule is reproducible;
/// production seeds it from the system. SplitMix64: small, fast, and good enough for scheduling.
public final class SeededRandom {
    private var state: UInt64
    public init(seed: UInt64) { state = seed }
    public static func fromSystem() -> SeededRandom { SeededRandom(seed: UInt64.random(in: 0...UInt64.max)) }

    public func nextUInt64() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
    /// Uniform in [0, 1).
    public func unit() -> Double { Double(nextUInt64() >> 11) / Double(1 << 53) }
    public func callAsFunction() -> Double { unit() }
}

public enum WeightedChoice {
    /// Index drawn with probability weight / total. `unit` is uniform in [0, 1). Non-positive weights are never chosen.
    public static func index(weights: [Double], unit: Double) -> Int? {
        let total = weights.reduce(0) { $0 + max(0, $1) }
        guard total > 0 else { return nil }
        var target = min(max(0, unit), 1 - Double.ulpOfOne) * total
        var lastPositive: Int?
        for (i, w) in weights.enumerated() where w > 0 {
            lastPositive = i
            if target < w { return i }
            target -= w
        }
        return lastPositive
    }
}
