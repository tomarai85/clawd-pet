import Testing
import Foundation
import AppKit
import ClawdCore
import ClawdDesktop

// `/resume` in the panel: the list inside the picker, the pick through the controller's one gate. The roots are temporary folders, the lister is a
// seam the test answers (at once, or by hand), no window is shown or made key, and no claude runs.

@MainActor
private final class ResumeRig {
    let base: String
    let folder: String
    let roots: ChatResume.Roots
    let web: ControllerRig
    var calls = 0
    /// Answers each listing at once from the fixture's folders; false holds them in `held`.
    var answerAtOnce = true
    var held: [(folder: String, done: (ChatResume.Listing) -> Void)] = []
    /// Every listing the lister made, in order: what a cancelled one read is in it.
    var made: [ChatResume.Listing] = []

    var rig: ControllerRig { web }
    var controller: ChatController { web.controller }
    var session: FakeChatSession { web.session }
    var body: ChatWebBody { web.controller.livePanel!.terminal!.webBody! }
    var input: ChatInputTextView { body.inputView }

    init() throws {
        base = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()),
                                           create: true).path
        folder = base + "/chat-folder"
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: base + "/claude/projects", withIntermediateDirectories: true)
        try FileManager.default.createDirectory(atPath: base + "/claude/sessions", withIntermediateDirectories: true)
        roots = ChatResume.Roots(projects: base + "/claude/projects", sessions: base + "/claude/sessions")
        let holder = Holder()
        var attach = ChatAttachEnvironment()
        attach.state = try artifactStore()
        let environment = ChatResumeEnvironment(roots: roots, list: { folder, excluding, cancelled, done in
            holder.owner?.calls += 1
            let make = { () -> ChatResume.Listing in
                let listing = ChatResume.list(folder: folder, roots: holder.owner?.roots ?? .none, excluding: excluding, cancelled: cancelled)
                holder.owner?.made.append(listing)
                return listing
            }
            if holder.owner?.answerAtOnce == true { done(make()) } else { holder.owner?.held.append((folder, { _ in done(make()) })) }
        })
        web = ControllerRig(web: ChatWebEnvironment(pageDirectory: chatPageDirectory, openLink: { _ in }, pasteboard: FakePasteboard(), attach: attach,
                                                    composerTimers: ManualChatTimers(), resume: environment))
        holder.owner = self
        web.chatSettings.folder = folder
    }
    private final class Holder { weak var owner: ResumeRig? }
    deinit { try? FileManager.default.removeItem(atPath: base) }

    func open() throws {
        web.open()
        try #require(controller.isOpen, "the chat opened: \(web.logs)")
    }
    func type(_ text: String) { web.type(text, into: body) }
    func enter() { input.modifiers = { [] }; input.doCommand(by: #selector(NSResponder.insertNewline(_:))) }
    func esc() { input.doCommand(by: #selector(NSResponder.cancelOperation(_:))) }
    func rows() -> [String] { body.picker.rows.map(\.item.name) }

    var directory: String {
        let path = roots.projects! + "/" + ChatResume.slug(ChatResume.resolvedFolder(folder))
        try? FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true)
        return path
    }
    /// A conversation file the listing keeps: a user line recorded in this folder.
    @discardableResult
    func conversation(_ prompt: String, age: TimeInterval = 0) throws -> String {
        let id = UUID().uuidString.lowercased()
        let line = "{\"type\":\"user\",\"message\":{\"role\":\"user\",\"content\":\"\(prompt)\"},\"cwd\":\"\(ChatResume.resolvedFolder(folder))\"}\n"
        let path = directory + "/" + id + ".jsonl"
        try line.write(toFile: path, atomically: true, encoding: .utf8)
        let seconds = Int(Date().timeIntervalSince1970 - age)
        var times = [timeval(tv_sec: seconds, tv_usec: 0), timeval(tv_sec: seconds, tv_usec: 0)]
        utimes(path, &times)
        return id
    }
}

private extension ControllerRig {
    func type(_ text: String, into body: ChatWebBody) {
        body.inputView.insertText(text, replacementRange: NSRange(location: NSNotFound, length: 0))
    }
}

@Suite("Chat resume, the panel", .serialized)
@MainActor
struct ChatPanelResumeSuite {
    @Test func ChatPanel_enterOnResumeTypedWholeOpensTheListAndSendsNothing() throws {
        let r = try ResumeRig()
        let newer = try r.conversation("newer talk", age: 10), older = try r.conversation("older talk", age: 500)
        try r.open()
        r.type("/resume")
        #expect(r.calls == 0 && r.body.autocompleteState != .none, "the command row alone loads nothing")
        r.enter()
        #expect(r.session.sent.isEmpty, "nothing is sent to Claude: \(r.session.sent)")
        #expect(r.input.string == "/resume " && r.input.selectedRange() == NSRange(location: 8, length: 0))
        #expect(r.calls == 1 && r.body.isPickerOpen && r.body.picker.headings == ["RESUME SESSION"], "\(r.calls) \(r.body.picker.headings)")
        #expect(r.rows() == ["newer talk", "older talk"], "\(r.rows())")
        #expect(r.body.picker.rows.first?.item.conversationId == newer && r.body.picker.rows.last?.item.conversationId == older)
        #expect(r.rig.lines("CHAT command name=resume outcome=opened").count == 1 && r.rig.lines("CHAT resume list rows=2").count == 1, "\(r.rig.logs)")
        // The CLI's alias.
        r.body.inputText = ""
        r.type("/continue")
        r.enter()
        #expect(r.input.string == "/resume " && r.session.sent.isEmpty)
    }

    @Test func ChatPanel_pickingARowResumesSpendsTheDraftAndPausesTheQueue() throws {
        let r = try ResumeRig()
        let newer = try r.conversation("newer talk", age: 10)
        let older = try r.conversation("older talk", age: 500)
        try r.open()
        r.type("/resume ol")
        try #require(r.rows() == ["older talk"], "the text filters: \(r.rows())")
        r.enter()
        #expect(r.session.resumes.map(\.id) == [older] && r.session.resumes.first?.title == "older talk", "\(r.session.resumes)")
        #expect(r.body.inputText.isEmpty && !r.body.isPickerOpen, "the draft is spent")
        #expect(r.controller.history.entries.last == "/resume ol")
        #expect(r.controller.queue.pause == .resumed, "\(r.controller.queue.pause)")
        #expect(r.session.sent.isEmpty && r.rig.lines("CHAT resume pick outcome=ok").count == 1)
        // A press on a row picks the same way.
        r.type("/resume ")
        let row = try #require(r.body.picker.rows.first)
        #expect(row.item.conversationId == newer)
        row.mouseDown(with: NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                               eventNumber: 0, clickCount: 1, pressure: 1)!)
        #expect(r.session.resumes.map(\.id) == [older, newer])
        #expect(r.rig.lines("CHAT resume pick outcome=ok").count == 2)
    }

    @Test func ChatPanel_aRefusedPickKeepsTheDraftAndTheList() throws {
        let r = try ResumeRig()
        try r.conversation("a talk")
        try r.open()
        r.type("/resume ")
        try #require(r.rows() == ["a talk"])
        r.session.turn = .running
        r.enter()
        #expect(r.session.resumes.isEmpty && r.input.string == "/resume " && r.body.isPickerOpen, "a turn runs")
        #expect(r.body.statusText == ChatHostCommand.turnRefusal)
        r.session.turn = .none
        r.session.hasUnsettledSend = true
        r.enter()
        #expect(r.session.resumes.isEmpty && r.input.string == "/resume " && r.body.statusText == ChatHostCommand.unsettledRefusal, "an unsettled send")
        r.session.hasUnsettledSend = false
        r.session.resumeAccepts = false
        r.enter()
        #expect(r.input.string == "/resume " && r.body.isPickerOpen, "the session refused it too")
        r.session.resumeAccepts = true
        // An attachment in the composer holds it (the chips gate is the pick's own: the typed path decides it earlier).
        let calls = r.session.resumes.count
        r.body.composer.restoreChips([ChatComposerChip(unavailable: "a.png")])
        try #require(!r.body.composer.chips.persisted.isEmpty)
        r.enter()
        #expect(r.session.resumes.count == calls && r.input.string == "/resume " && r.body.isPickerOpen && r.body.statusText == ChatHostCommand.attachmentsRefusal,
                "chips: \(r.body.statusText)")
        try #require(r.body.composer.strip.unavailableViews.first).removeButton.performClick(nil)
        try #require(r.body.composer.chips.persisted.isEmpty)
        // A send in doubt holds it: the card's Send would write into the resumed conversation, since the spawn forgets what the old one got.
        r.body.inputText = "first"
        r.enter()
        if let first = r.session.requests.last { r.session.deliver(first) }
        let lost = ChatSendRequest(text: "maybe", origin: .draft, steer: true, chips: [])
        r.session.settle(lost) { .doubt($0, .childEnded) }
        try #require(r.controller.queue.doubtCards.map(\.id) == [lost.uuid], "the doubt card is there: \(r.controller.queue.doubtCards)")
        r.session.turn = .none
        r.body.inputText = ""
        r.type("/resume ")
        try #require(r.rows() == ["a talk"] && r.body.isPickerOpen)
        r.enter()
        #expect(r.session.resumes.count == calls && r.input.string == "/resume " && r.body.isPickerOpen && r.body.statusText == ChatHostCommand.unsettledRefusal,
                "doubt card: \(r.body.statusText)")
        try #require(r.body.queueList.rows.count == 1)
        r.body.queueList.rows[0].deleteButton.performClick(nil)
        try #require(r.controller.queue.doubtCards.isEmpty)
        r.enter()
        #expect(r.session.resumes.count == calls + 1 && r.body.inputText.isEmpty, "allowed once nothing holds it")
    }

    @Test func ChatPanel_aHeldOrUncheckableRowIsRefusedAtThePick() throws {
        let r = try ResumeRig()
        let id = try r.conversation("a talk")
        try r.open()
        r.type("/resume ")
        try #require(r.rows() == ["a talk"])
        // This process's own pid is a live holder; the record is dated ahead of the process start so that it counts.
        let record = r.roots.sessions! + "/\(getpid()).json"
        let ahead = Int(Date().timeIntervalSince1970) + 5
        var times = [timeval(tv_sec: ahead, tv_usec: 0), timeval(tv_sec: ahead, tv_usec: 0)]
        try "{\"pid\":\(getpid()),\"sessionId\":\"\(id)\",\"kind\":\"interactive\"}".write(toFile: record, atomically: true, encoding: .utf8)
        utimes(record, &times)
        r.enter()
        #expect(r.session.resumes.isEmpty && r.input.string == "/resume " && r.body.isPickerOpen && r.body.statusText == ChatResume.heldText, "held: \(r.body.statusText)")
        #expect(r.rig.lines("CHAT resume pick outcome=held").count == 1)
        // A live record that does not say which conversation it holds cannot be checked.
        try "{\"pid\":\(getpid())}".write(toFile: record, atomically: true, encoding: .utf8)
        utimes(record, &times)
        r.enter()
        #expect(r.session.resumes.isEmpty && r.input.string == "/resume " && r.body.statusText == ChatResume.unknownHolderText, "unknown: \(r.body.statusText)")
        #expect(r.rig.lines("CHAT resume pick outcome=unknown").count == 1)
        // Without the record the same pick goes through.
        try FileManager.default.removeItem(atPath: record)
        r.enter()
        #expect(r.session.resumes.map(\.id) == [id] && r.body.inputText.isEmpty)
    }

    @Test func ChatPanel_aSendDuringTheResumesStopKeepsTheDraft() throws {
        let r = try ResumeRig()
        let id = try r.conversation("a talk")
        try r.open()
        r.session.resumeStops = true
        r.type("/resume ")
        try #require(r.rows() == ["a talk"])
        r.enter()
        try #require(r.session.resumes.map(\.id) == [id] && r.controller.queue.pause == .resumed && r.session.turn == .stopping)
        r.type("a short message")
        r.enter()
        #expect(r.session.sent.isEmpty && r.body.inputText == "a short message", "the draft stays: \(r.body.inputText)")
        #expect(r.body.statusText == "Wait for the current turn to stop.", "\(r.body.statusText)")
        #expect(r.controller.queue.cards.isEmpty, "it did not become a held card: \(r.controller.queue.cards)")
        // The stop ends: the same message goes straight through.
        r.session.turn = .none
        r.enter()
        #expect(r.session.sent == ["a short message"] && r.controller.queue.cards.isEmpty)
    }

    @Test func ChatPanel_aRowFromAnotherFolderIsRefused() throws {
        let r = try ResumeRig()
        try r.conversation("a talk")
        try r.open()
        r.type("/resume ")
        try #require(r.rows() == ["a talk"])
        let elsewhere = r.base + "/elsewhere"
        try FileManager.default.createDirectory(atPath: elsewhere, withIntermediateDirectories: true)
        r.rig.chatSettings.folder = elsewhere
        r.enter()
        #expect(r.session.resumes.isEmpty && r.body.statusText == ChatResume.otherFolderText, "\(r.body.statusText)")
        #expect(r.input.string == "/resume " && r.body.isPickerOpen)
        #expect(r.rig.lines("CHAT resume pick outcome=folder").count == 1)
    }

    @Test func ChatPanel_aGoneRowSaysNotFound() throws {
        let r = try ResumeRig()
        let id = try r.conversation("vanishing talk")
        try r.open()
        r.type("/resume ")
        try #require(r.rows() == ["vanishing talk"])
        try FileManager.default.removeItem(atPath: r.directory + "/" + id + ".jsonl")
        r.enter()
        #expect(r.session.resumes.isEmpty && r.body.statusText == "Session \"vanishing talk\" was not found.", "\(r.body.statusText)")
        #expect(r.input.string == "/resume ")
    }

    @Test func ChatPanel_slashResumeWithAnUnknownArgumentSaysNotFound() throws {
        let r = try ResumeRig()
        let id = try r.conversation("a talk")
        let other = try r.conversation("hidden", age: 100)
        try FileManager.default.removeItem(atPath: r.directory + "/" + other + ".jsonl")
        try r.open()
        r.type("/resume zzz")
        #expect(r.body.picker.statusText == ChatResume.noMatchText("zzz"), "\(String(describing: r.body.picker.statusText))")
        r.enter()
        #expect(r.session.resumes.isEmpty && r.session.sent.isEmpty)
        #expect(r.body.statusText == "Session zzz was not found." && r.input.string == "/resume zzz", "\(r.body.statusText)")
        // An id of a file in the folder resumes though no row matched it by text (the list is still loading, so no row is there to match).
        r.answerAtOnce = false
        r.body.inputText = ""
        r.type("/resume " + id.uppercased())
        r.enter()
        #expect(r.session.resumes.map(\.id) == [id], "the typed upper-case id is handed on lower-case: \(r.session.resumes)")
    }

    @Test func ChatPanel_theListLoadsOncePerEntryAndDropsLateResults() throws {
        let r = try ResumeRig()
        try r.conversation("a talk")
        try r.open()
        r.answerAtOnce = false
        r.type("/resume ")
        #expect(r.calls == 1 && r.body.picker.statusText == ChatResume.loadingText, "\(String(describing: r.body.picker.statusText))")
        r.type("a")
        r.type("b")
        #expect(r.calls == 1, "typing filters in memory and loads nothing")
        r.esc()
        #expect(!r.body.isPickerOpen)
        r.body.inputText = ""
        r.type("/resume ")
        #expect(r.calls == 2 && r.held.count == 2)
        r.held[0].done(ChatResume.Listing())
        #expect(r.body.picker.statusText == ChatResume.loadingText && r.rows().isEmpty, "the first load was dropped: it was cancelled with its mode")
        r.held[1].done(ChatResume.Listing())
        #expect(r.rows() == ["a talk"] && r.rig.lines("CHAT resume list rows=1").count == 1, "\(r.rows())")
        // A load answered after the chat's folder changed is dropped.
        r.body.inputText = ""
        r.type("/resume ")
        #expect(r.calls == 3)
        r.rig.chatSettings.folder = r.base
        r.held[2].done(ChatResume.Listing())
        #expect(r.body.picker.statusText == ChatResume.loadingText)
    }

    @Test func ChatPanel_noResumeWorkWithTheChatClosed() throws {
        let r = try ResumeRig()
        try r.conversation("a talk")
        r.answerAtOnce = false
        #expect(r.calls == 0)
        try r.open()
        r.type("hello")
        #expect(r.calls == 0, "an open chat that is not in the mode loads nothing")
        r.body.inputText = ""
        r.type("/resume ")
        #expect(r.calls == 1)
        let closing = r.body
        r.controller.close(.button)
        #expect(!r.controller.isOpen)
        r.held[0].done(ChatResume.Listing())
        #expect(r.rig.lines("CHAT resume list").isEmpty, "a result for a closed chat is dropped: \(r.rig.logs)")
        #expect(r.made.last?.read == 0, "the close cancelled the listing before it read a file: \(String(describing: r.made.last))")
        #expect(r.calls == 1)
        // The closed chat's body is still a body: a command typed into it asks for a list, and the controller, with no panel open, loads nothing.
        closing.inputText = ""
        closing.inputView.insertText("/resume x", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(r.calls == 1, "a closed chat requests no list")
        #expect(r.held.count == 1 && r.rig.lines("CHAT resume list").isEmpty)
    }

    @Test func ChatPanel_resumeTakesNoKeyAndOpensNoWindow() throws {
        let r = try ResumeRig()
        try r.conversation("a talk")
        try r.open()
        let keys = r.rig.keys.count, presented = r.rig.presented, windows = NSApp.windows.count
        let keyWindow = NSApp.keyWindow, activations = r.rig.focus.activationRequests
        r.type("/resume")
        r.enter()
        try #require(r.rows() == ["a talk"])
        r.enter()
        try #require(r.session.resumes.count == 1)
        r.type("next message")
        r.enter()
        #expect(r.session.sent == ["next message"])
        #expect(r.rig.keys.count == keys && r.rig.presented == presented && NSApp.windows.count == windows && NSApp.keyWindow === keyWindow)
        #expect(r.rig.focus.activationRequests == activations, "no activation is asked for")
    }
}
