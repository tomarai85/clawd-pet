import Testing
import Foundation
import AppKit
import CoreGraphics
import ClawdCore
import ClawdRendering
import ClawdDesktop

/// Spec 4.4 and 7b: a click is taken only on Clawd's body pixels, his costume pixels and the open menu's rectangle. Since Sprint 4c this
/// is a property of WHICH WINDOW EXISTS WHERE, not of a flag flipped while the pointer moves (a flag can lose a race: the pointer leaves
/// Clawd and clicks before the process has changed it). The picture is cut in two windows that share no pixel: the body window holds
/// exactly the pixels that take clicks; the stage window holds everything else and ignores mouse events for its whole life.
@Suite("ClickThroughTests", .serialized)
struct ClickThroughTests {
    enum Kind { case transparent, body, costume, prop }

    /// What a cell is, decided from the picture's colours and the catalog (not from the hit mask under test).
    private func classify(_ stage: StageFrame, cell x: Int, _ y: Int, costume: [CGRect], head: CellPoint?, canvasOrigin: CellPoint) -> Kind {
        let p = stage.composed.raster[x, y]
        if p.a == 0 { return .transparent }
        let global = CGPoint(x: stage.layout.clawdTopLeft.x + (Double(x) + 0.5) * stage.layout.cellPt, y: stage.layout.clawdTopLeft.y - (Double(y) + 0.5) * stage.layout.cellPt)
        if costume.contains(where: { $0.contains(global) }) { return .costume }
        let bodyColours: Set<Pixel> = [Pixel(215, 119, 87), Pixel(190, 104, 77), Pixel(191, 105, 77), Pixel(175, 135, 255)]
        if bodyColours.contains(p) { return .body }
        if p == Pixel(20, 20, 19), let head {
            let cx = x - canvasOrigin.x, cy = y - canvasOrigin.y
            if cx >= head.x - 8, cx < head.x + 8, cy >= head.y, cy < head.y + 12 { return .body }
        }
        return .prop
    }

    private func costumeRects(_ look: LookArt, head: CellPoint?, stage: StageFrame) -> [CGRect] {
        guard let head else { return [] }
        let o = stage.composed.canvasOrigin
        return look.layers.filter(\.takesClicks).map { layer in
            let x = o.x + head.x + layer.offset.x, y = o.y + head.y + layer.offset.y
            return CGRect(x: stage.layout.clawdTopLeft.x + Double(x) * stage.layout.cellPt,
                          y: stage.layout.clawdTopLeft.y - Double(y + layer.raster.height) * stage.layout.cellPt,
                          width: Double(layer.raster.width) * stage.layout.cellPt, height: Double(layer.raster.height) * stage.layout.cellPt)
        }
    }

    /// What the sweep of one frame found.
    struct Sweep { var counts: [Kind: Int] = [:]; var gapCellsInTheBodyWindow = 0; var bodyWindowCells = 0 }

    /// Walks every cell of a frame and asks which window a click on its centre reaches.
    private func sweep(_ frame: SchedulerFrame, now: Double, look: LookArt, pixelScale: Double = 1, menu: CGRect? = nil, label: String) throws -> Sweep {
        let request = StageRequest(frame: frame, now: now, geometry: Screens.geometry(), pixelScale: pixelScale, menuRect: menu)
        let stage = try #require(try stageRenderer.compose(request))
        let pictures = try PanelPictures(stage)
        let head = stage.composed.head.map { CellPoint($0.x, $0.y) }
        let rects = costumeRects(look, head: head, stage: stage)
        var result = Sweep()
        for y in 0..<stage.composed.raster.height { for x in 0..<stage.composed.raster.width {
            let kind = classify(stage, cell: x, y, costume: rects, head: head, canvasOrigin: stage.composed.canvasOrigin)
            let point = CGPoint(x: stage.layout.clawdTopLeft.x + (Double(x) + 0.5) * stage.layout.cellPt, y: stage.layout.clawdTopLeft.y - (Double(y) + 0.5) * stage.layout.cellPt)
            if let menu, menu.contains(point) { continue }
            let receiver = pictures.receiver(at: point)
            let inBodyWindow = pictures.body?.rect.contains(point) ?? false
            if inBodyWindow { result.bodyWindowCells += 1 }
            switch kind {
            case .body, .costume:
                if receiver != .body { Issue.record("\(label): cell (\(x),\(y)) is \(kind) but a click on it reaches \(receiver)"); return result }
            case .transparent, .prop:
                // Outside the body window no window of ours exists: the click goes to the app behind. Inside it (the gap between two
                // legs, a prop beside the torso) the body window takes the click and ignores it (v1 did the same); that is counted.
                if inBodyWindow { result.gapCellsInTheBodyWindow += 1 }
                else if receiver != .appBehind { Issue.record("\(label): cell (\(x),\(y)) is \(kind), outside the body window, but a click on it reaches \(receiver)"); return result }
            }
            result.counts[kind, default: 0] += 1
        } }
        return result
    }

    private var cases: [(String, SchedulerFrame, Double, LookArt)] {
        get throws {
            [("rest", Frames.rest(), 0, .plain),
             ("heart prop", Frames.motion("A12-heart"), 0.6, .plain),
             ("coffee prop", Frames.motion("A19-coffee"), 0.5, .plain),
             ("bubble art in the frame", Frames.motion("A1-thinking"), 1.2, .plain),
             ("laptop", Frames.motion("A20-laptop"), 1.0, .plain),
             ("rainbow", Frames.motion("A13-rainbow"), 2.0, .plain),
             ("side view", Frames.motion("A6-turning"), 1.0, .plain),
             ("helmet at rest", Frames.rest(look: "helmet"), 0, try stageRenderer.art.look("helmet")),
             ("headphones in motion", Frames.motion("A2-looking", look: "headphones"), 1.0, try stageRenderer.art.look("headphones")),
             ("sunglasses jumping", Frames.motion("A3-jumping", look: "sunglasses"), 0.5, try stageRenderer.art.look("sunglasses"))]
        }
    }

    @Test func ClickThrough_menuClosed_onlyBodyAndCostumePixelsReachTheBodyWindowAndEveryOtherPixelOutsideItReachesTheAppBehind() throws {
        var totals: [Kind: Int] = [:], gaps = 0, windowCells = 0
        for backing in [1.0, 2.0] {
            for (label, frame, now, look) in try cases {
                let result = try sweep(frame, now: now, look: look, pixelScale: backing, label: "\(label) @\(Int(backing))x")
                for (k, v) in result.counts { totals[k, default: 0] += v }
                gaps += result.gapCellsInTheBodyWindow; windowCells += result.bodyWindowCells
            }
        }
        #expect(totals[.body, default: 0] > 1000 && totals[.transparent, default: 0] > 1000 && totals[.prop, default: 0] > 50 && totals[.costume, default: 0] > 50,
                "the sweep must have met every kind of pixel: \(totals)")
        // The residual, measured: cells inside the body window that are not body pixels (a click there is taken and ignored, as in v1).
        emit("CLICK-THROUGH residual: \(gaps) of \(windowCells) cells inside the body windows are not body or costume pixels (\(String(format: "%.1f", Double(gaps) * 100 / Double(max(1, windowCells)))) %)")
        #expect(Double(gaps) <= Double(windowCells) * 0.5, "most of what the body window holds must be Clawd: \(gaps) of \(windowCells)")
    }

    @Test func ClickThrough_theTwoPicturesShareNoPixelAndTogetherAreTheWholePicture() throws {
        for backing in [1.0, 2.0] {
            for (label, frame, now, look) in try cases {
                let stage = try #require(try stageRenderer.compose(StageRequest(frame: frame, now: now, geometry: Screens.geometry(), pixelScale: backing)))
                let pictures = try PanelPictures(stage)
                let full = stage.pixels, rest = pictures.stage.pixels
                #expect(pictures.stage.rect == stage.panelFrame, "\(label): the stage window keeps the rectangle the whole panel had")
                #expect(rest.width == full.width && rest.height == full.height)
                let hit = stage.composed.hit, factor = stage.layout.cellFactor, origin = stage.layout.clawdPixelOrigin
                var together = rest.data, claimed = 0
                if let body = pictures.body {
                    let bx = Int(((body.rect.minX - stage.panelFrame.minX) * backing).rounded()), by = Int(((stage.panelFrame.maxY - body.rect.maxY) * backing).rounded())
                    #expect(abs(body.rect.width * backing - Double(body.pixels.width)) < 1e-6 && abs(body.rect.height * backing - Double(body.pixels.height)) < 1e-6,
                            "\(label): the window is as big as its picture")
                    for y in 0..<body.pixels.height { for x in 0..<body.pixels.width {
                        let i = ((by + y) * full.width + bx + x) * 4, j = (y * body.pixels.width + x) * 4
                        let bodyAlpha = body.pixels.data[j + 3]
                        if bodyAlpha != 0 {
                            claimed += 1
                            if rest.data[i + 3] != 0 { Issue.record("\(label): pixel (\(bx + x),\(by + y)) is in both pictures"); return }
                            let cx = (bx + x - origin.x).quotientAndRemainder(dividingBy: factor).quotient, cy = (by + y - origin.y).quotientAndRemainder(dividingBy: factor).quotient
                            if !hit.isOpaque(cx, cy) { Issue.record("\(label): pixel (\(bx + x),\(by + y)) is in the body picture but its cell takes no click"); return }
                        }
                        // The body picture is the full picture inside the hit cells and nothing elsewhere.
                        for k in 0..<4 { together[i + k] = together[i + k] | body.pixels.data[j + k] }
                    } }
                    if let bounds = stage.hit.bounds, body.rect.minX >= stage.panelFrame.minX, body.rect.maxX <= stage.panelFrame.maxX {
                        #expect(abs(body.rect.minX - bounds.minX) < 1e-9 && abs(body.rect.maxX - bounds.maxX) < 1e-9, "\(label): the body window is the hit bounds \(bounds), not \(body.rect)")
                    }
                } else {
                    Issue.record("\(label): a frame with Clawd in it must have a body window")
                }
                #expect(together == full.data, "\(label): the two pictures together are not the whole picture")
                #expect(claimed > 100, "\(label): the body picture holds Clawd (\(claimed) pixels)")
                // Every pixel that takes a click is in the body picture; counted from the full picture.
                var wanted = 0
                for cy in 0..<hit.height { for cx in 0..<hit.width where hit.isOpaque(cx, cy) {
                    for py in max(0, origin.y + cy * factor)..<min(full.height, origin.y + (cy + 1) * factor) {
                        for px in max(0, origin.x + cx * factor)..<min(full.width, origin.x + (cx + 1) * factor) where full.data[(py * full.width + px) * 4 + 3] != 0 { wanted += 1 }
                    }
                } }
                #expect(wanted == claimed, "\(label): \(wanted) painted pixels take clicks, \(claimed) are in the body picture")
            }
        }
    }

    @Test func ClickThrough_aPictureCutOffAtTheScreenEdgeStillSplitsExactly() throws {
        // Clawd at the left and the right edge of the visible frame, at both pixel densities: the picture is cropped by the display, the
        // hit cells that are cropped away are not in any window, and what is left still adds up to the whole picture.
        for (home, backing) in [(-20.0, 1.0), (-20.0, 2.0), (1440.0 - 28.0, 1.0), (1440.0 - 28.0, 2.0)] {
            let request = StageRequest(frame: Frames.rest(), now: 0, geometry: Screens.geometry(homeX: home), pixelScale: backing)
            let stage = try #require(try stageRenderer.compose(request))
            let pictures = try PanelPictures(stage)
            let full = stage.pixels
            var together = pictures.stage.pixels.data
            if let body = pictures.body {
                let bx = Int(((body.rect.minX - stage.panelFrame.minX) * backing).rounded()), by = Int(((stage.panelFrame.maxY - body.rect.maxY) * backing).rounded())
                #expect(bx >= 0 && by >= 0 && bx + body.pixels.width <= full.width && by + body.pixels.height <= full.height, "home \(home) @\(backing)x: the body window lies inside the picture")
                for y in 0..<body.pixels.height { for x in 0..<body.pixels.width {
                    let i = ((by + y) * full.width + bx + x) * 4, j = (y * body.pixels.width + x) * 4
                    for k in 0..<4 { together[i + k] |= body.pixels.data[j + k] }
                } }
            }
            #expect(together == full.data, "home \(home) @\(backing)x: the two pictures together are the whole picture")
            #expect(pictures.stage.rect == stage.panelFrame)
        }
    }

    @Test func ClickThrough_menuOpen_theMenuIsItsOwnReceiverAndTheBodyWindowIsUnchanged() throws {
        let menu = CGRect(x: 640, y: 40, width: 90, height: 120)       // beside Clawd at home (576...624), overlapping the bubble's area
        let open = try PanelPictures(try #require(try stageRenderer.compose(StageRequest(frame: Frames.rest(), now: 0, geometry: Screens.geometry(), menuRect: menu))))
        let closed = try PanelPictures(try #require(try stageRenderer.compose(StageRequest(frame: Frames.rest(), now: 0, geometry: Screens.geometry()))))
        #expect(open.menuRect == menu); #expect(closed.menuRect == nil)
        for point in [CGPoint(x: 641, y: 41), CGPoint(x: 700, y: 100), CGPoint(x: 729, y: 159)] {
            #expect(open.receiver(at: point) == .menu, "inside the open menu \(point)")
            #expect(closed.receiver(at: point) == .appBehind, "the same point with the menu closed")
        }
        for point in [CGPoint(x: 639, y: 100), CGPoint(x: 731, y: 100), CGPoint(x: 700, y: 39), CGPoint(x: 700, y: 161)] {
            #expect(open.receiver(at: point) == .appBehind, "outside the menu and outside Clawd \(point)")
        }
        #expect(open.body?.rect == closed.body?.rect, "the body window does not change when the menu opens")
        let onBody = CGPoint(x: closed.stage.rect.midX, y: try #require(closed.body?.rect).midY)
        #expect(open.receiver(at: onBody) == .body); #expect(open.interactiveRects.count == 2); #expect(closed.interactiveRects.count == 1)
    }

    @Test func ClickThrough_theBubbleAndTheTransparentStageAreInTheStagePictureAndReachTheAppBehind() throws {
        let frame = Frames.pose("listen", scene: .listening, bubble: BubbleState(style: 1, scene: .listening))
        let stage = try #require(try stageRenderer.compose(StageRequest(frame: frame, now: 0.25, geometry: Screens.geometry())))
        let pictures = try PanelPictures(stage)
        let bubble = try #require(stage.bubble)
        var painted = 0
        for y in 0..<bubble.bitmap.raster.height { for x in 0..<bubble.bitmap.raster.width where bubble.bitmap.raster.isOpaque(x, y) {
            let p = CGPoint(x: bubble.rect.minX + (Double(x) + 0.5) * BubbleLayout.pixelPt, y: bubble.rect.maxY - (Double(y) + 0.5) * BubbleLayout.pixelPt)
            if pictures.receiver(at: p) != .appBehind { Issue.record("a click on the bubble at \(p) would be taken"); return }
            // and the pixel is drawn by the stage window
            let px = Int(((p.x - stage.panelFrame.minX) * pictures.stage.pixelScale).rounded(.down)), py = Int(((stage.panelFrame.maxY - p.y) * pictures.stage.pixelScale).rounded(.down))
            if pictures.stage.pixels.data[(py * pictures.stage.pixels.width + px) * 4 + 3] == 0 { Issue.record("the bubble pixel at \(p) is not in the stage picture"); return }
            painted += 1
        } }
        #expect(painted > 60)
        #expect(pictures.receiver(at: CGPoint(x: stage.canvas.minX + 1, y: stage.canvas.maxY - 1)) == .appBehind, "the empty corner of Clawd's canvas")
        #expect(pictures.receiver(at: CGPoint(x: stage.canvas.midX, y: stage.canvas.minY + 20)) == .body, "and his body takes it")
        #expect(pictures.body.map { !$0.rect.intersects(bubble.rect) } == true, "the body window does not reach the bubble")
    }

    @Test func ClickThrough_receiverIsAFunctionOfTheFrameAloneSoAParkedPointerNeverNeedsRechecking() throws {
        // No state, no pointer, no timer: the answer for a point is a function of the current pictures. The jump lifts the body, so a point on
        // a leg of the rest pose is on nothing mid-jump, and that follows from the new frame alone.
        let rest = try PanelPictures(try #require(try stageRenderer.compose(StageRequest(frame: Frames.rest(), now: 0, geometry: Screens.geometry()))))
        let restFrame = try #require(try stageRenderer.compose(StageRequest(frame: Frames.rest(), now: 0, geometry: Screens.geometry())))
        let jumpFrame = try #require(try stageRenderer.compose(StageRequest(frame: Frames.motion("A3-jumping"), now: 0.35, geometry: Screens.geometry())))
        let jump = try PanelPictures(jumpFrame)
        let leg = CGPoint(x: restFrame.canvas.minX + 9, y: restFrame.canvas.minY + 3)
        #expect(rest.receiver(at: leg) == .body, "a leg of the rest pose")
        #expect((jump.receiver(at: leg) == .body) == (jump.body?.rect.contains(leg) ?? false))
        #expect(jumpFrame.hit.containsBody(leg) == false || jump.receiver(at: leg) == .body, "a point on Clawd's body in the new frame reaches the body window")
        #expect(jump.body?.rect != rest.body?.rect, "the body window moves with the frame")
    }

    @MainActor @Test func ClickThrough_theStagePanelNeverTakesAMouseEventWhateverIsDoneToIt() throws {
        let stagePanel = StagePanel(overFullScreen: false)
        #expect(stagePanel.ignoresMouseEvents); #expect(stagePanel.windowServerIgnoresMouseEvents, "the window server was told at creation")
        stagePanel.ignoresMouseEvents = false
        #expect(stagePanel.ignoresMouseEvents, "a caller cannot turn it off")
        #expect(stagePanel.windowServerIgnoresMouseEvents, "and the window server still ignores its events")
        let body = PetPanel(overFullScreen: false)
        #expect(!body.ignoresMouseEvents, "a body window takes clicks from its creation")
        let set = PanelSet(overFullScreen: false)
        #expect(set.violations() == [], "\(set.violations())")
        #expect(set.stage.ignoresMouseEvents); #expect(!set.body.ignoresMouseEvents)
        // The detector flags a stage window that takes events and a body window that ignores them.
        let broken = PanelSet(overFullScreen: false)
        broken.body.ignoresMouseEvents = true
        let found = broken.violations()
        #expect(found.contains("a window that must take clicks ignores them"))
        negativeControl("body-window-ignores-clicks-is-flagged", expectationHolds: found.isEmpty)
        #expect(!set.stage.isVisible && !set.body.isVisible, "the test never shows a window")
    }

    @MainActor @Test func ClickThrough_thePanelSetPlacesEachWindowShowsTheBodyOnlyWhenThereIsOneAndKeepsItWhileAPressLasts() throws {
        var shown: [String] = [], gone: [String] = []
        let set = PanelSet(overFullScreen: false)
        func name(_ panel: NSPanel) -> String { panel === set.stage ? "stage" : panel === set.body ? "body" : "menu" }
        let env = RuntimeEnvironment(displays: { DisplaySet(all: []) }, pointer: { .zero }, aquaLogPath: { "" }, aquaRunning: { true },
                                     present: { shown.append(name($0)) }, dismiss: { gone.append(name($0)) }, inputIdle: { 0 }, observeDesktop: { _, _ in nil })
        let stage = try #require(try stageRenderer.compose(StageRequest(frame: Frames.rest(), now: 0, geometry: Screens.geometry())))
        let pictures = try PanelPictures(stage)
        set.show(pictures, environment: env)
        #expect(set.stage.frame == stage.panelFrame); #expect(set.body.frame == pictures.body?.rect)
        #expect(shown.sorted() == ["body", "stage"], "both windows are ordered in, once")
        #expect(set.view.frame.size == pictures.body?.rect.size && set.view.window === set.body, "the clicks reach the view of the body window")
        // A picture with nothing that takes a click: the body window goes, unless a press began on it.
        let noBody = PanelPictures(stage: pictures.stage, body: nil, menuRect: nil)
        set.show(noBody, holdBody: true, environment: env)
        #expect(!gone.contains("body"), "a press in progress keeps the body window, or its button-up is lost")
        set.show(noBody, environment: env)
        #expect(gone.contains("body"), "with no press it goes")
        // The menu gets a window of its own, which takes clicks, and the same call closes it.
        let withMenu = PanelPictures(stage: pictures.stage, body: pictures.body, menuRect: CGRect(x: 640, y: 40, width: 90, height: 120))
        set.show(withMenu, environment: env)
        let menuWindow = try #require(set.menu)
        #expect(menuWindow.frame == CGRect(x: 640, y: 40, width: 90, height: 120)); #expect(!menuWindow.ignoresMouseEvents)
        #expect(set.violations() == [], "\(set.violations())")
        set.show(pictures, environment: env)
        #expect(gone.contains("menu"))
        set.hide(environment: env)
        #expect(Set(gone).isSuperset(of: ["stage", "body", "menu"]))
    }

    @Test func ClickThrough_theHitBoundsAreTheBodyAndCostumeAlone() throws {
        let plain = try #require(try stageRenderer.compose(StageRequest(frame: Frames.motion("A12-heart"), now: 0.6, geometry: Screens.geometry())))
        let bounds = try #require(plain.hit.bounds)
        // the heart rises 6.5 units above the canvas; the hit bounds stay inside the canvas
        #expect(plain.clawdRect.height > plain.canvas.height + 20)
        #expect(plain.canvas.insetBy(dx: -0.01, dy: -0.01).contains(bounds), "\(bounds) vs \(plain.canvas)")
        // and the body window of that frame is the hit bounds, not the heart's rectangle
        let pictures = try PanelPictures(plain)
        #expect(pictures.body?.rect == bounds, "\(String(describing: pictures.body?.rect)) vs \(bounds)")
        #expect(pictures.stage.rect.height > bounds.height + 20)
    }

    // MARK: the open menu (Sprint M)

    /// The menu beside Clawd's canvas, as the runtime places it.
    private func menuRect(for stage: StageFrame) -> CGRect {
        MenuPlacement.rect(size: MenuLayout(looks: stageRenderer.art.catalog.looks.map(\.id), drawnStyles: StageRuntime.drawnBubbleStyles).size, canvas: stage.canvas, visible: Screens.visible)
    }

    @Test func ClickThrough_menuOpen_everythingOutsideTheMenuStillPassesThroughAndTheMenuTakesItsOwnClicksOverEveryKindOfFrame() throws {
        var totals: [Kind: Int] = [:], inMenu = 0
        for backing in [1.0, 2.0] {
            for (label, frame, now, look) in try cases {
                let closed = try #require(try stageRenderer.compose(StageRequest(frame: frame, now: now, geometry: Screens.geometry(), pixelScale: backing)))
                let menu = menuRect(for: closed)
                // the sweep skips the cells under the menu (they belong to it) and holds every other cell to the same rule as with the menu closed
                let result = try sweep(frame, now: now, look: look, pixelScale: backing, menu: menu, label: "\(label) @\(Int(backing))x, menu open")
                for (k, v) in result.counts { totals[k, default: 0] += v }
                let open = try #require(try stageRenderer.compose(StageRequest(frame: frame, now: now, geometry: Screens.geometry(), pixelScale: backing, menuRect: menu)))
                let pictures = try PanelPictures(open), closedPictures = try PanelPictures(closed)
                #expect(pictures.body?.rect == closedPictures.body?.rect, "\(label): opening the menu does not change Clawd's body window")
                // a grid over the menu and 20 pt around it: inside it takes the click, outside it only Clawd's own window does
                var x = menu.minX - 20
                while x < menu.maxX + 20 {
                    var y = menu.minY - 20
                    while y < menu.maxY + 20 {
                        let point = CGPoint(x: x + 0.5, y: y + 0.5)
                        let want: ClickReceiver = menu.contains(point) ? .menu : (closedPictures.body?.rect.contains(point) == true ? .body : .appBehind)
                        if pictures.receiver(at: point) != want { Issue.record("\(label): at \(point) a click reaches \(pictures.receiver(at: point)), not \(want)"); return }
                        if menu.contains(point) { inMenu += 1 }
                        y += 7
                    }
                    x += 7
                }
                #expect(closedPictures.menuRect == nil && pictures.menuRect == menu)
            }
        }
        #expect(totals[.body, default: 0] > 1000 && totals[.transparent, default: 0] > 1000 && totals[.prop, default: 0] > 50 && totals[.costume, default: 0] > 50, "\(totals)")
        #expect(inMenu > 500, "the grid met the menu: \(inMenu) points")
    }

    @Test func ClickThrough_menuOpen_aBubbleAndAPropBesideTheMenuStillPassThroughAndMenuItemsTakeClicks() throws {
        // A dictation's bubble above Clawd's head and the heart prop's tall stage, with the menu open beside them.
        for (label, frame, now) in [("bubble", Frames.pose("listen", scene: .listening, bubble: BubbleState(style: 1, scene: .listening)), 0.25),
                                    ("heart", Frames.motion("A12-heart"), 0.6)] {
            let closed = try #require(try stageRenderer.compose(StageRequest(frame: frame, now: now, geometry: Screens.geometry())))
            let menu = menuRect(for: closed)
            let open = try #require(try stageRenderer.compose(StageRequest(frame: frame, now: now, geometry: Screens.geometry(), menuRect: menu)))
            let pictures = try PanelPictures(open)
            let layout = MenuLayout(looks: stageRenderer.art.catalog.looks.map(\.id), drawnStyles: StageRuntime.drawnBubbleStyles)
            for item in layout.items {
                let global = CGPoint(x: menu.minX + item.rect.midX, y: menu.maxY - item.rect.midY)
                #expect(pictures.receiver(at: global) == .menu, "\(label): item \(item.key)/\(item.value) takes a click")
            }
            if let bubble = open.bubble {
                var seen = 0
                for y in 0..<bubble.bitmap.raster.height { for x in 0..<bubble.bitmap.raster.width where bubble.bitmap.raster.isOpaque(x, y) {
                    let p = CGPoint(x: bubble.rect.minX + (Double(x) + 0.5) * BubbleLayout.pixelPt, y: bubble.rect.maxY - (Double(y) + 0.5) * BubbleLayout.pixelPt)
                    if menu.contains(p) { continue }
                    #expect(pictures.receiver(at: p) == .appBehind, "\(label): a click on the bubble at \(p) goes to the app behind")
                    seen += 1
                } }
                #expect(seen > 40, "\(label): the bubble's pixels were met")
            }
            // the stage window is the union of Clawd's picture, the bubble and the menu, and it never takes a click
            #expect(open.panelFrame.contains(menu.intersection(Screens.visible)), "\(label): the stage window covers the menu's rectangle")
            #expect(pictures.stage.rect == open.panelFrame)
            #expect(pictures.receiver(at: CGPoint(x: menu.minX - 1, y: menu.midY)) == .appBehind, "\(label): one point left of the menu")
        }
    }

    @MainActor @Test func ClickThrough_menuWindow_isANewNonActivatingWindowForEveryOpeningThatPassesTheFocusAudit() throws {
        var shown: [String] = [], gone: [String] = []
        let set = PanelSet(overFullScreen: false)
        func name(_ panel: NSPanel) -> String { panel === set.stage ? "stage" : panel === set.body ? "body" : "menu" }
        let env = RuntimeEnvironment(displays: { DisplaySet(all: []) }, pointer: { .zero }, aquaLogPath: { "" }, aquaRunning: { true },
                                     present: { shown.append(name($0)) }, dismiss: { gone.append(name($0)) }, inputIdle: { 0 }, observeDesktop: { _, _ in nil })
        let layout = MenuLayout(looks: stageRenderer.art.catalog.looks.map(\.id), drawnStyles: StageRuntime.drawnBubbleStyles)
        var built: [Int] = []
        set.menuFactory = { gen in built.append(gen); return MenuView(layout: layout, gen: gen) }
        let stage = try #require(try stageRenderer.compose(StageRequest(frame: Frames.rest(), now: 0, geometry: Screens.geometry())))
        let pictures = try PanelPictures(stage)
        let rect = menuRect(for: stage)
        let withMenu = PanelPictures(stage: pictures.stage, body: pictures.body, menuRect: rect)
        set.pendingMenuGen = 1
        set.show(withMenu, environment: env)
        let first = try #require(set.menu)
        #expect(first.gen == 1 && built == [1] && first.frame == rect && first.contentView === first.menuView)
        #expect(!first.ignoresMouseEvents && !first.canBecomeKey && !first.canBecomeMain && !first.isKeyWindow, "it takes clicks and never becomes key or main")
        #expect(FocusAudit.violations(of: first) == [] && set.violations() == [], "\(FocusAudit.violations(of: first)) \(set.violations())")
        // the same opening drawn again keeps its window; a close drops it; the next opening gets a new one with the next number
        set.show(withMenu, environment: env)
        #expect(set.menu === first && built == [1], "a picture of the same opening keeps its window")
        set.show(pictures, environment: env)
        #expect(set.menu == nil && gone.contains("menu"), "the close drops the window")
        set.pendingMenuGen = 2
        set.show(withMenu, environment: env)
        let second = try #require(set.menu)
        #expect(second !== first && second.gen == 2 && built == [1, 2], "one panel per opening")
        #expect(first.gen == 1, "the old window still knows its own number")
        #expect(set.violations() == [] && FocusAudit.violations(of: second) == [])
        set.hide(environment: env)
        #expect(set.menu == nil && gone.filter { $0 == "menu" }.count >= 2)
        #expect(!set.stage.isVisible && !set.body.isVisible && !first.isVisible && !second.isVisible, "the test never shows a window")
    }

    // MARK: behavioural negative control: no pointer callback can change where a click goes

    /// Which window a click at each point reaches (the topmost window whose frame holds it and whose `ignoresMouseEvents` is false; the menu is
    /// above the body) or the app behind, and every window's frame and flag.
    @MainActor private func decisions(_ windows: [(String, NSPanel)], over grid: [CGPoint]) -> [String] {
        var table: [String] = windows.map { "\($0.0) \($0.1.frame) ignores=\($0.1.ignoresMouseEvents)" }
        let order = ["menu", "body", "stage"]
        for point in grid {
            let hit = order.compactMap { n in windows.first { $0.0 == n } }.first { !$0.1.ignoresMouseEvents && $0.1.frame.contains(point) }
            table.append("\(point) -> \(hit?.0 ?? "behind")")
        }
        return table
    }

    /// Yields after each area: every mouseEntered redraws the menu (about 75 ms in a debug build), and 61 areas held on the main thread in one
    /// go starved the other main-actor tests of the full suite for up to 47 s.
    @MainActor private func enterAndExit(_ view: NSView, areas: [NSTrackingArea], onlyEnter: Bool = false) async throws {
        func event(_ type: NSEvent.EventType, at p: CGPoint) throws -> NSEvent {
            try #require(NSEvent.enterExitEvent(with: type, location: p, modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
        }
        for area in areas {
            let centre = CGPoint(x: area.rect.midX, y: area.rect.midY)
            guard let owner = area.owner as? NSResponder else { continue }
            owner.mouseEntered(with: try event(.mouseEntered, at: centre))
            if !onlyEnter { owner.mouseExited(with: try event(.mouseExited, at: CGPoint(x: -50, y: -50))) }
            await Task.yield()
        }
    }

    @MainActor @Test func ClickThrough_menuOpen_theDecisionTableIsTheSameWithThePointerSourcesTheyCallbacksAndWithoutThem() async throws {
        let stage = try #require(try stageRenderer.compose(StageRequest(frame: Frames.rest(), now: 0, geometry: Screens.geometry())))
        let pictures = try PanelPictures(stage)
        let rect = menuRect(for: stage)
        let withMenu = PanelPictures(stage: pictures.stage, body: pictures.body, menuRect: rect)
        let layout = MenuLayout(looks: stageRenderer.art.catalog.looks.map(\.id), drawnStyles: StageRuntime.drawnBubbleStyles)
        let env = RuntimeEnvironment(displays: { DisplaySet(all: []) }, pointer: { .zero }, aquaLogPath: { "" }, aquaRunning: { true },
                                     present: { _ in }, dismiss: { _ in }, inputIdle: { 0 }, observeDesktop: { _, _ in nil })
        func open() -> (PanelSet, MenuPanel) {
            let set = PanelSet(overFullScreen: false)
            set.menuFactory = { MenuView(layout: layout, gen: $0) }
            set.pendingMenuGen = 1
            set.show(withMenu, environment: env)
            return (set, set.menu!)
        }
        let union = stage.panelFrame.union(pictures.body?.rect ?? .zero).union(rect).insetBy(dx: -20, dy: -20)
        var grid: [CGPoint] = []
        var gx = union.minX
        while gx < union.maxX { var gy = union.minY; while gy < union.maxY { grid.append(CGPoint(x: gx + 0.5, y: gy + 0.5)); gy += 6 }; gx += 6 }
        func windows(_ set: PanelSet, _ menu: NSPanel) -> [(String, NSPanel)] { [("stage", set.stage), ("body", set.body), ("menu", menu)] }

        // D0: with the pointer sources: a monitor installed (a fake source: a real global monitor in a test process might raise a permission
        // dialog on the user's screen, which no test may do; the monitor touches no window either way) and the real tracking areas added
        let (set0, menu0) = open()
        let fake = MenuFakeSource()
        let monitor = fake.install { _ in }
        menu0.menuView.armTracking()
        #expect(!menu0.menuView.trackingAreas.isEmpty)
        let d0 = decisions(windows(set0, menu0), over: grid)
        // D1: after each tracking area's owner has been sent mouseEntered and mouseExited, and once more with only mouseEntered (the pointer stays on an item)
        try await enterAndExit(menu0.menuView, areas: menu0.menuView.trackingAreas)
        let d1a = decisions(windows(set0, menu0), over: grid)
        try await enterAndExit(menu0.menuView, areas: menu0.menuView.trackingAreas, onlyEnter: true)
        let d1b = decisions(windows(set0, menu0), over: grid)
        #expect(monitor != nil && fake.live == 1)
        if let monitor { fake.remove(monitor) }
        menu0.menuView.disarmTracking()
        // D2: no pointer source at all (nothing installed, no area armed)
        let (set2, menu2) = open()
        let d2 = decisions(windows(set2, menu2), over: grid)
        #expect(d0 == d1a && d0 == d1b && d0 == d2, "the decision table is the same with the monitor and the areas, after every callback, and without them")
        // and it is the table the pictures alone give
        let expected = grid.map { p -> String in
            let receiver = withMenu.receiver(at: p)
            return "\(p) -> \(receiver == .menu ? "menu" : receiver == .body ? "body" : "behind")"
        }
        #expect(Array(d0.dropFirst(3)) == expected, "D0's receivers are PanelPictures.receiver(at:) at every grid point")
        #expect(set0.violations() == [] && set2.violations() == [])

        // Negative control: a menu view whose mouseEntered turns its window's mouse events off (the old pointer-driven click-through)
        // changes the table, and the comparison above would flag it.
        final class PointerDrivenView: NSView {
            override func mouseEntered(with event: NSEvent) { window?.ignoresMouseEvents = true }
        }
        let evil = PetPanel(overFullScreen: false)
        let evilView = PointerDrivenView(frame: CGRect(origin: .zero, size: rect.size))
        evil.contentView = evilView
        evil.setFrame(rect, display: false)
        evilView.addTrackingArea(NSTrackingArea(rect: evilView.bounds, options: [.mouseEnteredAndExited, .activeAlways], owner: evilView, userInfo: nil))
        let before = decisions([("stage", set2.stage), ("body", set2.body), ("menu", evil)], over: grid)
        try await enterAndExit(evilView, areas: evilView.trackingAreas)
        let after = decisions([("stage", set2.stage), ("body", set2.body), ("menu", evil)], over: grid)
        negativeControl("a-menu-view-whose-mouse-entered-flips-ignores-mouse-events", expectationHolds: before == after)
    }

    // MARK: the body window's rectangle (amendment D-5, R3-2: styles 13-15)

    /// Every bubble pixel with any alpha, in global points: the centre of the bubble's own pixel.
    private func bubblePoints(_ bubble: PlacedBubble, backing: Double) -> [CGPoint] {
        let design = BubbleDesign.resolved(bubble.style), raster = bubble.bitmap.raster
        let pt = design.isSmooth ? 1 / backing : BubbleChecks.pixelPt(design)
        var points: [CGPoint] = []
        for y in 0..<raster.height { for x in 0..<raster.width where raster.isOpaque(x, y) {
            points.append(CGPoint(x: bubble.rect.minX + (Double(x) + 0.5) * pt, y: bubble.rect.maxY - (Double(y) + 0.5) * pt))
        } }
        return points
    }

    /// A click anywhere inside the body window's rectangle is taken by the body window, hit cell or not. A bubble of the styles that keep off it
    /// (13-15) has no pixel there: every pixel of it, its shadow included, goes to the app behind, above and beside Clawd, at every size and density,
    /// in every look and in the motions that raise an arm or a prop above his head.
    @Test func ClickThrough_noBubblePixelLiesInTheBodyWindowsRectangle() throws {
        let styles = BubbleDesign.allIds.filter { $0 >= 13 }
        var frames: [(name: String, frame: SchedulerFrame, now: Double)] = stageRenderer.art.lookIDs.map { ("look \($0)", Frames.rest(look: $0, scene: .thinking), 0) }
        for id in ["A12-heart", "A3-jumping", "A10-breakdancing", "A7-swaying", "A29-fishing", "A13-rainbow", "A20-laptop"] { frames.append(("motion \(id)", Frames.motion(id), 1.0)) }
        var checked = 0, sideCount = 0
        for style in styles { for scale in [1.0, 1.5, 2.0, 3.0, 4.0] { for backing in [1.0, 2.0] { for side in [false, true] {
            let geometry = side
                ? PetGeometry(scale: scale, homeOrigin: CGPoint(x: 300, y: Screens.visible.maxY - 48 * scale), displayFrame: Screens.display, visibleFrame: Screens.visible)
                : Screens.geometry(scale: scale)
            for (name, base, now) in frames {
                var frame = base; frame.bubble = BubbleState(style: style, scene: .thinking)
                let request = StageRequest(frame: frame, now: now, geometry: geometry, pixelScale: backing,
                                           content: BubbleContent(scene: .thinking, elapsed: 0.7, verb: "Cogitating"), bubbleSide: side ? .right : .above)
                let stage = try #require(try stageRenderer.compose(request))
                guard let bubble = stage.bubble else { continue }       // no clear place: no bubble is the rule's own answer
                let pictures = try PanelPictures(stage)
                if bubble.plan.connection == .side { sideCount += 1 }
                for point in bubblePoints(bubble, backing: backing) where pictures.receiver(at: point) != .appBehind {
                    Issue.record("style \(style) size \(scale) \(backing)x \(side ? "beside" : "above") \(name): a click at \(point) on the bubble would be taken")
                    return
                }
                checked += 1
            }
        } } } }
        #expect(checked > styles.count * 100 && sideCount > 0, "\(checked) pictures, \(sideCount) beside Clawd")
    }

    /// A bubble under Clawd's feet takes no click, shadow included: every pixel of it, for every style, goes to the app behind, whatever look or motion
    /// is around the feet, at every size and density.
    @Test func ClickThrough_aBelowBubbleAndItsShadowPassClicksThrough() throws {
        var frames: [(name: String, frame: SchedulerFrame, now: Double)] = ["plain", "skateboard", "pool-float", "helmet"].map { ("look \($0)", Frames.rest(look: $0, scene: .thinking), 0) }
        for id in ["A12-heart", "A10-breakdancing", "A7-swaying", "A29-fishing"] { frames.append(("motion \(id)", Frames.motion(id), 1.0)) }
        var checked = 0, below = 0
        for style in BubbleDesign.allIds { for scale in [1.0, 2.0, 4.0] { for backing in [1.0, 2.0] {
            for (name, base, now) in frames {
                var frame = base; frame.bubble = BubbleState(style: style, scene: .thinking)
                let request = StageRequest(frame: frame, now: now, geometry: Screens.geometry(scale: scale, homeY: 300), pixelScale: backing,
                                           content: BubbleContent(scene: .thinking, elapsed: 0.7, verb: "Cogitating"))
                let stage = try #require(try stageRenderer.compose(request))
                guard let bubble = stage.bubble else { continue }
                if bubble.plan.side == .below { below += 1 }
                let pictures = try PanelPictures(stage)
                for point in bubblePoints(bubble, backing: backing) where pictures.receiver(at: point) != .appBehind {
                    Issue.record("style \(style) size \(scale) \(backing)x \(name): a click at \(point) on the \(bubble.plan.side) bubble would be taken")
                    return
                }
                checked += 1
            }
        } } }
        #expect(checked > 15 * 3 * 2 * 8 / 2 && below == checked, "\(checked) pictures, \(below) of them below Clawd")
    }

    /// A synthetic hit mask of two shapes far apart (an L and a ring): its rectangle spans a transparent gap. An unguarded placement puts the bubble
    /// beside the L, in the gap, where a click is taken by the body window; the guarded one lies wholly outside the rectangle.
    @Test func ClickThrough_aSparseHitMaskKeepsTheBubbleOutOfItsWholeRectangle() throws {
        // A ring in the top right (rows 0-2) and an L lower down on the left (rows 4-11): the rectangle of the two spans the empty rows between and the
        // empty columns to the L's right, where a bubble beside the L would lie.
        var cells = Raster(width: 20, height: 12)
        for y in 0..<3 { for x in 15..<20 where x == 15 || x == 19 || y == 0 || y == 2 { cells[x, y] = Pixel(1, 2, 3) } }
        for y in 4..<12 { cells[0, y] = Pixel(1, 2, 3); cells[1, y] = Pixel(1, 2, 3) }
        for y in 10..<12 { for x in 0..<6 { cells[x, y] = Pixel(1, 2, 3) } }
        let topLeft = CGPoint(x: 400, y: 300), cellPt = 4.0
        let hit = HitRegion(raster: cells, topLeft: topLeft, cellPt: cellPt)
        let window = try #require(hit.bounds)
        #expect(window == CGRect(x: 400, y: 252, width: 80, height: 48), "\(window)")
        let mask = ClawdMask(raster: cells, topLeft: topLeft, cellPt: cellPt)
        for style in BubbleDesign.allIds.filter({ $0 >= 13 }) {
            let design = BubbleDesign.resolved(style)
            let text = BubbleText.content(BubbleContent(scene: .thinking, elapsed: 0.7, verb: "Cogitating"), elements: stageRenderer.elements, design: design)
            // no room above (the frame ends 16 pt over the L's head): the bubble goes beside Clawd, at the body's rows
            let visible = CGRect(x: 0, y: 0, width: 1440, height: topLeft.y)
            func site(_ guarded: Bool) -> BubbleSite {
                BubbleSite(headTop: CGPoint(x: topLeft.x + 2 * cellPt, y: topLeft.y - 4 * cellPt), bodyCentreY: topLeft.y - 7 * cellPt, unit: 4,
                           display: CGRect(x: 0, y: 0, width: 1440, height: 900), visible: visible, clawd: mask, bodyWindow: guarded ? window : nil)
            }
            let open = try #require(BubblePlacement.plan(design: design, runs: text.runs, dots: text.dots, site: site(false), scale: 2, side: .right), "style \(style)")
            #expect(open.rect.intersects(window), "style \(style): without the rule the bubble \(open.rect) is placed in the rectangle \(window)")
            let plan = try #require(BubblePlacement.plan(design: design, runs: text.runs, dots: text.dots, site: site(true), scale: 2, side: .right), "style \(style)")
            #expect(!plan.rect.intersects(window) && !mask.intersects(plan.rect), "style \(style): the bubble \(plan.rect) lies in the rectangle \(window)")
            // every pixel of the picture, shadow included, goes to the app behind
            let bubble = design.render(runs: text.runs, dots: text.dots, opening: plan.opening, connection: plan.connection, variant: plan.variant,
                                       tipColumn: plan.tipColumn)
            let pt = BubbleChecks.pixelPt(design)
            var painted = 0
            for y in 0..<bubble.raster.height { for x in 0..<bubble.raster.width where bubble.raster.isOpaque(x, y) {
                let point = CGPoint(x: plan.rect.minX + (Double(x) + 0.5) * pt, y: plan.rect.maxY - (Double(y) + 0.5) * pt)
                if window.contains(point) { Issue.record("style \(style): a click at \(point) on the bubble would be taken"); return }
                painted += 1
            } }
            #expect(painted > 100, "style \(style)")
        }
    }


    /// A new style's bubble and its shadow pass clicks through: above and beside Clawd, at pixel scale 1 and 2, points inside the shape (box and connector)
    /// and inside the shadow margin all go to the app behind.
    @Test func ClickThrough_aNewStylesBubbleAndItsShadowPassClicksThrough() throws {
        let short = CGRect(x: 0, y: 0, width: 800, height: 56)
        let cases: [(name: String, geometry: PetGeometry, connection: BubbleConnection)] = [
            ("above", Screens.geometry(), .above),
            ("side", PetGeometry(scale: 1, homeOrigin: CGPoint(x: 100, y: 0), displayFrame: short, visibleFrame: short), .side),
        ]
        for style in BubbleDesign.allIds.filter({ $0 >= 13 }) { for c in cases { for pixelScale in [1.0, 2.0] { for appearance in [BubbleAppearance.light, .dark] {
            let request = StageRequest(frame: Frames.pose("think", scene: .thinking, bubble: BubbleState(style: style, scene: .thinking)), now: 0.1, geometry: c.geometry,
                                       pixelScale: pixelScale,
                                       content: BubbleContent(scene: .thinking, elapsed: 0.7, duration: 5, verb: "Cogitating", pastVerb: "Cooked", appearance: appearance))
            let stage = try #require(try stageRenderer.compose(request), "style \(style) \(c.name)")
            let pictures = try PanelPictures(stage)
            let bubble = try #require(stage.bubble, "style \(style) \(c.name) \(pixelScale)x")
            #expect(bubble.plan.connection == c.connection, "style \(style) \(c.name): the bubble is \(bubble.plan.connection)")
            let box = bubble.plan.boxRect, shape = bubble.plan.shapeRect, picture = bubble.rect
            let inside = [CGPoint(x: box.midX, y: box.midY), CGPoint(x: box.minX + 3, y: box.minY + 3), CGPoint(x: box.maxX - 3, y: box.maxY - 3),
                          CGPoint(x: shape.midX, y: shape.minY + 1)]
            // the shadow margin: the picture's own bottom edge row and its side columns, outside the shape
            let margin = [CGPoint(x: picture.midX, y: picture.minY + 0.25), CGPoint(x: picture.minX + 0.25, y: picture.midY), CGPoint(x: picture.maxX - 0.25, y: picture.midY)]
            for point in inside + margin {
                #expect(pictures.receiver(at: point) == .appBehind, "style \(style) \(c.name) \(pixelScale)x \(appearance): a click at \(point) on the bubble would be taken")
            }
        } } } }
    }
}
