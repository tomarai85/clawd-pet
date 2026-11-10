import Foundation

/// The commands Clawd's chat claims as Orca's structured host does (Q25, D4): `/clear`, `/compact`, `/model` and `/effort`, matched only on the
/// draft's exact first token (SH/structured-agent-session-composer.ts:50-56, 87-106, 134-200). Everything else is Claude's: an unknown `/token`
/// is sent as typed. `/init` is not claimed, but it is gated (a Clawd deviation): the chat runs in the home folder unless `chatFolder` says
/// otherwise, and a careless `/init` would write ~/CLAUDE.md, which every Claude Code session under $HOME loads.
public enum ChatHostCommand {
    public struct Parts: Equatable {
        public var name: String
        public var argument: String
    }

    /// Orca `commandParts`: the text starts with `/`, and `^\\/([^\\s]+)(?:\\s+(.*))?$` matches its trimmed end. `.` stops at a line break, so an
    /// argument with a line break inside it does not match and the text is not a command. The name is lower-cased.
    public static func parts(_ text: String) -> Parts? {
        guard text.hasPrefix("/") else { return nil }
        let scalars = Array(ChatJSText.trimmedEnd(text).unicodeScalars.dropFirst())
        var index = 0
        while index < scalars.count, !ChatJSText.isWhitespace(scalars[index]) { index += 1 }
        guard index > 0 else { return nil }
        let name = String(String.UnicodeScalarView(scalars[0..<index])).lowercased()
        if index == scalars.count { return Parts(name: name, argument: "") }
        while index < scalars.count, ChatJSText.isWhitespace(scalars[index]) { index += 1 }
        let rest = scalars[index...]
        guard !rest.contains(where: ChatJSText.isLineTerminator) else { return nil }
        return Parts(name: name, argument: ChatJSText.trimmed(String(String.UnicodeScalarView(rest))))
    }

    /// Whether `folder` is the home folder: the same standardized, symlink-resolved path compared without regard to case (the volume ignores it), or the
    /// same directory by device and inode.
    public static func folderIsHome(_ folder: String, home: String) -> Bool {
        func resolved(_ path: String) -> String { URL(fileURLWithPath: path).resolvingSymlinksInPath().standardizedFileURL.path }
        if resolved(folder).lowercased() == resolved(home).lowercased() { return true }
        var a = stat(), b = stat()
        return stat(folder, &a) == 0 && stat(home, &b) == 0 && a.st_dev == b.st_dev && a.st_ino == b.st_ino
    }

    /// The /init gate's own reading of a draft, which does not go through `parts` (that returns nil for an argument with a line break inside it): the
    /// first token of the trimmed draft, up to any white space or line break, lower-cased, is `/init`.
    public static func isInit(_ text: String) -> Bool {
        let scalars = Array(ChatJSText.trimmed(text).unicodeScalars)
        var end = 0
        while end < scalars.count, !ChatJSText.isWhitespace(scalars[end]), !ChatJSText.isLineTerminator(scalars[end]) { end += 1 }
        return String(String.UnicodeScalarView(scalars[0..<end])).lowercased() == "/init"
    }

    /// The name a log line carries for a draft: `init` for every form the gate reads, else the claimed or typed command name, else `none`.
    public static func logName(_ text: String) -> String { isInit(text) ? "init" : parts(text)?.name ?? "none" }

    public static let claimed: Set<String> = ["model", "effort", "clear", "compact", "resume", "continue"]

    public static let attachmentsRefusal = "Remove attachments before using a chat-session command."
    public static let turnRefusal = "Wait for the current turn to finish before using this command."
    public static let unsettledRefusal = "Resolve pending or unconfirmed messages before using this command."
    public static let modelAnswer = "Models are unavailable for this chat session."
    public static let effortAnswer = "Reasoning effort are unavailable for this chat session."
    public static let initRefusal = "Set chatFolder first: /init writes CLAUDE.md into the chat's folder, which is your home folder now."
    /// The refusal for picking or typing a conversation to resume, in Orca's order: attachments, then the turn, then unsettled sends. nil: allowed.
    public static func resumeRefusal(hasChips: Bool, turnActive: Bool, sendUnsettled: Bool) -> String? {
        if hasChips { return attachmentsRefusal }
        if turnActive { return turnRefusal }
        if sendUnsettled { return unsettledRefusal }
        return nil
    }
    public static func argumentRefusal(_ name: String) -> String { "Use /\(name) without arguments." }

    public enum Decision: Equatable {
        /// Not Clawd's: sent as typed, through the ordinary send path.
        case text
        /// Shown in the status line; nothing is sent and the draft is kept.
        case refuse(String)
        /// `/model` and `/effort`: Orca answers them as accepted with the words as the notice (:168-180), so the draft is taken like a sent one, but
        /// nothing reaches Claude.
        case answer(String)
        /// Claude gets exactly this text through the ordinary send path: `/compact`, or `/clear` (a local command of the CLI, cost 0).
        case send(String)
        /// `/resume` or `/continue` typed whole: the controller opens the conversations list; nothing is sent.
        case openResume
        /// `/resume <text>`: resume the conversation the text names (an id or a title), or say it was not found. Nothing is sent to Claude.
        case resume(String)
    }

    /// What a draft means. The order is Orca's: attachments, then arguments, then the admission of a turn and of unsettled sends.
    public static func decide(_ text: String, hasChips: Bool, turnActive: Bool, sendUnsettled: Bool, chatFolderIsHome: Bool) -> Decision {
        // The /init gate fails closed: it reads the draft with its white space trimmed (Claude Code trims before it looks for a slash, so ` /init`
        // runs there), and the name is lower-cased by `parts`. Only the four claimed names need an exact first token (Orca).
        if chatFolderIsHome, isInit(text) { return .refuse(initRefusal) }
        guard let command = parts(text) else { return .text }
        guard claimed.contains(command.name) else { return .text }
        if command.name == "resume" || command.name == "continue" {
            if command.argument.isEmpty { return .openResume }
            if let words = resumeRefusal(hasChips: hasChips, turnActive: turnActive, sendUnsettled: sendUnsettled) { return .refuse(words) }
            return .resume(command.argument)
        }
        if hasChips { return .refuse(attachmentsRefusal) }
        switch command.name {
        case "clear", "compact":
            if !command.argument.isEmpty { return .refuse(argumentRefusal(command.name)) }
            if turnActive { return .refuse(turnRefusal) }
            if sendUnsettled { return .refuse(unsettledRefusal) }
            return .send("/" + command.name)
        case "model": return .answer(modelAnswer)
        default: return .answer(effortAnswer)
        }
    }
}
