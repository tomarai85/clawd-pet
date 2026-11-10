import Testing
import Foundation
import ClawdCore
import ClawdRendering

/// A look's signature motion never shows Clawd without the look's props (SignatureSpan.swift; Tom, 2026-11-08: "after animation there's a
/// glich that clawd turn out to original looks for 0.2 sec").
@Suite("Signature motions keep their look", .serialized)
struct SignatureSpanTests {
    private let art = stageRenderer.art
    private let pairs: [(look: String, motion: String, span: ClosedRange<Int>)] = [
        ("detective", "D12-inspect", 17...103), ("coffee", "A19-coffee", 6...26),
        ("headphones", "A18-headphones", 10...65), ("wand", "A25-spark", 5...66),
    ]

    /// The middle of frame `k`'s time on screen, from the clip's start.
    private func time(_ clip: Clip, _ k: Int) -> Double { (Double(clip.ms[0..<k].reduce(0, +)) + Double(clip.ms[k]) / 2) / 1000 }
    /// What the renderer draws when the look stands at rest: the idle pose with the look's layers on.
    private func restPicture(_ look: LookArt) throws -> Raster {
        StageCompose.compose(clip: try art.pose("idle"), frameIndex: 0, look: look).raster
    }
    private func drawn(_ frame: SchedulerFrame, at now: Double) throws -> Raster {
        try stageRenderer.clawd(for: frame, now: now, blink: false).raster
    }
    private func motionFrame(_ id: String, look: String, duration: Double, loops: Bool = false, holds: Bool = false, mirrored: Bool = false,
                             dragging: Bool = false) -> SchedulerFrame {
        SchedulerFrame(dragging: dragging, playback: MotionPlayback(source: .motion(id), use: "idle", startedAt: 0, duration: duration, loops: loops,
                                                                    holdsLastFrame: holds, mirrored: mirrored), look: look)
    }

    @Test func SignatureSpan_theSpansFitTheShippedAtlas() throws {
        let atlas = try JSONSerialization.jsonObject(with: Data(contentsOf: artDirectory.appendingPathComponent("clawd-atlas.json"))) as? [String: Any]
        let motions = (atlas?["motions"] as? [[String: Any]]) ?? []
        #expect(SignatureSpan.spans.count == pairs.count)
        for (lookID, motionID, span) in pairs {
            #expect(SignatureSpan.span(look: lookID, motion: motionID) == span, "\(lookID) \(motionID): the judged span is \(span)")
            let look = try art.look(lookID), clip = try art.motion(motionID)
            #expect(look.signature.contains(motionID) && !look.layerOnSignature && !look.layers.isEmpty, "\(lookID) draws no layer on \(motionID)")
            // clip indices are the atlas' own frame indices: no bridge sits before the motion's frames
            let own = (motions.first { $0["id"] as? String == motionID }?["frames"] as? [Any])?.count
            #expect(own == clip.frames.count, "\(motionID): the clip has \(clip.frames.count) frames, the atlas \(own ?? -1)")
            #expect(span.lowerBound > 0 && span.upperBound < clip.frames.count - 1, "\(motionID): \(span) inside 1..<\(clip.frames.count - 1)")
        }
    }

    @Test func SignatureSpan_everyLookThatHidesItsLayersOnASignatureHasASpan() throws {
        var checked = 0
        for id in art.lookIDs {
            let look = try art.look(id)
            guard !look.layerOnSignature, !look.layers.isEmpty else { continue }
            for motion in look.signature {
                checked += 1
                let covered = SignatureSpan.span(look: id, motion: motion) != nil || SignatureSpan.wholeMotion[id]?.contains(motion) == true
                #expect(covered, "look \(id) draws no layer on its signature \(motion), which has no span: its first and last frames would show Clawd without the look")
            }
        }
        #expect(checked == 5, "detective, coffee, headphones, wand and the skateboard: \(checked)")
    }

    @Test func SignatureSpan_atEveryIndexTheLookShowsItsRestPictureOrItsOwnFrame() throws {
        for (lookID, motionID, span) in pairs {
            let look = try art.look(lookID), clip = try art.motion(motionID), rest = try restPicture(look)
            let frame = motionFrame(motionID, look: lookID, duration: clip.duration)
            for k in clip.frames.indices {
                let picture = try drawn(frame, at: time(clip, k))
                if span.contains(k) {
                    let own = StageCompose.compose(clip: clip, frameIndex: k, look: look, layersOn: false).raster
                    #expect(picture == own, "\(lookID) \(motionID) frame \(k) inside \(span): the motion's own frame, layers off")
                } else {
                    #expect(picture == rest, "\(lookID) \(motionID) frame \(k) outside \(span): the look's rest picture, layers on")
                }
            }
        }
    }

    @Test func SignatureSpan_otherLooksPlayTheWholeMotion() throws {
        // Plain wears no props: D12-inspect's hat going on (9) and being tossed (108) play as they are.
        let clip = try art.motion("D12-inspect"), plain = try art.look("plain")
        let frame = motionFrame("D12-inspect", look: "plain", duration: clip.duration)
        for k in [0, 9, 108, 112] {
            #expect(try drawn(frame, at: time(clip, k)) == StageCompose.compose(clip: clip, frameIndex: k, look: plain).raster, "plain D12-inspect frame \(k)")
        }
        // Ultra hides no layer (it has none): its signature A25-spark plays whole, the lead and tail included.
        let spark = try art.motion("A25-spark"), ultra = try art.look("ultra")
        let sparkFrame = motionFrame("A25-spark", look: "ultra", duration: spark.duration)
        for k in [0, 4, 70] {
            #expect(try drawn(sparkFrame, at: time(spark, k)) == StageCompose.compose(clip: spark, frameIndex: k, look: ultra, layersOn: false).raster,
                    "ultra A25-spark frame \(k)")
        }
    }

    @Test func SignatureSpan_loopsHoldsEndsMirrorsAndDragsKeepTheLook() throws {
        let look = try art.look("detective"), clip = try art.motion("D12-inspect"), rest = try restPicture(look)
        let s = 17, e = 103
        // a loop's second cycle
        let looping = motionFrame("D12-inspect", look: "detective", duration: clip.duration, loops: true)
        #expect(try drawn(looping, at: clip.duration + time(clip, 0)) == rest, "second cycle, frame 0")
        #expect(try drawn(looping, at: clip.duration + time(clip, s - 1)) == rest, "second cycle, frame \(s - 1)")
        #expect(try drawn(looping, at: clip.duration + time(clip, s)) == StageCompose.compose(clip: clip, frameIndex: s, look: look, layersOn: false).raster,
                "second cycle, frame \(s)")
        // a held last frame
        let held = motionFrame("D12-inspect", look: "detective", duration: clip.duration, holds: true)
        #expect(try drawn(held, at: clip.duration + 5) == rest, "held last frame")
        // a motion that ended while its scene goes on: the scene's pose with the layers on
        let ended = motionFrame("D12-inspect", look: "detective", duration: clip.duration)
        let idle = try art.pose("idle")
        #expect(try drawn(ended, at: clip.duration + 1) == StageCompose.compose(clip: idle, frameIndex: idle.loopStart, look: look).raster, "ended")
        // mirrored: the rest picture outside the span, the mirrored own frame inside
        let mirrored = motionFrame("D12-inspect", look: "detective", duration: clip.duration, mirrored: true)
        #expect(try drawn(mirrored, at: time(clip, e + 1)) == rest, "mirrored, frame \(e + 1)")
        #expect(try drawn(mirrored, at: time(clip, e)) == StageCompose.compose(clip: clip, frameIndex: e, look: look, layersOn: false, mirrored: true).raster,
                "mirrored, frame \(e)")
        // dragged while the motion plays
        let dragged = motionFrame("D12-inspect", look: "detective", duration: clip.duration, dragging: true)
        #expect(try drawn(dragged, at: time(clip, s - 1)) == rest, "dragged, frame \(s - 1)")
    }
}
