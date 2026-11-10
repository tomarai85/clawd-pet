import Testing
import Foundation
@testable import ClawdCore

struct ChatHostCommandResumeTests {
    private func decide(_ text: String, chips: Bool = false, turn: Bool = false, unsettled: Bool = false) -> ChatHostCommand.Decision {
        ChatHostCommand.decide(text, hasChips: chips, turnActive: turn, sendUnsettled: unsettled, chatFolderIsHome: false)
    }

    @Test func ChatHostCommand_resumeAndContinueAreClaimed() {
        #expect(decide("/resume") == .openResume)
        #expect(decide("/Resume") == .openResume)
        #expect(decide("/continue") == .openResume)
        #expect(decide("/resume   ") == .openResume)
        #expect(decide("/resume x") == .resume("x"))
        #expect(decide("/continue some words") == .resume("some words"))
        #expect(decide("/resumes") == .text)
        #expect(decide("/resume x\ny") == .text, "a multi-line argument is text, as Orca's commandParts has it")
        // Typing the argument is refused in Orca's order; opening the list is harmless.
        #expect(decide("/resume x", chips: true, turn: true, unsettled: true) == .refuse(ChatHostCommand.attachmentsRefusal))
        #expect(decide("/resume x", turn: true, unsettled: true) == .refuse(ChatHostCommand.turnRefusal))
        #expect(decide("/resume x", unsettled: true) == .refuse(ChatHostCommand.unsettledRefusal))
        #expect(decide("/resume", chips: true, turn: true) == .openResume)
        #expect(ChatHostCommand.resumeRefusal(hasChips: false, turnActive: false, sendUnsettled: false) == nil)
    }

    @Test func ChatCatalog_theResumeRowIsOfferedOnceBeforeAndAfterAReport() {
        var catalog = ChatCatalog()
        #expect(catalog.pickerEntries.filter { $0.name == "resume" }.count == 1)
        let frame = ChatCatalogFrame(.names(slashCommands: ["help", "compact"], skills: [], terminal: []))
        _ = catalog.observe(frame)
        #expect(catalog.entries?.contains { $0.name == "resume" } == false, "never saved or reported")
        let shown = catalog.pickerEntries
        #expect(shown.filter { $0.name == "resume" }.count == 1 && shown.last?.name == "resume")
        #expect(shown.last?.description == "Resume a previous conversation" && shown.last?.argumentHint == "[conversation id or search term]")
        let own = ChatCatalog(saved: [ChatCommandEntry(name: "resume", kind: .command, description: "Theirs")])
        #expect(own.pickerEntries.filter { $0.name == "resume" }.count == 1)
    }

    @Test func ChatPicker_resumeWithASpaceIsTheConversationsMode() {
        func mode(_ text: String, caret: Int? = nil) -> String {
            switch ChatAutocomplete.derive(draft: text, caret: caret ?? text.utf16.count, entries: ChatCatalog.fallback, dismissedKey: nil) {
            case .none: return "none"
            case .slash: return "slash"
            case .mention: return "mention"
            case .conversations(let value): return "conversations:\(value.command):\(value.query)"
            }
        }
        #expect(mode("/resume") == "slash")
        #expect(mode("/resume ") == "conversations:resume:")
        #expect(mode("/Resume \t  login") == "conversations:resume:login")
        #expect(mode(" /resume ") == "none")
        #expect(mode("x /resume ") == "none")
        #expect(mode("/continue q") == "conversations:continue:q")
        #expect(mode("/resume q\nmore") == "none", "one line only")
        #expect(mode("/resume q", caret: 7) == "slash", "the caret is before the space")
        #expect(mode("/resumes ") == "none")
        // Loading, then rows, none, no match.
        func rows(_ list: [ChatResumeRow]?, _ text: String) -> ChatAutocomplete.Conversations? {
            if case .conversations(let value) = ChatAutocomplete.derive(draft: text, caret: text.utf16.count, entries: [], dismissedKey: nil, resume: list) { return value }
            return nil
        }
        let a = ChatResumeRow(id: "11111111-2222-4333-8444-555555555555", title: "Fix parser", subtitle: "3 hr. ago", folder: "/f", modified: Date())
        #expect(rows(nil, "/resume ")?.status == .loading)
        #expect(rows([], "/resume ")?.status == ChatAutocomplete.Conversations.Status.none)
        #expect(rows([a], "/resume zzz")?.status == .noMatch("zzz"))
        let shown = rows([a], "/resume pars")
        #expect(shown?.status == nil && shown?.items.map(\.name) == ["Fix parser"] && shown?.items.first?.conversationId == a.id && shown?.items.first?.kind == .conversation)
        // The state asks for the list once per entry and drops the rows when the mode closes.
        var state = ChatAutocompleteState()
        state.refresh(text: "/resume", caret: 7, marked: false)
        let early = state.takeListWanted()
        #expect(!early)
        state.refresh(text: "/resume ", caret: 8, marked: false)
        let first = state.takeListWanted(), again = state.takeListWanted()
        #expect(first && !again)
        state.setResumeRows([a])
        state.refresh(text: "/resume f", caret: 9, marked: false)
        let same = state.takeListWanted()
        #expect(!same && state.items.count == 1 && state.resumeRows != nil)
        state.dismiss()
        let closed = state.takeListClosed()
        #expect(closed && state.resumeRows == nil && !state.isOpen)
        state.refresh(text: "/resume fi", caret: 10, marked: false)
        let stillDismissed = state.takeListWanted()
        #expect(!state.isOpen && !stillDismissed, "still dismissed")
        state.refresh(text: "", caret: 0, marked: false)
        state.refresh(text: "/resume ", caret: 8, marked: false)
        let reentered = state.takeListWanted()
        #expect(reentered, "a new entry loads again")
    }
}
