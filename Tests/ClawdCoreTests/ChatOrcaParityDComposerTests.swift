import Testing
import Foundation
import AppKit
import ClawdCore
import ClawdDesktop

// Orca parity round D, sprint 2: the composer's history (Q7) and saved draft (Q8) as the controller drives them. No window is shown or made key; the
// timers are manual and the state root is a temporary directory.

@MainActor
private final class ComposerRig {
    let state: OwnState
    let timers = ManualChatTimers()
    let web: WebKindRig

    init(state: OwnState? = nil) throws {
        self.state = try state ?? artifactStore()
        var attach = ChatAttachEnvironment()
        attach.state = self.state
        web = WebKindRig(attach: attach, composerTimers: timers)
    }

    var rig: ControllerRig { web.rig }
    var controller: ChatController { web.controller }
    var body: ChatWebBody { web.body! }
    var input: ChatInputTextView { body.inputView }

    func open(at time: TimeInterval = 1) throws {
        rig.open(at: time)
        try #require(controller.isOpen, "the chat opened: \(rig.logs)")
    }
    func send(_ text: String) {
        body.inputText = text
        web.pressEnter()
        rig.session.finish(.success(seconds: 1))
    }
    func up() { input.doCommand(by: #selector(NSResponder.moveUp(_:))) }
    func down() { input.doCommand(by: #selector(NSResponder.moveDown(_:))) }
    func savedFile() throws -> ChatComposerFile {
        try JSONDecoder().decode(ChatComposerFile.self, from: ReadOnlyFile.data(try state.url(ChatComposerStore.fileName).path))
    }
    var fileExists: Bool { (try? state.url(ChatComposerStore.fileName).path).map { FileManager.default.fileExists(atPath: $0) } ?? false }
    var caretAtEnd: Bool { input.selectedRange() == NSRange(location: (input.string as NSString).length, length: 0) }
}

@Suite("Chat orca parity D, the composer's history and saved draft", .serialized)
@MainActor
struct ChatOrcaParityDComposerSuite {
    // MARK: Q7

    @Test func ChatOrcaD7_upRecallsTheSentTextsFromTheLastDownComesBackAndPastTheLastIsEmpty() throws {
        let r = try ComposerRig()
        try r.open()
        for text in ["a", "b", "c"] { r.send(text) }
        #expect(r.body.inputText.isEmpty)
        var seen: [String] = []
        for _ in 0..<4 { r.up(); seen.append(r.body.inputText); #expect(r.caretAtEnd) }
        #expect(seen == ["c", "b", "a", "a"], "\(seen)")
        seen = []
        for _ in 0..<3 { r.down(); seen.append(r.body.inputText) }
        #expect(seen == ["b", "c", ""], "\(seen)")
        #expect(r.controller.history.index == nil)
        r.down()
        #expect(r.body.inputText.isEmpty, "Down when not recalling does nothing")
    }

    @Test func ChatOrcaD7_upOnANonEmptyDraftThatIsNotARecallMovesTheCaretAndRecallsNothing() throws {
        let r = try ComposerRig()
        try r.open()
        r.send("old")
        r.body.inputText = "draft\nsecond line"
        r.up()
        #expect(r.body.inputText == "draft\nsecond line" && r.controller.history.index == nil, "nothing recalled: \(r.body.inputText)")
    }

    @Test func ChatOrcaD7_aDuplicateSendIsPushedOnce() throws {
        let r = try ComposerRig()
        try r.open()
        r.send("same"); r.send("same")
        #expect(r.controller.history.entries == ["same"])
    }

    @Test func ChatOrcaD7_typingAfterARecallMakesTheNextUpStartFromTheEnd() throws {
        let r = try ComposerRig()
        try r.open()
        for text in ["a", "b", "c"] { r.send(text) }
        r.up(); r.up()
        #expect(r.body.inputText == "b" && r.controller.history.index == 1)
        r.web.type("!")
        #expect(r.controller.history.index == nil, "typing is an edit")
        r.body.inputText = ""
        r.up()
        #expect(r.body.inputText == "c", "the next Up starts from the end, not from b: \(r.body.inputText)")
    }

    @Test func ChatOrcaD7_aRecallIsNotAnEditButAPasteIs() throws {
        let r = try ComposerRig()
        try r.open()
        for text in ["a", "b"] { r.send(text) }
        r.up(); r.up()
        #expect(r.controller.history.index == 0, "two recalls, one index step each")
        r.input.setSelectedRange(NSRange(location: 1, length: 0))
        r.web.type("x")
        #expect(r.controller.history.index == nil)
    }

    @Test func ChatOrcaD7_markedTextBlocksTheRecall() throws {
        let r = try ComposerRig()
        try r.open()
        r.send("a"); r.send("b")
        r.input.setMarkedText("\u{304B}", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: 0, length: 0))
        #expect(r.input.hasMarkedText())
        // Marking is itself an edit, so the arrow's own taker is replaced by a counter: a composition must never reach it.
        var asked = 0
        r.input.onHistory = { _ in asked += 1; return true }
        r.up(); r.down()
        #expect(asked == 0, "the input method owns the arrows while composing")
        r.input.unmarkText()
        r.input.string = ""
        r.up()
        #expect(asked == 1, "without a composition the key reaches the history")
    }

    @Test func ChatOrcaD7_theHistorySurvivesACloseAndReopen() throws {
        let r = try ComposerRig()
        try r.open()
        r.send("kept")
        r.controller.close(.button)
        try r.open(at: 9)
        r.up()
        #expect(r.body.inputText == "kept", "\(r.body.inputText)")
    }

    // MARK: Q8

    @Test func ChatOrcaD8_theDraftIsWrittenAt250msAfterTheFirstChangeAndABurstIsOneWrite() throws {
        let r = try ComposerRig()
        try r.open()
        r.web.type("ab")                                        // 0 ms
        r.web.type("cd")                                        // 200 ms
        #expect(r.timers.live == [ChatComposerStore.debounce] && !r.fileExists, "nothing before the 250 ms: \(r.timers.live)")
        r.timers.fire(exactly: ChatComposerStore.debounce)
        #expect(try r.savedFile().draft == "abcd", "the file holds both at 250 ms")
    }

    @Test func ChatOrcaD8_aDraftTypedAt300msSurvivesAQuitAt400msInANewController() throws {
        let r = try ComposerRig()
        try r.open()
        r.web.type("typed at 300")
        #expect(!r.fileExists, "the 250 ms timer has not fired")
        r.controller.shutdown(timeout: 0)
        #expect(try r.savedFile().draft == "typed at 300", "the quit wrote it")
        let next = try ComposerRig(state: r.state)
        #expect(next.controller.draft == "typed at 300")
        try next.open()
        #expect(next.body.inputText == "typed at 300", "the restored draft is in the input")
    }

    @Test func ChatOrcaD8_aSendWritesTheClearedDraftAtOnceAndCloseWritesWhatIsInTheInput() throws {
        let r = try ComposerRig()
        try r.open()
        r.web.type("hello")
        r.timers.fire(exactly: ChatComposerStore.debounce)
        #expect(try r.savedFile().draft == "hello")
        r.web.pressEnter()
        #expect(try r.savedFile().draft == nil, "the send cleared it on disk at once, with no timer fired")
        r.rig.session.finish(.success(seconds: 1))
        r.web.type("half")
        r.controller.close(.button)
        #expect(try r.savedFile().draft == "half", "a close writes at once")
        #expect(r.timers.live.isEmpty)
    }

    @Test func ChatOrcaD8_aSendThatCameBackUnsentIsSavedWithTheDraft() throws {
        let r = try ComposerRig()
        try r.open()
        r.web.type("will fail")
        r.web.pressEnter()
        r.rig.session.failSend("will fail")
        #expect(try r.savedFile().draft == "will fail", "the restored text is on disk")
    }

    @Test func ChatOrcaD8_aRefusedSaveShowsTheIconBetweenTheInputAndSendAndTheEmptyHeightDoesNotChange() throws {
        let r = try ComposerRig()
        try FileManager.default.createDirectory(atPath: try r.state.url("chat-private").path, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try r.open()
        let composer = r.body.composer
        composer.layoutComposer()
        let emptyHeight = composer.preferredHeight(), inputWidth = r.input.enclosingScrollView!.frame.width
        #expect(!composer.isDraftWarningShown && emptyHeight == 54)
        r.web.type("x")
        r.timers.fire(exactly: ChatComposerStore.debounce)
        #expect(composer.isDraftWarningShown, "storage refused the draft")
        r.body.inputText = ""
        composer.layoutComposer()
        let scroll = r.input.enclosingScrollView!, icon = composer.draftWarning
        #expect(composer.preferredHeight() == emptyHeight, "the empty composer's height is the same with the icon: \(composer.preferredHeight())")
        #expect(inputWidth - scroll.frame.width == 18, "the input is 18 pt narrower (0.75 text scale): \(inputWidth - scroll.frame.width)")
        #expect(scroll.frame.maxX + 3 == icon.frame.minX && icon.frame.maxX + 3 == composer.sendButton.frame.minX && icon.frame.width == 12 && icon.frame.height == 12,
                "icon \(icon.frame) between input \(scroll.frame) and send \(composer.sendButton.frame)")
        #expect(icon.toolTip == "This draft couldn't be saved yet. Clawd keeps trying.")
        chmod(try r.state.url("chat-private").path, 0o700)
        r.web.type("y")
        r.timers.fire(exactly: ChatComposerStore.debounce)
        #expect(!composer.isDraftWarningShown, "the first write that succeeds takes the icon away")
        #expect(try r.savedFile().draft == "y")
        composer.layoutComposer()
        #expect(r.input.enclosingScrollView!.frame.width == inputWidth && composer.preferredHeight() == emptyHeight)
    }

    @Test func ChatOrcaD8_theLogCarriesCountsAndNoDraftText() throws {
        let r = try ComposerRig()
        try r.open()
        r.web.type("PRIVATE-WORDS")
        r.timers.fire(exactly: ChatComposerStore.debounce)
        r.web.pressEnter()
        r.controller.close(.button)
        #expect(!r.rig.logs.joined(separator: "\n").contains("PRIVATE"), "\(r.rig.logs)")
    }

    @Test func ChatOrcaD8_anEnvironmentWithNoStateKeepsNoDraftOnDiskAndStillRecalls() throws {
        let web = WebKindRig()
        web.rig.open()
        web.type("a")
        web.pressEnter()
        #expect(web.controller.composerStore == nil && web.controller.history.entries == ["a"])
    }
}
