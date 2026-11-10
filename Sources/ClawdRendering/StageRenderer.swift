import Foundation
import CoreGraphics
import ClawdCore

/// What the stage needs for one picture. The scheduler's frame says what Clawd is doing; the rest is where and how big.
public struct StageRequest {
    public var frame: SchedulerFrame
    /// The scheduler's clock (the monotonic `PetClock.now`): playback time is `now - startedAt`.
    public var now: TimeInterval
    /// The rest pose's blink (the scheduler leaves it to the controller).
    public var blink: Bool
    /// Size, home, display and visible frame. `scale` is the effective size (`Placement.effectiveScale`).
    public var geometry: PetGeometry
    /// Device pixels per point of the display (1 on the ultrawide, 2 on Retina).
    public var pixelScale: Double
    /// The words of a bubble; its style and scene come from `frame.bubble`.
    public var content: BubbleContent
    /// The open menu's rectangle, global points (it joins the hit region while it is open).
    public var menuRect: CGRect?
    /// Where the bubble sits (the `bubbleSide` setting): the chosen side, an absolute screen direction. A placement-time input only.
    public var bubbleSide: BubbleSide
    /// The placement memory of the bubble on screen (amendment D-2 E): what the last presented frame committed. The renderer is pure: it reads this and
    /// proposes the next one in the layout; the runtime commits it only after the frame is presented.
    public var bubbleMemory: BubbleMemory?
    public init(frame: SchedulerFrame, now: TimeInterval, blink: Bool = false, geometry: PetGeometry, pixelScale: Double = 1,
                content: BubbleContent = BubbleContent(scene: .listening), menuRect: CGRect? = nil, bubbleSide: BubbleSide = .below,
                bubbleMemory: BubbleMemory? = nil) {
        self.frame = frame; self.now = now; self.blink = blink; self.geometry = geometry; self.pixelScale = pixelScale
        self.content = content; self.menuRect = menuRect; self.bubbleSide = bubbleSide; self.bubbleMemory = bubbleMemory
    }
}

public struct PlacedBubble {
    public let style: Int
    public let plan: BubblePlan
    public let bitmap: BubbleBitmap
    /// The bubble picture in global points, on the device pixel grid.
    public var rect: CGRect { plan.rect }
}

/// Where everything of one picture is, in global AppKit points (y up), before any pixel is drawn.
public struct StageLayout {
    public let composed: ComposedClawd
    /// Clawd's 12 x 12 canvas. It depends on home, walk offset and size, and on nothing else: never on the bubble, the stage or a look.
    public let canvas: CGRect
    /// Everything Clawd draws: his stage and every look layer.
    public let clawdRect: CGRect
    public let clawdTopLeft: CGPoint
    public let cellPt: Double
    public let bubble: PlacedBubble?
    /// The window: the union of Clawd's picture and the bubble, inside the visible frame, Clawd alone down to the display's bottom edge (`PetGeometry.windowArea`).
    public let panel: CGRect
    /// The head anchor H (top centre of the head or the worn costume).
    public let headTop: CGPoint
    public let pixelScale: Double
    public let menuRect: CGRect?
    /// F (amendment D-3): the bottom of Clawd's feet, or of an item that hangs under them, on the torso's centre column. nil: the frame has no anchor.
    public let feetBottom: CGPoint?
    /// The memory this layout proposes (nil: no bubble is shown). It becomes the request's memory once the frame is presented.
    public let memory: BubbleMemory?
    /// How the bubble's placement differs from the one the request's memory shows (nil: it does not).
    public let placementChange: PlacementChangeKind?
    public var hit: HitRegion { HitRegion(raster: composed.hit, topLeft: clawdTopLeft, cellPt: cellPt, menuRect: menuRect) }
    public var clawdMask: ClawdMask { ClawdMask(raster: composed.raster, topLeft: clawdTopLeft, cellPt: cellPt) }
    /// Device pixels per art cell: a whole number at every size on Retina and at every size but 0.75 at 1x (1.5 px there).
    public var cellPixels: Double { cellPt * pixelScale }
    /// Whether every cell is the same whole number of device pixels (`cellFactor`).
    public var wholeCells: Bool { abs(cellPixels - cellPixels.rounded()) < 1e-6 }
    /// Device pixels per art cell, rounded; exact when `wholeCells`.
    public var cellFactor: Int { Int(cellPixels.rounded()) }
    /// The device-pixel edges of the raster's columns and rows, counted from its first column and row (width + 1 and height + 1 of them).
    public var columnEdges: [Int] { Self.edges(count: composed.raster.width, canvasAt: composed.canvasOrigin.x, cellPixels: cellPixels) }
    public var rowEdges: [Int] { Self.edges(count: composed.raster.height, canvasAt: composed.canvasOrigin.y, cellPixels: cellPixels) }
    /// Cell edges on the device grid, cut from the canvas's corner: edge k lies floor(k x cellPixels) pixels from it. With whole cells that is
    /// k x cellFactor; with 1.5 px cells they come out 1 and 2 px in turn, so a 4 pt unit (two cells) is always 3 px and the cut moves with
    /// Clawd, never under him.
    public static func edges(count: Int, canvasAt origin: Int, cellPixels: Double) -> [Int] {
        func edge(_ cell: Int) -> Int { Int((Double(cell) * cellPixels + 1e-6).rounded(.down)) }
        let first = edge(-origin)
        return (0...max(0, count)).map { edge($0 - origin) - first }
    }
    /// Where Clawd's raster begins inside the window's device-pixel picture (its top-left cell).
    public var clawdPixelOrigin: (x: Int, y: Int) {
        func edge(_ cell: Int) -> Int { Int((Double(cell) * cellPixels + 1e-6).rounded(.down)) }
        let x = Int(((canvas.minX - panel.minX) * pixelScale).rounded()), y = Int(((panel.maxY - canvas.maxY) * pixelScale).rounded())
        return (x + edge(-composed.canvasOrigin.x), y + edge(-composed.canvasOrigin.y))
    }
    /// Clawd's raster in device pixels: every cell a block of one colour on the edges above.
    public func clawdPixels() -> Raster {
        wholeCells ? composed.raster.upscaled(by: cellFactor) : composed.raster.upscaled(columns: columnEdges, rows: rowEdges)
    }
}

/// One finished picture of the panel.
public struct StageFrame {
    public let image: CGImage
    /// The same picture as a raster of device pixels.
    public let pixels: Raster
    public let layout: StageLayout
    public var pixelScale: Double { layout.pixelScale }
    public var panelFrame: CGRect { layout.panel }
    public var canvas: CGRect { layout.canvas }
    public var clawdRect: CGRect { layout.clawdRect }
    public var bubble: PlacedBubble? { layout.bubble }
    public var hit: HitRegion { layout.hit }
    public var composed: ComposedClawd { layout.composed }
    public var headTop: CGPoint { layout.headTop }
}

public final class StageRenderer {
    /// How often a glide (an under-feet look such as the skateboard) is redrawn while it moves.
    public static let glideFrameInterval: TimeInterval = 1.0 / 30
    /// Seconds from `elapsed` into a glide stretch to the next point of its redraw grid; a point less than `glideGridMinimum` away is skipped.
    static func untilNextGlideRedraw(elapsed: TimeInterval) -> TimeInterval {
        let step = glideFrameInterval
        var next = (max(0, elapsed) / step + 1e-9).rounded(.down) * step + step
        if next - elapsed < glideGridMinimum { next += step }
        return next - elapsed
    }
    static let glideGridMinimum: TimeInterval = 0.005
    public let art: ClawdArt
    public let elements: ClaudeElements
    public var guards: StageGuards = .all

    public init(art: URL) throws {
        self.art = try ClawdArt(directory: art)
        elements = ClaudeElements(directory: art)
    }

    // MARK: Clawd's picture

    /// Composed pictures are kept (at most `cacheLimit`): a looping motion shows the same frames again and again, and the rest pose
    /// every few seconds. A cache miss composes; a hit costs a dictionary lookup.
    static let cacheLimit = 512
    private var cache: [String: ComposedClawd] = [:]
    private var cacheOrder: [String] = []
    private let cacheLock = NSLock()
    private func cached(_ key: String, _ make: () -> ComposedClawd) -> ComposedClawd {
        cacheLock.lock()
        if let hit = cache[key] { cacheLock.unlock(); return hit }
        cacheLock.unlock()
        let made = make()
        cacheLock.lock(); defer { cacheLock.unlock() }
        if cache[key] == nil {
            cache[key] = made; cacheOrder.append(key)
            if cacheOrder.count > Self.cacheLimit { cache[cacheOrder.removeFirst()] = nil }
        }
        return made
    }
    private func compose(_ clip: Clip, _ index: Int, _ look: LookArt, layersOn: Bool = true, mirrored: Bool = false) -> ComposedClawd {
        cached("\(clip.id)#\(index)#\(look.id)#\(layersOn)#\(mirrored)") {
            StageCompose.compose(clip: clip, frameIndex: index, look: look, layersOn: layersOn, mirrored: mirrored)
        }
    }

    /// The pose a v1 scene falls back to when its motion has ended while the scene goes on.
    static func scenePose(_ scene: Scene) -> String {
        switch scene {
        case .listening: return "listen"
        case .thinking: return "think"
        case .sent: return "hop"
        case .sleep: return "sleep"
        case .drag: return "dangle"
        default: return "idle"
        }
    }

    /// Clawd's picture for a frame: a v1 pose, a motion frame, the glide, or a look-change frame, in the look being drawn.
    public func clawd(for frame: SchedulerFrame, now: TimeInterval, blink: Bool) throws -> ComposedClawd {
        let look = try art.look(frame.displayedLook)
        func restFrame() throws -> ComposedClawd {
            let clip = try art.pose(blink ? "blink" : "idle")
            return compose(clip, 0, look)
        }
        guard let playback = frame.playback else { return try restFrame() }
        let elapsed = now - playback.startedAt
        switch playback.source {
        case .pose(let name):
            let clip = try art.pose(name)
            return compose(clip, clip.index(at: elapsed), look, mirrored: playback.mirrored)
        case .glide:
            // The skateboard rides: the frames of D14-ride over the seconds walked, mirrored when Clawd goes left. A glide with no ride (the art
            // has none, or the leg is too short) keeps the rest picture and only its place moves.
            guard let ride = playback.ride, art.hasMotion(GlideRide.motionID) else { return try restFrame() }
            let clip = try art.motion(GlideRide.motionID)
            let index = ride.frame(at: elapsed)
            guard clip.frames.indices.contains(index) else { return try restFrame() }
            let signature = look.signature.contains(GlideRide.motionID)
            return compose(clip, index, look, layersOn: look.layerOnSignature || !signature, mirrored: playback.mirrored)
        case .transition(let from, let to):
            let k = LookTransition.frameIndex(progress: frame.transitionProgress ?? 0)
            return try LookTransition.compose(art: art, from: try art.look(from), to: try art.look(to), frame: k)
        case .motion(let id):
            let clip = try art.motion(id)
            if let end = playback.endsAt, now >= end, !(clip.holds || playback.holdsLastFrame) {
                // The motion is over while its scene goes on: the scene's v1 pose, or the rest pose.
                let name = Self.scenePose(frame.dragging ? .drag : frame.scene)
                let pose = try art.pose(name)
                return compose(pose, name == "hop" ? pose.frames.count - 1 : pose.loopStart, look)
            }
            let held = playback.holdsLastFrame || clip.holds
            let index = held && elapsed >= clip.duration ? clip.frames.count - 1 : clip.index(at: elapsed, loops: playback.loops)
            let signature = look.signature.contains(id)
            // Under its own look a signature motion draws its own frames only where they carry the look's props (SignatureSpan.swift):
            // elsewhere the look's rest picture, layers on, so the look never shows without its props.
            if signature, !look.layerOnSignature, !SignatureSpan.drawsOwnFrame(look: look.id, motion: id, index: index) { return try restFrame() }
            return compose(clip, index, look, layersOn: look.layerOnSignature || !signature, mirrored: playback.mirrored)
        }
    }

    // MARK: the panel

    private func snap(_ v: Double, _ backing: Double) -> Double { (v * backing).rounded() / backing }

    /// Where everything goes, without drawing a pixel. nil when nothing is shown (hidden, in a quiet condition).
    public func layout(_ request: StageRequest) throws -> StageLayout? {
        let frame = request.frame
        guard frame.visibility == .visible else { return nil }
        let backing = max(1, min(4, request.pixelScale))
        let geometry = request.geometry
        let cellPt = BubbleLayoutMetrics.cellPt(scale: geometry.scale)
        let composed = try clawd(for: frame, now: request.now, blink: request.blink)

        // Clawd's canvas: home plus the walk, on the device pixel grid. Nothing below changes it.
        let canvasSide = Double(StageGeometry.canvasCells) * cellPt
        var canvas = CGRect(x: snap(Double(geometry.homeOrigin.x) + frame.walkOffset, backing), y: snap(Double(geometry.homeOrigin.y), backing),
                            width: canvasSide, height: canvasSide)
        func topLeft(_ canvas: CGRect) -> CGPoint {
            CGPoint(x: canvas.minX - Double(composed.canvasOrigin.x) * cellPt, y: canvas.maxY + Double(composed.canvasOrigin.y) * cellPt)
        }
        func clawdRect(_ canvas: CGRect) -> CGRect {
            let tl = topLeft(canvas)
            return CGRect(x: tl.x, y: tl.y - Double(composed.raster.height) * cellPt,
                          width: Double(composed.raster.width) * cellPt, height: Double(composed.raster.height) * cellPt)
        }
        let visible = geometry.visibleFrame

        // The bubble.
        var decided: BubbleDecision?
        func place(at canvas: CGRect) -> PlacedBubble? {
            decided = nil
            guard let bubble = frame.bubble, let headRow = composed.headTopRow, let column = composed.headCentreColumn,
                  let centreRow = composed.bodyCentreRow else { return nil }
            var content = request.content; content.scene = bubble.scene
            let level = BubbleText.fadeLevel(scene: bubble.scene, elapsed: content.elapsed)
            guard level > 0 else { return nil }
            let design = BubbleDesign.resolved(bubble.style)
            let text = BubbleText.content(content, elements: elements, design: design)
            let runs = BubbleText.fitted(text.runs, dots: text.dots, design: design)
            // The body window's rectangle: the hit cells' bounds on the device grid. A style that keeps off it is placed clear of it too.
            var bodyWindow: CGRect?
            if design.keepsOffTheBodyWindow, let bounds = HitRegion(raster: composed.hit, topLeft: topLeft(canvas), cellPt: cellPt).bounds {
                let minX = (bounds.minX * backing).rounded(.down) / backing, minY = (bounds.minY * backing).rounded(.down) / backing
                let maxX = (bounds.maxX * backing).rounded(.up) / backing, maxY = (bounds.maxY * backing).rounded(.up) / backing
                bodyWindow = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
            }
            let headX = canvas.minX + Double(column) * cellPt
            let feet = composed.feetBottomRow.map { CGPoint(x: headX, y: canvas.maxY - Double($0) * cellPt) }
            let site = BubbleSite(headTop: CGPoint(x: headX, y: canvas.maxY - Double(headRow) * cellPt),
                                  bodyCentreY: canvas.maxY - Double(centreRow) * cellPt, unit: geometry.unit,
                                  display: geometry.displayFrame, visible: visible,
                                  clawd: ClawdMask(raster: composed.raster, topLeft: topLeft(canvas), cellPt: cellPt), bodyWindow: bodyWindow,
                                  feetBottom: feet, menu: request.menuRect)
            // The SENT fade keeps a still-safe placement (D-5 10): no return during it.
            guard let decision = BubblePlacement.decide(design: design, runs: runs, dots: text.dots, site: site, scale: geometry.scale, guards: guards,
                                                        side: request.bubbleSide, backing: backing, memory: request.bubbleMemory, now: request.now,
                                                        holdReturn: bubble.scene == .sent) else { return nil }
            decided = decision
            var plan = decision.plan
            plan.rect.origin = CGPoint(x: snap(plan.rect.minX, backing), y: snap(plan.rect.minY, backing))
            plan.shapeRect.origin = CGPoint(x: snap(plan.shapeRect.minX, backing), y: snap(plan.shapeRect.minY, backing))
            plan.boxRect.origin = CGPoint(x: snap(plan.boxRect.minX, backing), y: snap(plan.boxRect.minY, backing))
            let bitmap = (plan.connectorHidden ? design.withoutConnector : design).render(
                runs: runs, dots: text.dots, opening: plan.opening, connection: plan.connection, variant: plan.variant, tipColumn: plan.tipColumn, fadeLevel: level,
                backing: backing, appearance: content.appearance)
            return PlacedBubble(style: design.id, plan: plan, bitmap: bitmap)
        }
        var placed = place(at: canvas)

        // The window is the union of Clawd's picture and the bubble, inside the visible frame.
        var union = clawdRect(canvas)
        if let placed { union = union.union(placed.rect) }
        if let menu = request.menuRect { union = union.union(menu) }
        if !guards.contains(.fixedClawd) {
            // v1's behaviour: the window as a whole is pushed inside the visible frame, and Clawd goes with it.
            var dx = 0.0, dy = 0.0
            if union.maxX > visible.maxX { dx = visible.maxX - union.maxX }
            if union.minX + dx < visible.minX { dx = visible.minX - union.minX }
            if union.maxY > visible.maxY { dy = visible.maxY - union.maxY }
            if union.minY + dy < visible.minY { dy = visible.minY - union.minY }
            canvas = canvas.offsetBy(dx: dx, dy: dy)
            placed = place(at: canvas)
            union = clawdRect(canvas)
            if let placed { union = union.union(placed.rect) }
        }
        var panel = union.intersection(geometry.windowArea)
        if panel.isNull || panel.isEmpty { panel = clawdRect(canvas) }
        let minX = (panel.minX * backing).rounded(.down) / backing, minY = (panel.minY * backing).rounded(.down) / backing
        let maxX = (panel.maxX * backing).rounded(.up) / backing, maxY = (panel.maxY * backing).rounded(.up) / backing
        panel = CGRect(x: minX, y: minY, width: maxX - minX, height: maxY - minY)
        let headTop = CGPoint(x: canvas.minX + Double(composed.headCentreColumn ?? StageGeometry.canvasCells / 2) * cellPt,
                              y: canvas.maxY - Double(composed.headTopRow ?? 0) * cellPt)
        let feetBottom = composed.feetBottomRow.map { CGPoint(x: headTop.x, y: canvas.maxY - Double($0) * cellPt) }
        return StageLayout(composed: composed, canvas: canvas, clawdRect: clawdRect(canvas), clawdTopLeft: topLeft(canvas), cellPt: cellPt,
                           bubble: placed, panel: panel, headTop: headTop, pixelScale: backing, menuRect: request.menuRect,
                           feetBottom: feetBottom, memory: placed == nil ? nil : decided?.memory, placementChange: placed == nil ? nil : decided?.change)
    }

    /// Draws everything. nil when nothing is shown (hidden, in a quiet condition).
    public func compose(_ request: StageRequest) throws -> StageFrame? {
        guard let layout = try layout(request) else { return nil }
        let backing = layout.pixelScale, panel = layout.panel
        // Pixels: Clawd's cells on the device grid (`clawdPixels`) and the bubble's pixels, enlarged by a whole device-pixel factor.
        let pxW = max(1, Int((panel.width * backing).rounded())), pxH = max(1, Int((panel.height * backing).rounded()))
        var picture = Raster(width: pxW, height: pxH)
        let origin = layout.clawdPixelOrigin
        picture.blit(layout.clawdPixels(), x: origin.x, y: origin.y)
        if let placed = layout.bubble, placed.bitmap.raster.width > 0 {
            // A pixel style's picture is enlarged by a whole factor; a smooth style's was drawn at the backing and is blitted 1:1.
            let design = BubbleDesign.resolved(placed.style)
            let factor = design.isSmooth ? 1 : Int((design.pixelPt * backing).rounded())
            picture.blit(placed.bitmap.raster.upscaled(by: factor), x: Int(((placed.rect.minX - panel.minX) * backing).rounded()),
                         y: Int(((panel.maxY - placed.rect.maxY) * backing).rounded()))
        }
        return StageFrame(image: try picture.cgImage(), pixels: picture, layout: layout)
    }

    // MARK: timing

    /// The layout the picture of this request has: the frame just composed, else the layout worked out.
    private func layoutOf(_ request: StageRequest, composed: StageFrame?) -> StageLayout? {
        if let composed { return composed.layout }
        return try? layout(request)
    }

    /// Seconds until the picture changes by itself (a new motion frame, a spinner tick, the cursor, a fade step, a look-change frame). The bubble's
    /// own boundary counts only when the picture shows the bubble: a bubble that placement dropped (a display too small for it) arms no wake.
    public func nextChange(_ request: StageRequest, composed: StageFrame? = nil) -> TimeInterval? {
        let frame = request.frame
        guard frame.visibility == .visible else { return nil }
        var intervals: [TimeInterval] = []
        if let playback = frame.playback {
            let elapsed = request.now - playback.startedAt
            switch playback.source {
            case .pose(let name):
                if let clip = try? art.pose(name), let next = clip.nextChange(after: elapsed) { intervals.append(next) }
            case .motion(let id):
                if let clip = try? art.motion(id) {
                    if let next = clip.nextChange(after: elapsed, loops: playback.loops) { intervals.append(next) }
                    if let end = playback.endsAt, request.now < end { intervals.append(end - request.now) }
                }
            case .transition:
                if let next = LookTransition.nextChange(progress: frame.transitionProgress ?? 0, duration: playback.duration) { intervals.append(next) }
            case .glide:
                // A glide keeps one still pose while the position moves every instant: without its own wake it was drawn only when
                // some other timer fired, about three times a second, and slid in jumps. A glide that stands (the pointer is in the way,
                // the ride's frame is held) changes nothing until the scheduler moves it again, and asks for no redraw.
                // The redraws lie on a fixed grid from the start of the stretch (the next point is the previous one plus a step): a tick handled
                // late does not push the grid, and one that missed whole steps skips to the next point.
                if playback.ride?.held == nil { intervals.append(Self.untilNextGlideRedraw(elapsed: request.now - playback.startedAt)) }
            }
        }
        let shown = frame.bubble == nil ? nil : layoutOf(request, composed: composed)
        if let bubble = frame.bubble, shown?.bubble != nil {
            var content = request.content; content.scene = bubble.scene
            // A bubble that fell back to another placement returns to a better one after it has fitted for the return delay (D-2 E3): the layout
            // at that instant is what moves it, so the wake is armed for it even when nothing else would change.
            if let since = shown?.memory?.pendingSince {
                let remaining = since + BubbleLayout.returnDelay - request.now
                if remaining > 0 { intervals.append(remaining) }
            }
            if let next = BubbleText.nextChange(scene: bubble.scene, elapsed: content.elapsed, design: BubbleDesign.resolved(bubble.style),
                                                reduceMotion: content.reduceMotion, tick: elements.tick) { intervals.append(next) }
        }
        return intervals.min()
    }
}

enum BubbleLayoutMetrics {
    /// One art cell in points: half a Clawd unit.
    static func cellPt(scale: Double) -> Double { PetCatalog.pointsPerUnit * scale / 2 }
}
