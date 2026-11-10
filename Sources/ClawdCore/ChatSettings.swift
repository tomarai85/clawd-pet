import Foundation

/// `chatPermissions` (spec F5). `ask` comes with the permission prompts; until then an unknown value reads as the default.
public enum ChatPermissions: String, Equatable {
    case bypass, deny

    /// The Claude Code flags of F2.1 for this mode.
    public var arguments: [String] {
        switch self {
        case .bypass: return ["--permission-mode", "bypassPermissions", "--permission-prompts", "none"]
        case .deny: return ["--permission-mode", "default", "--permission-prompts", "none"]
        }
    }
}

/// `chatView` (spec F5, r9; Stage 2): which surface the chat panel shows. `chat` (the default) is the web transcript over Clawd's native input on
/// the stream-json path; `stream` is the old AppKit view on the same path; `terminal` is the SwiftTerm TUI. Stage 4 removes `stream` and `terminal`.
public enum ChatView: String, Equatable { case chat, terminal, stream }

/// `chatOutsideClick`: what a plain click in another application does to the open panel. `close` (the default) closes it; `stay` is Orca's own
/// behaviour, where a press elsewhere never closes. A press that moves at least 4 pt is a drag and closes nothing either way.
public enum ChatOutsideClick: String, Equatable { case close, stay }

/// The `control.json` keys of the chat (spec F5). Every key is read on its own: a missing, wrong-typed or out-of-range value gives that key's
/// default and touches no other key. All are live; a running child keeps the flags it was started with.
public struct ChatSettings: Equatable {
    public static let defaultPath = ["$HOME/.local/bin", "$HOME/bin", "/opt/homebrew/bin", "/opt/homebrew/sbin", "/usr/local/bin", "/usr/bin", "/bin",
                                     "/usr/sbin", "/sbin"]

    /// Q6: where `claude` is looked for while `chatClaude` is not set, in this order. The one constant: nothing else names these places.
    public static let claudeSearchList = ["$HOME/.local/bin", "/opt/homebrew/bin", "/usr/local/bin"]

    public var enabled = true
    /// The path `chatClaude` gave (`~` expanded), else the default `~/.local/bin/claude`. A caller that sets it names the binary for good.
    public var claude: String { didSet { claudeIsSet = true } }
    /// `chatClaude` was given and the reader accepted it (or a caller set `claude`). The Q6 search runs only while this is false.
    public private(set) var claudeIsSet = false
    /// The folders the Q6 search looks in (`$HOME` stands for the home folder); a test points it at stubbed files.
    public var claudeSearch = ChatSettings.claudeSearchList
    let home: String
    public var folder: String
    public var permissions: ChatPermissions = .deny
    public var view: ChatView = .chat
    public var outsideClick: ChatOutsideClick = .close
    public var model: String?
    public var path: String
    /// `chatQueueFollowUps` (D13): a send while Claude answers becomes a queued card (Orca's `nativeChatQueueFollowUps`, on unless set off). Off sends it
    /// into the running turn at once.
    public var queueFollowUps = true

    public init(home: String = NSHomeDirectory()) {
        self.home = home
        claude = home + "/.local/bin/claude"
        folder = home
        path = Self.defaultPath.map { $0.replacingOccurrences(of: "$HOME", with: home) }.joined(separator: ":")
    }

    public init(data: Data, home: String = NSHomeDirectory()) {
        self.init(object: (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:], home: home)
    }

    public init(object: [String: Any], home: String = NSHomeDirectory()) {
        self.init(home: home)
        if let value = object["chat"] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() { enabled = value.boolValue }
        if let value = Self.absolutePath(object["chatClaude"], home: home) { claude = value; claudeIsSet = true }
        if let value = Self.absolutePath(object["chatFolder"], home: home) { folder = value }
        if let value = object["chatPermissions"] as? String, let mode = ChatPermissions(rawValue: value) { permissions = mode }
        if let value = object["chatView"] as? String, let surface = ChatView(rawValue: value) { view = surface }
        if let value = object["chatOutsideClick"] as? String, let mode = ChatOutsideClick(rawValue: value) { outsideClick = mode }
        if let value = object["chatModel"] as? String, Self.validModel(value) { model = value }
        if let value = object["chatPath"] as? String, Self.validPath(value) { path = value }
        if let value = object["chatQueueFollowUps"] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() { queueFollowUps = value.boolValue }
    }

    /// The real binary behind `path` (symlinks resolved) when it is a regular executable file: the chat's own check before a spawn.
    public static func runnable(_ path: String) -> String? {
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        var info = stat()
        guard stat(resolved, &info) == 0, (info.st_mode & S_IFMT) == S_IFREG, access(resolved, X_OK) == 0 else { return nil }
        return resolved
    }

    /// Where the chat finds `claude` now. A set `chatClaude` always wins, present or not (no search runs); otherwise the first place of the
    /// search list that holds a runnable `claude`. Nothing is written: the result lives in memory only.
    public enum ClaudeLocation: Equatable {
        /// `chatClaude` is set: the path as given, and the real binary behind it when it runs.
        case given(path: String, resolved: String?)
        /// Not set, and found at the default `~/.local/bin/claude`.
        case defaultPlace(path: String, resolved: String)
        /// Not set, and found by the search at another place of the list.
        case searched(path: String, resolved: String)
        /// Not set, and found nowhere.
        case nowhere

        /// The real binary to start, when there is one.
        public var resolved: String? {
            switch self {
            case .given(_, let resolved): return resolved
            case .defaultPlace(_, let resolved), .searched(_, let resolved): return resolved
            case .nowhere: return nil
            }
        }
    }

    /// "~/.local/bin, /opt/homebrew/bin or /usr/local/bin", from the search's own list.
    public static var searchedPlaces: String {
        let places = claudeSearchList.map { $0.replacingOccurrences(of: "$HOME", with: "~") }
        return places.dropLast().joined(separator: ", ") + " or " + (places.last ?? "")
    }

    /// The chat's refusal when `claude` cannot be started: the set path, or the places the search looked in when no path is set.
    public func claudeMissingText() -> String {
        if case .nowhere = claudeLocation() { return "Claude Code was not found in \(Self.searchedPlaces)" }
        return "Claude Code was not found at \(claude)"
    }

    public func claudeLocation() -> ClaudeLocation {
        if claudeIsSet { return .given(path: claude, resolved: Self.runnable(claude)) }
        for (index, directory) in claudeSearch.enumerated() {
            let path = directory.replacingOccurrences(of: "$HOME", with: home) + "/claude"
            guard let resolved = Self.runnable(path) else { continue }
            return index == 0 && path == claude ? .defaultPlace(path: path, resolved: resolved) : .searched(path: path, resolved: resolved)
        }
        return .nowhere
    }

    /// An absolute path of at most 1024 bytes, `~` expanded; anything else is nil.
    static func absolutePath(_ raw: Any?, home: String) -> String? {
        guard var text = raw as? String, !text.isEmpty, text.utf8.count <= 1024, !text.contains("\0") else { return nil }
        if text == "~" { text = home } else if text.hasPrefix("~/") { text = home + String(text.dropFirst(1)) }
        return text.hasPrefix("/") ? text : nil
    }

    /// `[A-Za-z0-9._:\[\]-]{1,64}`
    static func validModel(_ text: String) -> Bool {
        guard (1...64).contains(text.utf8.count) else { return false }
        return text.unicodeScalars.allSatisfy { scalar in
            (scalar.value < 128) && (CharacterSet.alphanumerics.contains(scalar) || "._:[]-".unicodeScalars.contains(scalar))
        }
    }

    /// Colon-separated absolute directories.
    static func validPath(_ text: String) -> Bool {
        guard !text.isEmpty, text.utf8.count <= 4096, !text.contains("\0") else { return false }
        return text.split(separator: ":", omittingEmptySubsequences: false).allSatisfy { $0.hasPrefix("/") }
    }
}
