import Testing
import Foundation
import Darwin
import ClawdCore
import ClawdDesktop

// Orca parity round D, deferred Lows (s4 L4, s5 L4, s7b NEW-1..3). Fake screens and a temporary state root only: nothing reads or writes the real
// chat-panel.json, no window is shown or made key, and no application is activated.

@MainActor
private final class SendRig {
    let state: OwnState
    let web: WebKindRig
    init() throws {
        state = try artifactStore()
        var attach = ChatAttachEnvironment()
        attach.state = state
        web = WebKindRig(isInstalled: { true }, attach: attach, composerTimers: ManualChatTimers())
    }
    var session: FakeChatSession { web.rig.session }
    var body: ChatWebBody { web.body! }
    var controller: ChatController { web.controller }
    func open() throws { web.rig.open(at: 1); try #require(controller.isOpen, "\(web.rig.logs)") }
    func enter(_ text: String) { body.inputText = text; web.pressEnter() }
    /// The private folder becomes one the store may not write into (0755), the way a refused folder looks.
    func breakStore() throws {
        let folder = state.root.appendingPathComponent("chat-private")
        try? FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
    }
    func fixStore() { chmod(state.root.appendingPathComponent("chat-private").path, 0o700) }
}

@Suite("Chat orca parity D, deferred Lows: a send needs a saved in-flight entry", .serialized)
@MainActor
struct ChatOrcaParityDLowsSendSuite {
    private static let words = "Not sent: Clawd could not save the message"

    @Test func ChatOrcaDLows_anEnterWhileTheStoreCannotSaveSendsNothingKeepsTheDraftAndSaysSoThenTheNextEnterSendsOnce() throws {
        let r = try SendRig()
        try r.open()
        try r.breakStore()
        r.enter("hello")
        #expect(r.session.sent.isEmpty && r.session.requests.isEmpty, "session.send is never called: \(r.session.sent)")
        #expect(r.body.inputText == "hello", "the draft stays in the composer: \(r.body.inputText)")
        #expect(r.body.statusText == Self.words, "\(r.body.statusText)")
        #expect(r.controller.composerStore?.saveFailed == true)
        // The store recovers: one failure does not block sends for good.
        r.fixStore()
        r.web.pressEnter()
        #expect(r.session.sent == ["hello"] && r.controller.composerStore?.saveFailed == false, "sent once: \(r.session.sent)")
    }

    @Test func ChatOrcaDLows_aDrainWhileTheStoreCannotSavePausesTheQueueKeepsTheCardAndResumeSendsItOnce() throws {
        let r = try SendRig()
        try r.open()
        r.enter("first")
        #expect(r.session.sent == ["first"] && r.session.turn == .running)
        r.enter("card")
        #expect(r.controller.queue.cards.map(\.text) == ["card"])
        try r.breakStore()
        r.session.finish(.success(seconds: 1))
        #expect(r.session.sent == ["first"], "the card is not sent: \(r.session.sent)")
        #expect(r.controller.queue.cards.map(\.text) == ["card"] && r.controller.queue.pause == .other, "\(r.controller.queue.pause)")
        r.fixStore()
        r.body.queueList.pauseRow?.resumeButton.performClick(nil)
        #expect(r.session.sent == ["first", "card"] && r.controller.queue.cards.isEmpty, "Resume sends it once: \(r.session.sent)")
    }
}
