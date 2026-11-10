import Foundation

/// What a terminal title says about claude (spec T-6, in Orca's order: src/shared/agent-title-status.ts:245-259 at 2b7b521). A title that starts
/// with "✳" (U+2733) is idle, checked first; otherwise a spinner glyph anywhere is work; anything else is unknown. The spinner glyphs are braille
/// U+2800-U+28FF and the quarter circles U+25D0-U+25D3 (agent-title-glyphs.ts:1-44).
public enum ChatTermTitle: Equatable {
    case idle, working, unknown

    public static func state(of title: String) -> ChatTermTitle {
        if title.unicodeScalars.first?.value == 0x2733 { return .idle }
        if title.unicodeScalars.contains(where: { (0x2800...0x28FF).contains($0.value) || (0x25D0...0x25D3).contains($0.value) }) { return .working }
        return .unknown
    }
}

/// The resume bookkeeping of one agent process (spec T-6; in T1 the id lives in memory only). The session to resume is the latest one that this
/// process started, that is known to have a stored conversation (a title read as work was seen during its children), whose folder is still
/// `chatFolder`, and whose resume has not failed. Otherwise the next spawn is fresh with a new id.
public struct ChatTermResume: Equatable {
    public private(set) var current: String?
    private var conversation: (id: String, folder: String)?
    public private(set) var failed: Set<String> = []

    public init() {}

    public static func == (a: ChatTermResume, b: ChatTermResume) -> Bool {
        a.current == b.current && a.conversation?.id == b.conversation?.id && a.conversation?.folder == b.conversation?.folder && a.failed == b.failed
    }

    /// The id and mode of the next spawn in `folder`; a fresh spawn takes `newId` and becomes the current session.
    public mutating func next(folder: String, newId: String) -> ChatTermLaunch.Mode {
        if let conversation, conversation.folder == folder, !failed.contains(conversation.id) { current = conversation.id; return .resume(conversation.id) }
        current = newId
        return .fresh(newId)
    }

    /// A title read as work was seen during the current session's child: claude shows one only while a turn runs, after it has the prompt.
    public mutating func sawWork(folder: String) {
        if let current { conversation = (current, folder) }
    }

    /// A `--resume` of `id` failed: it is never resumed again in this agent process.
    public mutating func resumeFailed(_ id: String) { failed.insert(id) }
}

/// The user's own exit keys as one input-path send carries them (R9.12 item 4, r12). One function, used by the resume mark (a child the user
/// typed an exit key into is not a failed resume) and by the draft rule (Ctrl+C clears a draft).
public enum ChatTermExitKey: Equatable {
    case ctrlC, ctrlD

    /// The single byte 0x03 or 0x04, or exactly one CSI u key event `ESC [ key[:shifted[:base]] [; m[:type] [; text]] u` whose key code or
    /// base-layout key is 99 (C) or 100 (D), with Control set in m (bit 4 of m - 1) and a press (no event type, or 1). So `CSI 99;5u`,
    /// `CSI 99:67;6u` and `CSI 12381::99;5u` (a kana source under the alternate-keys flag) are Ctrl+C, and `CSI 99;5:3u` (a release) is not.
    public static func match(_ bytes: [UInt8]) -> ChatTermExitKey? {
        if bytes == [0x03] { return .ctrlC }
        if bytes == [0x04] { return .ctrlD }
        guard bytes.count >= 4, bytes[0] == 0x1B, bytes[1] == 0x5B, bytes.last == 0x75 else { return nil }
        guard let body = String(bytes: bytes[2..<(bytes.count - 1)], encoding: .ascii) else { return nil }
        let fields = body.split(separator: ";", maxSplits: 2, omittingEmptySubsequences: false).map(String.init)
        func number(_ text: String) -> Int? { text.isEmpty || !text.allSatisfy({ $0.isASCII && $0.isNumber }) ? nil : Int(text) }
        let keys = fields[0].split(separator: ":", omittingEmptySubsequences: false).map(String.init)
        guard (1...3).contains(keys.count), let code = number(keys[0]) else { return nil }
        let shifted = keys.count > 1 ? keys[1] : "", base = keys.count > 2 ? keys[2] : ""
        guard shifted.isEmpty || number(shifted) != nil, base.isEmpty || number(base) != nil else { return nil }
        let baseKey = number(base)
        var modifiers = 1, type = 1
        if fields.count > 1 {
            let parts = fields[1].split(separator: ":", omittingEmptySubsequences: false).map(String.init)
            guard (1...2).contains(parts.count), let value = number(parts[0]) else { return nil }
            modifiers = value
            if parts.count == 2 { guard let kind = number(parts[1]) else { return nil }; type = kind }
        }
        guard type == 1, modifiers >= 1, (modifiers - 1) & 4 != 0 else { return nil }
        if code == 99 || baseKey == 99 { return .ctrlC }
        if code == 100 || baseKey == 100 { return .ctrlD }
        return nil
    }
}

/// Whether text may be pending in claude's input (spec T-6): since the last plain Return or Ctrl+C typed in the panel, the user typed text (a
/// printable key, an IME commit or a paste). Fed with what the delegate sends to claude, in the order claude receives it.
///
/// A lone CR clears the draft except when it may not have sent the input (R9.12 item 6): (a) the previous send ended in a backslash (Claude Code's
/// newline; for a paste, the last byte of the pasted text, not of its markers), or (b) an `@` was typed at a word start since the latest lone CR,
/// with no space or tab after it, and the previous send was not a lone CR (the Return may have accepted the TUI's path suggestion; Clawd reads
/// no TUI state, it holds the draft across that one Return).
public struct ChatTermDraft: Equatable {
    public private(set) var pending = false
    /// The previous send ended in a backslash / was a lone CR.
    private var afterBackslash = false
    private var afterLoneReturn = false
    /// The next typed byte starts a word: the first since the spawn or the latest clear, or right after a space, a tab, a CR or an ESC CR.
    private var atWordStart = true
    /// An `@` was typed at a word start since the latest lone CR, with no space or tab after it.
    private var atArmed = false
    public init() {}

    private static let pasteEnd: [UInt8] = [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]

    /// `bytes` are what one send to claude carried; `fromPaste` marks Clawd's paste (with its markers when it was bracketed).
    public mutating func sent(_ bytes: [UInt8], fromPaste: Bool) {
        if fromPaste {
            pending = true
            var text = bytes
            if text.count >= Self.pasteEnd.count, Array(text.suffix(Self.pasteEnd.count)) == Self.pasteEnd { text.removeLast(Self.pasteEnd.count) }
            afterBackslash = text.last == 0x5C
            afterLoneReturn = false
            atWordStart = [0x20, 0x09, 0x0D, 0x0A].contains(text.last ?? 0)
            return
        }
        if ChatTermExitKey.match(bytes) == .ctrlC {
            clear()
            return
        }
        if bytes == [0x0D] {
            let holds = afterBackslash || (atArmed && !afterLoneReturn)
            if !holds { pending = false }
            afterBackslash = false; afterLoneReturn = true; atWordStart = true; atArmed = false
            return
        }
        // Text: anything that is not an escape sequence or a control byte (a printable ASCII byte or a multi-byte UTF-8 character).
        let text = bytes.contains(where: { $0 >= 0x20 && $0 != 0x7F }) && bytes.first != 0x1B
        if text {
            pending = true
            for byte in bytes {
                if byte == 0x40, atWordStart { atArmed = true }
                if byte == 0x20 || byte == 0x09 { atArmed = false }
                atWordStart = byte == 0x20 || byte == 0x09 || byte == 0x0D
            }
        } else if bytes == [0x1B, 0x0D] {
            atWordStart = true
        }
        afterBackslash = bytes.last == 0x5C
        afterLoneReturn = false
    }

    public mutating func clear() {
        pending = false
        afterBackslash = false; afterLoneReturn = false; atWordStart = true; atArmed = false
    }
}
