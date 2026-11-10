import Testing
import Foundation
import AppKit
import CoreGraphics
import ClawdCore
import ClawdRendering
import ClawdDesktop

// Sizes 0.5 and 0.75 (2026-11-08). Nothing here shows a window or touches a real state directory.

/// x * b is a whole number of device pixels.
private func onGrid(_ v: Double, _ b: Double) -> Bool { abs(v * b - (v * b).rounded()) < 1e-6 }

@Suite("Small sizes", .serialized)
struct SizeSmallSuite {
    // MARK: effectiveScale

    @Test func SizeSmall_everySizeIsTheSizePickedOnEveryDisplay() {
        // Tom, 2026-11-09: 0.75 looked like 0.5 on the 1x monitor; the size was cut to whole device pixels per cell (and 1.5 to 1).
        for size in AgentControl.allowedScales {
            #expect(Placement.effectiveScale(size) == size, "\(size)")
            for backing in [1.0, 2.0, 3.0] {
                // A 4 pt unit (two cells) is a whole number of device pixels at every size on every backing; only a cell can fall between
                // pixels (0.75 at an odd backing: 1.5 px at 1x, 4.5 px at 3x).
                #expect(onGrid(4 * size, backing), "\(size) at \(backing): a unit is \(4 * size * backing) px")
            }
        }
        #expect(Placement.effectiveScale(.nan) == 1 && Placement.effectiveScale(9) == 4 && Placement.effectiveScale(0.25) == 0.5)
    }

    @Test func SizeSmall_cellEdgesAreWholeFactorsOrAlternateOnTheCanvasGrid() {
        #expect(StageLayout.edges(count: 4, canvasAt: 0, cellPixels: 3) == [0, 3, 6, 9, 12])
        #expect(StageLayout.edges(count: 6, canvasAt: 0, cellPixels: 1.5) == [0, 1, 3, 4, 6, 7, 9])
        // Cut from the canvas's corner: with one cell before the canvas, the canvas's own cells still come out 1 then 2 px.
        let shifted = StageLayout.edges(count: 5, canvasAt: 1, cellPixels: 1.5)
        #expect(shifted == [0, 2, 3, 5, 6, 8], "\(shifted)")
        #expect(Raster(width: 2, height: 1, data: [9, 9, 9, 255, 7, 7, 7, 255]).upscaled(columns: [0, 1, 3], rows: [0, 2]).data
                == [9, 9, 9, 255, 7, 7, 7, 255, 7, 7, 7, 255, 9, 9, 9, 255, 7, 7, 7, 255, 7, 7, 7, 255])
        // Decreasing edges would write past the picture; the raster comes back unchanged instead.
        let two = Raster(width: 2, height: 1, data: [9, 9, 9, 255, 7, 7, 7, 255])
        #expect(two.upscaled(columns: [0, 2, 1], rows: [0, 1]).data == two.data)
    }

    // MARK: control.json and the saved state

    @Test func SizeSmall_controlAcceptsHalfAndThreeQuartersAndRejectsTheRest() throws {
        func scale(_ text: String) throws -> Double { try JSONDecoder().decode(AgentControl.self, from: Data(text.utf8)).scale }
        #expect(try scale(#"{"scale":0.75}"#) == 0.75)
        #expect(try scale(#"{"scale":0.5}"#) == 0.5)
        #expect(try scale(#"{"scale":0.6}"#) == 1)
        #expect(try scale(#"{"scale":0.25}"#) == 1)
        #expect(AgentControl.allowedScales == [0.5, 0.75, 1, 1.5, 2, 3, 4])
    }

    @Test func SizeSmall_controlAndSavedStateKeepTheSizeThroughAJSONRoundTrip() throws {
        for value in [0.5, 0.75] {
            var control = AgentControl(); control.scale = value
            let back = try JSONDecoder().decode(AgentControl.self, from: JSONEncoder().encode(control))
            #expect(back.scale == value, "control \(value)")
        }
        let state = try JSONDecoder().decode(AgentState.self, from: Data(#"{"xFrac":0.4,"feetFrac":0.1,"scale":0.75}"#.utf8))
        #expect(state.scale == 0.75 && state.position.scale == 0.75)
        // The size the agent runs at comes from the control file, never from the saved state.
        #expect(Placement.effectiveScale(try JSONDecoder().decode(AgentControl.self, from: Data(#"{"scale":0.75}"#.utf8)).scale) == 0.75)
    }

    // MARK: the stage at 0.5 and 0.75

    /// Whole-pixel cells only: 0.75 at 1x (1.5 px cells) has its own test below.
    private static let cases: [(requested: Double, backing: Double)] = [(0.5, 1), (0.5, 2), (0.75, 2), (1.5, 1)]
    private static let homes: [Double] = [4, 700, 1405]
    private static let walks: [Double] = [0, 13, -13]

    private func request(style: Int = 1, scene: Scene = .thinking, side: BubbleSide, home: Double, walk: Double, requested: Double, backing: Double) -> StageRequest {
        var frame = Frames.rest(bubble: BubbleState(style: style, scene: scene), scene: scene)
        frame.walkOffset = walk
        return sideRequest(style: style, scene: scene, side: side, homeX: home, scale: Placement.effectiveScale(requested),
                           pixelScale: backing, frame: frame)
    }

    /// Every on-screen guarantee of one case: cell factor, canvas, anchors, hit region, panel and bubble on the device grid, and the image `compose` returns
    /// (the stage's rendered picture) as whole device pixels equal to the panel times the backing.
    private func check(_ r: StageRequest, _ tag: String, requested: Double, backing b: Double) throws {
        let effective = Placement.effectiveScale(requested)
        let layout = try #require(try stageRenderer.layout(r), Comment(rawValue: tag))
        #expect(layout.cellFactor == Int((2 * effective * b).rounded()) && onGrid(2 * effective, b), "\(tag): cellFactor \(layout.cellFactor)")
        #expect(layout.canvas.width == Double(StageGeometry.canvasCells) * layout.cellPt && layout.canvas.width == 48 * effective, "\(tag): canvas \(layout.canvas)")
        let points: [(String, Double)] = [
            ("canvas.x", layout.canvas.minX), ("canvas.y", layout.canvas.minY), ("clawd.x", layout.clawdRect.minX), ("clawd.y", layout.clawdRect.minY),
            ("clawd.w", layout.clawdRect.width), ("clawd.h", layout.clawdRect.height), ("headTop.x", layout.headTop.x), ("headTop.y", layout.headTop.y),
            ("panel.x", layout.panel.minX), ("panel.y", layout.panel.minY), ("panel.w", layout.panel.width), ("panel.h", layout.panel.height),
        ] + (layout.feetBottom.map { [("feet.x", $0.x), ("feet.y", $0.y)] } ?? [])
            + (layout.hit.bounds.map { [("hit.minX", $0.minX), ("hit.minY", $0.minY), ("hit.maxX", $0.maxX), ("hit.maxY", $0.maxY)] } ?? [])
        for (name, value) in points { #expect(onGrid(value, b), "\(tag): \(name) = \(value)") }
        #expect(layout.feetBottom != nil && layout.hit.bounds != nil, "\(tag): feet and hit region exist")
        let bubble = try #require(layout.bubble, Comment(rawValue: tag + ": no bubble"))
        for (name, value) in [("x", bubble.rect.minX), ("y", bubble.rect.minY), ("w", bubble.rect.width), ("h", bubble.rect.height)] {
            #expect(onGrid(value, b), "\(tag): bubble \(name) = \(value)")
        }
        let frame = try #require(try stageRenderer.compose(r), Comment(rawValue: tag))
        let wide = Int((layout.panel.width * b).rounded()), high = Int((layout.panel.height * b).rounded())
        #expect(frame.image.width == wide && frame.image.height == high, "\(tag): image \(frame.image.width) x \(frame.image.height), panel x backing \(wide) x \(high)")
        #expect(frame.pixels.width == wide && frame.pixels.height == high, "\(tag): pixels \(frame.pixels.width) x \(frame.pixels.height)")
    }

    @Test func SizeSmall_theCanvasAndEveryAnchorLieOnTheDeviceGrid() throws {
        var checked = 0
        for (requested, backing) in Self.cases { for home in Self.homes { for side in BubbleSide.allCases { for walk in Self.walks {
            let r = request(side: side, home: home, walk: walk, requested: requested, backing: backing)
            try check(r, "size \(requested) b\(backing) home \(home) \(side) walk \(walk)", requested: requested, backing: backing)
            checked += 1
        } } } }
        #expect(checked == Self.cases.count * Self.homes.count * 4 * Self.walks.count)
    }

    @Test func SizeSmall_everyStyleAndSceneStillPlacesABubbleOnTheGridAtEveryWalkOffset() throws {
        var checked = 0
        for (requested, backing) in Self.cases { for home in Self.homes { for side in BubbleSide.allCases { for walk in Self.walks {
            for style in BubbleDesign.allIds { for scene in [Scene.listening, .thinking, .sent] {
                let r = request(style: style, scene: scene, side: side, home: home, walk: walk, requested: requested, backing: backing)
                try check(r, "style \(style) \(scene) size \(requested) b\(backing) home \(home) \(side) walk \(walk)", requested: requested, backing: backing)
                checked += 1
            } }
        } } } }
        #expect(checked == Self.cases.count * Self.homes.count * 4 * Self.walks.count * BubbleDesign.allIds.count * 3)
    }

    /// Tom, 2026-11-09: on the 1x monitor each size must be drawn at its own size. 0.75 at 1x has 1.5 px cells; they are cut 1 and 2 px in turn on
    /// the canvas's grid, the windows stay on device pixels, and the body window takes exactly the pixels of the hit cells.
    @Test func SizeSmall_atOneXEverySizeIsDrawnAtItsOwnSize() throws {
        var bodyWidth: [Double: Int] = [:]
        for requested in [0.5, 0.75, 1, 1.5] { for home in Self.homes { for walk in Self.walks {
            let tag = "size \(requested) home \(home) walk \(walk)"
            let r = request(side: .right, home: home, walk: walk, requested: requested, backing: 1)
            let frame = try #require(try stageRenderer.compose(r), Comment(rawValue: tag))
            let layout = frame.layout
            #expect(layout.canvas.width == 48 * requested && onGrid(layout.canvas.minX, 1) && onGrid(layout.canvas.minY, 1), "\(tag): canvas \(layout.canvas)")
            let ox = layout.composed.canvasOrigin.x, oy = layout.composed.canvasOrigin.y, columns = layout.columnEdges, rows = layout.rowEdges
            try #require(columns.count > ox + 24 && rows.count > oy + 24, Comment(rawValue: tag))
            #expect(columns[ox + 24] - columns[ox] == Int(48 * requested) && rows[oy + 24] - rows[oy] == Int(48 * requested), "\(tag): canvas cells")
            for k in stride(from: 0, to: 24, by: 2) {
                #expect(columns[ox + k + 2] - columns[ox + k] == Int(4 * requested) && rows[oy + k + 2] - rows[oy + k] == Int(4 * requested), "\(tag): unit \(k / 2)")
            }
            #expect(frame.pixels.width == Int(layout.panel.width) && frame.pixels.height == Int(layout.panel.height), "\(tag): picture is the panel in pixels")
            let pictures = try PanelPictures(frame)
            let body = try #require(pictures.body, Comment(rawValue: tag + ": no body window"))
            for (name, v) in [("panel.x", pictures.stage.rect.minX), ("panel.y", pictures.stage.rect.minY), ("body.x", body.rect.minX), ("body.y", body.rect.minY),
                              ("body.w", body.rect.width), ("body.h", body.rect.height)] {
                #expect(onGrid(v, 1), "\(tag): \(name) = \(v)")
            }
            // Every pixel of a hit cell is in the body window, none is left in the stage window (which ignores clicks).
            let hit = layout.composed.hit, origin = layout.clawdPixelOrigin
            var leaked = 0
            for cy in 0..<hit.height { for cx in 0..<hit.width where hit.isOpaque(cx, cy) {
                for py in (origin.y + rows[cy])..<(origin.y + rows[cy + 1]) { for px in (origin.x + columns[cx])..<(origin.x + columns[cx + 1]) {
                    guard px >= 0, py >= 0, px < frame.pixels.width, py < frame.pixels.height else { continue }
                    if pictures.stage.pixels.data[(py * frame.pixels.width + px) * 4 + 3] != 0 { leaked += 1 }
                } }
            } }
            #expect(leaked == 0, "\(tag): \(leaked) pixels of the hit cells are left in the stage window")
            var joined = pictures.stage.pixels
            joined.blit(body.pixels, x: Int(body.rect.minX - pictures.stage.rect.minX), y: Int(pictures.stage.rect.maxY - body.rect.maxY))
            #expect(joined.data == frame.pixels.data, "\(tag): the stage and body pictures put back together are the picture")
            if home == 700 && walk == 0 { bodyWidth[requested] = body.pixels.width }
        } } }
        let w = try #require(bodyWidth[0.5]), three = try #require(bodyWidth[0.75]), one = try #require(bodyWidth[1]), big = try #require(bodyWidth[1.5])
        #expect(w < three && three < one && one < big, "body widths 0.5 \(w), 0.75 \(three), 1 \(one), 1.5 \(big)")
        #expect(abs(Double(three) - 0.75 * Double(one)) <= 1.5 && abs(Double(big) - 1.5 * Double(one)) <= 1.5, "in proportion: \(w) \(three) \(one) \(big)")
    }

    @Test func SizeSmall_theMenuSelectsTheSmallSizeChips() {
        let layout = MenuLayout(looks: stageRenderer.art.catalog.looks.map(\.id), drawnStyles: Set(SchedulerSettings.bubbleStyles))
        #expect(layout.items.filter { $0.key == "size" }.map(\.value) == ["0.5", "0.75", "1", "1.5", "2", "3", "4"])
        for scale in [0.5, 0.75] {
            var selection = MenuSelection(); selection.scale = scale
            let chosen = layout.items.filter { $0.key == "size" && selection.isSelected($0) }.map(\.value)
            #expect(chosen == [scale == 0.5 ? "0.5" : "0.75"], "scale \(scale): \(chosen)")
        }
    }

    // MARK: Settings

    @Test @MainActor func SizeSmall_settingsOffersSevenSizesAndRunsAndShowsTheSmallOnes() throws {
        #expect(SettingsChoice.sizes == ["0.5", "0.75", "1", "1.5", "2", "3", "4"])
        #expect(SettingsActions.action(for: .size("0.75"), shownOn: true).arguments == ["size", "0.75"])
        #expect(SettingsActions.action(for: .size("0.5"), shownOn: true).arguments == ["size", "0.5"])
        let r = try SettingsRig(control: ["scale": 0.75])
        try r.openFromMenuBar()
        let content = try #require(r.settings.content)
        content.show(SettingsSection.sizeSection)
        #expect(content.button(for: .size("0.75"))?.state == .on, "a selection of 0.75 shows as selected")
        for word in SettingsChoice.sizes where word != "0.75" { #expect(content.button(for: .size(word))?.state == .off, "\(word)") }
    }

    @Test @MainActor func SizeSmall_theSizeRowFitsTheLeastSettingsContent() throws {
        let r = try SettingsRig()
        try r.openFromMenuBar()
        let window = try r.window()
        let content = try #require(r.settings.content)
        content.show(SettingsSection.sizeSection)
        window.contentView?.layoutSubtreeIfNeeded()
        let buttons = try SettingsChoice.sizes.map { try #require(content.button(for: .size($0)), "no control for \($0)") }
        let row = try #require(buttons[0].superview, "the chips share one stack")
        #expect(buttons.allSatisfy { $0.superview === row })
        let rowWidth = row.fittingSize.width
        // The window is never narrower than 640 pt; the sidebar takes 178 and the section 24 pt either side.
        let room = SettingsGeometry.minimum.width - SettingsGeometry.sidebarWidth - 48
        print("SIZEROW width \(rowWidth) room \(room) chip \(buttons[0].frame.width)")
        #expect(rowWidth <= room, "the size row is \(rowWidth) pt wide, the least room is \(room) pt")
    }
}

private extension Double {
    func clamped(_ low: Double, _ high: Double) -> Double { Swift.min(high, Swift.max(low, self)) }
}
