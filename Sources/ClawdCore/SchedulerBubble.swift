import Foundation

/// Which of the fifteen bubble styles a dictation gets (spec 4.2). Pure functions; the scheduler holds the state.
public enum BubbleStyles {
    public static let all = SchedulerSettings.bubbleStyles
    /// 6 (pixel cloud above the head), 10 (rounded typing bubble) and the three the board's mock added, 13 (refined pixel art), 14 (smooth macOS
    /// bubble) and 15 (Claude Code's panel), weigh 3; the other ten 1.
    public static func weight(_ style: Int) -> Double { [6, 10, 13, 14, 15].contains(style) ? 3 : 1 }

    /// The next style. With L the previous dictation's style, it is drawn over the enabled styles other than L,
    /// each with probability w_j / (W - w_L). One enabled style is always that style. `noRepeat: false` and
    /// `weighted: false` exist only for the negative controls.
    public static func draw(enabled: [Int], last: Int?, unit: Double, noRepeat: Bool = true, weighted: Bool = true) -> Int? {
        guard !enabled.isEmpty else { return nil }
        if enabled.count == 1 { return enabled[0] }
        let candidates = noRepeat ? enabled.filter { $0 != last } : enabled
        guard !candidates.isEmpty else { return enabled[0] }
        let weights = candidates.map { weighted ? weight($0) : 1 }
        guard let index = WeightedChoice.index(weights: weights, unit: unit) else { return candidates[0] }
        return candidates[index]
    }

    /// Long-run share of each enabled style under `draw`: pi_j proportional to w_j x (W - w_j) (spec 4.2, detailed balance).
    public static func stationaryShares(enabled: [Int]) -> [Int: Double] {
        guard enabled.count > 1 else { return Dictionary(uniqueKeysWithValues: enabled.map { ($0, 1.0) }) }
        let total = enabled.reduce(0.0) { $0 + weight($1) }
        let raw = enabled.map { weight($0) * (total - weight($0)) }
        let sum = raw.reduce(0, +)
        return Dictionary(uniqueKeysWithValues: zip(enabled, raw.map { $0 / sum }))
    }
}
