import Testing
import Foundation
import CoreGraphics
@testable import ClawdCore
import ClawdRendering

// Amendment "the skateboard ride": the pictures. The real art, drawn through the real StageRenderer.

private let boardColours: Set<UInt32> = [0x561B2F, 0xEFAC54]
private func colour(_ p: Pixel) -> UInt32 { UInt32(p.r) << 16 | UInt32(p.g) << 8 | UInt32(p.b) }

/// A board pixel in canvas coordinates: where it is and what colour it has.
private struct BoardPixel: Hashable { var x: Int, y: Int, rgba: Pixel }

private func boardPixels(_ composed: ComposedClawd) -> Set<BoardPixel> {
    var out = Set<BoardPixel>()
    for y in 0..<composed.raster.height { for x in 0..<composed.raster.width {
        let p = composed.raster[x, y]
        if p.a == 255, boardColours.contains(colour(p)) { out.insert(BoardPixel(x: x - composed.canvasOrigin.x, y: y - composed.canvasOrigin.y, rgba: p)) }
    } }
    return out
}
private func occupied(_ pixels: Set<BoardPixel>) -> Set<CellPoint> { Set(pixels.map { CellPoint($0.x, $0.y) }) }

/// The glide frame the scheduler would hand the renderer with the ride held on motion frame `k`.
private func held(_ k: Int, mirrored: Bool = false) throws -> SchedulerFrame {
    var ride = try #require(GlideRide.plan(travel: 5, resumed: false, random: { 0.99 }))
    ride.held = k
    return SchedulerFrame(playback: MotionPlayback(source: .glide, use: "walk", startedAt: 0, duration: 0.001, loops: true, mirrored: mirrored, ride: ride),
                          look: "skateboard")
}

private func restPicture() throws -> ComposedClawd { try stageRenderer.clawd(for: Frames.rest(look: "skateboard"), now: 0, blink: false) }
private func rideFrame(_ k: Int, mirrored: Bool = false) throws -> ComposedClawd {
    try stageRenderer.clawd(for: try held(k, mirrored: mirrored), now: 0, blink: false)
}

@Suite("SkateRide: the pictures of a glide", .serialized)
struct SkateRideStage {
    @Test func SkateRide_aGlideDrawsRideFramesNotTheRestPicture() throws {
        // The middle of a 3 s rightward glide that began at 10 s.
        let ride = try #require(GlideRide.plan(travel: 3, resumed: false, random: { 0.99 }))
        let playback = MotionPlayback(source: .glide, use: "walk", startedAt: 10, duration: 0.001, loops: true, mirrored: false, ride: ride)
        let frame = SchedulerFrame(playback: playback, look: "skateboard", walkOffset: 60)
        let drawn = try stageRenderer.clawd(for: frame, now: 11.5, blink: false)
        let index = ride.frame(at: 1.5)
        #expect((GlideRide.start.upperBound..<GlideRide.stop.lowerBound).contains(index), "the middle of the glide is a cruise frame: \(index)")
        let clip = try stageRenderer.art.motion(GlideRide.motionID)
        let look = try stageRenderer.art.look("skateboard")
        let want = StageCompose.compose(clip: clip, frameIndex: index, look: look, layersOn: false)
        #expect(drawn.raster == want.raster, "the picture is D14-ride frame \(index) with the look's layers off")
        #expect(drawn.raster != (try restPicture()).raster, "and not the rest picture")
    }

    @Test func SkateRide_aGlideWithNoRideKeepsTheRestPicture() throws {
        let frame = SchedulerFrame(playback: MotionPlayback(source: .glide, use: "walk", startedAt: 0, duration: 0.001, loops: true), look: "skateboard")
        #expect(try stageRenderer.clawd(for: frame, now: 1, blink: false).raster == (try restPicture()).raster)
    }

    @Test func SkateRide_aLeftwardGlideFrameIsThePixelMirrorOfTheRightwardOneAtTheSameTime() throws {
        let ride = try #require(GlideRide.plan(travel: 4, resumed: false, random: { 0.99 }))
        func drawn(mirrored: Bool) throws -> ComposedClawd {
            let playback = MotionPlayback(source: .glide, use: "walk", startedAt: 0, duration: 0.001, loops: true, mirrored: mirrored, ride: ride)
            return try stageRenderer.clawd(for: SchedulerFrame(playback: playback, look: "skateboard"), now: 2.0, blink: false)
        }
        let right = try drawn(mirrored: false), left = try drawn(mirrored: true)
        #expect(right.raster.flippedHorizontally() == left.raster, "the leftward frame is the mirror of the rightward one")
        #expect(right.raster != left.raster, "and the cruise frame is not symmetric, so a missing mirror shows")
        #expect(left.head.map { $0.x } == right.head.map { StageGeometry.canvasCells - $0.x })
        // At every moment of the glide, the stop frames included.
        var elapsed = 0.0, asymmetric = 0
        while elapsed < 4.0 {
            let playback = { (mirrored: Bool) in MotionPlayback(source: .glide, use: "walk", startedAt: 0, duration: 0.001, loops: true, mirrored: mirrored, ride: ride) }
            let a = try stageRenderer.clawd(for: SchedulerFrame(playback: playback(false), look: "skateboard"), now: elapsed, blink: false)
            let b = try stageRenderer.clawd(for: SchedulerFrame(playback: playback(true), look: "skateboard"), now: elapsed, blink: false)
            #expect(a.raster.flippedHorizontally() == b.raster, "at \(elapsed) s")
            if a.raster != b.raster { asymmetric += 1 }
            elapsed += 0.05
        }
        #expect(asymmetric > 60, "most frames of a glide are not symmetric: \(asymmetric) of 80")
    }

    @Test func SkateRide_theFirstAndTheLastRideFrameCarryTheRestPicturesBoardPixelForPixel() throws {
        let rest = boardPixels(try restPicture())
        #expect(rest.count == 60, "the rest picture's board is 60 cells")
        for k in [0, GlideRide.frameCount - 1] {
            #expect(boardPixels(try rideFrame(k)) == rest, "motion frame \(k): coordinates and RGBA of the board")
            // Leftward: the occupied cells are the same; the wheel interiors may read as one more turn of the wheel.
            #expect(occupied(boardPixels(try rideFrame(k, mirrored: true))) == occupied(rest), "motion frame \(k) mirrored: the occupied cells")
        }
        #expect(boardPixels(try rideFrame(GlideRide.cruiseFirst)) == rest, "sprite frame 32, where a cruise without start begins, has the rest picture's board")
        #expect(boardPixels(try rideFrame(GlideRide.cruiseA.lowerBound)) != rest, "sprite frame 31 does not: the wheels turn")
    }

    @Test func SkateRide_aMirroredBoardHasTheSameOccupiedCellsAndOnlyWheelInteriorsDiffer() throws {
        let rest = boardPixels(try restPicture())
        let flipped = boardPixels(try rideFrame(0, mirrored: true))
        #expect(occupied(flipped) == occupied(rest))
        #expect(flipped.symmetricDifference(rest).count == 2 * 8, "8 wheel-interior cells read as one more step of the wheel")
    }

    @Test func SkateRide_aCruiseFrameKeepsTheHeadWhereTheRestPictureHasIt() throws {
        // Placement (R3-2): the frames are stored for the compositor's raise, so Clawd is exactly as high as in the rest picture.
        let rest = try restPicture()
        for k in [GlideRide.cruiseA.lowerBound, GlideRide.cruiseFirst] {
            #expect(try rideFrame(k).head == rest.head, "motion frame \(k)")
        }
    }

    @Test func SkateRide_theRideFramesStayInsideTheDeclaredExtentRightwardAndMirrored() throws {
        for mirrored in [false, true] {
            var minX = 99, maxX = -99, minY = 99, maxY = -99
            for k in 0..<GlideRide.frameCount {
                let c = try rideFrame(k, mirrored: mirrored)
                let b = try #require(c.raster.opaqueBounds)
                minX = min(minX, b.minX - c.canvasOrigin.x); maxX = max(maxX, b.maxX - c.canvasOrigin.x)
                minY = min(minY, b.minY - c.canvasOrigin.y); maxY = max(maxY, b.maxY - c.canvasOrigin.y)
            }
            let canvas = StageGeometry.canvasCells
            #expect(minX >= (mirrored ? -1 : 0) && maxX <= (mirrored ? canvas - 1 : canvas), "mirrored \(mirrored): x \(minX)...\(maxX)")
            #expect(minY >= -5 && maxY <= canvas - 1, "mirrored \(mirrored): y \(minY)...\(maxY): at most 2.5 units above the canvas and nothing below its baseline")
        }
    }

    @Test func SkateRide_theBoardLayerIsOffWhileTheRideDrawsItsOwnBoard() throws {
        let look = try stageRenderer.art.look("skateboard")
        #expect(look.signature.contains(GlideRide.motionID) && !look.layerOnSignature)
        let clip = try stageRenderer.art.motion(GlideRide.motionID)
        let drawn = try rideFrame(10)
        #expect(drawn.raster == StageCompose.compose(clip: clip, frameIndex: 10, look: look, layersOn: false).raster)
        #expect(drawn.raster != StageCompose.compose(clip: clip, frameIndex: 10, look: look, layersOn: true).raster, "the look's board layer would draw a second board")
    }

    @Test func SkateRide_theGlideRedrawsLieOnAFixedGridWhateverTheHandlingDelay() throws {
        let geometry = Screens.geometry()
        let moving = SchedulerFrame(playback: MotionPlayback(source: .glide, use: "walk", startedAt: 0, duration: 0.001, loops: true,
                                                             ride: GlideRide.plan(travel: 5, resumed: false, random: { 0.99 })), look: "skateboard")
        // Each tick is handled 0 to 8 ms after its deadline (the render, the present, the log write); the next wake is asked for from then.
        var now = 0.0, fires: [Double] = []
        for i in 0..<300 {
            let interval = try #require(stageRenderer.nextChange(StageRequest(frame: moving, now: now, geometry: geometry)))
            let fire = now + interval
            fires.append(fire)
            now = fire + Double(i % 9) / 1000
        }
        let mean = (fires[fires.count - 1] - fires[0]) / Double(fires.count - 1)
        #expect(abs(mean - 1.0 / 30) < 0.0005, "mean tick \(mean * 1000) ms, not 33.3 plus the handling delay")
        // A tick that missed whole steps skips to the next grid point instead of firing at once.
        let late = try #require(stageRenderer.nextChange(StageRequest(frame: moving, now: 10.0 / 30 + 0.05, geometry: geometry)))
        #expect(abs((10.0 / 30 + 0.05 + late) * 30 - (12 as Double)) < 1e-6, "0.05 s late lands on the grid point two steps on")
    }

    @Test func SkateRide_aGlideAsksForRedrawsExceptWhileTheRideIsHeld() throws {
        let geometry = Screens.geometry()
        let moving = SchedulerFrame(playback: MotionPlayback(source: .glide, use: "walk", startedAt: 0, duration: 0.001, loops: true,
                                                             ride: GlideRide.plan(travel: 5, resumed: false, random: { 0.99 })), look: "skateboard")
        let first = try #require(stageRenderer.nextChange(StageRequest(frame: moving, now: 1, geometry: geometry)))
        #expect(abs(first - StageRenderer.glideFrameInterval) < 1e-6, "a redraw is due one step after the last grid point")
        let standing = try held(12)
        #expect(stageRenderer.nextChange(StageRequest(frame: standing, now: 1, geometry: geometry)) == nil, "a held frame needs no redraw until the walk goes on")
    }

    @Test func SkateRide_theAtlasNamesTheSegmentsThePlaybackPlays() throws {
        let data = try Data(contentsOf: artDirectory.appendingPathComponent("clawd-atlas.json"))
        let root = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        let motions = try #require(root["motions"] as? [[String: Any]])
        let entry = try #require(motions.first { $0["id"] as? String == GlideRide.motionID })
        #expect(entry["uses"] as? [String] == ["ride"])
        #expect((entry["frames"] as? [Any])?.count == GlideRide.spriteFrameCount, "the entry holds the sprite's frames; the tail bridge adds the last two")
        let segments = try #require(entry["segments"] as? [[String: Any]])
        let ranges: [(String, Range<Int>)] = [("start", GlideRide.start), ("cruiseA", GlideRide.cruiseA), ("trick", GlideRide.trick),
                                              ("cruiseB", GlideRide.cruiseB), ("push", GlideRide.push),
                                              ("stop", GlideRide.stop.lowerBound..<GlideRide.spriteFrameCount)]
        #expect(segments.count == ranges.count)
        for (segment, range) in zip(segments, ranges) {
            #expect(segment["name"] as? String == range.0)
            #expect(segment["frames"] as? [Int] == [range.1.lowerBound, range.1.upperBound - 1], "\(range.0)")
            #expect(segment["srcFrames"] as? [Int] == [range.1.lowerBound + 23, range.1.upperBound - 1 + 23], "\(range.0)")
        }
        let ms = try #require(entry["ms"] as? [Int])
        #expect(ms.reduce(0, +) == 3250 && ms.allSatisfy { $0 == 83 || $0 == 84 }, "12 fps")
        let stage = try #require(entry["stage"] as? [String: Double])
        #expect(stage["right"] == 0.5 && stage["left"] == 0 && stage["up"] == 0 && stage["down"] == 3, "storage extent: \(stage)")
        let looks = try #require(root["looks"] as? [[String: Any]])
        let skate = try #require(looks.first { $0["id"] as? String == "skateboard" })
        #expect(skate["signature"] as? [String] == [GlideRide.motionID] && skate["layerOnSignature"] as? Bool == false)
    }

    @Test func SkateRide_noPoolPicksTheRideAndTheSkateboardKeepsItsIdleMotions() throws {
        let catalog = stageRenderer.art.catalog
        let ride = try #require(catalog.motion(id: GlideRide.motionID))
        #expect(ride.uses == [.ride] && ride.stage.down == 3 && ride.stage.right == 0.5)
        for look in catalog.looks {
            #expect(!catalog.idlePool(look: look.id).contains { $0.id == GlideRide.motionID }, "the idle pool of \(look.id)")
        }
        #expect(catalog.compatibleIdleCount(look: "skateboard") == 21, "the skateboard's idle motions are the fourteen of before the ride plus tier 1's seven")
        // A day of idle life in the skateboard look never starts it.
        let rig = SchedulerRig(catalog: catalog, settings: SchedulerFixture.settings { $0.motion = .lively; $0.walk = false; $0.lookPin = "skateboard" },
                               geometry: SchedulerFixture.geometry(homeX: 300, homeY: 200), seed: 5)
        rig.advance(86_400)
        #expect(rig.ids("idle", "signature:skateboard", "touch", "sent").count > 100)
        #expect(!rig.ids("idle", "signature:skateboard", "touch", "sent", "walk", "drop", "entrance").contains(GlideRide.motionID))
    }
}
