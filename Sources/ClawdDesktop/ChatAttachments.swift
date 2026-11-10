import AppKit
import ClawdCore

/// The pasteboard a drag carries. Tests build their own named boards of this type (never the general pasteboard) and so never name the system's.
public typealias ChatDragPasteboard = NSPasteboard

/// Orca's `@path` reference (shared/agent-image-paste.ts:29-41 formatNativeChatFileReference).
public enum ChatFileReference {
    /// The characters JavaScript's `\s` matches.
    private static let jsWhitespace: Set<Unicode.Scalar> = {
        var set: Set<Unicode.Scalar> = ["\u{09}", "\u{0A}", "\u{0B}", "\u{0C}", "\u{0D}", "\u{20}", "\u{A0}", "\u{1680}", "\u{2028}", "\u{2029}",
                                         "\u{202F}", "\u{205F}", "\u{3000}", "\u{FEFF}"]
        for value in 0x2000...0x200A { set.insert(Unicode.Scalar(UInt32(value))!) }
        return set
    }()

    /// `@path` without whitespace or `@`; else `@"path"` without a quote; else `@'path'` without an apostrophe; else `@"…"` with each quote escaped.
    public static func format(_ path: String) -> String {
        let scalars = path.unicodeScalars
        if !scalars.contains(where: { jsWhitespace.contains($0) || $0 == "@" }) { return "@" + path }
        // JavaScript's `includes` and `replace` work per UTF-16 code unit: a quote fused with a combining mark is still a quote.
        if !scalars.contains("\"") { return "@\"" + path + "\"" }
        if !scalars.contains("'") { return "@'" + path + "'" }
        var escaped = String.UnicodeScalarView()
        for scalar in scalars {
            if scalar == "\"" { escaped.append("\\") }
            escaped.append(scalar)
        }
        return "@\"" + String(escaped) + "\""
    }

    /// The references joined by one space and followed by one trailing space (use-native-chat-resolved-path-attachments.ts:63-79).
    public static func text(for paths: [String]) -> String { paths.map(format).joined(separator: " ") + " " }
}

/// Orca's drop limits (shared/native-file-drop.ts:5-6, 188-224) and the words the status line uses.
public enum ChatDropText {
    public static let maxPaths = 256
    public static let maxPathBytes = 262_144
    public static let tooMany = "Drop contains too many files. Drop 256 or fewer files at a time."
    public static let tooLarge = "Drop path list is too large. Drop fewer files or use a shorter path list."
    public static let unresolved = "Clawd couldn't read a path for the dropped files. Save them to disk first, then drop the saved files."
    public static let waiting = "Too many attachments are waiting. Finish composing before attaching more."
    public static let overCap = "Not inserted: the message would be over 1 MiB"
    /// Orca's `nativeDropTempCopyFailed` and its `_one` form (en.json:1172-1173).
    public static func copyFailed(count: Int, reason: String) -> String {
        count == 1 ? "Clawd couldn't copy 1 dropped file. \(reason)" : "Clawd couldn't copy \(count) dropped files. \(reason)"
    }
}

/// What a drag or a paste pasteboard carries that the chat takes.
public enum ChatDropContent {
    /// Promise types (Photos, Mail, Dia image drags): not received, they get the "couldn't read a path" message.
    public static var promiseTypes: [NSPasteboard.PasteboardType] { NSFilePromiseReceiver.readableDraggedTypes.map { NSPasteboard.PasteboardType($0) } }
    public static var registeredTypes: [NSPasteboard.PasteboardType] { [.fileURL] + promiseTypes }

    public static func carriesFiles(_ pasteboard: NSPasteboard) -> Bool {
        let types = pasteboard.types ?? []
        return types.contains(.fileURL) || types.contains { promiseTypes.contains($0) }
    }

    public static func carriesPromise(_ pasteboard: NSPasteboard) -> Bool {
        (pasteboard.types ?? []).contains { promiseTypes.contains($0) }
    }

    /// The POSIX path of each file URL, in order (`urlReadingFileURLsOnly`).
    public static func paths(_ pasteboard: NSPasteboard) -> [String] {
        let urls = pasteboard.readObjects(forClasses: [NSURL.self], options: [.urlReadingFileURLsOnly: true]) as? [URL] ?? []
        return urls.map(\.path)
    }
}

/// What the pasteboard holds for a paste (Q15): its text, its image (png or tiff), whether an image type is the pasteboard's first type, and the
/// names of its file URLs (a Finder copy carries the file names as text).
public struct ChatPasteContents {
    public var hasText: Bool
    public var text: String?
    public var image: Data?
    /// An image type comes first among the pasteboard's types. Rich text copied from Numbers, Excel, Word, Pages or Keynote puts its text types first
    /// and carries a TIFF or PDF rendition, so its image is not taken when there is text (inference, N8).
    public var imageFirst: Bool
    public var fileNames: [String]
    public init(hasText: Bool, image: Data? = nil, text: String? = nil, imageFirst: Bool = false, fileNames: [String] = []) {
        self.hasText = hasText; self.image = image; self.text = text; self.imageFirst = imageFirst; self.fileNames = fileNames
    }
    public static let production: () -> ChatPasteContents = {
        let pasteboard = NSPasteboard.general
        let types = pasteboard.types ?? []
        let hasText = types.contains(.string)
        let image = pasteboard.data(forType: .png) ?? pasteboard.data(forType: .tiff)
        let first = types.first
        return ChatPasteContents(hasText: hasText, image: image, text: hasText ? pasteboard.string(forType: .string) : nil,
                                 imageFirst: first == .png || first == .tiff,
                                 fileNames: ChatDropContent.paths(pasteboard).map { ($0 as NSString).lastPathComponent })
    }

    /// The text of a paste that carries an image, or nil when the text only labels the copied files (NC/native-chat-clipboard-payload.ts:39-63): the
    /// lines of the text, sorted, equal the names of the pasteboard's file URLs.
    public func textToInsert() -> String? {
        guard let text, !text.isEmpty else { return nil }
        if !fileNames.isEmpty {
            let lines = text.split(whereSeparator: \.isNewline).map(String.init).sorted()
            if lines == fileNames.sorted() { return nil }
        }
        return text
    }
}

/// What the attach, drop and paste paths take from the machine. The defaults do nothing real: no storage, no picker, work runs inline. The
/// real values are `production` and the agent's store, which the runtime fills in.
public struct ChatAttachEnvironment {
    /// The agent's own state directory (drop copies and pasted images go under it); nil keeps nothing.
    public var state: OwnState?
    /// The per-user temp directory that drag providers write into.
    public var temporaryDirectory: String = NSTemporaryDirectory()
    public var fileCap: Int64 = DragTempCopier.fileCap
    public var totalCap: Int64 = DragTempCopier.totalCap
    /// Runs `work` off the main thread, then `done` on the main queue. The default runs both at once.
    public var background: (_ work: @escaping () -> Void, _ done: @escaping () -> Void) -> Void = { work, done in work(); done() }
    public var pasteContents: () -> ChatPasteContents = { ChatPasteContents(hasText: true) }
    /// Reads the chips' files off the main thread, one at a time, for their thumbnails and the preview (Q14).
    public var chipLoader = ChatChipLoader()
    public var encodePNG: (Data) -> Data? = ClipboardImage.encodePNG
    public var picker: () -> ChatAttachPicking = { InertAttachPicker() }
    public var wallMilliseconds: () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
    public var uuid: () -> UUID = { UUID() }
    public var wall: () -> Date = { Date() }
    /// A monotonic clock for the per-drop timeout.
    public var uptime: () -> TimeInterval = { ProcessInfo.processInfo.systemUptime }
    public init() {}

    public static var production: ChatAttachEnvironment {
        var env = ChatAttachEnvironment()
        env.background = { work, done in
            DispatchQueue.global(qos: .utility).async { work(); DispatchQueue.main.async(execute: done) }
        }
        env.pasteContents = ChatPasteContents.production
        env.chipLoader = ChatChipLoader.production
        env.picker = { ChatAttachPicker() }
        return env
    }
}

/// One opening's file attachments: the drop's paths, the paste's image and the picker's file reach the composer here, with Orca's limits, quoting,
/// IME hold and drag-temp copies. Everything it logs is a count or a reason (F6). It dies with the opening.
public final class ChatAttachmentSession {
    private final class Ticket {
        var paths: [String]
        var copies: [DragTempResult]?
        var target: String
        var promise: Bool
        var cancelled = false
        /// Its copy is the one running now, and its 120 s deadline (main queue) has run out.
        var running = false
        var timedOut = false
        var timer: ChatTimerHandle?
        init(paths: [String], target: String, promise: Bool) { self.paths = paths; self.target = target; self.promise = promise }
    }

    public let gen: Int
    /// Called with the stored path of a paste that finished after its opening closed (set by the controller).
    public var storedAfterClose: ((String) -> Void)?
    private weak var body: ChatWebBody?
    private let env: ChatAttachEnvironment
    private let log: (String) -> Void
    private let nextTurn: (@escaping () -> Void) -> Void
    private let after: (TimeInterval, @escaping () -> Void) -> ChatTimerHandle?
    private var closed = false
    private var tickets: [Ticket] = []
    /// The drops whose copy has not ended, in drop order: the head runs and the rest wait, so the copies run one at a time under one byte budget
    /// (Orca native-file-drop-relay.ts:75-80).
    private var copyQueue: [Ticket] = []
    /// References waiting for a composition to end.
    private var pending: [String] = []
    private var flushScheduled = false
    private let copier: DragTempCopier?
    private var imagesInFlight = 0

    public init(gen: Int, body: ChatWebBody, environment: ChatAttachEnvironment, nextTurn: @escaping (@escaping () -> Void) -> Void,
                after: @escaping (TimeInterval, @escaping () -> Void) -> ChatTimerHandle? = { _, _ in nil }, log: @escaping (String) -> Void) {
        self.gen = gen; self.body = body; env = environment; self.nextTurn = nextTurn; self.after = after; self.log = log
        copier = environment.state.map { DragTempCopier(state: $0, temporaryDirectory: environment.temporaryDirectory, fileCap: environment.fileCap, totalCap: environment.totalCap) }
    }

    /// How many references wait for a composition to end (for the tests).
    public var queuedCount: Int { pending.count }
    /// Whether the input takes an attachment now (Orca `claim.disabled`).
    public var isLocked: Bool { body?.composer.isLocked ?? true }

    // MARK: drops, picks

    /// The paths of a drop, a pick or Clawd's own body: limits, copies, then the references (B3-B8). `target` is `panel` or `pet`.
    public func dropped(paths: [String], carriedPromise: Bool, target: String) {
        guard !closed, let body else { return }
        func refuse(_ why: String, _ text: String?) {
            if let text { body.setStatus(text) }
            log("CHAT drop gen=\(gen) target=\(target) paths=\(paths.count) copied=0 queued=\(pending.count) refused=\(why)")
        }
        if isLocked { refuse("locked", nil); return }
        if paths.isEmpty {
            if carriedPromise { refuse("unresolved", ChatDropText.unresolved) } else { refuse("empty", nil) }
            return
        }
        if paths.count > ChatDropText.maxPaths { refuse("too-many", ChatDropText.tooMany); return }
        if paths.reduce(0, { $0 + $1.utf8.count }) > ChatDropText.maxPathBytes { refuse("too-large", ChatDropText.tooLarge); return }
        let ticket = Ticket(paths: paths, target: target, promise: carriedPromise)
        tickets.append(ticket)
        if paths.contains(where: DragTempCopier.mayNeed) {
            if copyQueue.count >= DragTempCopier.maxPending || copier == nil {
                let reason: DragTempFailure = copier == nil ? .storageUnavailable : .busy
                ticket.copies = paths.map { DragTempCopier.mayNeed($0) ? .failed(path: $0, reason: reason) : .pass($0) }
            } else {
                copyQueue.append(ticket)
                startNextCopy()
            }
        } else {
            ticket.copies = paths.map { .pass($0) }
        }
        drain()
    }

    /// Starts the copy at the head of the queue unless one is running. Its deadline is a main-queue timer, so a copy that never returns (a source
    /// that went from a file to something that blocks) fails its drop with `timed-out` and the next copy goes (Orca native-file-drop-relay.ts:196-228).
    private func startNextCopy() {
        guard !closed, let copier, let ticket = copyQueue.first, !ticket.running else { return }
        ticket.running = true
        let deadline = env.uptime() + DragTempCopier.dropTimeout
        let uptime = env.uptime
        var results: [DragTempResult] = []
        let paths = ticket.paths
        ticket.timer = after(DragTempCopier.dropTimeout) { [weak self, weak ticket] in
            guard let self, let ticket else { return }
            self.copyTimedOut(ticket)
        }
        env.background({ [weak ticket] in
            results = copier.materialize(paths, isCancelled: { ticket?.cancelled ?? true }, now: uptime, deadline: deadline)
        }, { [weak self] in
            guard let self else { copier.discard(results); return }
            // A copy whose deadline ran out was failed and left the queue already; whatever it made late is removed.
            if ticket.timedOut { copier.discard(results); return }
            ticket.timer?.cancel(); ticket.timer = nil
            self.copyQueue.removeAll { $0 === ticket }
            if ticket.cancelled || self.closed { copier.discard(results); self.tickets.removeAll { $0 === ticket }; return }
            ticket.copies = results
            self.drain()
            self.startNextCopy()
        })
    }

    private func copyTimedOut(_ ticket: Ticket) {
        guard !closed, ticket.running, !ticket.timedOut, ticket.copies == nil else { return }
        ticket.timedOut = true
        ticket.cancelled = true
        ticket.timer = nil
        ticket.copies = ticket.paths.map { DragTempCopier.mayNeed($0) ? .failed(path: $0, reason: .timedOut) : .pass($0) }
        copyQueue.removeAll { $0 === ticket }
        drain()
        startNextCopy()
    }

    /// Inserts the finished drops from the head of the queue, in the order they were made.
    private func drain() {
        while let head = tickets.first, let copies = head.copies {
            tickets.removeFirst()
            apply(head, copies)
        }
    }

    private func apply(_ ticket: Ticket, _ copies: [DragTempResult]) {
        guard let body else { return }
        var inserted: [String] = []
        var failures: [DragTempFailure] = []
        var copied = 0
        for result in copies {
            switch result {
            case .pass(let path): inserted.append(path)
            case .copied(_, let to): inserted.append(to); copied += 1
            case .failed(_, let reason): failures.append(reason)
            }
        }
        var queued = 0
        var refused = failures.isEmpty ? "none" : "copy-failed"
        // Images become chips by the basename's extension; every other path keeps round B's `@path` insertion (Q14).
        let images = inserted.filter(ChatChipImages.isImagePath)
        inserted = inserted.filter { !ChatChipImages.isImagePath($0) }
        if !images.isEmpty { body.composer.attachImages(paths: images) }
        if !inserted.isEmpty {
            switch insert(inserted.map(ChatFileReference.format)) {
            case .inserted: break
            case .queued: queued = inserted.count
            case .refusedWaiting: refused = "waiting"
            case .refusedOverCap: refused = "cap"
            }
        }
        if !failures.isEmpty {
            let same = failures.allSatisfy { $0 == failures[0] }
            body.setStatus(ChatDropText.copyFailed(count: failures.count, reason: (same ? failures[0] : .copyFailed).words))
        }
        log("CHAT drop gen=\(gen) target=\(ticket.target) paths=\(ticket.paths.count) copied=\(copied) queued=\(queued) refused=\(refused)")
    }

    // MARK: insertion (B5, B6)

    private enum Outcome { case inserted, queued, refusedWaiting, refusedOverCap }

    /// The references at the start of the input's selection (never replacing it), or held while an input method composes.
    private func insert(_ references: [String]) -> Outcome {
        guard let body else { return .refusedOverCap }
        let input = body.inputView
        if input.hasMarkedText() {
            if pending.count + references.count > ChatDropText.maxPaths {
                body.setStatus(ChatDropText.waiting)
                return .refusedWaiting
            }
            pending += references
            return .queued
        }
        return insertNow(references) ? .inserted : .refusedOverCap
    }

    private func insertNow(_ references: [String]) -> Bool {
        guard let body else { return false }
        let input = body.inputView
        let text = references.joined(separator: " ") + " "
        let ns = input.string as NSString
        var place = min(max(0, input.selectedRange().location), ns.length)
        // Never inside a composed character or a surrogate pair.
        if place > 0, place < ns.length { place = ns.rangeOfComposedCharacterSequence(at: place).location }
        let before = input.string
        // The insertion is its own undo step: one Undo takes the reference away and leaves the typing before it.
        input.breakUndoCoalescing()
        input.insertText(text, replacementRange: NSRange(location: place, length: 0))
        input.breakUndoCoalescing()
        guard input.string != before else { return false }
        body.setStatus("")
        return true
    }

    /// The input method may have finished composing: the queue is applied on the next main-queue turn (use-native-chat-resolved-path-attachments.ts:154-176).
    public func compositionMayHaveEnded() {
        guard !closed, !pending.isEmpty, !flushScheduled, let body, !body.inputView.hasMarkedText() else { return }
        flushScheduled = true
        nextTurn { [weak self] in
            guard let self else { return }
            self.flushScheduled = false
            guard !self.closed, !self.pending.isEmpty, let body = self.body, !body.inputView.hasMarkedText() else { return }
            let waiting = self.pending
            self.pending = []
            _ = self.insertNow(waiting)
        }
    }

    /// The input was locked: what waits is dropped (a locked input takes nothing).
    public func lockChanged() { if isLocked { pending = [] } }

    // MARK: paste (P4, Q15)

    /// Cmd+V and the menu's Paste. A pasteboard with an image reads text and image together: the text goes in first (unless it only labels the
    /// copied files), then the image becomes a chip. With text, the image is taken only when an image type is the pasteboard's first type. True when it
    /// took the paste; false leaves it to the text field.
    public func pasteImageIfAny() -> Bool {
        guard !closed, let body else { return false }
        let contents = env.pasteContents()
        guard let data = contents.image, !contents.hasText || contents.imageFirst else { return false }
        // The input refuses text while an image send reads its files: the paste waits for it as any edit does.
        guard !body.composer.isLocked else { return true }
        func end(_ result: String, bytes: Int, status: String?) {
            if let status { body.setStatus(status) }
            log("CHAT paste-image gen=\(gen) bytes=\(bytes) result=\(result)")
        }
        // The text goes in first, whatever becomes of the image (Q15).
        if contents.hasText, let text = contents.textToInsert() {
            let input = body.inputView
            input.insertText(text, replacementRange: input.selectedRange())
        }
        guard let size = ClipboardImage.pixelSize(of: data) else { end("failed", bytes: 0, status: ClipboardImage.failed); return true }
        guard ClipboardImage.pixelsAcceptable(width: size.width, height: size.height) else { end("too-large", bytes: 0, status: ClipboardImage.tooLarge); return true }
        guard let state = env.state else { end("failed", bytes: 0, status: ClipboardImage.failed); return true }
        let encode = env.encodePNG, ms = env.wallMilliseconds(), id = env.uuid(), afterClose = storedAfterClose, background = env.background
        var outcome: (result: String, bytes: Int, path: String?) = ("failed", 0, nil)
        // The encode starts when the thumbnail is made, not beside it: one decode of the pasted bytes at a time (Q14, deferred Low S5 L4).
        _ = body.composer.beginPendingImage(data: data) { [weak self] chip in
            background({
                guard let png = encode(data) else { return }
                if png.count > ClipboardImage.maxBytes { outcome = ("too-large", png.count, nil); return }
                do { outcome = ("ok", png.count, try ClipboardImage.store(png, in: state, milliseconds: ms, id: id)) } catch { outcome = ("failed", png.count, nil) }
            }, { [weak self] in
                // A closed opening has no strip to show the chip in: a stored paste joins the saved draft through the controller.
                let stored = outcome.result == "ok" ? outcome.path : nil
                guard let self else { if let stored { afterClose?(stored) }; return }
                guard !self.closed, let body = self.body else {
                    self.log("CHAT paste-image gen=\(self.gen) bytes=\(outcome.bytes) result=\(outcome.result)")
                    if let stored { afterClose?(stored) }
                    return
                }
                body.composer.settlePendingImage(chip, path: outcome.result == "ok" ? outcome.path : nil)
                switch outcome.result {
                case "ok": end("ok", bytes: outcome.bytes, status: nil)
                case "too-large": end("too-large", bytes: outcome.bytes, status: ClipboardImage.tooLarge)
                default: end("failed", bytes: outcome.bytes, status: ClipboardImage.failed)
                }
            })
        }
        return true
    }

    // MARK: storage

    /// The sweeps of the drop copies and the pasted images, off the main thread (S5): at agent start and at each open.
    public static func sweepStorage(_ environment: ChatAttachEnvironment) {
        guard let state = environment.state else { return }
        let copier = DragTempCopier(state: state, temporaryDirectory: environment.temporaryDirectory)
        let now = environment.wall()
        environment.background({ copier.sweep(now: now); ClipboardImage.sweep(in: state, now: now) }, {})
    }

    // MARK: close

    /// The opening ended: running copies stop and their partial directories go, and nothing waits for a composition any more.
    public func cancel() {
        closed = true
        pending = []
        for ticket in tickets { ticket.cancelled = true; ticket.timer?.cancel(); ticket.timer = nil }
        copyQueue = []
        let finished = tickets.compactMap { $0.copies }
        tickets = []
        for results in finished { copier?.discard(results) }
    }
}
