import Testing
import Foundation
@testable import ClawdCore

// Orca parity round D, sprint 3, the Core side: the `/` catalog (Q9), the picker's rules (Q10), and the commands Clawd claims with their divider
// (Q25). No window, no web view and no timer: values in, values out. The real child's frames come from the contained captures
// (Tests/Fixtures/chat/PROVENANCE.md).

func catalogFrame(_ json: String) -> ChatCatalogFrame? {
    for event in chatParseOne(json) { if case .commandCatalog(let frame) = event { return frame } }
    return nil
}

private func jsonArray(_ names: [String]) -> String { "[" + names.map { "\"\($0)\"" }.joined(separator: ",") + "]" }

func initLine(slash: [String], skills: [String] = [], terminal: [String] = []) -> String {
    "{\"type\":\"system\",\"subtype\":\"init\",\"session_id\":\"s\",\"slash_commands\":\(jsonArray(slash)),\"skills\":\(jsonArray(skills)),\"terminal_slash_commands\":\(jsonArray(terminal))}"
}

func changedLine(_ descriptors: [[String: Any]]) -> String {
    let data = try! JSONSerialization.data(withJSONObject: ["type": "system", "subtype": "commands_changed", "commands": descriptors])
    return String(decoding: data, as: UTF8.self)
}

private func shape(_ catalog: ChatCatalog) -> [String] { (catalog.entries ?? []).map { "\($0.kind == .skill ? "skill" : "command") \($0.name)" } }

private func clearTurnEvents() throws -> [ChatEvent] {
    var running = 0
    return try chatFixtureLines("d-clear-uuid.jsonl").filter { line in
        if line.contains("\"state\":\"running\"") { running += 1 }
        return running >= 3
    }.flatMap { ChatStreamParser.parse(line: $0) }
}

@Suite("Chat orca parity D, the catalog and the claimed commands")
struct ChatOrcaParityDCatalogSuite {
    // MARK: Q9

    @Test func ChatOrcaD9_anInitWhereSkillsIsASubsetOfSlashCommandsGivesItsCommandsAndSkillsWithTheTerminalNamesHidden() throws {
        var catalog = ChatCatalog()
        let frame = try #require(catalogFrame(initLine(slash: ["help", "compact", "review", "doctor", "color"], skills: ["review"], terminal: ["doctor", "color"])))
        let changed = catalog.observe(frame)
        #expect(changed)
        #expect(shape(catalog) == ["command help", "command compact", "skill review"], "\(shape(catalog))")
        let again = catalog.observe(frame)
        #expect(!again, "the same frame again changes nothing")
    }

    @Test func ChatOrcaD9_theRealTwoTurnCaptureGivesHelpCompactAndContextFromInitThenOnlyHelpAndCompactAfterItsCommandsChangedAndTheTextSurvivesTheNextInit() throws {
        var catalog = ChatCatalog()
        var seen: [[String]] = []
        for event in try chatEvents("p1-two-turns.jsonl") {
            guard case .commandCatalog(let frame) = event else { continue }
            _ = catalog.observe(frame)
            seen.append(shape(catalog))
        }
        #expect(seen == [["command help", "command compact", "command context"], ["command help", "command compact"],
                         ["command help", "command compact", "command context"]], "\(seen)")
        let help = try #require(catalog.entries?.first { $0.name == "help" }), compact = try #require(catalog.entries?.first { $0.name == "compact" })
        #expect(help.description == "Show help" && compact.description == "Compact the conversation", "the second init is name-only: it keeps the text")
        #expect(help.argumentHint == nil, "an empty hint is nothing")
    }

    @Test func ChatOrcaD9_aDescriptorFrameAddsDescriptionsAndHintsThatSurviveANameOnlyFrameAndASkillIsAnyNameTheLastClassificationDidNotKnowAsACommand() throws {
        var catalog = ChatCatalog()
        let descriptors = try #require(catalogFrame(changedLine([["name": "review", "description": "Review a change", "argumentHint": "<pr>"], ["name": "deploy"]])))
        _ = catalog.observe(descriptors)
        #expect(shape(catalog) == ["command review", "command deploy"], "before any classification every name is a command")
        #expect(catalog.entries?.first?.description == "Review a change" && catalog.entries?.first?.argumentHint == "<pr>")
        _ = catalog.observe(try #require(catalogFrame(initLine(slash: ["review", "deploy"], skills: ["deploy"]))))
        #expect(shape(catalog) == ["command review", "skill deploy"])
        #expect(catalog.entries?.first?.description == "Review a change" && catalog.entries?.first?.argumentHint == "<pr>", "a name-only frame keeps the text")
        _ = catalog.observe(try #require(catalogFrame(changedLine([["name": "review"], ["name": "deploy"], ["name": "fresh"]]))))
        #expect(shape(catalog) == ["command review", "skill deploy", "skill fresh"],
                "a name the last classification knew as a command stays one; any other name is a skill: \(shape(catalog))")
        #expect(catalog.entries?.first?.description == nil, "a descriptor frame replaces the text: the new one had none")
    }

    @Test func ChatOrcaD9_aTerminalNameIsHiddenFromADescriptorFrameToo() throws {
        var catalog = ChatCatalog()
        _ = catalog.observe(try #require(catalogFrame(initLine(slash: ["a", "doctor"], terminal: ["doctor"]))))
        _ = catalog.observe(try #require(catalogFrame(changedLine([["name": "a"], ["name": "doctor"]]))))
        #expect(shape(catalog) == ["command a"], "\(shape(catalog))")
    }

    @Test func ChatOrcaD9_aTwoHundredAndOneCharacterNameIsDroppedAndSoIsTheFiveHundredAndThirteenthName() throws {
        let long = String(repeating: "n", count: 201), fits = String(repeating: "n", count: 200)
        let frame = try #require(catalogFrame(initLine(slash: [long, fits, "has space", " padded ", ""])))
        guard case .names(let names, _, _) = frame.body else { Issue.record("not names"); return }
        #expect(names == [fits, "padded"], "a name is 1-200 characters with no white space inside; the ends are trimmed: \(names.map(\.count))")
        let many = try #require(catalogFrame(initLine(slash: (0..<600).map { "c\($0)" })))
        guard case .names(let kept, _, _) = many.body else { Issue.record("not names"); return }
        #expect(kept.count == 512 && kept.last == "c511" && !kept.contains("c512"), "at most 512 names: \(kept.count)")
        var catalog = ChatCatalog()
        _ = catalog.observe(many)
        #expect(catalog.entries?.count == 512)
    }

    @Test func ChatOrcaD9_aDescriptionOrHintOverItsLimitIsDroppedNotCutAndWhiteSpaceCollapses() throws {
        let frame = try #require(catalogFrame(changedLine([
            ["name": "a", "description": String(repeating: "d", count: 201), "argumentHint": String(repeating: "h", count: 101)],
            ["name": "b", "description": String(repeating: "d", count: 200), "argumentHint": String(repeating: "h", count: 100)],
            ["name": "c", "description": "  two\n\t words  ", "argumentHint": " <x>   <y> "]])))
        guard case .descriptors(let rows) = frame.body else { Issue.record("not descriptors"); return }
        try #require(rows.count > 0, "rows needs 1 elements: \(rows.count)")
        #expect(rows[0].description == nil && rows[0].argumentHint == nil, "over the limit: dropped, not cut")
        try #require(rows.count > 1, "rows needs 2 elements: \(rows.count)")
        #expect(rows[1].description?.count == 200 && rows[1].argumentHint?.count == 100)
        try #require(rows.count > 2, "rows needs 3 elements: \(rows.count)")
        #expect(rows[2].description == "two words" && rows[2].argumentHint == "<x> <y>", "\(rows[2])")
    }

    @Test func ChatOrcaD9_aDescriptionHoldingU202EIsShownWithoutItAndTheTextIsCutToTwoHundredFortyAndEightyCharacters() {
        let rows = ChatPicker.items(entries: [ChatCommandEntry(name: "x", kind: .command, description: "he\u{202E}llo\u{200B} wor\u{0007}ld", argumentHint: "<a\u{202E}b>")], query: "")
        #expect(rows.first?.description == "hello world" && rows.first?.argumentHint == "<ab>", "\(String(describing: rows.first))")
        let longText = String(repeating: "t", count: 200), longHint = String(repeating: "h", count: 100)
        let cut = ChatPicker.items(entries: [ChatCommandEntry(name: "y", kind: .command, description: longText, argumentHint: longHint)], query: "")
        #expect(cut.first?.description?.count == 200 && cut.first?.argumentHint?.count == 80, "the hint shows 80: \(cut.first?.argumentHint?.count ?? -1)")
        let wide = ChatPicker.items(entries: [ChatCommandEntry(name: "z", kind: .command, description: String(repeating: "t", count: 300))], query: "")
        #expect(wide.first?.description?.count == 240, "the sanitizer's own cut is 240 for text that came from a saved file")
    }

    @Test func ChatOrcaD9_aThreeHundredCharacterUserDescriptionGivesPersonalAndNoDescriptionAndTheOtherLabelsComeFromTheRawDescriptor() throws {
        let raw = String(repeating: "x", count: 293) + " (user)"
        let frame = try #require(catalogFrame(changedLine([
            ["name": "mine", "description": raw],
            ["name": "proj", "description": "Does a thing (project)  "],
            ["name": "design:sync", "description": "Plugin one"],
            ["name": "inbox", "builtin": true],
            ["name": "plain", "description": "Plain"],
            ["name": "both:x", "description": "Both (user)"]])))
        guard case .descriptors(let rows) = frame.body else { Issue.record("not descriptors"); return }
        #expect(rows.map(\.scope) == ["Personal", "Project", "Plugin", "Built-in", nil, "Personal"], "\(rows.map(\.scope))")
        try #require(rows.count > 0, "rows needs 1 elements: \(rows.count)")
        #expect(rows[0].description == nil, "300 characters is over the limit")
        var catalog = ChatCatalog()
        _ = catalog.observe(frame)
        #expect(catalog.entries?.first?.scope == "Personal" && catalog.entries?.first?.description == nil)
    }

    @Test func ChatOrcaD9_beforeTheFirstReportThePickerOffersTheFourHostCommandsWithTheirWords() {
        let catalog = ChatCatalog()
        #expect(catalog.entries == nil)
        let items = ChatPicker.items(entries: catalog.pickerEntries, query: "")
        #expect(items.map(\.name) == ["model", "effort", "clear", "compact", "resume"])
        #expect(items.map(\.description) == ["Choose the model", "Choose reasoning effort", "Start a fresh conversation", "Compact conversation context",
                                              "Resume a previous conversation"])
    }

    @Test func ChatOrcaD9_theSavedCatalogIsCheckedAgainWhenItIsReadAndSeedsTheClassification() throws {
        let state = try artifactStore()
        let store = ChatCatalogStore(state: state, log: { _ in })
        store.save([ChatCommandEntry(name: "review", kind: .skill, description: "Review", scope: "Project"), ChatCommandEntry(name: "help", kind: .command)])
        #expect(store.load()?.map(\.name) == ["review", "help"])
        try state.write(Data(#"{"version":1,"entries":[{"name":"ok","kind":"command"},{"name":"bad name","kind":"command"},{"name":"s","kind":"skill","scope":"Evil","description":"fine"}]}"#.utf8),
                        to: ChatCatalogStore.fileName)
        let loaded = try #require(store.load())
        #expect(loaded.map(\.name) == ["ok", "s"] && loaded[1].scope == nil && loaded[1].description == "fine", "\(loaded)")
        try state.write(Data("not json".utf8), to: ChatCatalogStore.fileName)
        #expect(store.load() == nil)
        var catalog = ChatCatalog(saved: [ChatCommandEntry(name: "review", kind: .skill, description: "Review"), ChatCommandEntry(name: "help", kind: .command)])
        _ = catalog.observe(try #require(catalogFrame(changedLine([["name": "help"], ["name": "review"], ["name": "new"]]))))
        #expect(shape(catalog) == ["command help", "skill review", "skill new"], "the saved kinds classify: \(shape(catalog))")
    }

    // MARK: Q10 the picker's rules

    private func sample() -> [ChatCommandEntry] {
        [ChatCommandEntry(name: "help", kind: .command, description: "Show help"), ChatCommandEntry(name: "compact", kind: .command),
         ChatCommandEntry(name: "context", kind: .command), ChatCommandEntry(name: "clear", kind: .command),
         ChatCommandEntry(name: "review", kind: .skill, scope: "Project"), ChatCommandEntry(name: "commit", kind: .skill, scope: "Personal")]
    }

    @Test func ChatOrcaD10_theTriggerIsALeadingSlashOrAMidPromptOneAndAMentionOtherwise() {
        func mode(_ text: String, caret: Int? = nil) -> String {
            switch ChatAutocomplete.derive(draft: text, caret: caret ?? text.utf16.count, entries: sample(), dismissedKey: nil) {
            case .none: return "none"
            case .slash(let slash): return "slash \(slash.query) \(slash.triggerKey) \(slash.dispatchable)"
            case .mention(let query): return "mention \(query)"
            case .conversations: return "conversations"
            }
        }
        #expect(mode("/") == "slash  /:0 true" && mode("/co") == "slash co /:0 true")
        #expect(mode("/co now") == "none" && mode("path/to") == "none", "a space ends the leading token; a slash inside a word is prose")
        #expect(mode("x /rev") == "slash rev /:2 false" && mode("x /rev/x") == "none", "a mid-prompt query stops at the next slash")
        #expect(mode("@ab") == "mention ab" && mode("see @a/b") == "mention a/b" && mode("a@b") == "none")
        #expect(mode("/compact now", caret: 4) == "slash com /:0 true", "the text before the caret decides")
        #expect(mode("x /rev @fi") == "mention fi", "a mention is looked at before a mid-prompt slash")
    }

    @Test func ChatOrcaD10_commandsAndSkillsAreRankedSeparatelyAndCaseInsensitivelyAndEqualRanksKeepTheCatalogOrder() {
        let rows = ChatPicker.items(entries: sample(), query: "COMP")
        #expect(rows.map(\.name) == ["compact"], "\(rows.map(\.name))")
        let all = ChatPicker.items(entries: sample(), query: "")
        #expect(all.map(\.name) == ["help", "compact", "context", "clear", "review", "commit"], "commands in catalog order, then skills by scope and name: \(all.map(\.name))")
        let co = ChatPicker.items(entries: sample(), query: "co")
        #expect(co.map(\.name) == ["compact", "context", "commit"], "prefix matches first in catalog order, then the skills group: \(co.map(\.name))")
        let ranks = ChatPicker.items(entries: [ChatCommandEntry(name: "xab", kind: .command), ChatCommandEntry(name: "ab", kind: .command), ChatCommandEntry(name: "abc", kind: .command),
                                               ChatCommandEntry(name: "a-b", kind: .command), ChatCommandEntry(name: "q", kind: .command, description: "has ab inside")], query: "ab")
        #expect(ranks.map(\.name) == ["ab", "abc", "xab", "a-b", "q"], "exact 0, prefix 1, contains 2, subsequence 3, description 4: \(ranks.map(\.name))")
        #expect(ChatPicker.items(entries: sample(), query: "zzz").isEmpty, "no match drops the item")
    }

    @Test func ChatOrcaD10_eachGroupShowsAtMostFiftyAndASkillThatSharesACommandsNameKeepsOnlyTheCommandRowAnnotated() {
        let many = (0..<60).map { ChatCommandEntry(name: "s\($0)", kind: .skill) } + (0..<60).map { ChatCommandEntry(name: "c\($0)", kind: .command) }
        let rows = ChatPicker.items(entries: many, query: "")
        #expect(rows.filter { $0.kind == .command }.count == 50 && rows.filter { $0.kind == .skill }.count == 50)
        let shared = ChatPicker.items(entries: [ChatCommandEntry(name: "review", kind: .command), ChatCommandEntry(name: "review", kind: .skill)], query: "")
        #expect(shared.count == 1 && shared[0].kind == .command && shared[0].skillCollision && shared[0].annotation == "Also a skill name - agent decides", "\(shared)")
    }

    @Test func ChatOrcaD10_aPickReplacesTheTypedTokenWithTheItemsTokenAndASpaceAndTheCaretGoesAfterIt() throws {
        let compact = try #require(ChatPicker.items(entries: sample(), query: "comp").first)
        let leading = try #require(ChatPicker.apply(draft: "/comp", caret: 5, item: compact))
        #expect(leading.draft == "/compact " && leading.caret == 9)
        let mid = try #require(ChatPicker.apply(draft: "say /comp now", caret: 9, item: compact))
        #expect(mid.draft == "say /compact  now" && mid.caret == 13, "the text after the caret stays: \(mid)")
        #expect(ChatPicker.apply(draft: "plain", caret: 5, item: compact) == nil)
        let mention = try #require(ChatPicker.applyMention(draft: "look @ab", caret: 8, query: "ab"))
        #expect(mention.draft == "look @ab " && mention.caret == 9)
    }

    @Test func ChatOrcaD10_theStateWrapsOnThreeItemsAndEscStaysClosedUntilTheTokenIsLeftOrReplacedWholesale() {
        let three = Array(sample().prefix(3))
        var state = ChatAutocompleteState(entries: three)
        state.refresh(text: "/", caret: 1, marked: false)
        #expect(state.slash?.items.count == 3 && state.active == 0)
        for expected in [1, 2, 0] {
            let moved = state.move(1)
            #expect(moved && state.active == expected)
        }
        let back = state.move(-1)
        #expect(back && state.active == 2, "Up wraps the other way")
        state.refresh(text: "/c", caret: 2, marked: false)
        #expect(state.active == 0, "a new draft starts at the first row")
        state.dismiss()
        #expect(!state.isOpen)
        state.refresh(text: "/co", caret: 3, marked: false)
        #expect(!state.isOpen, "typing inside the token keeps it closed")
        state.refresh(text: "/co", caret: 1, marked: false)
        #expect(!state.isOpen, "so does a caret move inside it")
        state.refresh(text: "", caret: 0, marked: false)
        state.refresh(text: "/", caret: 1, marked: false)
        #expect(state.isOpen, "an edit that left the token ends the dismissal")
        state.refresh(text: "/co", caret: 3, marked: false)
        state.dismiss()
        state.refresh(text: "/x", caret: 2, marked: false)
        #expect(state.isOpen, "one edit that replaces the token wholesale is a new trigger")
        state.refresh(text: "/x", caret: 2, marked: true)
        #expect(!state.isOpen, "marked text hides the picker")
        state.refresh(text: "/x", caret: 2, marked: false)
        #expect(state.isOpen, "and its end brings it back")
    }

    @Test func ChatOrcaD10_anEmptyResultStillShowsTheNoMatchRowAndTakesNoArrowKeys() {
        var state = ChatAutocompleteState(entries: sample())
        state.refresh(text: "/zzz", caret: 4, marked: false)
        #expect(state.isOpen && state.slash?.items.isEmpty == true && state.activeItem == nil)
        let moved = state.move(1)
        #expect(!moved, "no row to move over")
        state.dismiss()
        #expect(!state.isOpen, "Esc dismisses the empty picker too")
    }

    // MARK: Q25 the commands Clawd claims

    @Test func ChatOrcaD25_aCommandIsOnlyTheDraftsExactFirstTokenLowerCasedAndAnArgumentWithALineBreakInsideIsNotACommand() {
        #expect(ChatHostCommand.parts("/clear") == ChatHostCommand.Parts(name: "clear", argument: ""))
        #expect(ChatHostCommand.parts("/CLEAR  \n") == ChatHostCommand.Parts(name: "clear", argument: ""))
        #expect(ChatHostCommand.parts("/clear now") == ChatHostCommand.Parts(name: "clear", argument: "now"))
        #expect(ChatHostCommand.parts("/clear\n\nnow") == ChatHostCommand.Parts(name: "clear", argument: "now"), "the space run takes the line breaks before the argument")
        #expect(ChatHostCommand.parts("/clear a\nb") == nil, "`.` stops at a line break, so the whole text does not match (Orca's own regex)")
        #expect(ChatHostCommand.parts(" /clear") == nil && ChatHostCommand.parts("clear") == nil && ChatHostCommand.parts("/") == nil && ChatHostCommand.parts("/ x") == nil)
    }

    @Test func ChatOrcaD25_theDecisionFollowsOrcasOrderAttachmentsThenArgumentsThenTheTurnThenUnsettledSends() {
        func decide(_ text: String, chips: Bool = false, turn: Bool = false, unsettled: Bool = false, home: Bool = true) -> ChatHostCommand.Decision {
            ChatHostCommand.decide(text, hasChips: chips, turnActive: turn, sendUnsettled: unsettled, chatFolderIsHome: home)
        }
        #expect(decide("/clear") == .send("/clear") && decide("/COMPACT") == .send("/compact"))
        #expect(decide("/clear now", chips: true) == .refuse("Remove attachments before using a chat-session command."))
        #expect(decide("/clear now", turn: true) == .refuse("Use /clear without arguments."))
        #expect(decide("/compact x") == .refuse("Use /compact without arguments."))
        #expect(decide("/clear", turn: true, unsettled: true) == .refuse("Wait for the current turn to finish before using this command."))
        #expect(decide("/compact", unsettled: true) == .refuse("Resolve pending or unconfirmed messages before using this command."))
        #expect(decide("/model sonnet") == .answer("Models are unavailable for this chat session.") && decide("/effort", turn: true) == .answer("Reasoning effort are unavailable for this chat session."))
        #expect(decide("/model", chips: true) == .refuse("Remove attachments before using a chat-session command."))
        #expect(decide("/clea") == .text && decide("/clearx") == .text && decide("/reset") == .text && decide("/new") == .text && decide(" /clear") == .text && decide("hello") == .text)
        #expect(decide("/init") == .refuse("Set chatFolder first: /init writes CLAUDE.md into the chat's folder, which is your home folder now."))
        #expect(decide("/init", home: false) == .text && decide("/INIT x", home: true) == .refuse(ChatHostCommand.initRefusal))
    }

    private func clearedTranscript() throws -> (ChatTranscript, before: Int) {
        var t = ChatTranscript()
        t.appendUser("one")
        t.apply(.textDelta(messageKey: "m", blockIndex: 0, text: "hello"))
        t.apply(.result(outcome: .success, durationMs: 1, totalCost: 0, sessionId: "old", text: "hello"))
        let before = try #require(t.entries.map(\.id).max())
        t.expectedSessionId = "old"
        t.appendUser("/clear")
        for event in try clearTurnEvents() { t.apply(event) }
        return (t, before)
    }

    @Test func ChatOrcaD25_theResetFrameMakesOneClearedDividerAboveWhichTheOldEntriesStayAndBelowWhichTheNextReplyLands() throws {
        var (t, _) = try clearedTranscript()
        #expect(t.entries.map(\.kind) == [.user, .assistant, .footer, .user, .divider, .footer], "\(t.entries.map(\.kind))")
        #expect(t.entries.first { $0.kind == .divider }?.text == "Conversation cleared")
        #expect(t.entries.prefix(3).map(\.text).prefix(2) == ["one", "hello"], "the old entries are kept")
        t.appendUser("next")
        t.apply(.textDelta(messageKey: "m2", blockIndex: 0, text: "fresh reply"))
        let divider = try #require(t.entries.firstIndex { $0.kind == .divider }), reply = try #require(t.entries.firstIndex { $0.text == "fresh reply" })
        #expect(reply > divider, "the next reply lands below the divider")
    }

    @Test func ChatOrcaD25_aNewEntryAfterAClearHasAnIdGreaterThanEveryIdBeforeItAndNoIdIsReused() throws {
        var (t, before) = try clearedTranscript()
        t.appendUser("next")
        let ids = t.entries.map(\.id)
        #expect(Set(ids).count == ids.count && ids == ids.sorted(), "\(ids)")
        #expect(t.entries.filter { $0.id > before }.count == 4 && t.entries.last!.id > before, "everything after the clear is newer than everything before it")
        #expect(t.entries.first { $0.kind == .divider }!.id > before)
    }

    @Test func ChatOrcaD25_afterTheResetTheFollowingInitAddsNoAnotherSessionNoticeButAnInitWithANewIdAndNoResetLeavesTheTranscriptAndShowsIt() throws {
        let (cleared, _) = try clearedTranscript()
        #expect(!cleared.entries.contains { $0.kind == .notice }, "the init that follows a reset names a new session on purpose: \(cleared.entries.map(\.text))")
        var failed = ChatTranscript()
        failed.appendUser("one")
        failed.expectedSessionId = "asked"
        failed.apply(.initialized(sessionId: "another", model: "m", permissionMode: "default", version: "1"))
        #expect(failed.entries.map(\.kind) == [.user, .notice] && failed.entries.last?.text == "Claude Code continued another session than the one requested",
                "a failed --resume empties nothing and keeps the notice: \(failed.entries.map(\.text))")
        #expect(!failed.entries.contains { $0.kind == .divider })
    }

    @Test func ChatOrcaD25_aResetWithAnotherTriggerIsCountedAndAddsNoDivider() {
        var t = ChatTranscript()
        t.apply(.conversationReset(trigger: "resume", newConversationId: "x"))
        #expect(t.entries.isEmpty && t.ignoredCounts == ["conversation_reset/resume": 1])
    }

    @Test func ChatOrcaD25_theResetLineParsesWithItsTriggerAndTheIdItCarries() throws {
        let events = try clearTurnEvents().filter { if case .conversationReset = $0 { return true } else { return false } }
        #expect(events == [.conversationReset(trigger: "clear", newConversationId: "00000000-0000-4000-8000-000000000095")], "\(events)")
        #expect(chatParseOne(#"{"type":"conversation_reset"}"#) == [.conversationReset(trigger: "", newConversationId: "")])
        #expect(chatParseOne(#"{"type":"conversation_reset","trigger":5}"#).count == 1)
    }

    @MainActor
    @Test func ChatOrcaD25_aRealChildsClearGivesTheDividerAndNoNoticeAndLogsTheIdsAndTheCatalogFrameArrives() async throws {
        let rig = try ChatRig(stub: "replay-clear.sh", permissions: .deny)
        var frames: [ChatCatalogFrame] = []
        rig.session.onCatalog = { frames.append($0) }
        #expect(rig.session.send("/clear"))
        #expect(rig.session.hasUnsettledSend, "the line has not been reported written yet")
        #expect(await rig.wait { rig.outcomes.count == 1 })
        #expect(!rig.session.hasUnsettledSend, "the write settled")
        #expect(rig.session.transcript.entries.map(\.kind) == [.user, .divider, .footer], "\(rig.session.transcript.entries.map(\.kind)) \(rig.texts)")
        #expect(frames.count == 1, "the init's catalog is reported once")
        if case .names(let names, _, let hidden)? = frames.first?.body { #expect(names == ["clear", "compact", "context"] && hidden.count == 4) } else { Issue.record("no names frame") }
        let line = try #require(rig.log.first { $0.hasPrefix("CHAT clear from=") })
        #expect(line.hasSuffix(" to=00000000"), "\(line)")
        #expect(rig.log.allSatisfy { !$0.contains("/clear") && !$0.contains(rig.folder) }, "the log rule: ids and counts only")
        rig.session.stop(.userStop)
        #expect(await rig.wait { rig.session.turn == .none && rig.log.contains { $0.hasPrefix("CHAT sweep") } })
    }
}
