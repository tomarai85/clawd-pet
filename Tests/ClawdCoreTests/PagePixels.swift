import Foundation

/// What a page measurement can promise at the chat's page zoom (0.75, pinned by `ChatTextSize_thePageIsDrawnAtThreeQuartersOfItsSize`).
/// Layout and scrolling land on screen pixels, and one screen pixel is `1 / zoom` page pixels in the tests' 1x views (4/3 at 0.75; finer on a 2x
/// screen). So a scroll set to the end reads back less than one step short of the fractional end, a measured height is within one step of its CSS
/// value, and a position the page restores (a scroll set from a laid-out top plus a whole-pixel offset, then measured) is within two steps and
/// half a pixel of where it was asked to be. A broken pin, anchor or restore misses by far more than that.
enum PagePixels {
    static let zoom = 0.75
    static let step = 1 / zoom

    /// The scroller is at its end: `top` is at most one step short of `max`.
    static func atEnd(_ place: [String: Any]) -> Bool {
        guard let top = place["top"] as? Double, let max = place["max"] as? Double else { return false }
        return top <= max && max - top < step
    }

    /// A measured length is the CSS length to within one step.
    static func length(_ value: Double?, is css: Double) -> Bool {
        guard let value else { return false }
        return abs(value - css) <= step
    }

    /// A position the page set and the test measured is where it was asked to be: two steps and half a pixel.
    static func position(_ value: Double?, is target: Double) -> Bool {
        guard let value else { return false }
        return abs(value - target) <= 2 * step + 0.5
    }
}
