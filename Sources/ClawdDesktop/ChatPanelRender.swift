import AppKit
import ClawdCore

/// F3: the transcript's entries as text. User turns, assistant text (fenced code blocks and inline code in a monospaced font, everything
/// else as received), tool lines with a status glyph, notices (dim), errors (red) and the turn footer. Links stay plain text: nothing here
/// ever sets a `.link` attribute, so nothing in the panel can open a URL or a file.
public enum ChatPanelRender {
    public static let toolLineLimit = 120
    static let bodySize: CGFloat = 13

    static var body: NSFont { .systemFont(ofSize: bodySize) }
    static var mono: NSFont { .monospacedSystemFont(ofSize: bodySize - 1, weight: .regular) }
    static var small: NSFont { .systemFont(ofSize: bodySize - 2) }

    static func paragraph(before: CGFloat = 0, after: CGFloat = 6, indent: CGFloat = 0) -> NSParagraphStyle {
        let style = NSMutableParagraphStyle()
        style.paragraphSpacingBefore = before; style.paragraphSpacing = after
        style.firstLineHeadIndent = indent; style.headIndent = indent
        return style
    }

    public static func render(_ entries: [ChatEntry]) -> NSAttributedString {
        let out = NSMutableAttributedString()
        for entry in entries { append(entry, to: out) }
        return out
    }

    static func append(_ entry: ChatEntry, to out: NSMutableAttributedString) {
        switch entry.kind {
        case .user:
            out.append(NSAttributedString(string: entry.text + "\n", attributes: [
                .font: NSFont.systemFont(ofSize: bodySize, weight: .semibold), .foregroundColor: NSColor.labelColor,
                .backgroundColor: NSColor.quaternaryLabelColor, .paragraphStyle: paragraph(before: 8, after: 8)]))
        case .assistant:
            out.append(assistant(entry.text))
            if entry.elided { out.append(NSAttributedString(string: ChatTranscript.elidedNotice + "\n", attributes: dim())) }
        case .tool:
            out.append(NSAttributedString(string: toolLine(entry) + "\n", attributes: [
                .font: mono, .foregroundColor: toolColor(entry.status), .paragraphStyle: paragraph(after: 2, indent: 10)]))
        case .notice:
            out.append(NSAttributedString(string: entry.text + "\n", attributes: dim()))
        case .divider:
            out.append(NSAttributedString(string: "\u{2014} " + entry.text + " \u{2014}\n", attributes: dim()))
        case .error:
            out.append(NSAttributedString(string: entry.text + "\n", attributes: [
                .font: body, .foregroundColor: NSColor.systemRed, .paragraphStyle: paragraph(before: 4, after: 6)]))
        case .footer:
            out.append(NSAttributedString(string: footer(entry) + "\n", attributes: [
                .font: small, .foregroundColor: NSColor.tertiaryLabelColor, .paragraphStyle: paragraph(after: 10)]))
        }
    }

    static func dim() -> [NSAttributedString.Key: Any] {
        [.font: small, .foregroundColor: NSColor.secondaryLabelColor, .paragraphStyle: paragraph(before: 2, after: 6)]
    }

    static func glyph(_ status: ChatToolStatus?) -> String {
        switch status {
        case .running: return "…"
        case .done: return "✓"
        case .failed: return "✕"
        case .unknown: return "?"
        case nil: return "•"
        }
    }
    static func toolColor(_ status: ChatToolStatus?) -> NSColor {
        switch status {
        case .failed: return .systemRed
        case .running: return .labelColor
        default: return .secondaryLabelColor
        }
    }

    /// `✓ Bash  ls -la  (3s)`: the glyph, the tool name, the one-line summary cut to 120 characters and, while Claude Code reports it, the seconds.
    public static func toolLine(_ entry: ChatEntry) -> String {
        var line = glyph(entry.status) + " " + (entry.tool ?? "tool")
        let summary = entry.text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: true).first.map(String.init) ?? ""
        if !summary.isEmpty {
            let cut = summary.count > toolLineLimit ? String(summary.prefix(toolLineLimit)) + "…" : summary
            line += "  " + cut
        }
        if let seconds = entry.seconds, seconds >= 1, let whole = wholeSeconds(seconds) { line += "  (\(whole)s)" }
        return line
    }

    /// The seconds Claude Code reported, as a count to show: nil (no duration is shown) for a value an Int cannot hold or one over 99,999.
    static func wholeSeconds(_ seconds: Double) -> Int? {
        guard let whole = Int(exactly: seconds.rounded()), whole <= 99_999 else { return nil }
        return whole
    }

    /// The turn footer: the duration and the cost, labelled as Claude Code reports it.
    public static func footer(_ entry: ChatEntry) -> String {
        var parts: [String] = []
        if let ms = entry.ms { parts.append(String(format: "%.1f s", Double(ms) / 1000)) }
        if let cost = entry.cost { parts.append(String(format: "$%.4f as Claude Code reports it", cost)) }
        return parts.isEmpty ? "Done" : parts.joined(separator: " · ")
    }

    /// Assistant text: a line that starts with three backticks opens or closes a fenced block (monospaced, the fence lines not shown);
    /// inside the other text a pair of single backticks makes inline code.
    static func assistant(_ text: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        var inFence = false
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        for raw in lines {
            let line = String(raw)
            if line.trimmingCharacters(in: .whitespaces).hasPrefix("```") { inFence.toggle(); continue }
            if inFence {
                out.append(NSAttributedString(string: line + "\n", attributes: [
                    .font: mono, .foregroundColor: NSColor.labelColor, .backgroundColor: NSColor.quaternaryLabelColor,
                    .paragraphStyle: paragraph(after: 0, indent: 8)]))
            } else {
                out.append(inline(line + "\n"))
            }
        }
        return out
    }

    static func inline(_ line: String) -> NSAttributedString {
        let out = NSMutableAttributedString()
        let plain: [NSAttributedString.Key: Any] = [.font: body, .foregroundColor: NSColor.labelColor, .paragraphStyle: paragraph(after: 2)]
        let code: [NSAttributedString.Key: Any] = [.font: mono, .foregroundColor: NSColor.labelColor, .backgroundColor: NSColor.quaternaryLabelColor,
                                                    .paragraphStyle: paragraph(after: 2)]
        var rest = Substring(line)
        // A backtick with no partner stays literal text.
        while let open = rest.firstIndex(of: "`"), let close = rest[rest.index(after: open)...].firstIndex(of: "`") {
            out.append(NSAttributedString(string: String(rest[..<open]), attributes: plain))
            out.append(NSAttributedString(string: String(rest[rest.index(after: open)..<close]), attributes: code))
            rest = rest[rest.index(after: close)...]
        }
        out.append(NSAttributedString(string: String(rest), attributes: plain))
        return out
    }
}
