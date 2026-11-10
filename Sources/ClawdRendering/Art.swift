import Foundation
import CoreGraphics
import ImageIO
import ClawdCore

public enum ArtError: Error { case invalidAtlas, missingFrame(String), invalidFont, encoding }
public struct Pose: Decodable {
    public let frames: [String]
    public let ms: [Double]
    public let loop: Bool
    public var duration: Double { ms.reduce(0, +) / 1000 }
    public func frame(at elapsed: Double) -> Int {
        var remainder = max(0, elapsed)
        if loop { remainder.formTruncatingRemainder(dividingBy: duration) }
        else if remainder >= duration { return frames.count - 1 }
        for i in frames.indices { remainder -= ms[i] / 1000; if remainder < 0 { return i } }
        return frames.count - 1
    }
    public func nextFrame(after elapsed: Double) -> Double? {
        guard frames.count > 1, loop || elapsed < duration else { return nil }
        let t = max(0, elapsed).truncatingRemainder(dividingBy: duration)
        var end = 0.0
        for ms in ms { end += ms / 1000; if end > t { return end - t } }
        return 0.001
    }
}
public final class ArtAtlas {
    public let unit: Double
    public let poses: [String: Pose]
    public let width: Int
    public let height: Int
    private var images: [String: CGImage] = [:]
    public init(directory: URL) throws {
        struct Atlas: Decodable { let unit: Double; let poses: [String: Pose] }
        let atlas = try JSONDecoder().decode(Atlas.self, from: ReadOnlyFile.data(directory.appendingPathComponent("clawd-atlas.json").path))
        guard atlas.unit > 0, atlas.unit <= 16,
              ["idle", "blink", "listen", "think", "hop", "sleep", "dangle"].allSatisfy({ atlas.poses[$0] != nil }) else {
            throw ArtError.invalidAtlas
        }
        var canvas: CGSize?
        for pose in atlas.poses.values {
            guard !pose.frames.isEmpty, pose.frames.count == pose.ms.count,
                  pose.ms.allSatisfy({ $0.isFinite && $0 > 0 }) else { throw ArtError.invalidAtlas }
            for name in pose.frames {
                guard !name.hasPrefix("/"), !name.split(separator: "/").contains("..") else { throw ArtError.invalidAtlas }
                let data = try ReadOnlyFile.data(directory.appendingPathComponent(name).path)
                guard let source = CGImageSourceCreateWithData(data as CFData, nil), let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
                    throw ArtError.missingFrame(name)
                }
                let size = CGSize(width: image.width, height: image.height)
                if let canvas, canvas != size { throw ArtError.invalidAtlas }
                canvas = size; images[name] = image
            }
        }
        guard let canvas else { throw ArtError.invalidAtlas }
        unit = atlas.unit; poses = atlas.poses; width = Int(canvas.width); height = Int(canvas.height)
    }
    public func image(pose: String, elapsed: Double) -> CGImage {
        let clip = poses[pose] ?? poses["idle"]!
        return images[clip.frames[clip.frame(at: elapsed)]]!
    }
}

public struct ClaudeElements {
    // Spec-defined defaults for absent extraction keys; no invented list of verbs.
    public static let specDefaultTable: [String: String] = [
        "presentVerb": "Clauding", "interrupt": "  \u{23BF}  Interrupted",
        "error": "  \u{23BF}  Error", "sent": "\u{23FA} Sent",
        "ellipsis": "\u{2026}", "prompt": ">", "promptChar": "\u{276F}", "completeGlyph": "\u{273B}"
    ]
    public var glyphs = ["\u{00B7}", "\u{2722}", "\u{2733}", "\u{2736}", "\u{273B}", "\u{273D}"]
    public var tick = 0.1
    public var period = 2.0
    public var present = [specDefaultTable["presentVerb"]!]
    public var past: [String] = []
    public var interrupt = specDefaultTable["interrupt"]!
    public var error = specDefaultTable["error"]!
    public var ellipsis = specDefaultTable["ellipsis"]!
    /// Claude Code's input-box prompt character (`input_box.prompt_char`) and the ASCII stand-in for a font that cannot draw it.
    public var promptChar = specDefaultTable["promptChar"]!
    public var promptFallbackASCII = specDefaultTable["prompt"]!
    /// What the chip actually draws. `SceneRenderer` picks `promptChar` when its font cascade can render it; until then it is the fallback.
    public var prompt = specDefaultTable["prompt"]!
    public var completeGlyph = specDefaultTable["completeGlyph"]!
    public var colors = ["claude": [215.0, 119, 87], "promptBorder": [136, 136, 136],
                         "text": [255, 255, 255], "inactive": [153, 153, 153], "error": [255, 107, 128],
                         "userMessageBackground": [55, 55, 55]]
    public init(directory: URL? = nil) {
        guard let directory,
              let data = try? ReadOnlyFile.data(directory.appendingPathComponent("claude-code-elements.json").path),
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return }
        func object(_ key: String) -> [String: Any] { root[key] as? [String: Any] ?? [:] }
        if let values = object("spinner_glyphs")["default_sequence"] as? [String], !values.isEmpty { glyphs = values }
        let timing = object("spinner_timing")
        if let ms = (timing["clock_tick_ms"] as? [String: Any])?["value"] as? Double, ms >= 50 { tick = ms / 1000 }
        if let ms = (timing["frame_index_formula"] as? [String: Any])?["period_ms"] as? Double, ms > 0 { period = ms / 1000 }
        if let verbs = object("present_verbs")["values"] as? [String], !verbs.isEmpty { present = verbs }
        past = object("past_verbs")["values"] as? [String] ?? []
        interrupt = object("interrupt")["rendered"] as? String ?? interrupt
        // The message body is deliberately omitted; the extraction supplies only its prefix.
        if let prefix = object("interrupt")["prefix"] as? String { error = prefix + "Error" }
        ellipsis = object("ellipsis")["value"] as? String ?? ellipsis
        promptFallbackASCII = object("input_box")["prompt_char_fallback_ascii"] as? String ?? promptFallbackASCII
        promptChar = object("input_box")["prompt_char"] as? String ?? promptChar
        prompt = promptFallbackASCII
        completeGlyph = object("turn_complete_line")["prefix_glyph"] as? String ?? completeGlyph
        if let palette = object("theme_colors_dark")["values"] as? [String: String] {
            for (key, value) in palette {
                let numbers = value.split(whereSeparator: { !$0.isNumber }).compactMap { Double($0) }
                if numbers.count == 3, numbers.allSatisfy({ (0...255).contains($0) }) { colors[key] = numbers }
            }
        }
    }
    public func spinner(at time: Double) -> String {
        let tickTime = floor(max(0, time) / tick) * tick
        let index = Int(((1 - cos(2 * .pi * tickTime / period)) / 2 * Double(glyphs.count - 1)).rounded())
        return glyphs[min(glyphs.count - 1, max(0, index))]
    }
    /// The glyph of tick number `frame` of Claude Code's clock: the same cosine and sequence as `spinner(at:)`, for a caller that has already
    /// counted the ticks with `BubbleText.phaseIndex` (a time such as 0.3 s is a tick short of the tick it is on in floating point).
    public func spinner(frame: Int) -> String {
        let tickTime = Double(max(0, frame)) * tick
        let index = Int(((1 - cos(2 * .pi * tickTime / period)) / 2 * Double(glyphs.count - 1)).rounded())
        return glyphs[min(glyphs.count - 1, max(0, index))]
    }
}
