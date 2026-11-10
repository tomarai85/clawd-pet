import Foundation
import ClawdCore

/// The procedural look change (spec 6.5 and T1): Clawd ducks below the baseline in the old look, the stage clips him, and he
/// rises in the new look. The first frame is the old look's rest picture and the last is the new look's, so the change begins and
/// ends exactly on what is on screen before and after it. Dust uses the pixels Claude Code's C1 jump uses.
public enum LookTransition {
    /// Frames of the whole change: `sinkFrames` going down, as many coming up. The scheduler's 1.6 s makes each 80 ms (12.5 fps).
    public static let frameCount = 20
    public static let sinkFrames = 10
    /// The grey of Claude Code's dust glyphs (render-core.js PX.dust).
    public static let dust = Pixel(153, 153, 153)

    /// Dust cells in units on the 12 x 12 canvas: C1's `dot` puff and its `wave` puff (render-core.js:161-162).
    public static let dotPuff: [CellPoint] = [CellPoint(0, 11), CellPoint(11, 11)]
    public static let wavePuff: [CellPoint] = [CellPoint(0, 10), CellPoint(1, 11), CellPoint(10, 11), CellPoint(11, 10)]

    /// The frame on screen at `progress` (0...1): 0 is the first, 1 the last.
    public static func frameIndex(progress: Double) -> Int { min(frameCount - 1, max(0, Int((progress * Double(frameCount)).rounded(.down)))) }

    /// Seconds until the picture changes again.
    public static func nextChange(progress: Double, duration: Double) -> Double? {
        let k = frameIndex(progress: progress)
        guard k < frameCount - 1 else { return nil }
        return max(0.001, (Double(k + 1) / Double(frameCount) - progress) * duration)
    }

    /// How far below its rest position the picture is at depth step `j` (0 = rest, `sinkFrames - 1` = fully hidden), in cells.
    static func depth(step j: Int, hiddenDepth: Int) -> Int {
        if j <= 0 { return 0 }
        if j >= sinkFrames - 1 { return hiddenDepth }
        return Int((Double(hiddenDepth) * Double(j) / Double(sinkFrames - 1)).rounded())
    }
    /// 0 is the rest frame, 1 and 2 carry the C1 puffs (dot, then wave), the rest have none; the same on the way up.
    static func step(forFrame k: Int) -> Int { k < sinkFrames ? k : frameCount - 1 - k }

    public static func compose(art: ClawdArt, from: LookArt, to: LookArt, frame k: Int, blink: Bool = false) throws -> ComposedClawd {
        let index = min(max(0, k), frameCount - 1)
        let rising = index >= sinkFrames
        let clip = try art.pose(blink && index == 0 ? "blink" : "idle")
        let look = rising ? to : from
        let rest = StageCompose.compose(clip: clip, frameIndex: 0, look: look)
        let j = step(forFrame: index)
        guard j > 0 else { return rest }
        let canvas = StageGeometry.canvasCells
        // The picture goes down until its topmost pixel has passed the baseline, then nothing of it is left.
        let top = (rest.raster.opaqueBounds?.minY ?? rest.canvasOrigin.y + canvas) - rest.canvasOrigin.y
        let hidden = max(1, canvas - top)
        let shift = depth(step: j, hiddenDepth: hidden)
        var raster = rest.raster.shifted(dx: 0, dy: shift), hit = rest.hit.shifted(dx: 0, dy: shift)
        // The stage clips at the baseline: nothing is drawn below the canvas' bottom row.
        let baseline = rest.canvasOrigin.y + canvas
        for y in baseline..<max(baseline, raster.height) { for x in 0..<raster.width { raster[x, y] = .clear; hit[x, y] = .clear } }
        let puff: [CellPoint] = j == 1 ? dotPuff : j == 2 ? wavePuff : []
        for unit in puff {
            raster.fill(x: rest.canvasOrigin.x + unit.x * 2, y: rest.canvasOrigin.y + unit.y * 2, width: 2, height: 2, dust)
        }
        return ComposedClawd(raster: raster, canvasOrigin: rest.canvasOrigin, head: rest.head.map { CellPoint($0.x, $0.y + shift) }, hit: hit,
                             headTopRow: rest.headTopRow.map { $0 + shift }, headCentreColumn: rest.headCentreColumn,
                             bodyCentreRow: rest.bodyCentreRow.map { $0 + shift },
                             feetBottomRow: rest.feetBottomRow.map { min($0 + shift, canvas) })
    }
}
