import Testing
import Foundation
import AppKit
import ClawdCore
import ClawdDesktop

// Orca parity round D, sprint 3, the panel side: the `/` picker and the mention hint inside the body (Q10), Esc's order (Q11), the commands Clawd
// claims as the controller's one send gate decides them (Q25), and the catalog's file (Q9). No window is shown or made key; the timers are manual
// and the state root is a temporary directory.

@MainActor
private final class PickerRig {
    let state: OwnState
    let web: WebKindRig

    init(state: OwnState? = nil) throws {
        self.state = try state ?? artifactStore()
        var attach = ChatAttachEnvironment()
        attach.state = self.state
        web = WebKindRig(attach: attach, composerTimers: ManualChatTimers())
    }

    var rig: ControllerRig { web.rig }
    var controller: ChatController { web.controller }
    var body: ChatWebBody { web.body! }
    var input: ChatInputTextView { body.inputView }
    var session: FakeChatSession { rig.session }

    func open() throws {
        rig.open()
        try #require(controller.isOpen, "the chat opened: \(rig.logs)")
    }
    func type(_ text: String) { web.type(text) }
    func enter() { web.pressEnter() }
    func key(_ selector: Selector) { input.doCommand(by: selector) }
    func up() { key(#selector(NSResponder.moveUp(_:))) }
    func down() { key(#selector(NSResponder.moveDown(_:))) }
    func tab() { key(#selector(NSResponder.insertTab(_:))) }
    func esc() { key(#selector(NSResponder.cancelOperation(_:))) }
    /// A draft sent and answered, so the next one is a fresh turn.
    func send(_ text: String) {
        body.inputText = text
        enter()
        session.finish(.success(seconds: 1))
    }
    var caretAtEnd: Bool { input.selectedRange() == NSRange(location: (input.string as NSString).length, length: 0) }
    func rows() -> [String] { body.picker.rows.map(\.item.name) }

    static func entry(_ name: String, _ kind: ChatCommandKind = .command, _ description: String? = nil, scope: String? = nil) -> ChatCommandEntry {
        ChatCommandEntry(name: name, kind: kind, description: description, scope: scope)
    }
    static let sample: [ChatCommandEntry] = [entry("help", .command, "Show help"), entry("compact"), entry("context"), entry("clear"), entry("review", .skill, "Review a change", scope: "Project"),
                                             entry("commit", .skill, scope: "Personal")]
    static func mouseDown() -> NSEvent {
        NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!
    }
}

@Suite("Chat orca parity D, the picker, the claimed commands and Esc", .serialized)
@MainActor
struct ChatOrcaParityDPickerSuite {
    // MARK: Q10

    @Test func ChatOrcaD10_aBareSlashShowsBothGroupsSlashCompRanksCompactFirstAndDownWrapsOnThreeItems() throws {
        let r = try PickerRig()
        try r.open()
        r.body.setCatalog(PickerRig.sample)
        r.type("/")
        #expect(r.body.isPickerOpen && r.body.picker.headings == ["COMMANDS", "SKILLS"], "\(r.body.picker.headings)")
        #expect(r.rows() == ["help", "compact", "context", "clear", "review", "commit"], "\(r.rows())")
        r.body.inputText = ""
        r.type("/COMP")
        #expect(r.rows() == ["compact"] && r.body.picker.headings == ["COMMANDS"], "\(r.rows())")
        r.body.setCatalog(Array(PickerRig.sample.prefix(3)))
        r.body.inputText = ""
        r.type("/")
        #expect(r.rows().count == 3 && r.body.pickerActiveIndex == 0 && r.body.picker.activeIndex == 0)
        var seen: [Int] = []
        for _ in 0..<3 { r.down(); seen.append(r.body.pickerActiveIndex) }
        #expect(seen == [1, 2, 0] && r.body.picker.activeIndex == 0, "Down x3 wraps on 3 items: \(seen)")
        r.up()
        try #require(r.body.picker.rows.count > 2, "r.body.picker.rows needs 3 elements: \(r.body.picker.rows.count)")
        #expect(r.body.pickerActiveIndex == 2 && r.body.picker.activeIndex == 2 && r.body.picker.rows[2].isActive && !r.body.picker.rows[0].isActive)
        #expect(r.input.string == "/", "the arrows move the picker, not the caret or the draft")
    }

    @Test func ChatOrcaD10_slashCoThenEnterCompletesAndSendsNothingAndASecondEnterSendsTheCommandThroughTheGate() throws {
        let r = try PickerRig()
        try r.open()
        r.body.setCatalog(PickerRig.sample)
        r.type("/co")
        r.enter()
        #expect(r.input.string == "/compact " && r.session.sent.isEmpty && r.caretAtEnd, "Enter on a prefix completes: \(r.input.string) \(r.session.sent)")
        #expect(!r.body.isPickerOpen, "the space ends the token")
        r.enter()
        #expect(r.session.sent == ["/compact"] && r.body.inputText.isEmpty, "the second Enter sends it through Q25: \(r.session.sent)")
    }

    @Test func ChatOrcaD10_aCommandTypedWholeThenEnterSendsAndTabCompletesWithTheCaretAfterTheSpace() throws {
        let r = try PickerRig()
        try r.open()
        r.body.setCatalog(PickerRig.sample)
        r.type("/compact")
        r.enter()
        #expect(r.session.sent == ["/compact"], "the typed token already equals the name: \(r.session.sent)")
        r.session.finish(.success(seconds: 1))
        r.type("/comp")
        r.tab()
        #expect(r.input.string == "/compact " && r.input.selectedRange() == NSRange(location: 9, length: 0) && r.session.sent == ["/compact"])
        r.body.inputText = ""
        r.type("/CoMpAcT")
        r.enter()
        #expect(r.session.sent == ["/compact", "/compact"], "the equality ignores case: \(r.session.sent)")
    }

    @Test func ChatOrcaD10_aSkillRowCompletesOnEnterEvenWhenItsNameIsTypedWhole() throws {
        let r = try PickerRig()
        try r.open()
        r.body.setCatalog(PickerRig.sample)
        r.type("/review")
        r.enter()
        #expect(r.input.string == "/review " && r.session.sent.isEmpty, "only a command dispatches: \(r.input.string)")
    }

    @Test func ChatOrcaD10_aMidPromptTokenCompletesOnEnterAndNeverSends() throws {
        let r = try PickerRig()
        try r.open()
        r.body.setCatalog(PickerRig.sample)
        r.type(" /rev")
        #expect(r.body.isPickerOpen && r.rows() == ["review"])
        r.enter()
        #expect(r.input.string == " /review " && r.session.sent.isEmpty, "\(r.input.string) \(r.session.sent)")
        r.body.inputText = ""
        r.type("say /compact")
        r.enter()
        #expect(r.input.string == "say /compact " && r.session.sent.isEmpty, "a mid-prompt command is part of the sentence: \(r.input.string)")
    }

    @Test func ChatOrcaD10_escHidesThePickerUntilTheTokenChangesAndAMouseDownOnARowCompletesWithoutLeavingTheInput() throws {
        let r = try PickerRig()
        try r.open()
        r.body.setCatalog(PickerRig.sample)
        r.type("/co")
        #expect(r.body.isPickerOpen)
        r.esc()
        #expect(!r.body.isPickerOpen && r.body.picker.isHidden && r.session.interrupts == 0)
        r.type("m")
        #expect(!r.body.isPickerOpen, "typing inside the token keeps it closed")
        r.body.inputText = ""
        r.type("/c")
        #expect(r.body.isPickerOpen, "an edit that left the token reopens it")
        let panel = try #require(r.web.panel)
        panel.focusInput()
        #expect(panel.firstResponder === r.input)
        let row = try #require(r.body.picker.rows.first { $0.item.name == "clear" })
        #expect(!row.acceptsFirstResponder && !r.body.picker.acceptsFirstResponder && !r.body.mentionHint.acceptsFirstResponder)
        row.mouseDown(with: PickerRig.mouseDown())
        #expect(r.input.string == "/clear " && r.session.sent.isEmpty, "a mouse-down completes and never sends: \(r.input.string)")
        #expect(panel.firstResponder === r.input, "the keyboard stays in the input")
    }

    @Test func ChatOrcaD10_theMentionHintShowsForAtAbAClickGivesAtAbSpaceAndEnterStillSends() throws {
        let r = try PickerRig()
        try r.open()
        r.type("look @ab")
        let hint = r.body.mentionHint
        #expect(!hint.isHidden && hint.query == "ab" && hint.shownText == "Referencing file: @ab" && r.body.picker.isHidden, "\(hint.shownText)")
        hint.mouseDown(with: PickerRig.mouseDown())
        #expect(r.input.string == "look @ab " && r.caretAtEnd && hint.isHidden, "\(r.input.string)")
        r.body.inputText = ""
        r.type("@")
        #expect(r.body.mentionHint.shownText == "Referencing file: @\u{2026}", "an empty query shows the ellipsis: \(r.body.mentionHint.shownText)")
        r.type("x")
        r.enter()
        #expect(r.session.sent == ["@x"], "Enter keeps sending: Orca has no mention key handling: \(r.session.sent)")
    }

    @Test func ChatOrcaD10_markedTextGetsNoPickerReactionAndSixtySkillsShowFifty() throws {
        let r = try PickerRig()
        try r.open()
        r.body.setCatalog(PickerRig.sample)
        r.type("/")
        #expect(r.body.isPickerOpen)
        r.input.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(!r.body.isPickerOpen && r.body.picker.isHidden, "marked text hides it")
        r.down(); r.enter()
        #expect(r.session.sent.isEmpty && r.body.pickerActiveIndex == 0 && !r.body.isPickerOpen, "no key reaches the picker while text is marked")
        r.input.unmarkText()
        #expect(r.body.isPickerOpen && r.body.picker.statusText == "No matching commands or skills", "its end brings the picker back for what was composed: \(r.input.string)")
        r.body.setCatalog((0..<60).map { PickerRig.entry("s\($0)", .skill) })
        r.body.inputText = ""
        r.type("/")
        #expect(r.body.picker.rows.count == 50 && r.body.picker.headings == ["SKILLS"], "\(r.body.picker.rows.count)")
    }

    @Test func ChatOrcaD10_theSkillRowShowsItsScopeAndTheCommandRowItsHintAndDescription() throws {
        let r = try PickerRig()
        try r.open()
        r.body.setCatalog([ChatCommandEntry(name: "help", kind: .command, description: "Show help", argumentHint: "<topic>"),
                           ChatCommandEntry(name: "review", kind: .skill, description: "Review a change", scope: "Project")])
        r.type("/")
        let rows = r.body.picker.rows
        #expect(rows.map(\.descriptionText) == ["Show help", "Review a change"] && rows.map(\.scopeText) == ["", "Project"], "\(rows.map(\.scopeText))")
        try #require(rows.count > 1, "rows needs 2 elements: \(rows.count)")
        #expect(rows[0].item.argumentHint == "<topic>" && rows[1].item.kind == .skill)
    }

    @Test func ChatOrcaD10_thePickerRestsThreePointsAboveTheStatusLineWhenItShowsElseAboveTheBoxAndKeepsTheBoxsEdges() throws {
        let r = try PickerRig()
        try r.open()
        r.body.setFrameSize(NSSize(width: 520, height: 304))
        r.body.setCatalog(PickerRig.sample)
        r.type("/")
        // The composer at the chat's 0.75 text scale: bottomPad 12, the one-row box 36, the side pad 9, the status line 12.
        let boxTop = r.body.composer.frame.minY + 12 + 36
        #expect(r.body.composer.preferredHeight() == 54)
        // Orca's 4 pt gap at the 0.75 text scale is 3 pt.
        #expect(r.body.picker.frame.minY == boxTop + 3, "without a status text: 3 pt above the box: \(r.body.picker.frame)")
        #expect(r.body.picker.frame.minX == 9 && r.body.picker.frame.width == 520 - 18, "the box's left and right edges: \(r.body.picker.frame)")
        r.body.setStatus("Not sent: something")
        #expect(r.body.picker.frame.minY == boxTop + 12 + 3, "with a status text: 3 pt above the status line: \(r.body.picker.frame)")
        #expect(r.body.composer.preferredHeight() == CGFloat(54 + 12), "the status line is the only thing that took height")
        r.body.setStatus("")
        #expect(r.body.picker.frame.minY == boxTop + 3)
    }

    /// The rows and headings at the chat's 0.75 text scale (Tom, 2026-11-09: "still the other things are big"): a row is 5 + 15 + 5 pt, 12 more
    /// with a description; a heading 20; the list's padding 3 and its border 1.
    @Test func ChatTextSize_thePickersRowsAndHeadingsAreAtThreeQuarters() throws {
        let r = try PickerRig()
        try r.open()
        r.body.setFrameSize(NSSize(width: 520, height: 900))
        r.body.setCatalog(PickerRig.sample)
        r.type("/")
        let rows = r.body.picker.rows
        #expect(rows.count >= 6 && r.body.picker.headings.count == 2, "\(rows.count) \(r.body.picker.headings)")
        for row in rows {
            row.needsLayout = true
            row.layoutSubtreeIfNeeded()
            #expect(row.frame.height == (row.item.description == nil ? 25 : 37), "\(row.item.name): \(row.frame.height)")
            #expect(row.tokenFrame.height == 15, "\(row.item.name): \(row.tokenFrame)")
        }
        let rowsHeight = rows.reduce(CGFloat(0)) { $0 + $1.frame.height }
        #expect(r.body.picker.contentHeight == 3 + 20 * 2 + rowsHeight + 3 + 2, "\(r.body.picker.contentHeight)")
    }

    @Test func ChatOrcaD10_thePickersHeightIsTheTranscriptAreaMinusSixCappedAt216AndNeverNegativeAndTheEmptyComposerKeepsItsHeight() throws {
        let r = try PickerRig()
        try r.open()
        r.body.setCatalog((0..<40).map { PickerRig.entry("c\($0)", .command, "A description") })
        let emptyHeight = r.body.composer.preferredHeight()
        #expect(emptyHeight == 54)
        // Orca's 8 pt margin and 288 pt cap at the 0.75 text scale: 6 and 216. The panel's title bar is 27 pt.
        #expect(ChatPickerView.maxHeight == 216)
        func height(inPanel panel: CGFloat) -> CGFloat {
            r.body.setFrameSize(NSSize(width: 520, height: panel - 27))
            r.body.inputText = ""
            r.type("/")
            #expect(r.body.picker.contentHeight > 216, "the rows are taller than the cap: \(r.body.picker.contentHeight)")
            #expect(r.body.composer.preferredHeight() == emptyHeight && r.body.composer.frame.height == emptyHeight, "the open picker takes no height from the composer")
            return r.body.picker.frame.height
        }
        #expect(height(inPanel: 280) == 193, "a 280 pt panel: 280 - 27 - 54 - 6")
        #expect(height(inPanel: 240) == 153, "a 240 pt panel")
        #expect(height(inPanel: 340) == 216, "a 340 pt panel reaches the cap")
        #expect(height(inPanel: 900) == 216, "a tall panel gets the cap")
        #expect(height(inPanel: 27 + 54 + 4) == 0, "an area under 6 pt gives 0, never a negative height")
        #expect(height(inPanel: 27 + 54 + 108) == 102, "the transcript area less 6")
    }

    @Test func ChatOrcaD10_theMentionHintRestsLikeThePickerInsetNinePointsAndTwelveFromFourHundredEightyWide() throws {
        let r = try PickerRig()
        try r.open()
        r.body.setFrameSize(NSSize(width: 400, height: 304))
        r.type("@a")
        let hint = r.body.mentionHint
        // The composer at the chat's 0.75 text scale: side pad 9, bottomPad 12, the one-row box 36, the status line 12, the gap 3. Orca's 12 and 16 pt
        // insets are 9 and 12, and its 640 px breakpoint is in page pixels: 480 pt at the page's zoom.
        #expect(hint.frame.minX == 9 + 9 && hint.frame.width == 400 - 18 - 18 && hint.frame.minY == 12 + 36 + 3, "\(hint.frame)")
        #expect(hint.frame.height == ChatMentionHintView.height && ChatMentionHintView.height == 24 && r.body.composer.preferredHeight() == 54)
        r.body.setFrameSize(NSSize(width: 479, height: 304))
        #expect(hint.frame.minX == CGFloat(9 + 9), "just under the breakpoint: \(hint.frame)")
        r.body.setFrameSize(NSSize(width: 480, height: 304))
        #expect(hint.frame.minX == 9 + 12 && hint.frame.width == 480 - 18 - 24, "at the breakpoint: \(hint.frame)")
        r.body.setFrameSize(NSSize(width: 640, height: 304))
        #expect(hint.frame.minX == 9 + 12 && hint.frame.width == 640 - 18 - 24, "\(hint.frame)")
        r.body.setStatus("x")
        #expect(hint.frame.minY == CGFloat(12 + 36 + 12 + 3))
    }

    @Test func ChatOrcaD10_L8_anOpenPickerTakesUpAndDownBeforeTheHistoryAndRecallsNothing() throws {
        let r = try PickerRig()
        try r.open()
        r.body.setCatalog([PickerRig.entry("hello"), PickerRig.entry("help"), PickerRig.entry("helper")])
        r.send("/hello")
        r.send("/help")
        r.up()
        #expect(r.input.string == "/help" && r.body.isPickerOpen, "Up on the empty draft recalls the last send: \(r.input.string)")
        #expect(r.rows() == ["help", "helper"], "\(r.rows())")
        r.up()
        #expect(r.input.string == "/help" && r.body.pickerActiveIndex == 1, "the picker took the arrow: no recall, the active row wrapped: \(r.input.string) \(r.body.pickerActiveIndex)")
        r.down()
        #expect(r.input.string == "/help" && r.body.pickerActiveIndex == 0)
        r.esc()
        r.up()
        #expect(r.input.string == "/hello", "with the picker dismissed the history has its arrows again: \(r.input.string)")
    }

    // MARK: Q9 the catalog through the controller

    private func initFrame(_ names: [String]) throws -> ChatCatalogFrame {
        try #require(catalogFrame(initLine(slash: names, skills: ["review"], terminal: ["doctor"])))
    }

    @Test func ChatOrcaD9_theCatalogSurvivesARestartThroughItsPrivateFileAndIsWrittenOnlyWhenItChanges() throws {
        let first = try PickerRig()
        try first.open()
        try #require(first.session.onCatalog != nil)
        let frame = try initFrame(["help", "compact", "review", "doctor"])
        first.session.onCatalog?(frame)
        first.session.onCatalog?(frame)
        #expect(first.controller.catalog.entries?.map(\.name) == ["help", "compact", "review"])
        #expect(first.rig.lines("CHAT catalog saved").count == 1 && first.rig.lines("CHAT catalog n=3 skills=1").count == 1, "written once: \(first.rig.logs)")
        let path = try first.state.url(ChatCatalogStore.fileName).path
        var info = stat()
        #expect(lstat(path, &info) == 0 && info.st_mode & 0o777 == 0o600, "0600: \(String(info.st_mode, radix: 8))")
        first.body.setCatalog(first.controller.catalog.pickerEntries)
        first.type("/")
        #expect(first.rows() == ["help", "compact", "resume", "review"], "an open picker follows the catalog (and offers Clawd's own resume row)")
        let second = try PickerRig(state: first.state)
        #expect(second.controller.catalog.entries?.map(\.name) == ["help", "compact", "review"], "a new controller over the same state reads it")
        try second.open()
        second.type("/")
        #expect(second.rows() == ["help", "compact", "resume", "review"] && second.body.picker.headings == ["COMMANDS", "SKILLS"], "the saved catalog serves before any report: \(second.rows())")
        #expect(second.rig.lines("CHAT catalog read=ok n=3").count == 1)
    }

    @Test func ChatOrcaD9_withNothingSavedOrReportedTheFourHostCommandsAreOffered() throws {
        let r = try PickerRig()
        try r.open()
        r.type("/")
        #expect(r.rows() == ["model", "effort", "clear", "compact", "resume"] && r.rig.lines("CHAT catalog read=none").count == 1, "\(r.rows())")
        #expect(r.body.picker.rows.map(\.descriptionText) == ["Choose the model", "Choose reasoning effort", "Start a fresh conversation", "Compact conversation context", "Resume a previous conversation"])
    }

    @Test func ChatOrcaD9_theCatalogLinesAndFileCarryNoChatTextAndNoPath() throws {
        let r = try PickerRig()
        try r.open()
        r.session.onCatalog?(try initFrame(["help", "review"]))
        r.send("/secret-plan")
        let text = try String(contentsOfFile: r.state.url(ChatCatalogStore.fileName).path, encoding: .utf8)
        #expect(!text.contains("secret-plan") && !text.contains("/Users/") && !text.contains(NSHomeDirectory()), "\(text)")
        #expect(r.rig.logs.allSatisfy { !$0.contains("secret-plan") }, "\(r.rig.logs)")
    }

    // MARK: Q11

    private func runningPicker() throws -> (PickerRig, ChatWebPage) {
        let r = try PickerRig()
        try r.open()
        r.body.setCatalog(PickerRig.sample)
        r.type("go")
        r.enter()
        #expect(r.session.turn == .running)
        r.type("/co")
        #expect(r.body.isPickerOpen)
        return (r, try #require(r.body.page))
    }

    @Test func ChatOrcaD11_escClosesThePickerFirstThenTheLayerThenInterruptsTheTurnEachEscClosingOneThing() throws {
        let (r, page) = try runningPicker()
        var asked = 0
        page.layerDismissSource = { completion in asked += 1; completion(true) }
        page.received(["type": "layer", "open": true])
        r.esc()
        #expect(!r.body.isPickerOpen && asked == 0 && r.session.interrupts == 0, "the picker is the first thing Esc closes: \(asked) \(r.session.interrupts)")
        r.esc()
        #expect(asked == 1 && r.session.interrupts == 0, "then the layer: \(asked) \(r.session.interrupts)")
        page.received(["type": "layer", "open": false])
        r.esc()
        #expect(asked == 1 && r.session.interrupts == 1, "only when none is open does Esc interrupt the running turn")
        #expect(r.controller.isOpen && r.rig.lines("CHAT close").isEmpty)
    }

    @Test func ChatOrcaD11_aPickerOpenOnAnIdleChatEatsTheEscAndNothingElseHappens() throws {
        let r = try PickerRig()
        try r.open()
        r.body.setCatalog(PickerRig.sample)
        r.type("/")
        r.esc()
        #expect(!r.body.isPickerOpen && r.session.interrupts == 0 && r.controller.isOpen)
        r.esc()
        #expect(r.session.interrupts == 0 && r.controller.isOpen, "an idle chat with nothing open: Esc does nothing")
    }

    @Test func ChatOrcaD11_markedTextKeepsTheEscForTheInputMethodWhileThePickerStaysAsItWas() throws {
        let (r, _) = try runningPicker()
        r.input.setMarkedText("にほ", selectedRange: NSRange(location: 2, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        r.esc()
        #expect(r.session.interrupts == 0 && r.input.hasMarkedText(), "the input method's Esc")
        r.input.unmarkText()
        #expect(r.session.interrupts == 0)
    }

    // MARK: Q25 through the controller

    @Test func ChatOrcaD25_slashClearWithAnIdleChildWritesItAndTheDraftIsTakenIntoTheHistory() throws {
        let r = try PickerRig()
        try r.open()
        r.body.inputText = "/clear"
        r.enter()
        #expect(r.session.sent == ["/clear"] && r.body.inputText.isEmpty && r.body.statusText.isEmpty, "\(r.session.sent)")
        #expect(r.rig.lines("CHAT command name=clear outcome=sent").count == 1)
        r.session.finish(.success(seconds: 1))
        r.up()
        #expect(r.body.inputText == "/clear", "History gets it")
    }

    @Test func ChatOrcaD25_slashClearWithArgumentsAChipDuringATurnOrAnUnsettledSendIsRefusedWithOrcasWordsAndTheDraftIsKept() throws {
        let r = try PickerRig()
        try r.open()
        r.body.inputText = "/clear now"
        r.enter()
        #expect(r.body.statusText == "Use /clear without arguments." && r.session.sent.isEmpty && r.body.inputText == "/clear now")
        r.body.inputText = "/compact now"
        r.enter()
        #expect(r.body.statusText == "Use /compact without arguments." && r.session.sent.isEmpty)
        r.body.composer.attachImages(paths: ["/tmp/x.png"])
        r.body.inputText = "/clear"
        r.enter()
        #expect(r.body.statusText == "Remove attachments before using a chat-session command." && r.session.sent.isEmpty && r.body.inputText == "/clear")
        r.body.composer.removeSent([ChatComposerChip(path: "/tmp/x.png")])
        r.session.hasUnsettledSend = true
        r.enter()
        #expect(r.body.statusText == "Resolve pending or unconfirmed messages before using this command." && r.session.sent.isEmpty)
        r.session.hasUnsettledSend = false
        r.body.inputText = "go"
        r.enter()
        #expect(r.session.turn == .running && r.session.sent == ["go"])
        r.body.inputText = "/clear"
        r.enter()
        #expect(r.body.statusText == "Wait for the current turn to finish before using this command." && r.session.sent == ["go"] && r.body.inputText == "/clear",
                "during a turn: \(r.body.statusText)")
        r.body.inputText = "/compact"
        r.enter()
        #expect(r.body.statusText == "Wait for the current turn to finish before using this command." && r.session.sent == ["go"])
    }

    @Test func ChatOrcaD25_slashClearMatchesInAnyCaseWhileSlashCleaAndSlashClearxGoToClaudeAsTextAndSoDoLeadingSpaceAndTheAliases() throws {
        let r = try PickerRig()
        try r.open()
        r.body.setCatalog([])
        for text in ["/CLEAR", "/clea", "/clearx", " /clear", "/reset", "/new", "/compact"] { r.send(text) }
        #expect(r.session.sent == ["/clear", "/clea", "/clearx", " /clear", "/reset", "/new", "/compact"],
                "/CLEAR is Clawd's and goes as /clear; the rest go to Claude as typed: \(r.session.sent)")
        #expect(r.rig.lines("CHAT command name=clear outcome=sent").count == 1 && r.rig.lines("CHAT command name=compact outcome=sent").count == 1)
    }

    @Test func ChatOrcaD25_slashModelAndSlashEffortSendNothingAndAnswerWithOrcasWordsAndTheDraftIsTakenLikeASentOne() throws {
        let r = try PickerRig()
        try r.open()
        r.body.inputText = "/model sonnet"
        r.enter()
        #expect(r.session.sent.isEmpty && r.body.statusText == "Models are unavailable for this chat session." && r.body.inputText.isEmpty, "\(r.session.sent) \(r.body.statusText)")
        r.body.inputText = "/effort"
        r.enter()
        #expect(r.session.sent.isEmpty && r.body.statusText == "Reasoning effort are unavailable for this chat session.")
        r.up()
        #expect(r.body.inputText == "/effort", "Orca takes the draft as accepted: it is in the history")
        #expect(r.rig.lines("CHAT command name=model outcome=answered").count == 1 && r.rig.logs.allSatisfy { !$0.contains("sonnet") }, "\(r.rig.logs)")
    }

    @Test func ChatOrcaD25_slashInitIsRefusedWhileChatFolderIsUnsetOrIsTheHomeFolderAndSentOnceItNamesAnotherFolder() throws {
        let r = try PickerRig()
        try r.open()
        r.body.inputText = "/init"
        r.enter()
        #expect(r.session.sent.isEmpty && r.body.statusText == "Set chatFolder first: /init writes CLAUDE.md into the chat's folder, which is your home folder now.")
        #expect(r.body.inputText == "/init", "the draft is kept")
        r.rig.chatSettings.folder = NSHomeDirectory()
        r.enter()
        #expect(r.session.sent.isEmpty, "naming the home folder is the same as not naming one")
        r.rig.chatSettings.folder = "/tmp/x"
        r.enter()
        #expect(r.session.sent == ["/init"] && r.body.inputText.isEmpty, "\(r.session.sent)")
    }

    @Test func ChatOrcaD25_aClaimedCommandPassesTheSameGateAsEnterNoPageAndNoExamBrowser() throws {
        let r = try PickerRig()
        try r.open()
        r.rig.host.examRunning = true
        r.body.inputText = "/compact"
        r.enter()
        #expect(r.session.sent.isEmpty && r.body.statusText == "Not sent: an exam browser is running" && r.body.inputText == "/compact", "\(r.body.statusText)")
        r.rig.host.examRunning = false
        r.enter()
        #expect(r.session.sent == ["/compact"])
    }

    @Test func ChatOrcaD25_aPickedCommandIsOnlyCompletedAndEnterSendsOnlyAnExactMatch() throws {
        let r = try PickerRig()
        try r.open()
        r.body.setCatalog(PickerRig.sample)
        r.type("/cl")
        r.enter()
        #expect(r.session.sent.isEmpty && r.input.string == "/clear ", "\"/cl\" + Enter is never /clear: \(r.input.string) \(r.session.sent)")
        r.body.inputText = ""
        r.type("/com")
        r.enter()
        #expect(r.session.sent.isEmpty && r.input.string == "/compact ", "\"/com\" + Enter is never a command: \(r.input.string)")
    }

    // MARK: Sprint 3 review r1

    @Test func ChatOrcaD10_H1_aSkillTypedWholeStaysItselfOnEnterNeverTheCommandWhoseNameContainsIt() throws {
        let r = try PickerRig()
        try r.open()
        r.body.setCatalog([PickerRig.entry("ultrareview"), PickerRig.entry("security-review"), PickerRig.entry("review", .skill, scope: "Project")])
        r.type("/review")
        #expect(r.rows() == ["ultrareview", "security-review", "review"] && r.body.pickerActiveIndex == 2, "the exact name is the first active row: \(r.body.pickerActiveIndex)")
        r.enter()
        #expect(r.input.string == "/review " && r.session.sent.isEmpty, "\(r.input.string)")
        r.enter()
        #expect(r.session.sent == ["/review "], "the second Enter sends what was typed, as typed: \(r.session.sent)")
        r.session.finish(.success(seconds: 1))
        r.type("/Review")
        #expect(r.body.pickerActiveIndex == 2, "case does not matter")
        r.down()
        #expect(r.body.pickerActiveIndex == 0, "the arrows still move from there")
        r.body.inputText = ""
        r.type("/rev")
        #expect(r.body.pickerActiveIndex == 0, "without an exact name the first row is active")
    }

    @Test func ChatOrcaD25_M2_commandNamesWithHiddenOrControlCharactersGetNoRow() {
        let rows = ChatPicker.items(entries: [ChatCommandEntry(name: "cl\u{200B}ear", kind: .command), ChatCommandEntry(name: "x\u{202E}y", kind: .command),
                                              ChatCommandEntry(name: "a\u{0007}b", kind: .command), ChatCommandEntry(name: "fine", kind: .command)], query: "")
        #expect(rows.map(\.name) == ["fine"], "\(rows.map(\.name))")
    }

    @Test func ChatOrcaD25_M1_theInitGateReadsTheTrimmedDraftAnyCaseAndAChatFolderSpelledInAnotherCaseIsHome() throws {
        func decide(_ text: String) -> ChatHostCommand.Decision {
            ChatHostCommand.decide(text, hasChips: false, turnActive: false, sendUnsettled: false, chatFolderIsHome: true)
        }
        for text in [" /init", "\n/init", "\t/INIT x", "/init  ", "\u{00A0}/Init"] { #expect(decide(text) == .refuse(ChatHostCommand.initRefusal), "\(text.debugDescription)") }
        #expect(decide(" /clear") == .text && decide("\n/model") == .text, "the four claimed names keep exact matching: a leading space is text")
        #expect(decide("/initx") == .text && decide("/in") == .text)
        let home = NSHomeDirectory()
        #expect(ChatHostCommand.folderIsHome(home, home: home) && ChatHostCommand.folderIsHome(home.uppercased(), home: home) && ChatHostCommand.folderIsHome(home + "/", home: home))
        #expect(ChatHostCommand.folderIsHome(home + "/../" + (home as NSString).lastPathComponent, home: home))
        #expect(!ChatHostCommand.folderIsHome("/tmp", home: home))
    }

    @Test func ChatOrcaD25_M1_withChatFolderUnsetALeadingSpaceInitIsRefusedThroughTheController() throws {
        let r = try PickerRig()
        try r.open()
        for text in [" /init", "/INIT"] {
            r.body.inputText = text
            r.enter()
            #expect(r.session.sent.isEmpty && r.body.statusText == ChatHostCommand.initRefusal && r.body.inputText == text, "\(text.debugDescription) \(r.session.sent)")
        }
        r.rig.chatSettings.folder = NSHomeDirectory().uppercased()
        r.enter()
        #expect(r.session.sent.isEmpty, "a chatFolder that differs from home only in case is home")
        r.rig.chatSettings.folder = "/tmp/x"
        r.enter()
        #expect(r.session.sent == ["/INIT"])
    }

    @Test func ChatOrcaD25_L3_theExamGuardComesBeforeTheAnswerToModelAndEffortSoTheDraftIsKept() throws {
        let r = try PickerRig()
        try r.open()
        r.rig.host.examRunning = true
        r.body.inputText = "/model sonnet"
        r.enter()
        #expect(r.body.statusText == "Not sent: an exam browser is running" && r.body.inputText == "/model sonnet" && r.session.sent.isEmpty)
        r.rig.host.examRunning = false
        r.enter()
        #expect(r.body.statusText == ChatHostCommand.modelAnswer && r.body.inputText.isEmpty)
    }

    @Test func ChatOrcaD10_L4_aPickerLaidOutZeroPointsTallTakesNoKeysAndNoEsc() throws {
        let r = try PickerRig()
        try r.open()
        r.body.setCatalog((0..<10).map { PickerRig.entry("c\($0)") })
        r.type("go")
        r.enter()
        #expect(r.session.turn == .running)
        r.body.setFrameSize(NSSize(width: 520, height: 54 + 4))
        r.type("/")
        #expect(r.body.picker.frame.height == 0 && !r.body.isPickerOpen)
        r.down()
        #expect(r.body.pickerActiveIndex == 0, "no arrow reaches a picker nobody can see")
        r.esc()
        #expect(r.session.interrupts == 1, "Esc interrupts the turn instead of dismissing it: \(r.session.interrupts)")
    }

    @Test func ChatOrcaD10_L5_shiftEnterOnAFullyTypedCommandSendsItAsOrcaDoesNoShiftKeyCheckInThePickersEnterBranch() throws {
        let r = try PickerRig()
        try r.open()
        r.body.setCatalog(PickerRig.sample)
        r.type("/compact")
        r.web.pressEnter(modifiers: .shift)
        #expect(r.session.sent == ["/compact"], "NC/use-native-chat-composer-keydown.ts:78-89: \(r.session.sent)")
    }

    // MARK: Sprint 3 fix recheck

    @Test func ChatOrcaD25_N1_theInitGateReadsTheFirstTokenOfTheTrimmedDraftEvenWithALineBreakInTheArguments() throws {
        for text in ["/init\nfoo", "/init foo\nbar", "\t/init", "/INIT", " /Init\r\nx", "\n\n/init\n"] {
            #expect(ChatHostCommand.isInit(text) && ChatHostCommand.logName(text) == "init", "\(text.debugDescription)")
            #expect(ChatHostCommand.decide(text, hasChips: false, turnActive: false, sendUnsettled: false, chatFolderIsHome: true) == .refuse(ChatHostCommand.initRefusal))
        }
        for text in ["/initx", "/in", "init", "x /init", "/ init", ""] { #expect(!ChatHostCommand.isInit(text), "\(text.debugDescription)") }
        let r = try PickerRig()
        try r.open()
        for text in ["/init\nfoo", "/init foo\nbar"] {
            r.body.inputText = text
            r.enter()
            #expect(r.session.sent.isEmpty && r.body.statusText == ChatHostCommand.initRefusal && r.body.inputText == text, "\(text.debugDescription) \(r.session.sent)")
        }
    }

    @Test func ChatOrcaD25_N3_everyGatedFormLogsNameInitAndNeverTheDraft() throws {
        let r = try PickerRig()
        try r.open()
        for text in [" /init", "/INIT x", "\t/init\nfoo"] {
            r.body.inputText = text
            r.enter()
        }
        #expect(r.rig.lines("CHAT command name=init outcome=refused").count == 3 && r.rig.lines("CHAT command name=none").isEmpty, "\(r.rig.logs)")
        #expect(r.rig.logs.allSatisfy { !$0.contains("foo") })
    }

    @Test func ChatOrcaD10_N2_aCatalogFrameKeepsTheRowTheUserArrowedToWhenItIsStillThereElseFallsBackToTheExactNameThenRowZero() {
        func entries(_ names: [String]) -> [ChatCommandEntry] { names.map { ChatCommandEntry(name: $0, kind: .command) } }
        var state = ChatAutocompleteState(entries: entries(["alpha", "beta", "gamma"]))
        state.refresh(text: "/", caret: 1, marked: false)
        _ = state.move(1); _ = state.move(1)
        #expect(state.activeItem?.name == "gamma")
        state.setEntries(entries(["zero", "alpha", "beta", "gamma"]))
        #expect(state.activeItem?.name == "gamma" && state.active == 3, "the same item stays chosen: \(String(describing: state.activeItem?.name))")
        state.refresh(text: "/", caret: 1, marked: false)
        #expect(state.activeItem?.name == "gamma", "a report of the same text and caret changes nothing")
        state.setEntries(entries(["zero", "alpha"]))
        #expect(state.active == 0, "gone: row 0")
        state.refresh(text: "/alpha", caret: 6, marked: false)
        _ = state.move(1)
        state.setEntries(entries(["zero", "alpha", "alphabet"]))
        #expect(state.activeItem?.name == "alphabet" || state.activeItem?.name == "alpha")
        state.setEntries(entries(["zero", "alpha", "other"]))
        #expect(state.activeItem?.name == "alpha", "an item that is gone falls back to the exact name")
    }
}
