import Testing
import Foundation
import CoreGraphics
import ClawdCore
import ClawdRendering

private func solid(_ w: Int, _ h: Int, _ colour: Pixel) -> Raster {
    var r = Raster(width: w, height: h); r.fill(x: 0, y: 0, width: w, height: h, colour); return r
}
private let art = stageRenderer.art
private let hatColour = Pixel(10, 200, 30), mugColour = Pixel(30, 30, 220), boardColour = Pixel(120, 60, 20), coatColour = Pixel(240, 240, 240)

/// Fixture looks, one per class, with colours Clawd's own art never uses. Real art for these classes arrives in later sprints; the
/// compositor is the same code.
private enum FixtureLooks {
    static let costume = LookArt(id: "fx-hat", classes: ["costume"], layers: [
        LookArt.Layer(name: "hat", z: .front, offset: CellPoint(-5, -6), raster: solid(10, 6, hatColour), takesClicks: true)])
    static let held = LookArt(id: "fx-mug", classes: ["held"], layers: [
        LookArt.Layer(name: "mug", z: .front, offset: CellPoint(10, 2), raster: solid(5, 5, mugColour), takesClicks: false)], layerOnSignature: false, signature: ["A19-coffee"])
    static let underFeet = LookArt(id: "fx-board", classes: ["under-feet"], layers: [
        LookArt.Layer(name: "board", z: .front, anchor: .feet, offset: CellPoint(2, -3), raster: solid(20, 3, boardColour), takesClicks: false)], raise: 3)
    static let torso = LookArt(id: "fx-coat", classes: ["torso-overlay"], layers: [
        LookArt.Layer(name: "coat", z: .front, offset: CellPoint(-8, 6), raster: solid(16, 4, coatColour), takesClicks: true)])
    static let bodyColour = LookArt(id: "fx-purple", classes: ["body-color"], layers: [], bodyMap: [0xD77757: 0xAF87FF])
    static let behind = LookArt(id: "fx-halo", classes: ["costume"], layers: [
        LookArt.Layer(name: "halo", z: .back, offset: CellPoint(-8, -2), raster: solid(16, 14, hatColour), takesClicks: true)])
    static let all = [costume, held, underFeet, torso, bodyColour, behind]
}

@Suite("Looks compose onto frames", .serialized)
struct StageLookTests {
    private func restFrame(_ look: LookArt, layersOn: Bool = true, mirrored: Bool = false) throws -> ComposedClawd {
        StageCompose.compose(clip: try art.pose("idle"), frameIndex: 0, look: look, layersOn: layersOn, mirrored: mirrored)
    }
    private func pixel(_ c: ComposedClawd, canvasX: Int, canvasY: Int) -> Pixel { c.raster[c.canvasOrigin.x + canvasX, c.canvasOrigin.y + canvasY] }

    @Test func Looks_theHelmetOnTheRestPosesIsExactlyV1sHelmetFrames() throws {
        // v1 shipped helmet-idle and helmet-listen as frames of their own; the look layer on the plain poses must reproduce them.
        let helmet = try art.look("helmet")
        for (name, helmetName) in [("idle", "helmet-idle"), ("listen", "helmet-listen")] {
            let clip = try art.pose(name), reference = try art.pose(helmetName)
            for k in clip.frames.indices {
                let composed = StageCompose.compose(clip: clip, frameIndex: k, look: helmet)
                let expected = reference.frames[k].raster
                #expect(composed.raster == expected, "\(name)_\(k) with the helmet differs from \(helmetName)_\(k)")
            }
        }
    }

    @Test func Looks_everyLayerSitsAtTheHeadAnchorPlusItsOffsetOnEveryV1PoseFrame() throws {
        for id in ["helmet", "sunglasses", "headphones"] {
            let look = try art.look(id)
            for layer in look.layers {
                for (pose, positions) in layer.restPoses {
                    let clip = try art.pose(pose)
                    // the v1 frames of the pose, after the art's lead bridge (which has its own head anchor)
                    let own = Array(clip.frames.dropFirst(clip.loopStart))
                    #expect(own.count == positions.count, "\(id) \(pose): frame count")
                    for (k, position) in positions.enumerated() where k < own.count {
                        let head = try #require(own[k].head)
                        #expect(CellPoint(head.x + layer.offset.x, head.y + layer.offset.y) == position, "\(id) \(layer.name) \(pose)_\(k)")
                    }
                }
            }
        }
    }

    @Test func Looks_aLayerIsDrawnAtItsAnchorOnEveryFrameOfEveryCompatibleMotion() throws {
        var checked = 0
        for motion in art.catalog.motions {
            for lookID in motion.compatibleLooks ?? [] where lookID != "plain" {
                let look = try art.look(lookID)
                guard !look.signature.contains(motion.id), !look.layers.isEmpty else { continue }      // a body-colour look without a layer (Ultra) needs no head
                let clip = try art.motion(motion.id)
                for (k, frame) in clip.frames.enumerated() {
                    guard let head = frame.head else { Issue.record("\(motion.id) is listed for \(lookID) but frame \(k) has no head"); continue }
                    let composed = StageCompose.compose(clip: clip, frameIndex: k, look: look)
                    for layer in look.layers where layer.z == .front {
                        // Head anchored layers sit at the head (lifted with Clawd by the look's raise); feet anchored ones at the canvas' bottom.
                        let origin = layer.anchor == .feet ? CellPoint(layer.offset.x, 24 + layer.offset.y)
                                                           : CellPoint(head.x + layer.offset.x, head.y - look.raise + layer.offset.y)
                        for y in 0..<layer.raster.height { for x in 0..<layer.raster.width where layer.raster.isOpaque(x, y) {
                            let got = pixel(composed, canvasX: origin.x + x, canvasY: origin.y + y)
                            // An opaque layer pixel shows as itself; a translucent one (the shiny overlay) shows blended over what is under it.
                            let drawn = layer.raster[x, y].a == 255 ? got == layer.raster[x, y] : got.a != 0
                            if !drawn { Issue.record("\(motion.id)/\(lookID) frame \(k): layer pixel (\(x),\(y)) not at its anchor"); return }
                        } }
                    }
                    checked += 1
                }
            }
        }
        #expect(checked > 1000, "only \(checked) frames checked")
    }

    @Test func Looks_aSignatureMotionIsNotDrawnOverWhenTheLookDrawsItsOwnProp() throws {
        let headphones = try art.look("headphones")
        #expect(headphones.layerOnSignature == false)
        let signature = try #require(headphones.signature.first)
        let request = StageRequest(frame: Frames.motion(signature, look: "headphones"), now: 1.0, geometry: Screens.geometry())
        let withLook = try #require(try stageRenderer.compose(request))
        let plain = try #require(try stageRenderer.compose(StageRequest(frame: Frames.motion(signature, look: "plain"), now: 1.0, geometry: Screens.geometry())))
        #expect(withLook.pixels == plain.pixels, "the layer was composed onto its own signature motion")
    }

    @Test func Looks_fixtureCostumeGoesAboveTheHeadAndTakesClicks() throws {
        let c = try restFrame(FixtureLooks.costume)
        let head = try #require(c.head)
        #expect(pixel(c, canvasX: head.x - 5, canvasY: head.y - 6) == hatColour)
        #expect(pixel(c, canvasX: head.x + 4, canvasY: head.y - 1) == hatColour)
        #expect(pixel(c, canvasX: head.x + 5, canvasY: head.y - 1) == .clear)
        #expect(c.hit.isOpaque(c.canvasOrigin.x + head.x, c.canvasOrigin.y + head.y - 3), "costume pixels take clicks")
        #expect(c.headTopRow == head.y - 6, "H rises to the top of the costume")
    }

    @Test func Looks_fixtureHeldPropIsDrawnButTakesNoClicks() throws {
        let c = try restFrame(FixtureLooks.held)
        let head = try #require(c.head)
        #expect(pixel(c, canvasX: head.x + 10, canvasY: head.y + 2) == mugColour)
        #expect(!c.hit.isOpaque(c.canvasOrigin.x + head.x + 12, c.canvasOrigin.y + head.y + 3), "a held prop is not part of the hit region")
        #expect(c.headTopRow == head.y, "a held prop does not move H")
        // Its own signature motion draws the mug itself.
        let plain = StageCompose.compose(clip: try art.motion("A19-coffee"), frameIndex: 3, look: .plain)
        let signature = StageCompose.compose(clip: try art.motion("A19-coffee"), frameIndex: 3, look: FixtureLooks.held, layersOn: false)
        #expect(plain.raster == signature.raster)
    }

    @Test func Looks_fixtureUnderFeetLiftsClawdAndLeavesTheBoardOnTheBaseline() throws {
        let base = try restFrame(.plain), lifted = try restFrame(FixtureLooks.underFeet)
        let head = try #require(lifted.head)
        #expect(head.y == (try #require(base.head)).y - 3, "Clawd is raised by the board's height")
        // The torso's top row is 3 cells higher; the board fills the last 3 rows of the canvas.
        func firstBodyRow(_ c: ComposedClawd) -> Int { (0..<c.raster.height).first { y in (0..<c.raster.width).contains { c.raster[$0, y] == Pixel(215, 119, 87) } }! - c.canvasOrigin.y }
        #expect(firstBodyRow(lifted) == firstBodyRow(base) - 3)
        for y in 21..<24 { #expect(pixel(lifted, canvasX: 10, canvasY: y) == boardColour, "board row \(y)") }
        #expect(pixel(lifted, canvasX: 10, canvasY: 20) != boardColour)
        #expect(!lifted.hit.isOpaque(lifted.canvasOrigin.x + 10, lifted.canvasOrigin.y + 22), "the board takes no clicks")
        #expect(lifted.canvasRect.width == 24 && lifted.canvasRect.height == 24)
    }

    @Test func Looks_fixtureTorsoOverlayCoversTheBodyAndTakesClicks() throws {
        let c = try restFrame(FixtureLooks.torso)
        let head = try #require(c.head)
        #expect(pixel(c, canvasX: head.x, canvasY: head.y + 7) == coatColour)
        #expect(c.hit.isOpaque(c.canvasOrigin.x + head.x, c.canvasOrigin.y + head.y + 7))
        #expect(c.headTopRow == head.y, "a coat below the head does not move H")
    }

    @Test func Looks_fixtureBodyColourRecolorsTheBodyAndNothingElse() throws {
        let plain = try restFrame(.plain), purple = try restFrame(FixtureLooks.bodyColour)
        var recoloured = 0
        for y in 0..<plain.raster.height { for x in 0..<plain.raster.width {
            let before = plain.raster[x, y], after = purple.raster[x, y]
            if before == Pixel(215, 119, 87) { #expect(after == Pixel(175, 135, 255)); recoloured += 1 }
            else { #expect(after == before) }
        } }
        #expect(recoloured > 200)
        #expect(purple.hit == plain.hit, "a recoloured body takes clicks exactly where the plain one does")
    }

    @Test func Looks_aBackLayerIsDrawnBehindTheBody() throws {
        let c = try restFrame(FixtureLooks.behind)
        let head = try #require(c.head)
        #expect(pixel(c, canvasX: head.x, canvasY: head.y + 2) == Pixel(215, 119, 87), "the body wins over a back layer")
        #expect(pixel(c, canvasX: head.x, canvasY: head.y - 1) == hatColour)
    }

    @Test func Looks_aMirroredPictureIsTheUnmirroredOneFlippedAboutTheCanvasCentre() throws {
        for look in [LookArt.plain, FixtureLooks.held, FixtureLooks.costume] {
            let clip = try art.motion("A5-walking")
            for k in [0, 9, 17] {
                let a = StageCompose.compose(clip: clip, frameIndex: k, look: look)
                let b = StageCompose.compose(clip: clip, frameIndex: k, look: look, mirrored: true)
                #expect(b.raster.width == a.raster.width)
                for y in 0..<a.raster.height { for cx in -a.canvasOrigin.x..<(a.raster.width - a.canvasOrigin.x) {
                    #expect(a.raster[a.canvasOrigin.x + cx, y] == b.raster[b.canvasOrigin.x + (23 - cx), y], "frame \(k) cell (\(cx),\(y))")
                } }
                #expect(b.head?.x == 24 - (a.head?.x ?? 0))
            }
        }
    }

    @Test func Looks_theBodyIsOnlyBodyColoursAndTheEyesInsideTheTorso() throws {
        // A black pixel of a prop (A1's bubble dots) is not Clawd; his own eyes are.
        let clip = try art.motion("A1-thinking")
        let c = StageCompose.compose(clip: clip, frameIndex: 10, look: .plain)
        var eyes = 0, propBlack = 0
        for y in 0..<c.raster.height { for x in 0..<c.raster.width where c.raster[x, y] == Pixel(20, 20, 19) {
            if c.hit.isOpaque(x, y) { eyes += 1 } else { propBlack += 1 }
        } }
        #expect(eyes == 6, "frame 10 has two half-closed eyes of 3 cells each, got \(eyes)")
        #expect(propBlack == 1, "the bubble's dot must stay outside the hit region, got \(propBlack)")
    }

    @Test func Looks_theCatalogsCostumesTakeClicksAndItsHeldPropsDoNot() throws {
        for id in ["helmet", "sunglasses", "headphones"] {
            let look = try art.look(id)
            #expect(look.classes == ["costume"] && !look.layers.isEmpty && look.layers.allSatisfy(\.takesClicks), "\(id)")
        }
        for id in ["coffee", "wand"] {
            let look = try art.look(id)
            #expect(look.classes == ["held"] && !look.layers.isEmpty && look.layers.allSatisfy { !$0.takesClicks }, "\(id)")
            let c = StageCompose.compose(clip: try art.pose("idle"), frameIndex: 0, look: look)
            let plain = StageCompose.compose(clip: try art.pose("idle"), frameIndex: 0, look: .plain)
            let head = try #require(c.head)
            // the prop is drawn, and the hit region is exactly Clawd's own (a mug over his arm does not make the mug clickable elsewhere)
            for layer in look.layers {
                var drawn = 0
                for y in 0..<layer.raster.height { for x in 0..<layer.raster.width where layer.raster.isOpaque(x, y) {
                    if c.raster.isOpaque(c.canvasOrigin.x + head.x + layer.offset.x + x, c.canvasOrigin.y + head.y + layer.offset.y + y) { drawn += 1 }
                } }
                #expect(drawn > 0, "\(id) \(layer.name) is drawn")
            }
            for cy in -c.canvasOrigin.y..<(c.raster.height - c.canvasOrigin.y) { for cx in -c.canvasOrigin.x..<(c.raster.width - c.canvasOrigin.x) {
                let inHeld = c.hit.isOpaque(c.canvasOrigin.x + cx, c.canvasOrigin.y + cy)
                let inPlain = plain.hit.isOpaque(plain.canvasOrigin.x + cx, plain.canvasOrigin.y + cy)
                if inHeld != inPlain { Issue.record("\(id): the hit region differs from the plain body at canvas cell (\(cx),\(cy))"); return }
            } }
        }
    }

    @Test func Looks_everyLookIsRegisteredWithTheClassesTheSpecNames() throws {
        for id in art.lookIDs {
            let look = try art.look(id)
            #expect(!look.classes.isEmpty)
            #expect(look.classes.isSubset(of: ["plain", "costume", "held", "under-feet", "torso-overlay", "body-color"]), "\(id): \(look.classes)")
        }
    }
}

@Suite("Look change frames", .serialized)
struct LookTransitionTests {
    private func frame(_ k: Int, from: String, to: String) throws -> ComposedClawd {
        try LookTransition.compose(art: art, from: try art.look(from), to: try art.look(to), frame: k)
    }
    private func rest(_ look: String) throws -> ComposedClawd { try StageCompose.compose(clip: art.pose("idle"), frameIndex: 0, look: art.look(look)) }

    @Test func Transition_theFirstFrameIsTheOldLooksRestPictureAndTheLastTheNewOnes() throws {
        for from in ["plain", "helmet", "sunglasses", "headphones"] { for to in ["plain", "helmet", "sunglasses", "headphones"] where from != to {
            #expect(try frame(0, from: from, to: to).raster == rest(from).raster, "\(from)->\(to) first")
            #expect(try frame(LookTransition.frameCount - 1, from: from, to: to).raster == rest(to).raster, "\(from)->\(to) last")
        } }
    }

    @Test func Transition_takesAtMostTwoSecondsAndTheSchedulerGivesItOneAndAHalf() throws {
        let scheduled = 1.6
        #expect(scheduled <= 2.0)
        #expect(Double(LookTransition.frameCount) * 0.08 == scheduled, "20 frames of 80 ms")
        var seen = Set<Int>()
        for i in 0...1600 { seen.insert(LookTransition.frameIndex(progress: Double(i) / 1600)) }
        #expect(seen == Set(0..<LookTransition.frameCount), "every frame is reachable and no other index is")
    }

    @Test func Transition_theBodySinksBelowTheBaselineAndTheStageClipsIt() throws {
        for look in ["plain", "helmet", "headphones"] {
            var previousTop = -1
            for k in 0..<LookTransition.sinkFrames {
                let c = try frame(k, from: look, to: "plain")
                let baseline = c.canvasOrigin.y + 24
                // nothing at or below the baseline except dust
                for y in baseline..<c.raster.height { for x in 0..<c.raster.width { #expect(c.raster[x, y].isClear, "\(look) \(k): pixel below the baseline") } }
                let body = (0..<c.raster.height).first { y in (0..<c.raster.width).contains { c.raster[$0, y] == Pixel(215, 119, 87) } }
                if let body { #expect(body > previousTop, "\(look) \(k): not sinking"); previousTop = body }
            }
            let hidden = try frame(LookTransition.sinkFrames - 1, from: look, to: "plain")
            let dustless = (0..<hidden.raster.height).allSatisfy { y in (0..<hidden.raster.width).allSatisfy { hidden.raster[$0, y].isClear } }
            #expect(dustless, "\(look): the lowest frame is empty")
        }
    }

    @Test func Transition_aLookThatDrawsBelowTheBaselineIsClippedToo() throws {
        // A layer fixed to the canvas that hangs 6 cells under the baseline: at rest it is drawn, while Clawd sinks the stage clips it.
        let skirt = LookArt(id: "fx-skirt", classes: ["costume"], layers: [
            LookArt.Layer(name: "skirt", z: .front, anchor: .canvas, offset: CellPoint(4, 20), raster: solid(16, 10, Pixel(10, 200, 30)), takesClicks: true)])
        let rest = try LookTransition.compose(art: art, from: skirt, to: .plain, frame: 0)
        #expect(rest.raster.height > rest.canvasOrigin.y + 24, "the fixture really draws below the baseline")
        for k in 1..<LookTransition.sinkFrames {
            let c = try LookTransition.compose(art: art, from: skirt, to: .plain, frame: k)
            let baseline = c.canvasOrigin.y + 24
            for y in baseline..<c.raster.height { for x in 0..<c.raster.width {
                #expect(c.raster[x, y].isClear && c.hit[x, y].isClear, "frame \(k): a pixel below the baseline at (\(x),\(y))")
            } }
        }
    }

    @Test func Transition_dustSitsOnlyWhereClaudeCodesJumpPutsIt() throws {
        let allowed = Set((LookTransition.dotPuff + LookTransition.wavePuff).flatMap { u in
            [CellPoint(u.x * 2, u.y * 2), CellPoint(u.x * 2 + 1, u.y * 2), CellPoint(u.x * 2, u.y * 2 + 1), CellPoint(u.x * 2 + 1, u.y * 2 + 1)] })
        #expect(LookTransition.dotPuff == [CellPoint(0, 11), CellPoint(11, 11)])
        #expect(LookTransition.wavePuff == [CellPoint(0, 10), CellPoint(1, 11), CellPoint(10, 11), CellPoint(11, 10)])
        #expect(LookTransition.dust == Pixel(153, 153, 153))
        var dustFrames = 0
        for k in 0..<LookTransition.frameCount {
            let c = try frame(k, from: "helmet", to: "headphones")
            var any = false
            for y in 0..<c.raster.height { for x in 0..<c.raster.width where c.raster[x, y] == LookTransition.dust {
                any = true
                #expect(allowed.contains(CellPoint(x - c.canvasOrigin.x, y - c.canvasOrigin.y)), "frame \(k): dust at (\(x - c.canvasOrigin.x), \(y - c.canvasOrigin.y))")
            } }
            if any { dustFrames += 1 }
        }
        #expect(dustFrames == 4, "a dot puff and a wave puff going down, and the same coming up")
    }

    @Test func Transition_theLookSwapsAtTheMiddleWhereNothingIsShown() throws {
        let down = try frame(LookTransition.sinkFrames - 1, from: "helmet", to: "headphones"), up = try frame(LookTransition.sinkFrames, from: "helmet", to: "headphones")
        #expect(down.raster == up.raster, "the two lowest frames are the same empty stage")
    }
}
