import Testing
import Foundation
import Darwin
import ClawdCore
import ClawdDesktop

// Orca parity round D, deferred Lows (s4 L4, s5 L4, s7b NEW-1..3). Fake screens and a temporary state root only: nothing reads or writes the real
// chat-panel.json, no window is shown or made key, and no application is activated.

/// What the loader and the encoder did, in order.
private final class PasteEvents { var lines: [String] = [] }

/// A chip loader that holds its pieces until the test steps it, and logs where each starts and ends.
private final class RecordingChipLoader {
    let events: PasteEvents
    private var held: [(work: () -> Void, done: () -> Void)] = []
    init(_ events: PasteEvents) { self.events = events }
    func run(_ work: @escaping () -> Void, _ done: @escaping () -> Void) { held.append((work, done)) }
    var waiting: Int { held.count }
    func step() {
        guard !held.isEmpty else { return }
        let piece = held.removeFirst()
        events.lines.append("thumb-start"); piece.work(); events.lines.append("thumb-end"); piece.done()
    }
}

@Suite("Chat orca parity D, deferred Lows: one decode of a paste at a time", .serialized)
@MainActor
struct ChatOrcaParityDLowsPasteSuite {
    @Test func ChatOrcaDLows_aPastesPngIsEncodedOnlyAfterItsThumbnailIsMadeAndTheTwoNeverOverlap() throws {
        let (store, root) = try makeState()
        defer { try? FileManager.default.removeItem(at: root) }
        let events = PasteEvents(), loader = RecordingChipLoader(events), background = ManualBackground()
        var env = ChatAttachEnvironment()
        env.state = store
        env.background = { background.run($0, $1) }
        env.chipLoader.run = { loader.run($0, $1) }
        env.encodePNG = { data in
            events.lines.append("encode-start"); defer { events.lines.append("encode-end") }
            return ClipboardImage.encodePNG(data)
        }
        env.pasteContents = { ChatPasteContents(hasText: false, image: pngData(), imageFirst: true) }
        let web = WebKindRig(attach: env)
        web.rig.open()
        background.runAll()
        let body = try #require(web.body)
        body.inputView.paste(nil)
        let chips = body.composer.chips
        #expect(chips.items.count == 1 && chips.items[0].kind == .pending, "the chip shows first: \(chips.items)")
        #expect(loader.waiting == 1 && background.pending.isEmpty, "only the thumbnail is out; the encode waits: \(loader.waiting) \(background.pending.count)")
        background.runAll()
        #expect(events.lines.isEmpty, "nothing decodes the paste before the thumbnail does: \(events.lines)")
        loader.step()
        #expect(background.pending.count == 1, "the encode is out once the thumbnail is made")
        background.runAll()
        #expect(events.lines == ["thumb-start", "thumb-end", "encode-start", "encode-end"], "\(events.lines)")
        if case .file = chips.items[0].kind {} else { Issue.record("the chip settled with the stored file: \(chips.items)") }
    }
}
