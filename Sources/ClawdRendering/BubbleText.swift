import Foundation
import ClawdCore

/// What a bubble says now. The scene and its clock come from the controller; the verbs from Claude Code's extraction.
public struct BubbleContent: Equatable {
    public var scene: Scene
    /// Seconds since the scene began: drives the spinner, the cursor and the SENT fade.
    public var elapsed: Double
    /// Length of the dictation (the SENT line).
    public var duration: Double
    public var verb: String
    public var pastVerb: String?
    public var reduceMotion: Bool
    /// The macOS appearance. Styles 14 and 15 follow it; the pixel styles have one palette and ignore it.
    public var appearance: BubbleAppearance
    public init(scene: Scene, elapsed: Double = 0, duration: Double = 5, verb: String = "Clauding", pastVerb: String? = "Cooked",
                reduceMotion: Bool = false, appearance: BubbleAppearance = .light) {
        self.scene = scene; self.elapsed = elapsed; self.duration = duration; self.verb = verb; self.pastVerb = pastVerb
        self.reduceMotion = reduceMotion; self.appearance = appearance
    }
    public static let shownScenes: [Scene] = [.listening, .thinking, .sent, .interrupted, .error]
}

public enum BubbleText {
    public static let cursorPeriod = 0.5
    public static let typingStep = 0.2
    public static let reducedMotionPulse = 2.0
    public static let reducedMotionStep = 0.25
    /// Cells a whole bubble may take: the 200 pt cap at 2 pt per cell (styles 1-12; `widthCap(for:)` names a style's own).
    public static let widthCap = Int(200 / BubbleLayout.pixelPt)
    /// Pixels a whole bubble may take: the 200 pt cap in the style's own pixels, the picture's own margins (a drop shadow) counted.
    public static func widthCap(for design: BubbleDesign) -> Int { Int(200 / design.pixelPt) }

    /// The one tolerance-aware phase index (amendment D-8, R3-1): how many whole `period`s have passed at scene time `t`. A time short of a
    /// boundary by less than a nanosecond counts as on it, so the wake scheduler and every new animation state agree on which step they are in, at
    /// the instant before, at and after each boundary and however the time was accumulated.
    public static func phaseIndex(_ t: Double, period: Double) -> Int { Int(((max(0, t) + 1e-9) / period).rounded(.down)) }

    /// A duration the way Claude Code writes it, without the seconds once it reaches an hour (the bubble has a width cap).
    public static func duration(_ seconds: Double) -> String {
        let s = max(0, Int(seconds))
        if s < 60 { return "\(s)s" }
        if s < 3600 { return "\(s / 60)m \(s % 60)s" }
        return "\(s / 3600)h \(s / 60 % 60)m"
    }

    /// The single line a scene shows, with Claude Code's own marks, as runs and (style 10, thinking) the typing dots.
    public static func content(_ c: BubbleContent, elements: ClaudeElements, design: BubbleDesign) -> (runs: [BubbleRun], dots: BubbleDots?) {
        let line = lines(c, elements: elements, design: design)
        guard design.uppercase else { return line }
        return (line.runs.map { run in var run = run; run.text = design.cased(run.text); return run }, line.dots)
    }

    private static func lines(_ c: BubbleContent, elements: ClaudeElements, design: BubbleDesign) -> (runs: [BubbleRun], dots: BubbleDots?) {
        func collapse(_ s: String) -> String { s.split(whereSeparator: { $0 == " " || $0 == "\u{00A0}" }).joined(separator: " ") }
        let prompt = Character(elements.promptChar.isEmpty ? "\u{276F}" : String(elements.promptChar.prefix(1)))
        if design.face == .fine { return refinedLines(c, elements: elements, prompt: prompt, collapse: collapse) }
        if let smooth = design.smooth { return smoothLines(c, elements: elements, kind: smooth, prompt: prompt, collapse: collapse) }
        switch c.scene {
        case .listening:
            return ([BubbleRun(String(prompt), .dim), BubbleRun(" ", .dim),
                     BubbleRun("\u{2588}", .ink, visible: Int(max(0, c.elapsed) / cursorPeriod) % 2 == 0)], nil)
        case .thinking:
            let word = c.verb + elements.ellipsis
            if c.reduceMotion {
                // Claude Code's reduced-motion spinner: a still dot that pulses once every 2 s, in three steps (BubbleRun.dimLevel).
                let t = (max(0, c.elapsed) / reducedMotionStep).rounded(.down) * reducedMotionStep
                let level = 2 - Int((1 + cos(2 * .pi * t / reducedMotionPulse)) / 2 * 2.999)
                return ([BubbleRun("\u{25CF}", .claude, dimLevel: level), BubbleRun(" ", .claude), BubbleRun(word, .claude)], nil)
            }
            if design.usesDots {
                return ([BubbleRun(word, .claude)], BubbleDots(lit: Int(max(0, c.elapsed) / typingStep) % 3))
            }
            return ([BubbleRun(elements.spinner(at: c.elapsed), .claude), BubbleRun(" ", .claude), BubbleRun(word, .claude)], nil)
        case .sent:
            guard let past = c.pastVerb, !elements.past.isEmpty else { return ([BubbleRun(collapse(ClaudeElements.specDefaultTable["sent"]!), .dim)], nil) }
            return ([BubbleRun(elements.completeGlyph, .dim), BubbleRun(" ", .dim), BubbleRun(past + " for " + duration(c.duration), .dim)], nil)
        case .interrupted:
            let parts = collapse(elements.interrupt).split(separator: " ", maxSplits: 1).map(String.init)
            return ([BubbleRun(parts.first ?? "\u{23BF}", .dim), BubbleRun(" ", .dim), BubbleRun(parts.count > 1 ? parts[1] : "Interrupted", .dim)], nil)
        case .error:
            let parts = collapse(elements.error).split(separator: " ", maxSplits: 1).map(String.init)
            return ([BubbleRun(parts.first ?? "\u{23BF}", .error), BubbleRun(" ", .error), BubbleRun(parts.count > 1 ? parts[1] : "Error", .error)], nil)
        default:
            return ([], nil)
        }
    }

    /// Style 13's lines (the board's mock B): the prompt and the spinner in the mock's orange, 4 columns, the verb and its counting dots in the
    /// ember. There is no ellipsis: the dots count instead. Every state of the animation is a pure function of the scene time (`BubbleAnimation`).
    private static func refinedLines(_ c: BubbleContent, elements: ClaudeElements, prompt: Character,
                                     collapse: (String) -> String) -> (runs: [BubbleRun], dots: BubbleDots?) {
        // The 4 columns after a mark are the mark, a space (3 columns in the fine font) and the one column between runs: the words are today's, with
        // their space.
        func mark(_ text: String, _ role: BubbleRole, visible: Bool = true, dimLevel: Int = 0) -> [BubbleRun] {
            [BubbleRun(text, role, visible: visible, dimLevel: dimLevel, gapAfter: 0), BubbleRun(" ", role)]
        }
        switch c.scene {
        case .listening:
            return (mark(String(prompt), .claude) + [BubbleRun("\u{2588}", .ink, visible: BubbleAnimation.cursorOn(at: c.elapsed))], nil)
        case .thinking:
            if c.reduceMotion {
                return (mark("\u{25CF}", .claude, dimLevel: BubbleAnimation.pulseLevel(at: c.elapsed)) + [BubbleRun(c.verb, .shimmer)], BubbleDots(count: 3))
            }
            return (mark(BubbleAnimation.spinnerGlyph(at: c.elapsed, elements: elements), .claude) + [BubbleRun(c.verb, .shimmer)],
                    BubbleDots(count: BubbleAnimation.dotCount(at: c.elapsed)))
        case .sent:
            guard let past = c.pastVerb, !elements.past.isEmpty else { return ([BubbleRun(collapse(ClaudeElements.specDefaultTable["sent"]!), .dim)], nil) }
            return (mark(elements.completeGlyph, .dim) + [BubbleRun(past + " for " + duration(c.duration), .dim)], nil)
        case .interrupted:
            let parts = collapse(elements.interrupt).split(separator: " ", maxSplits: 1).map(String.init)
            return (mark(parts.first ?? "\u{23BF}", .dim) + [BubbleRun(parts.count > 1 ? parts[1] : "Interrupted", .dim)], nil)
        case .error:
            let parts = collapse(elements.error).split(separator: " ", maxSplits: 1).map(String.init)
            return (mark(parts.first ?? "\u{23BF}", .error) + [BubbleRun(parts.count > 1 ? parts[1] : "Error", .error)], nil)
        default:
            return ([], nil)
        }
    }

    /// Styles 14 and 15 (the board's mock C and D). Their marks are shapes (`BubbleRun.mark`), their dots are 14's wave and 15's count. The words are
    /// today's; no run carries an ellipsis, the dots count instead.
    private static func smoothLines(_ c: BubbleContent, elements: ClaudeElements, kind: SmoothKind, prompt: Character,
                                    collapse: (String) -> String) -> (runs: [BubbleRun], dots: BubbleDots?) {
        let macOS = kind == .macOS
        func glyph(_ text: String, _ role: BubbleRole, dimLevel: Int = 0) -> BubbleRun {
            // 15 draws every glyph as text in a 12 pt slot; 14 draws the same marks as shapes
            switch text {
            case "\u{276F}": return macOS ? BubbleRun("", role, mark: .chevron) : BubbleRun(text, role, slot: SmoothBubble.spinnerSlot)
            // the hook is a shape in both (no font 15 names has it); 15 keeps it in the spinner's 12 pt slot
            case "\u{23BF}": return macOS ? BubbleRun("", role, mark: .hook) : BubbleRun("", role, mark: .hook, slot: SmoothBubble.spinnerSlot)
            case "\u{25CF}", "\u{23FA}": return BubbleRun("", role, dimLevel: dimLevel, mark: .disc)
            case "\u{273B}" where macOS: return BubbleRun("", role, mark: .asterisk(degrees: 0))
            default: return BubbleRun(text, role, slot: macOS ? nil : SmoothBubble.spinnerSlot)
            }
        }
        switch c.scene {
        case .listening:
            let on = BubbleAnimation.cursorOn(at: c.elapsed)
            return (macOS ? [glyph(String(prompt), .dim), BubbleRun("", .claude, visible: on, mark: .caret)]
                          : [BubbleRun(String(prompt), .dim), BubbleRun("", .ink, visible: on, mark: .block)], nil)
        case .thinking:
            if c.reduceMotion {
                let dot = BubbleRun("", .claude, dimLevel: BubbleAnimation.pulseLevel(at: c.elapsed), mark: .disc)
                return macOS ? ([dot, BubbleRun(c.verb, .ink)], BubbleDots(opacities: [1, 1, 1]))
                             : ([dot, BubbleRun(c.verb, .claude)], BubbleDots(count: 3))
            }
            if macOS {
                return ([BubbleRun("", .claude, mark: .asterisk(degrees: BubbleAnimation.asteriskDegrees(at: c.elapsed))), BubbleRun(c.verb, .ink)],
                        BubbleDots(opacities: BubbleAnimation.dotOpacities(at: c.elapsed)))
            }
            return ([BubbleRun(BubbleAnimation.spinnerGlyph(at: c.elapsed, elements: elements), .claude, slot: SmoothBubble.spinnerSlot),
                     BubbleRun(c.verb, .claude, glint: BubbleAnimation.shimmerIndex(at: c.elapsed, letters: c.verb.count))], BubbleDots(count: BubbleAnimation.dotCount(at: c.elapsed)))
        case .sent:
            guard let past = c.pastVerb, !elements.past.isEmpty else {
                let parts = collapse(ClaudeElements.specDefaultTable["sent"]!).split(separator: " ", maxSplits: 1).map(String.init)
                return ([glyph(parts.first ?? "\u{23FA}", .dim), BubbleRun(parts.count > 1 ? parts[1] : "Sent", .dim)], nil)
            }
            return ([glyph(elements.completeGlyph, .dim), BubbleRun(past + " for " + duration(c.duration), .dim)], nil)
        case .interrupted:
            let parts = collapse(elements.interrupt).split(separator: " ", maxSplits: 1).map(String.init)
            return ([glyph(parts.first ?? "\u{23BF}", .dim), BubbleRun(parts.count > 1 ? parts[1] : "Interrupted", .dim)], nil)
        case .error:
            let parts = collapse(elements.error).split(separator: " ", maxSplits: 1).map(String.init)
            return ([glyph(parts.first ?? "\u{23BF}", .error), BubbleRun(parts.count > 1 ? parts[1] : "Error", .error)], nil)
        default:
            return ([], nil)
        }
    }

    /// Runs the width cap cannot hold are shortened from the end of the last run of text (before its closing ellipsis): a bubble is never larger than
    /// its cap. A smooth style's marks and dots are not text and stay.
    public static func fitted(_ runs: [BubbleRun], dots: BubbleDots?, design: BubbleDesign, connection: BubbleConnection = .side) -> [BubbleRun] {
        var runs = runs
        let limit = widthCap(for: design) - design.margins.side * 2 - (connection == .side ? design.connectorColumns() : 0)
        while design.boxWidth(runs: runs, dots: dots) > limit, let index = runs.lastIndex(where: { $0.mark == nil }), runs[index].text.count > 2 {
            var text = Array(runs[index].text)
            let ellipsis: Character = "\u{2026}"
            if text.last == ellipsis { text.removeLast(2); text.append(ellipsis) } else { text.removeLast() }
            runs[index].text = String(text)
        }
        return runs
    }

    /// Dither level of the SENT fade: 4 whole, down to 1, 0 gone. The fade takes the last `fade` seconds of `lifetime`.
    public static func fadeLevel(scene: Scene, elapsed: Double) -> Int {
        guard scene == .sent else { return 4 }
        let start = SceneRenderer.sentFadeStart, end = SceneMachine.sentDuration
        if elapsed < start { return 4 }
        if elapsed >= end { return 0 }
        let remaining = (end - elapsed) / (end - start)
        return max(1, min(4, Int((remaining * 4).rounded(.up))))
    }

    /// Time until the bubble's picture next changes by itself, nil when it is still.
    public static func nextChange(scene: Scene, elapsed: Double, design: BubbleDesign, reduceMotion: Bool, tick: Double) -> Double? {
        /// New styles count the next boundary from an index with the shared tolerance, on the grid starting at `origin` with step `period` (D-8,
        /// R2-6, R3-1): a time that is on a boundary, as a wake that has just fired at one is, moves on to the next boundary, never to one a
        /// float's width ahead. The result is always more than a nanosecond ahead of `elapsed`.
        func untilBoundary(_ period: Double, origin: Double = 0) -> Double {
            // The original styles keep their remainder-based schedule; only the new states use phaseIndex.
            if design.id <= 12 { return period - (max(0, elapsed) - origin).truncatingRemainder(dividingBy: period) }
            let t = max(0, elapsed)
            return origin + Double(phaseIndex(t - origin, period: period) + 1) * period - t
        }
        switch scene {
        case .listening: return untilBoundary(cursorPeriod)
        case .thinking:
            if reduceMotion { return untilBoundary(reducedMotionStep) }
            return untilBoundary(design.usesDots ? typingStep : tick)
        case .sent:
            let start = SceneRenderer.sentFadeStart, step = (SceneMachine.sentDuration - start) / 4
            if elapsed < start { return start - elapsed }
            if elapsed >= SceneMachine.sentDuration { return nil }
            return untilBoundary(step, origin: start)
        default: return nil
        }
    }
}

/// The animation state of the new styles as pure functions of the scene time (amendment D-8). The picture drawn at `t` is the picture drawn from
/// the state at `t`; every step index is `BubbleText.phaseIndex`.
public enum BubbleAnimation {
    /// LISTENING's cursor: on for 0.5 s, off for 0.5 s.
    public static let cursorPeriod = 0.5
    /// The counting dots step every 0.4 s: 1, 2, 3, 1.
    public static let countingStep = 0.4

    public static func cursorOn(at t: Double) -> Bool { BubbleText.phaseIndex(t, period: cursorPeriod) % 2 == 0 }
    /// How many dots are shown: 1 + (floor(t / 0.4) mod 3).
    public static func dotCount(at t: Double) -> Int { 1 + BubbleText.phaseIndex(t, period: countingStep) % 3 }
    /// Claude Code's spinner glyph on Claude Code's own clock (`ClaudeElements.spinner(frame:)`).
    public static func spinnerGlyph(at t: Double, elements: ClaudeElements) -> String {
        elements.spinner(frame: BubbleText.phaseIndex(t, period: elements.tick))
    }
    /// The reduced-motion dot's colour step: 0, 1 or 2 over 2 s in 0.25 s steps, pulsing away from the fill and back.
    /// 14's asterisk: 12 degrees every 0.1 s, one turn in 3 s.
    public static func asteriskDegrees(at t: Double) -> Double { Double(BubbleText.phaseIndex(t, period: 0.1) % 30) * 12 }
    /// 14's three dots (the mock's `pulse` keyframes, :83): the opacity of each is 0.28 at 0%, 1.0 at 40% and 0.28 at 100% of 1.2 s, eased in and out,
    /// delayed 0, 0.2 and 0.4 s, sampled on the 0.1 s grid.
    public static func dotOpacities(at t: Double) -> [Double] {
        let tenths = BubbleText.phaseIndex(t, period: 0.1)
        return (0..<3).map { k in dotOpacity(tenthsIntoCycle: ((tenths - 2 * k) % 12 + 12) % 12) }
    }
    /// One dot's opacity `tenths` tenths of a second into its 1.2 s cycle.
    public static func dotOpacity(tenthsIntoCycle tenths: Int) -> Double {
        let f = Double(tenths) / 12, low = 0.28
        return f <= 0.4 ? low + (1 - low) * ease(f / 0.4) : 1 - (1 - low) * ease((f - 0.4) / 0.6)
    }
    /// CSS `ease-in-out`, cubic-bezier(0.42, 0, 0.58, 1), solved by bisection.
    static func ease(_ x: Double) -> Double {
        func bezier(_ t: Double, _ a: Double, _ b: Double) -> Double { 3 * (1 - t) * (1 - t) * t * a + 3 * (1 - t) * t * t * b + t * t * t }
        var low = 0.0, high = 1.0
        for _ in 0..<60 { let mid = (low + high) / 2; if bezier(mid, 0.42, 0.58) < x { low = mid } else { high = mid } }
        return bezier((low + high) / 2, 0, 1)
    }
    /// 15's shimmer for a verb of `n` letters: Claude Code's index moved 11 steps, so that the glint starts on the verb's last letter, g(0) = n - 1.
    public static func shimmerIndex(at t: Double, letters n: Int) -> Int { (n + 10) - ((BubbleText.phaseIndex(t, period: 0.2) + 11) % (n + 20)) }
    public static func pulseLevel(at t: Double) -> Int {
        let step = BubbleText.reducedMotionStep
        let sampled = Double(BubbleText.phaseIndex(t, period: step)) * step
        return 2 - Int((1 + cos(2 * .pi * sampled / BubbleText.reducedMotionPulse)) / 2 * 2.999)
    }
}
