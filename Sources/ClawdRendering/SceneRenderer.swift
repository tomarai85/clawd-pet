import Foundation
import CoreGraphics
import CoreText
import ImageIO
import UniformTypeIdentifiers
import ClawdCore

public struct RenderFrame {
    public var scene: Scene
    public var chipScene: Scene
    public var elapsed: Double
    public var duration: Double
    public var verb: String
    public var pastVerb: String?
    public var scale: Double
    public var helmet: Bool
    public var blink: Bool
    /// Device pixels per point of the screen the picture will be shown on (1 on the ultrawide, 2 on Retina).
    public var pixelScale: Double
    public init(scene: Scene, chipScene: Scene? = nil, elapsed: Double = 0, duration: Double = 5,
                verb: String = "Clauding", pastVerb: String? = "Cooked", scale: Double = 1,
                helmet: Bool = false, blink: Bool = false, pixelScale: Double = 1) {
        self.scene = scene; self.chipScene = chipScene ?? scene; self.elapsed = elapsed
        self.duration = duration; self.verb = verb; self.pastVerb = pastVerb
        self.scale = scale; self.helmet = helmet; self.blink = blink; self.pixelScale = pixelScale
    }
    public var chipVisible: Bool { ![Scene.idle, .sleep, .drag].contains(chipScene) }
}
extension SceneRenderer {
    /// The one place a controller state becomes a render input, shared by the agent and the tests.
    public func frame(from state: PetViewState, scale: Double, helmet: Bool, pixelScale: Double = 1) -> RenderFrame {
        let present = elements.present, past = elements.past
        return RenderFrame(scene: state.scene, chipScene: state.chipScene, elapsed: state.elapsed, duration: state.duration,
                           verb: present[state.verbSeed % max(1, present.count)],
                           pastVerb: past.isEmpty ? nil : past[state.pastSeed % past.count],
                           scale: scale, helmet: helmet, blink: state.blink, pixelScale: pixelScale)
    }
    /// Time until the picture next changes by itself (pose frame, spinner glyph, cursor blink, SENT fade), or nil when it is static.
    public func animationInterval(for state: PetViewState, scale: Double, helmet: Bool) -> TimeInterval? {
        let frame = self.frame(from: state, scale: scale, helmet: helmet)
        var intervals: [TimeInterval] = []
        if let pose = atlas.poses[self.pose(for: frame)], let next = pose.nextFrame(after: frame.elapsed) { intervals.append(next) }
        switch state.chipScene {
        case .thinking: intervals.append(elements.tick)
        case .listening: intervals.append(0.5)
        case .sent:
            // The picture must change at the moment the fade starts, not only once the fade is under way: otherwise the
            // wake after the hop is the 2 s deadline itself and the chip disappears without fading.
            intervals.append(frame.elapsed >= SceneRenderer.sentFadeStart ? 0.05 : SceneRenderer.sentFadeStart - frame.elapsed)
        default: break
        }
        return intervals.min()
    }
}
public final class SceneRenderer {
    public static let fontPath = "/System/Library/Fonts/Menlo.ttc"
    /// SENT fades out over its last 0.4 s and is gone at `SceneMachine.sentDuration`.
    public static let sentFadeDuration: TimeInterval = 0.4
    public static let sentFadeStart: TimeInterval = SceneMachine.sentDuration - sentFadeDuration
    public let atlas: ArtAtlas
    public let elements: ClaudeElements
    public let font: CTFont
    public init(art: URL, fontPath: String = SceneRenderer.fontPath) throws {
        atlas = try ArtAtlas(directory: art)
        guard let descriptors = CTFontManagerCreateFontDescriptorsFromURL(URL(fileURLWithPath: fontPath) as CFURL) as? [CTFontDescriptor],
              let regular = descriptors.first(where: { (CTFontDescriptorCopyAttribute($0, kCTFontStyleNameAttribute) as? String) == "Regular" }) ?? descriptors.first else {
            throw ArtError.invalidFont
        }
        let created = CTFontCreateWithFontDescriptor(regular, 12.5, nil)
        font = created
        var loaded = ClaudeElements(directory: art)
        loaded.prompt = Self.resolvePrompt(preferred: loaded.promptChar, fallback: loaded.promptFallbackASCII, font: created)
        elements = loaded
    }
    /// True when CoreText can draw every character of `text` with `font` or a font its cascade substitutes. A glyph from the
    /// LastResort font is a placeholder box, not the character, so it does not count.
    public static func canRender(_ text: String, in font: CTFont) -> Bool {
        guard !text.isEmpty else { return false }
        for scalar in text.unicodeScalars {
            let character = String(scalar)
            let units = Array(character.utf16)
            let substitute = CTFontCreateForString(font, character as CFString, CFRange(location: 0, length: units.count))
            if (CTFontCopyPostScriptName(substitute) as String) == "LastResort" { return false }
            var glyphs = [CGGlyph](repeating: 0, count: units.count)
            guard CTFontGetGlyphsForCharacters(substitute, units, &glyphs, units.count), glyphs[0] != 0 else { return false }
        }
        return true
    }
    /// Claude Code's own prompt character when the font cascade can draw it, the ASCII stand-in only when it cannot.
    public static func resolvePrompt(preferred: String, fallback: String, font: CTFont) -> String {
        canRender(preferred, in: font) ? preferred : fallback
    }
    public func pose(for frame: RenderFrame) -> String {
        let pose: String
        switch frame.scene {
        case .idle: pose = frame.blink ? "blink" : "idle"
        case .listening: pose = "listen"
        case .thinking: pose = "think"
        case .sent: pose = "hop"
        case .sleep: pose = "sleep"
        case .drag: pose = "dangle"
        case .interrupted, .error: pose = "idle"
        }
        let helmet = "helmet-" + pose
        return frame.helmet && atlas.poses[helmet] != nil ? helmet : pose
    }
    public func chipText(_ frame: RenderFrame) -> String {
        switch frame.chipScene {
        case .listening: return elements.prompt + " "
        case .thinking: return elements.spinner(at: frame.elapsed) + " " + frame.verb + elements.ellipsis
        case .sent:
            guard let past = frame.pastVerb, !elements.past.isEmpty else { return ClaudeElements.specDefaultTable["sent"]! }
            let seconds = max(0, Int(frame.duration))
            let duration = seconds < 60 ? "\(seconds)s" : seconds < 3600 ? "\(seconds / 60)m \(seconds % 60)s" : "\(seconds / 3600)h \(seconds / 60 % 60)m \(seconds % 60)s"
            return elements.completeGlyph + " " + past + " for " + duration
        case .interrupted: return elements.interrupt
        case .error: return elements.error
        default: return ""
        }
    }
    private func color(_ key: String, alpha: Double = 1) -> CGColor {
        let rgb = elements.colors[key] ?? [255, 255, 255]
        return CGColor(colorSpace: CGColorSpace(name: CGColorSpace.sRGB)!, components: rgb.map { $0 / 255 } + [alpha])!
    }
    public func render(_ frame: RenderFrame, fixedCanvas: Bool = false) throws -> CGImage {
        let scale = max(0.25, min(4, frame.scale))
        let bodyWidth = Double(atlas.width) * atlas.unit * scale
        let bodyHeight = Double(atlas.height) * atlas.unit * scale
        let text = chipText(frame)
        let role = frame.chipScene == .error ? "error" : frame.chipScene == .thinking ? "claude" : "inactive"
        let attributed = NSAttributedString(string: text, attributes: [
            NSAttributedString.Key(kCTFontAttributeName as String): font,
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color(role)
        ])
        let line = CTLineCreateWithAttributedString(attributed)
        let chipWidth = max(84, ceil(CTLineGetTypographicBounds(line, nil, nil, nil)) + 24)
        let width = Int(ceil(fixedCanvas ? max(360, bodyWidth + chipWidth + 12) : frame.chipVisible ? bodyWidth + chipWidth + 12 : bodyWidth))
        let height = Int(ceil(fixedCanvas ? max(80, bodyHeight) : max(44, bodyHeight)))
        // Layout is in points; the bitmap has `pixelScale` device pixels per point so text and blocks stay sharp on Retina.
        let px = max(1, min(4, frame.pixelScale))
        let pixelWidth = Int(ceil(Double(width) * px)), pixelHeight = Int(ceil(Double(height) * px))
        guard let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8, bytesPerRow: pixelWidth * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ArtError.encoding }
        context.scaleBy(x: px, y: px)
        context.interpolationQuality = .none
        context.draw(atlas.image(pose: pose(for: frame), elapsed: frame.elapsed), in: CGRect(x: 0, y: 0, width: bodyWidth, height: bodyHeight))
        if frame.chipVisible {
            context.saveGState()
            if frame.chipScene == .sent { context.setAlpha(max(0, min(1, (SceneMachine.sentDuration - frame.elapsed) / Self.sentFadeDuration))) }
            let box = CGRect(x: bodyWidth + 8, y: 8, width: chipWidth, height: 30)
            let path = CGPath(roundedRect: box.insetBy(dx: 0.5, dy: 0.5), cornerWidth: 7, cornerHeight: 7, transform: nil)
            context.setFillColor(color("userMessageBackground", alpha: 0.9)); context.addPath(path); context.fillPath()
            if frame.chipScene == .listening {
                context.setStrokeColor(color("promptBorder")); context.setLineWidth(1); context.addPath(path); context.strokePath()
                if Int(frame.elapsed * 2) % 2 == 0 {
                    // The cursor sits right after the prompt, wherever the font puts it.
                    let cursorX = (box.minX + 10 + CTLineGetTypographicBounds(line, nil, nil, nil) + 3).rounded()
                    context.setFillColor(color("text")); context.fill(CGRect(x: cursorX, y: box.minY + 8, width: 7, height: 14))
                }
            }
            context.setShouldSmoothFonts(false)
            context.textPosition = CGPoint(x: box.minX + 10, y: box.minY + 10)
            CTLineDraw(line, context); context.restoreGState()
        }
        guard let image = context.makeImage() else { throw ArtError.encoding }; return image
    }
    public static func png(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(data, UTType.png.identifier as CFString, 1, nil) else { throw ArtError.encoding }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { throw ArtError.encoding }; return data as Data
    }
    public static func pixels(_ image: CGImage) throws -> Data {
        guard let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8, bytesPerRow: image.width * 4,
            space: CGColorSpace(name: CGColorSpace.sRGB)!, bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue) else { throw ArtError.encoding }
        context.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
        return Data(bytes: context.data!, count: image.width * image.height * 4)
    }
}
