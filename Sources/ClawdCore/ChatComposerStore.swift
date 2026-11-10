import Foundation
import Darwin

/// An image chip of the saved draft: the file it names, or (when the file is gone) only its name so it can be attached again.
public struct ChatComposerChip: Codable, Equatable {
    public var path: String?
    public var unavailable: String?
    public init(path: String? = nil, unavailable: String? = nil) { self.path = path; self.unavailable = unavailable }
}

/// chat-private/chat-composer.json, version 1 (spec Q8, Interface Contract): every field optional, so a file written by an earlier sprint is read by a
/// later one. The sends and cards belong to the later sprints; the file only carries them whole.
public struct ChatComposerFile: Codable, Equatable {
    public struct Card: Codable, Equatable {
        public var id: String, text: String, state: String, hold: String
        public var paused: String?
        /// The chips the send had, kept on a card made from a send (a doubt or returned card) so the chip strip can show them.
        public var chips: [ChatComposerChip]?
        public init(id: String, text: String, state: String, hold: String, paused: String? = nil, chips: [ChatComposerChip]? = nil) {
            self.id = id; self.text = text; self.state = state; self.hold = hold; self.paused = paused; self.chips = chips
        }
    }
    public struct Send: Codable, Equatable {
        public var uuid: String, text: String
        public var origin: String?
        public var chips: [ChatComposerChip]?
        public init(uuid: String, text: String, origin: String? = nil, chips: [ChatComposerChip]? = nil) {
            self.uuid = uuid; self.text = text; self.origin = origin; self.chips = chips
        }
    }
    public var version: Int?
    public var draft: String?
    public var chips: [ChatComposerChip]?
    public var cards: [Card]?
    public var pause: String?
    public var inflight: [Send]?
    public var doubt: [Send]?
    public init() { version = 1 }
}

/// The composer's saved state: the draft with its chips (and, for the later sprints, the cards and the sends not yet settled), kept in memory and
/// written to chat-private/chat-composer.json with Orca's rules (NC/native-chat-composer-draft-persistence.ts): 250 ms after the first change not yet
/// saved, at once on `flush`. Every write is private (OwnState.writePrivate). A refused write keeps everything in memory, sets `saveFailed` and is
/// tried again at the next change. Logs carry counts only.
public final class ChatComposerStore {
    public static let directory = "chat-private"
    public static let fileName = directory + "/chat-composer.json"
    /// Read cap = write cap: 1 MiB of draft and 1 MiB of cards with every character escaped fit.
    public static let capBytes = 16 * 1024 * 1024
    public static let debounce: TimeInterval = 0.25

    private let state: OwnState
    private let timers: ChatTimers
    private let log: (String) -> Void
    private var pending: ChatTimerHandle?
    private var written: ChatComposerFile
    private var durableOwed = false
    /// The agent's quit is held while a write is owed (ChatQuit): a SIGTERM inside the 250 ms goes through `onQuit` and the flush, not past it.
    private var quitHeld = false
    /// The unparsable file could not be renamed to `.bad`: a save would overwrite it, so saves are refused until the rename works.
    private var badStuck = false
    public private(set) var content: ChatComposerFile
    /// The warning icon is up: the last write was refused, or it had to leave something out.
    public private(set) var saveFailed = false
    /// Called when `saveFailed` changes.
    public var onSaveStateChanged: (() -> Void)?

    public init(state: OwnState, timers: ChatTimers, log: @escaping (String) -> Void) {
        self.state = state; self.timers = timers; self.log = log
        state.removeStaleTemps(in: Self.directory)
        let loaded = Self.load(state, log: log)
        content = loaded.file; written = loaded.file; badStuck = loaded.stuck
    }
    deinit { releaseQuit() }

    /// Whether the unparsable composer file is still on disk.
    private func fileExists() -> Bool {
        var info = stat()
        guard let path = try? state.url(Self.fileName).path else { return true }
        return lstat(path, &info) == 0
    }

    /// Whether the store holds the agent's quit open now: while a write is owed (the 250 ms after a change), until it is written. For the tests.
    public var holdsQuit: Bool { quitHeld }

    private func holdQuit() {
        guard !quitHeld else { return }
        quitHeld = true
        ChatQuit.cleanupStarting()
    }
    private func releaseQuit() {
        guard quitHeld else { return }
        quitHeld = false
        ChatQuit.cleanupEnded()
    }

    /// The file's content. A file over the cap or one that does not parse is renamed `<name>.bad` (one slot, replacing an older one) and never
    /// overwritten in place; the start is then from empty.
    private static func load(_ state: OwnState, log: (String) -> Void) -> (file: ChatComposerFile, stuck: Bool) {
        var info = stat()
        guard let path = try? state.url(fileName).path, lstat(path, &info) == 0 else { log("CHAT composer-state read=none"); return (ChatComposerFile(), false) }
        func setAside(_ why: String) -> (file: ChatComposerFile, stuck: Bool) {
            let stuck = (try? state.rename(fileName, to: fileName + ".bad")) == nil
            log("CHAT composer-state read=\(why)")
            return (ChatComposerFile(), stuck)
        }
        guard info.st_mode & S_IFMT == S_IFREG, info.st_size <= capBytes else { return setAside("over") }
        guard let data = try? ReadOnlyFile.data(path, limit: capBytes) else { return setAside("bad") }
        guard var file = try? JSONDecoder().decode(ChatComposerFile.self, from: data), file.version == 1 || file.version == nil else { return setAside("bad") }
        file.version = 1
        file.chips = file.chips.map { checked($0, exists: { FileManager.default.fileExists(atPath: $0) }) }
        return (file, false)
    }

    /// A chip whose file no longer exists becomes an unavailable chip that keeps the file's name.
    public static func checked(_ chips: [ChatComposerChip], exists: (String) -> Bool) -> [ChatComposerChip] {
        chips.map { chip in
            guard let path = chip.path, !exists(path) else { return chip }
            return ChatComposerChip(unavailable: (path as NSString).lastPathComponent)
        }
    }

    /// The chip files are looked at again (at each open and at each send: the sweeps can remove one mid-run).
    public func recheckChips(exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) {
        guard let chips = content.chips else { return }
        let now = Self.checked(chips, exists: exists)
        guard now != chips else { return }
        content.chips = now
        changed(durable: false)
    }

    // MARK: changes

    public var draft: String { content.draft ?? "" }

    /// The draft text changed: it is written 250 ms after the first change not yet saved.
    public func setDraft(_ text: String) {
        guard text != draft else { return }
        content.draft = text.isEmpty ? nil : text
        changed(durable: false)
    }

    public func setChips(_ chips: [ChatComposerChip]) {
        let new = chips.isEmpty ? nil : chips
        guard new != content.chips else { return }
        content.chips = new
        changed(durable: false)
    }

    /// A change to the cards, the sends not yet settled or the doubt list: written with F_FULLFSYNC (the cards and sends are power-safe).
    public func update(durable: Bool, _ change: (inout ChatComposerFile) -> Void) {
        let before = content
        change(&content)
        guard content != before else { return }
        changed(durable: durable)
    }

    private func changed(durable: Bool) {
        if durable { durableOwed = true }
        guard pending == nil else { return }
        holdQuit()
        pending = timers.after(Self.debounce) { [weak self] in self?.pending = nil; self?.save(); self?.releaseQuit() }
    }

    /// Writes what has not been written, now (a send, a queue change, a close, the quit). A write that failed is tried again here too.
    public func flush() {
        pending?.cancel(); pending = nil
        save()
        releaseQuit()
    }

    /// Whether a write is waiting for its 250 ms (for the tests).
    public var hasPendingWrite: Bool { pending != nil }

    // MARK: the write

    private static func encode(_ file: ChatComposerFile) -> Data? {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        return try? encoder.encode(file)
    }

    private func save() {
        guard content != written || saveFailed else { return }
        if badStuck {
            // A file that is gone blocks nothing: the rename of a missing source fails, but there is nothing left to overwrite.
            badStuck = (try? state.rename(Self.fileName, to: Self.fileName + ".bad")) == nil && fileExists()
            if badStuck { return fail(bytes: 0) }
        }
        var file = content
        file.version = 1
        guard var data = Self.encode(file) else { return fail(bytes: 0) }
        var leftOut = false
        if data.count > Self.capBytes {
            // Sends not yet settled and doubts are never left out: the draft goes first, then the waiting cards from the newest.
            leftOut = true
            file.draft = nil; file.chips = nil
            data = Self.encode(file) ?? data
            while data.count > Self.capBytes, let index = file.cards?.lastIndex(where: { $0.state == "waiting" }) {
                _ = file.cards?.remove(at: index)
                data = Self.encode(file) ?? data
            }
            guard data.count <= Self.capBytes else { return fail(bytes: data.count) }
        }
        do {
            try state.writePrivate(data, to: Self.fileName, durable: durableOwed)
        } catch {
            return fail(bytes: data.count)
        }
        durableOwed = false
        written = content
        if leftOut { noteFailure(bytes: data.count) } else { noteRecovery() }
        setFailed(leftOut)
    }

    private func fail(bytes: Int) {
        noteFailure(bytes: bytes)
        setFailed(true)
    }

    /// One line when saving starts failing and one when it works again, not one per attempt (a refused folder is retried at every keystroke).
    private func noteFailure(bytes: Int) {
        if !saveFailed { log("CHAT composer-state saved=failed bytes=\(bytes)") }
    }
    private func noteRecovery() {
        if saveFailed { log("CHAT composer-state saved=ok") }
    }

    private func setFailed(_ value: Bool) {
        guard saveFailed != value else { return }
        saveFailed = value
        onSaveStateChanged?()
    }
}
