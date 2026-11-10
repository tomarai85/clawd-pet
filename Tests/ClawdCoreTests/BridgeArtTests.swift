import Testing
import Foundation
import ClawdCore
import ClawdRendering

// Smooth round 2: the in-between pictures (`bridges` of the atlas) at the five seams where one frame changed too many cells at once. The art and the
// checker are in scripts/port-bridge-art.py and scripts/check-art-contract.py (v2:BR); here is what the stage and the catalog do with them.

/// A composed picture as {cell in canvas coordinates: pixel}, so two pictures of different stages compare cell by cell.
private func cells(_ picture: ComposedClawd) -> [CellPoint: Pixel] {
    var out: [CellPoint: Pixel] = [:]
    for y in 0..<picture.raster.height { for x in 0..<picture.raster.width where picture.raster.isOpaque(x, y) {
        out[CellPoint(x - picture.canvasOrigin.x, y - picture.canvasOrigin.y)] = picture.raster[x, y]
    } }
    return out
}

private func changed(_ a: [CellPoint: Pixel], _ b: [CellPoint: Pixel]) -> Int {
    Set(a.keys).union(b.keys).filter { a[$0] != b[$0] }.count
}

/// What the stage draws `seconds` after a frame began.
private func drawn(_ frame: SchedulerFrame, at seconds: Double) throws -> [CellPoint: Pixel] {
    cells(try stageRenderer.clawd(for: frame, now: seconds, blink: false))
}

@Suite("Bridges: the in-between pictures", .serialized)
struct BridgeArt {
    private var catalog: PetCatalog { stageRenderer.art.catalog }

    // MARK: what a bridge adds to a motion

    @Test func Bridge_aMotionsCatalogFramesAndPlayingTimeIncludeItsLeadAndItsTail() throws {
        // frames and milliseconds of the motion itself (the atlas entry) plus the bridge before it and after it
        let expected: [(id: String, frames: Int, ms: Int)] = [
            ("C1-jump", 12 + 1, 720 + 60), ("C2-celebrate", 15 + 1, 900 + 60), ("C11-boop", 11 + 1, 660 + 60),
            ("A34-arcade", 49 + 3 + 3, 4083 + 250 + 250), (GlideRide.motionID, 39 + 2, 3250 + 167),
        ]
        for item in expected {
            let motion = try #require(catalog.motion(id: item.id), "\(item.id)")
            #expect(motion.frameCount == item.frames, "\(item.id) frames")
            #expect(abs(motion.duration - Double(item.ms) / 1000) < 1e-9, "\(item.id) playing time \(motion.duration)")
        }
        #expect(try #require(catalog.motion(id: GlideRide.motionID)).frameCount == GlideRide.frameCount)
        // a motion without a bridge is what it was: A12-heart's 22 frames are the atlas entry's
        let heart = try #require(catalog.motion(id: "A12-heart"))
        #expect(heart.frameCount == (try stageRenderer.art.motion("A12-heart")).frames.count && heart.frameCount == 22)
        #expect(catalog.issues.isEmpty, "\(catalog.issues)")
    }

    @Test func Bridge_theClipPlaysLeadThenTheMotionThenTail() throws {
        let art = stageRenderer.art
        let c1 = try art.motion("C1-jump")
        #expect(c1.frames.count == 13 && c1.ms.first == 60 && c1.ms.count == 13 && c1.loopStart == 0)
        let ride = try art.motion(GlideRide.motionID)
        #expect(ride.frames.count == GlideRide.frameCount && Array(ride.ms.suffix(2)) == [83, 84])
        let arcade = try art.motion("A34-arcade")
        #expect(arcade.frames.count == 55 && Array(arcade.ms.prefix(3)) == [83, 84, 83] && Array(arcade.ms.suffix(3)) == [84, 83, 83])
        // the lead is its own picture, not the motion's first frame twice
        #expect(cells(try draw(c1, 0)) != cells(try draw(c1, 1)))
    }

    private func draw(_ clip: Clip, _ index: Int) throws -> ComposedClawd {
        StageCompose.compose(clip: clip, frameIndex: index, look: .plain)
    }

    // MARK: poses: the lead plays once and the loop repeats after it

    @Test func Bridge_aPosesLeadPlaysOnceAndTheLoopStartsAfterIt() throws {
        let dangle = try stageRenderer.art.pose("dangle")
        #expect(dangle.frames.count == 3 && dangle.ms == [60, 300, 300] && dangle.loopStart == 1 && dangle.loops)
        let at = { (t: Double) in dangle.index(at: t) }
        #expect(at(0) == 0 && at(0.059) == 0, "the lead")
        #expect(at(0.061) == 1 && at(0.359) == 1 && at(0.361) == 2 && at(0.659) == 2, "dangle#0, dangle#1")
        #expect(at(0.661) == 1 && at(0.961) == 2 && at(60.0 + 0.1) == 1, "then the loop repeats from dangle#0, never from the lead")
        #expect(abs(try #require(dangle.nextChange(after: 0.01)) - 0.05) < 1e-9)
        #expect(abs(try #require(dangle.nextChange(after: 0.7)) - 0.26) < 1e-9, "inside the loop's second pass")
        let hop = try stageRenderer.art.pose("hop")
        #expect(hop.frames.count == 5 && hop.ms == [60, 60, 150, 70, 60] && hop.loopStart == 1 && !hop.loops)
        #expect(hop.index(at: 0.01) == 0 && hop.index(at: 0.07) == 1 && hop.index(at: 0.5) == 4 && hop.index(at: 99) == 4)
    }

    @Test func Bridge_aLoopingClipWithoutALeadLoopsFromItsFirstFrame() {
        let frame = ClipFrame(raster: Raster(width: 1, height: 1), head: nil)
        let plain = Clip(id: "x", frames: [frame, frame, frame], ms: [100, 100, 100], loops: true)
        #expect(plain.loopStart == 0 && plain.index(at: 0.35) == 0 && plain.index(at: 0.05) == 0 && plain.index(at: 0.15) == 1)
        let led = Clip(id: "y", frames: [frame, frame, frame], ms: [100, 100, 100], loops: true, loopStart: 1)
        #expect(led.index(at: 0.05) == 0 && led.index(at: 0.15) == 1 && led.index(at: 0.25) == 2 && led.index(at: 0.35) == 1)
    }

    @Test func Bridge_aDragThatLostItsMotionFallsBackToDangleNumberZeroNotToTheLead() throws {
        // StageRenderer: a motion that is over while the scene goes on shows the scene's pose; for the drag that is dangle#0, the frame after the lead.
        let frame = SchedulerFrame(dragging: true, playback: MotionPlayback(source: .motion("A12-heart"), use: "idle", startedAt: 0, duration: 1))
        let dangle = try stageRenderer.art.pose("dangle")
        let want = cells(StageCompose.compose(clip: dangle, frameIndex: 1, look: .plain))
        #expect(try drawn(frame, at: 2.0) == want)
        #expect(want != cells(StageCompose.compose(clip: dangle, frameIndex: 0, look: .plain)), "and the lead is a different picture")
    }

    // MARK: the seams, drawn by the stage itself

    /// The pictures of one seam in the plain look: the rest picture, the bridge's frames, the target's frame at the seam.
    private func seam(_ id: String, side: String) throws -> (steps: [Int], direct: Int) {
        let rest = try drawn(Frames.rest(), at: 0)
        let kind = id.hasPrefix("dangle") || id.hasPrefix("hop") ? "pose" : "motion"
        let target = id.hasPrefix("dangle") ? "dangle" : id.hasPrefix("hop") ? "hop" : id.replacingOccurrences(of: "-lead", with: "").replacingOccurrences(of: "-tail", with: "")
        let clip = kind == "pose" ? try stageRenderer.art.pose(target) : try stageRenderer.art.motion(target)
        let bridge = try bridgeFrameCount(id)
        let range = side == "lead" ? 0..<bridge : (clip.frames.count - bridge)..<clip.frames.count
        func picture(_ k: Int) throws -> [CellPoint: Pixel] {
            let frame = kind == "pose" ? Frames.pose(target, scene: target == "hop" ? .sent : .drag) : Frames.motion(target)
            return try drawn(frame, at: middleOf(frame: k, in: clip))
        }
        let edge = try picture(side == "lead" ? range.upperBound : range.lowerBound - 1)
        let sequence = side == "lead" ? [rest] + (try range.map(picture)) + [edge] : [edge] + (try range.map(picture)) + [rest]
        return ((0..<(sequence.count - 1)).map { changed(sequence[$0], sequence[$0 + 1]) }, changed(sequence.first!, sequence.last!))
    }

    private func bridgeFrameCount(_ id: String) throws -> Int {
        let data = try Data(contentsOf: artDirectory.appendingPathComponent("clawd-atlas.json"))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let entry = try #require((root["bridges"] as? [[String: Any]])?.first { $0["id"] as? String == id }, "\(id)")
        return (entry["frames"] as? [Any])?.count ?? 0
    }

    @Test func Bridge_theStageDrawsEverySeamInStepsOfAtMostSevenTenthsOfTheJumpItReplaced() throws {
        let seams = [("dangle-lead", "lead"), ("hop-lead", "lead"), ("C1-jump-lead", "lead"), ("C2-celebrate-lead", "lead"), ("C11-boop-lead", "lead"),
                     ("A34-arcade-lead", "lead"), ("A34-arcade-tail", "tail")]
        for (id, side) in seams {
            let (steps, direct) = try seam(id, side: side)
            #expect(direct > 100, "\(id): the seam without the bridge changes \(direct) cells")
            #expect(steps.max()! * 10 <= direct * 7, "\(id): steps \(steps) of \(direct)")
        }
    }

    @Test func Bridge_theSkateboardsStopRisesToTheRestPictureInStepsOfAtMostSixtyCells() throws {
        let look = "skateboard"
        let ride = try stageRenderer.art.motion(GlideRide.motionID)
        let rest = try drawn(Frames.rest(look: look), at: 0)
        var previous = try drawn(Frames.motion(GlideRide.motionID, look: look), at: middleOf(frame: 38, in: ride))
        var steps: [Int] = []
        for k in 39..<GlideRide.frameCount {
            let now = try drawn(Frames.motion(GlideRide.motionID, look: look), at: middleOf(frame: k, in: ride))
            steps.append(changed(previous, now)); previous = now
        }
        steps.append(changed(previous, rest))
        #expect(steps.count == 3 && steps.max()! <= 60, "crouch, rise, rise, rest: \(steps) (the crouch to the rest picture in one step was 92)")
    }

    // MARK: a pose's lead reaches the scheduler's own playback

    @Test func Bridge_theSentSceneAndTheDragStartOnTheLeadFrame() throws {
        let hop = Frames.pose("hop", scene: .sent)
        let dangle = Frames.pose("dangle", scene: .drag)
        let hopClip = try stageRenderer.art.pose("hop"), dangleClip = try stageRenderer.art.pose("dangle")
        #expect(try drawn(hop, at: 0.01) == cells(StageCompose.compose(clip: hopClip, frameIndex: 0, look: .plain)))
        #expect(try drawn(dangle, at: 0.01) == cells(StageCompose.compose(clip: dangleClip, frameIndex: 0, look: .plain)))
        #expect(try drawn(dangle, at: 0.07) == cells(StageCompose.compose(clip: dangleClip, frameIndex: 1, look: .plain)))
    }
}
