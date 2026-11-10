import Testing
import Foundation
import AppKit
import ClawdCore
import ClawdDesktop
@testable import SwiftTerm

/// The chat terminal's Orca look: colours, font, cursor and the panel chrome, for dark and for light. No window is made or shown.
@MainActor
struct ChatLookTests {
    private func rig(_ name: NSAppearance.Name, size: CGSize = CGSize(width: 640, height: 420)) -> (ChatTerminalContainer, ChatTerminalView) {
        let bounds = CGRect(origin: .zero, size: size)
        let terminal = ChatTerminalView(frame: CGRect(x: 0, y: 0, width: size.width, height: size.height - ChatTerminalContainer.headerHeight))
        let container = ChatTerminalContainer(frame: bounds, view: terminal)
        container.appearance = NSAppearance(named: name)
        container.layoutSubtreeIfNeeded()
        return (container, terminal)
    }

    private func srgb(_ color: NSColor) -> [Int] {
        let c = color.usingColorSpace(.sRGB) ?? color
        return [Int((c.redComponent * 255).rounded()), Int((c.greenComponent * 255).rounded()), Int((c.blueComponent * 255).rounded())]
    }
    private func triple(_ rgb: ChatLook.RGB) -> [Int] { [Int(rgb.r), Int(rgb.g), Int(rgb.b)] }

    /// The panel as a 2x bitmap, drawn without a window. SwiftTerm paints a snapshot its frame driver publishes on a tick, and the display link that
    /// ticks it needs a visible window, so the test asks the driver for one immediate tick and lets the main run loop deliver it. The container's
    /// own chrome comes from `cacheDisplay` with the terminal view hidden; the terminal's cells and glyphs are drawn by SwiftTerm's own draw into a
    /// bitmap context of their own (its layer-backed draw leaves glyphs out of a bitmap without a window), over the terminal background, which the
    /// view leaves to its layer. `cacheDisplay` draws the whole tree into one CG context in subview order, and the context's text matrix is not
    /// part of the graphics state: the tab label (drawn first) leaves it moved, and SwiftTerm, which never sets it, would draw its glyphs shifted a
    /// second time. In the panel itself every layer-backed view has a context of its own, so this exists only in this offscreen composite.
    private func bitmap(of view: NSView, terminal: ChatTerminalView) -> NSBitmapImageRep? {
        let scale: CGFloat = 2
        view.layoutSubtreeIfNeeded()
        terminal.frameDriver.markDirty()
        terminal.frameDriver.requestImmediateTick()
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.3))
        view.displayIfNeeded()
        func makeRep(_ size: CGSize) -> NSBitmapImageRep? {
            NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: Int(size.width * scale), pixelsHigh: Int(size.height * scale), bitsPerSample: 8,
                             samplesPerPixel: 4, hasAlpha: true, isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)
        }
        // The terminal alone, glyphs included.
        guard let termRep = makeRep(terminal.bounds.size), let termContext = NSGraphicsContext(bitmapImageRep: termRep) else { return nil }
        termContext.cgContext.scaleBy(x: scale, y: scale)
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = termContext
        terminal.drawTerminalContents(dirtyRect: terminal.bounds, context: termContext.cgContext, bufferOffset: 0)
        NSGraphicsContext.restoreGraphicsState()
        // The container's chrome.
        guard let chrome = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { return nil }
        terminal.isHidden = true
        view.cacheDisplay(in: view.bounds, to: chrome)
        terminal.isHidden = false
        guard let rep = makeRep(view.bounds.size), let context = NSGraphicsContext(bitmapImageRep: rep),
              let termImage = termRep.cgImage, let chromeImage = chrome.cgImage else { return nil }
        let cg = context.cgContext
        cg.scaleBy(x: scale, y: scale)
        cg.addPath(CGPath(roundedRect: view.bounds, cornerWidth: ChatLook.cornerRadius, cornerHeight: ChatLook.cornerRadius, transform: nil))
        cg.clip()
        cg.draw(chromeImage, in: view.bounds)
        cg.setFillColor((terminal.appliedLook ?? .dark).background.color.cgColor)
        cg.fill(terminal.frame)
        cg.draw(termImage, in: terminal.frame)
        return rep
    }
    private func pixel(_ rep: NSBitmapImageRep, x: Int, yFromTop: Int) -> [Int] {
        srgb(rep.colorAt(x: x, y: yFromTop) ?? .clear)
    }

    @Test func ChatLook_theAppliedColoursAreOrcasForDarkAndLight() {
        for (name, look) in [(NSAppearance.Name.darkAqua, ChatLook.dark), (.aqua, ChatLook.light)] {
            let (container, terminal) = rig(name)
            #expect(container.look.isDark == look.isDark, "\(name.rawValue): the container follows its appearance")
            #expect(terminal.appliedLook?.isDark == look.isDark, "\(name.rawValue): the terminal follows it too")
            #expect(srgb(terminal.nativeBackgroundColor) == triple(look.background), "\(name.rawValue) background")
            #expect(srgb(terminal.nativeForegroundColor) == triple(look.foreground), "\(name.rawValue) foreground")
            #expect(srgb(terminal.caretColor) == triple(look.cursor), "\(name.rawValue) cursor")
            #expect(srgb(terminal.caretTextColor ?? .clear) == triple(look.cursorText), "\(name.rawValue) cursor text")
            #expect(srgb(terminal.selectedTextBackgroundColor) == triple(look.selection), "\(name.rawValue) selection")
        }
        #expect(triple(ChatLook.dark.background) == [0x0a, 0x0e, 0x14] && triple(ChatLook.dark.foreground) == [0xb3, 0xb1, 0xad], "Ayu Dark")
        #expect(triple(ChatLook.dark.cursor) == [0xe6, 0xb4, 0x50] && triple(ChatLook.dark.selection) == [0x27, 0x37, 0x47], "Ayu Dark cursor and selection")
        #expect(ChatLook.dark.ansi.count == 16 && ChatLook.light.ansi.count == 16)
        #expect(triple(ChatLook.light.background) == [255, 255, 255] && triple(ChatLook.light.foreground) == [0x17, 0x17, 0x17], "Orca Light")
    }

    @Test func ChatLook_everyAnsiColourIsDrawnAsItsPaletteEntry() throws {
        for (name, look) in [(NSAppearance.Name.darkAqua, ChatLook.dark), (.aqua, ChatLook.light)] {
            let (container, terminal) = rig(name, size: CGSize(width: 640, height: 420))
            // Row 1: sixteen blocks with the ANSI background 40-47 and 100-107, two columns each.
            var text = "\u{1b}[2J\u{1b}[H"
            for i in 0..<16 { text += "\u{1b}[\(i < 8 ? 40 + i : 92 + i)m  " }
            text += "\u{1b}[0m"
            terminal.feed(text: text)
            let rep = try #require(bitmap(of: container, terminal: terminal))
            let top = Int(ChatLook.titleBarHeight + ChatLook.terminalPadding) + 4
            let scale = CGFloat(rep.pixelsWide) / container.bounds.width
            // Find the first row's blocks by scanning along the row for the sixteen distinct fills, in order.
            let y = Int((CGFloat(top) * scale).rounded())
            let expected = look.ansi.map(triple).reduce(into: [[Int]]()) { if $0.last != $1 { $0.append($1) } }
            // A pixel counts as a palette entry when it is within 2 levels per channel of it (the bitmap's colour conversion).
            func entry(_ p: [Int]) -> [Int]? { expected.first { zip($0, p).allSatisfy { abs($0 - $1) <= 2 } } }
            var seen: [[Int]] = []
            for x in 0..<rep.pixelsWide {
                if let hit = entry(pixel(rep, x: x, yFromTop: y)), hit != seen.last { seen.append(hit) }
            }
            #expect(seen == expected, "\(name.rawValue): the sixteen palette entries in order, got \(seen)")
        }
    }

    @Test func ChatLook_theFontIsUdevGothic10WithFallbacks() {
        let font = ChatLook.terminalFont()
        #expect(font.pointSize == 10, "10 pt")
        if let udev = NSFont(name: "UDEVGothicNFLG-Regular", size: 10) {
            #expect(font.fontName == "UDEVGothicNFLG-Regular" && font.familyName == "UDEV Gothic NFLG", "the Regular face of UDEV Gothic NFLG: \(font.fontName)")
            #expect(NSFont(name: "UDEVGothicNFLG-Bold", size: 10) != nil, "the Bold face is installed")
            _ = udev
        } else {
            #expect(font.isFixedPitch, "a missing UDEV Gothic falls back to SF Mono, fixed-pitch: \(font.fontName)")
        }
        let (_, terminal) = rig(.darkAqua)
        #expect(terminal.font.fontName == font.fontName && terminal.font.pointSize == 10, "the terminal view uses it")
        #expect(ChatLook.titleFont().pointSize == 9, "Orca's 12 pt title at the chat's 0.75 text scale")
    }

    @Test func ChatLook_theCursorIsABlinkingBlockAndTheScrollbarIsOverlay() {
        let (_, terminal) = rig(.darkAqua)
        #expect(ChatTerminalView.cursorStyle == .blinkBlock)
        #expect(terminal.scrollerStyle == .overlay)
    }

    @Test func ChatLook_theChromeHasOrcasLayerValues() throws {
        for (name, look) in [(NSAppearance.Name.darkAqua, ChatLook.dark), (.aqua, ChatLook.light)] {
            let (container, terminal) = rig(name)
            let layer = try #require(container.layer)
            #expect(layer.cornerRadius == 10 && layer.masksToBounds, "\(name.rawValue): corner radius 10")
            #expect(layer.borderWidth == 1, "\(name.rawValue): 1 px border")
            let border = try #require(layer.borderColor.flatMap { NSColor(cgColor: $0) }?.usingColorSpace(.sRGB))
            let base: CGFloat = look.isDark ? 1 : 0
            #expect(abs(border.redComponent - base) < 0.01 && abs(border.alphaComponent - 0.14) < 0.01, "\(name.rawValue): border is \(look.isDark ? "white" : "black") at 14 %")
            // Orca's 36 px bar at the chat's 0.75 text scale.
            let bar = try #require(container.subviews.first { $0.frame.height == 27 })
            #expect(bar.frame.height == 27 && ChatTerminalContainer.headerHeight == 27, "\(name.rawValue): 27 px title bar")
            #expect(bar.frame.minY + bar.frame.height == container.bounds.height - 1, "\(name.rawValue): the bar sits inside the border")
            let fill = try #require(bar.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) })
            #expect(srgb(fill) == triple(look.titleFill), "\(name.rawValue): title bar fill is \(look.isDark ? "#171717" : "#ffffff")")
            let rule = try #require(bar.subviews.first { $0.frame.height == 1 })
            #expect(rule.frame.width == bar.frame.width && rule.frame.minY == 0, "\(name.rawValue): 1 px bottom border")
            #expect(container.headerText == "Claude Code", "the title label")
            #expect(container.closeButton.frame.width == 18 && container.closeButton.acceptsFirstMouse(for: nil), "the close button is an 18 px control (Orca's 24 at the 0.75 text scale) that takes the first mouse")
            #expect(container.closeButton.layer?.borderWidth == 0 && container.closeButton.layer?.backgroundColor?.alpha == 0, "\(name.rawValue): the close button is a ghost at rest")
            container.closeButton.setHovered(true)
            #expect(container.closeButton.layer?.backgroundColor.flatMap { NSColor(cgColor: $0) }.map(srgb) == srgb(look.buttonHover), "\(name.rawValue): a hover fill")
            container.closeButton.setHovered(false)
            #expect(container.closeButton.image != nil, "the close button draws an icon")
            #expect(terminal.frame.maxY == bar.frame.minY - ChatLook.terminalPadding && terminal.frame.minX == 1 + ChatLook.terminalPadding,
                    "the terminal fills what is under the bar, inside the 1 px border and Orca's 4 pt padding on the left and the top")
        }
    }

    @Test func ChatLook_theLookFollowsTheAppearanceLiveWithoutAnObserver() {
        let (container, terminal) = rig(.darkAqua)
        #expect(container.look.isDark)
        container.appearance = NSAppearance(named: .aqua)
        #expect(!container.look.isDark && srgb(terminal.nativeBackgroundColor) == [255, 255, 255], "a change to light repaints at once")
        container.appearance = NSAppearance(named: .darkAqua)
        #expect(container.look.isDark && srgb(terminal.nativeBackgroundColor) == [0x0a, 0x0e, 0x14], "and back to dark")
    }

    /// Writes the offscreen pictures the main session compares with Orca: the sixteen colours, bold, a Japanese line.
    @Test func ChatLook_renderThePanelPicturesOffscreen() throws {
        var root = URL(fileURLWithPath: #filePath)
        while root.lastPathComponent != "Tests" && root.path != "/" { root.deleteLastPathComponent() }
        root.deleteLastPathComponent()
        let folder = root.appendingPathComponent(".evidence/orca-look3")
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // The default size (520 x 340) in both appearances, and the minimum (420 x 280) in dark.
        let pictures: [(NSAppearance.Name, String, CGSize)] = [(.darkAqua, "dark", ChatPanelGeometry.defaultSize), (.aqua, "light", ChatPanelGeometry.defaultSize),
                                                              (.darkAqua, "min", ChatPanelGeometry.minSize)]
        for (name, label, size) in pictures {
            let (container, terminal) = rig(name, size: size)
            container.setTitle("\u{2733} Claude Code")
            var text = "\u{1b}[2J\u{1b}[H\u{1b}[1mClaude Code\u{1b}[0m v2.1  Opus\r\n\r\n"
            text += "normal  \u{1b}[1mbold\u{1b}[0m  \u{1b}[3mitalic\u{1b}[0m  \u{1b}[4munderline\u{1b}[0m\r\n"
            for base in [30, 90] {
                for i in 0..<8 { text += "\u{1b}[\(base + i)m\(base + i) \u{1b}[0m" }
                text += "\r\n"
            }
            for i in 0..<16 { text += "\u{1b}[\(i < 8 ? 40 + i : 92 + i)m   \u{1b}[0m" }
            text += "\r\n\r\n日本語の表示テスト：こんにちは、世界。ファイルを読み込みました。\r\n"
            text += "\u{1b}[1m\u{1b}[32m+ added line\u{1b}[0m\r\n\u{1b}[31m- removed line\u{1b}[0m\r\n> \u{1b}[7m \u{1b}[0m"
            terminal.feed(text: text)
            let rep = try #require(bitmap(of: container, terminal: terminal))
            let png = try #require(rep.representation(using: .png, properties: [:]))
            try png.write(to: folder.appendingPathComponent("panel-\(label).png"))
        }
    }
}
