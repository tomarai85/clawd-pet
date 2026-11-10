import Foundation
import CoreGraphics
import ClawdCore
@testable import ClawdRendering

/// The shape of a smooth picture, measured the way the picture was drawn: the shape's coverage of every device pixel.
struct SmoothShapeMask {
    let width: Int, height: Int
    let bytes: [UInt8]
    /// 0 outside the shape, 255 inside it, between along its anti-aliased outline.
    func coverage(_ x: Int, _ y: Int) -> Int { x >= 0 && y >= 0 && x < width && y < height ? Int(bytes[y * width + x]) : 0 }
    /// Within a device pixel of a pixel that is not wholly inside: the anti-aliased band of the outline.
    func touchesTheOutline(_ x: Int, _ y: Int) -> Bool {
        for dy in -1...1 { for dx in -1...1 where coverage(x + dx, y + dy) < 255 { return true } }
        return false
    }
    var shapeBounds: (minX: Int, minY: Int, maxX: Int, maxY: Int)? {
        var minX = Int.max, minY = Int.max, maxX = -1, maxY = -1
        for y in 0..<height { for x in 0..<width where bytes[y * width + x] > 0 { minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y) } }
        return maxX < 0 ? nil : (minX, minY, maxX, maxY)
    }
}

enum SmoothChecks {
    static let elements = stageRenderer.elements
    static func shapeCoverage(style: Int, bitmap: BubbleBitmap, appearance: BubbleAppearance, connection: BubbleConnection, opening: BubbleOpening, variant: BubbleVariant,
                              backing: Double, scene: Scene, elapsed: Double, reduce: Bool) throws -> SmoothShapeMask {
        let design = BubbleDesign.resolved(style)
        let text = BubbleText.content(BubbleContent(scene: scene, elapsed: elapsed, duration: 5, verb: "Cogitating", pastVerb: "Cooked", reduceMotion: reduce, appearance: appearance),
                                      elements: elements, design: design)
        let prepared = SmoothBubble.prepare(design: design, runs: text.runs, dots: text.dots, opening: opening, connection: connection, variant: variant, tipColumn: nil,
                                            backing: backing, appearance: appearance)
        guard prepared.pixelWidth == bitmap.raster.width, prepared.pixelHeight == bitmap.raster.height else { throw ArtErrorForChecks.sizeMismatch }
        return SmoothShapeMask(width: prepared.pixelWidth, height: prepared.pixelHeight, bytes: SmoothBubble.shapeCoverage(prepared))
    }
}
enum ArtErrorForChecks: Error { case sizeMismatch }

/// The animation rules of D-8 as functions that list what a state function breaks, so that each can be fed a state function at half speed and must
/// report the wrong period (the in-suite control of each rule).
enum NewAnimationChecks {
    /// 14's asterisk: 12 degrees every 0.1 s, 3 s a turn. Sampled in the middle of a step, on the step itself and on an accumulated clock.
    static func asteriskPeriodViolations(_ angle: (Double) -> Double) -> [String] {
        var broken: [String] = []
        var accumulated = 0.0
        for k in 0...90 {
            let expected = Double((k % 30) * 12)
            for (label, t) in [("mid", Double(k) * 0.1 + 0.05), ("edge", Double(k) * 0.1), ("accumulated", accumulated)] where angle(t) != expected {
                broken.append("\(label) step \(k): \(angle(t)) degrees, expected \(expected)")
            }
            accumulated += 0.1
        }
        return broken
    }

    /// 14's dots: period 1.2 s, each dot 0.2 s behind the one before, peak at least 0.95 and low at most 0.35 over a period.
    static func dotWaveViolations(_ opacities: (Double) -> [Double]) -> [String] {
        var broken: [String] = []
        for k in 0..<36 {
            let t = Double(k) * 0.1
            let now = opacities(t), later = opacities(t + 1.2)
            if zip(now, later).contains(where: { abs($0 - $1) > 1e-9 }) { broken.append("the wave at \(t) s is not the wave 1.2 s later") }
            if t >= 0.4 {
                let earlier = opacities(t - 0.2)
                if abs(now[1] - earlier[0]) > 1e-9 || abs(now[2] - earlier[1]) > 1e-9 { broken.append("a dot at \(t) s is not the one before it 0.2 s ago") }
            }
        }
        for dot in 0..<3 {
            let sampled = (0..<12).map { opacities(Double($0) * 0.1)[dot] }
            if sampled.max()! < 0.95 { broken.append("dot \(dot) never reaches 0.95 (\(sampled.max()!))") }
            if sampled.min()! > 0.35 { broken.append("dot \(dot) never falls to 0.35 (\(sampled.min()!))") }
        }
        return broken
    }

    /// 13's and 15's dot counter: 1 + (floor(t / 0.4) mod 3).
    static func counterViolations(_ count: (Double) -> Int) -> [String] {
        var broken: [String] = []
        var accumulated = 0.0
        for k in 0...60 {
            let expected = 1 + k % 3
            for (label, t) in [("mid", Double(k) * 0.4 + 0.2), ("edge", Double(k) * 0.4), ("accumulated", accumulated)] where count(t) != expected {
                broken.append("\(label) step \(k) (\(t) s): \(count(t)) dots, expected \(expected)")
            }
            accumulated += 0.4
        }
        return broken
    }

    /// 15's shimmer for a verb of `letters` letters: g(t) = (n + 10) - ((floor(t / 0.2) + 11) mod (n + 20)).
    static func shimmerViolations(letters n: Int, _ index: (Double, Int) -> Int) -> [String] {
        var broken: [String] = []
        for k in 0..<(2 * (n + 20)) {
            let expected = (n + 10) - ((k + 11) % (n + 20))
            for (label, t) in [("mid", Double(k) * 0.2 + 0.1), ("edge", Double(k) * 0.2)] where index(t, n) != expected {
                broken.append("\(label) step \(k) (\(t) s): index \(index(t, n)), expected \(expected)")
            }
        }
        return broken
    }

    /// 13's and 15's spinner: Claude Code's glyph at the middle of each 0.1 s tick.
    static func spinnerViolations(_ glyph: (Double) -> String) -> [String] {
        var broken: [String] = []
        for k in 0..<80 {
            let t = Double(k) * 0.1 + 0.05
            if glyph(t) != stageRenderer.elements.spinner(at: t) { broken.append("at \(t) s: \(glyph(t)), Claude Code's clock says \(stageRenderer.elements.spinner(at: t))") }
        }
        return broken
    }
}
