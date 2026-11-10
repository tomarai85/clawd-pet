import Testing
import Foundation
import AppKit
import ClawdCore
import ClawdRendering
import ClawdDesktop

// The Claude Code section of the Settings window (Stage SA, Sprint SA4): Chat on or off with the line under it, the Model field, the Working
// folder (SA2) and Permissions. Every row runs the CLI verb for the same choice, through the one writer and against the stub CLI; nothing here shows
// a window, makes one key or touches the real state directory, the real claude or the real folders `claude` is searched in.

/// A stubbed `claude`: a regular executable file in a temporary folder.
private func stubbedClaude(in folder: URL, named name: String = "claude") throws -> String {
    try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
    let file = folder.appendingPathComponent(name)
    try Data("#!/bin/sh\n".utf8).write(to: file)
    try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: file.path)
    return file.path
}

private func temporaryFolder() throws -> URL {
    try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()), create: true)
}

/// Starts editing the Model field in Settings' own field editor and types `text` into it (as the user would, not yet committed).
@MainActor func typeInModel(_ r: SettingsRig, _ content: SettingsContent, _ text: String) throws -> SettingsFieldEditor {
    content.show(.claudeCode)
    let window = try r.window()
    #expect(window.makeFirstResponder(content.modelField), "the Model field takes the keyboard")
    let editor = try #require(content.modelField.currentEditor() as? SettingsFieldEditor, "the field is edited in Settings' own field editor")
    editor.string = text
    return editor
}

/// The runs of the stub CLI that were `chat model ...`.
@MainActor func modelRuns(_ r: SettingsRig) -> [[String]] { r.stub.started.filter { $0.count >= 2 && $0[0] == "chat" && $0[1] == "model" } }

@Suite("ClaudeCodeSection", .serialized)
@MainActor
struct ClaudeCodeSectionSuite {
    private func opened(control: [String: Any]? = nil, claudeSearch: [String] = []) throws -> (SettingsRig, SettingsContent) {
        let r = try SettingsRig(control: control, claudeSearch: claudeSearch)
        try r.openFromMenuBar()
        let content = try #require(r.settings.content)
        content.show(.claudeCode)
        return (r, content)
    }

    // MARK: the line under Chat with Claude Code

    @Test func ClaudeCodeSection_eachOfTheFiveLinesAppearsInItsCase() async throws {
        // The five lines as words, from the five cases of the check the chat makes before a spawn and of Q6's search.
        let places = "~/.local/bin, /opt/homebrew/bin or /usr/local/bin"
        #expect(SettingsClaudeLine.searchedPlaces == places)
        #expect(SettingsClaudeLine.text(for: .given(path: "/x/claude", resolved: "/x/claude")) == "claude found at /x/claude")
        #expect(SettingsClaudeLine.text(for: .given(path: "/x/claude", resolved: nil)) == "Claude Code not found at /x/claude")
        #expect(SettingsClaudeLine.text(for: .defaultPlace(path: "/Users/u/.local/bin/claude", resolved: "/r")) == "claude found at ~/.local/bin/claude")
        #expect(SettingsClaudeLine.text(for: .searched(path: "/opt/homebrew/bin/claude", resolved: "/r")) == "claude found at /opt/homebrew/bin/claude (found by search, not saved)")
        #expect(SettingsClaudeLine.text(for: .nowhere) == "Claude Code not found in \(places)")
        // The cases through the window, with stubbed files. (1) set and present, (2) set and missing with a claude in the search list, (4) unset and
        // found by the search, (5) unset and found nowhere. (3) needs the home folder's own `.local/bin`, which no test touches: ClaudePath_ covers it.
        let root = try temporaryFolder()
        let present = try stubbedClaude(in: root.appendingPathComponent("set"))
        let searched = try stubbedClaude(in: root.appendingPathComponent("search"))
        let empty = root.appendingPathComponent("empty").path
        try FileManager.default.createDirectory(atPath: empty, withIntermediateDirectories: true)
        let search = [empty, root.appendingPathComponent("search").path]

        let (setPresent, c1) = try opened(control: ["chatClaude": present], claudeSearch: search)
        #expect(c1.claudeLine.stringValue == "claude found at \(present)", "set and present: \(c1.claudeLine.stringValue)")
        #expect(setPresent.runtime.settingsClaudeLocation() == .given(path: present, resolved: URL(fileURLWithPath: present).resolvingSymlinksInPath().path))

        let missing = root.appendingPathComponent("gone/claude").path
        let (_, c2) = try opened(control: ["chatClaude": missing], claudeSearch: search)
        #expect(c2.claudeLine.stringValue == "Claude Code not found at \(missing)", "set and missing, though the search would find one: \(c2.claudeLine.stringValue)")

        let (_, c4) = try opened(claudeSearch: search)
        #expect(c4.claudeLine.stringValue == "claude found at \(searched) (found by search, not saved)", "unset, found by the search: \(c4.claudeLine.stringValue)")

        let (r5, c5) = try opened(claudeSearch: [empty])
        #expect(c5.claudeLine.stringValue == "Claude Code not found in \(places)", "unset, found nowhere: \(c5.claudeLine.stringValue)")
        // The line follows the settings: a `chatClaude` written while Settings is open shows at the apply.
        try writeControlLikeTheCLI(r5.rig.store.root, ["chatClaude": present])
        await r5.rig.spin(until: { c5.claudeLine.stringValue == "claude found at \(present)" }, limit: 20)
        #expect(c5.claudeLine.stringValue == "claude found at \(present)", "\(c5.claudeLine.stringValue)")
        // The search wrote nothing: control.json holds no `chatClaude` the CLI did not write, and a rig that only searched has none.
        let (r4, _) = try opened(claudeSearch: search)
        let written = (try? Data(contentsOf: r4.rig.store.root.appendingPathComponent("control.json"))) ?? Data()
        #expect(!String(decoding: written, as: UTF8.self).contains("chatClaude"), "the result of the search is never written")
        #expect(r4.cliRuns.isEmpty)
    }

    // MARK: the rows

    @Test func ClaudeCodeSection_rowsRunTheirVerbsAndStayEditableWhileOff() async throws {
        let (r, content) = try opened(control: ["chat": false])
        #expect(r.runtime.settingsValues().chatEnabled == false)
        // The rows stay editable while the chat is off.
        #expect(content.button(for: .chat(true))?.isEnabled == true && content.button(for: .chat(false))?.isEnabled == true)
        #expect(content.button(for: .permissions(.deny))?.isEnabled == true && content.button(for: .permissions(.bypass))?.isEnabled == true)
        #expect(content.modelField.isEnabled && content.modelField.isEditable && content.chooseButton.isEnabled)
        #expect(content.button(for: .chat(false))?.state == .on && content.button(for: .chat(true))?.state == .off, "Off is the shown state")
        #expect(content.button(for: .permissions(.deny))?.state == .on, "Refuse is the default")
        // Each control runs the verb of the same choice, under its own queue key (one per control.json key).
        for (choice, verb, queueKey) in [(SettingsChoice.chat(true), ["chat", "on"], "chat"), (.chat(false), ["chat", "off"], "chat"),
                                         (.permissions(.bypass), ["chat", "permissions", "bypass"], "chatPermissions"),
                                         (.permissions(.deny), ["chat", "permissions", "deny"], "chatPermissions")] {
            let args = try await pressChoice(r, content, choice)
            #expect(args == verb, "\(choice): \(args)")
            let action = SettingsActions.action(for: choice, shownOn: true)
            #expect(action.arguments == verb && action.queueKey == queueKey, "\(choice): \(action)")
        }
        // The model: the field's own text, empty meaning `chat model default`; the writer's log names the verb and never the model.
        let editor = try typeInModel(r, content, "sonnet")
        let before = finishedWrites(r)
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        await r.rig.spin(until: { finishedWrites(r) > before }, limit: 60)
        #expect(modelRuns(r) == [["chat", "model", "sonnet"]], "\(r.stub.started)")
        let writes = r.lines("MENU write ")
        #expect(writes.last?.contains("key=chatModel") == true && writes.last?.contains("verb=chat+model") == true, "\(writes)")
        #expect(r.lines("MENU").allSatisfy { !$0.contains("sonnet") } && r.lines("SETTINGS").allSatisfy { !$0.contains("sonnet") }, "no log line carries the model")
        try writeControlLikeTheCLI(r.rig.store.root, ["chatModel": "sonnet"])
        await r.rig.spin(until: { r.runtime.settingsValues().chatModel == "sonnet" }, limit: 20)
        editor.string = ""
        let again = finishedWrites(r)
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        await r.rig.spin(until: { finishedWrites(r) > again }, limit: 60)
        #expect(modelRuns(r) == [["chat", "model", "sonnet"], ["chat", "model", "default"]], "\(r.stub.started)")
        // The queue keys: with the writer held, every row of the section queues behind the one that runs and nothing replaces another.
        let gate = r.stub.root.appendingPathComponent("release")
        try r.stub.set("stub-release", gate.path)
        let held = finishedWrites(r), drops = r.lines("MENU drop").count
        press(try #require(content.button(for: .chat(true))))
        press(try #require(content.button(for: .permissions(.bypass))))
        editor.string = "opus"
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(r.lines("MENU drop").count == drops, "three rows, three queue keys: \(r.lines("MENU drop"))")
        try r.stub.set("release", "")
        await r.rig.spin(until: { finishedWrites(r) >= held + 3 }, limit: 60)
        #expect(Array(r.stub.started.suffix(3)) == [["chat", "on"], ["chat", "permissions", "bypass"], ["chat", "model", "opus"]], "\(r.stub.started)")
        // The allowed list names these verbs and no others of the chat.
        for good in [["chat", "on"], ["chat", "off"], ["chat", "permissions", "deny"], ["chat", "permissions", "bypass"], ["chat", "model", "x"], ["chat", "model", "default"]] {
            #expect(isAllowedSettingsVerb(good), "\(good)")
        }
        for bad in [["chat", "claude", "/x"], ["chat", "view", "terminal"], ["chat", "queue", "on"], ["chat", "permissions", "ask"], ["chat", "model"], ["chat", "on", "x"]] {
            #expect(!isAllowedSettingsVerb(bad), "\(bad)")
        }
    }

    // MARK: the Model field

    @Test func ClaudeCodeSection_theModelFieldCommitsOnlyOnReturnOrFocusChangeAndOnlyWhenChanged() async throws {
        let (r, content) = try opened()
        let window = try r.window()
        #expect((content.modelField.cell as? NSTextFieldCell)?.sendsActionOnEndEditing == false, "the field sends nothing when editing ends")
        // Return commits the text once; the same text again is not a change.
        let editor = try typeInModel(r, content, "son")
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        await r.rig.spin(until: { modelRuns(r).count == 1 }, limit: 60)
        #expect(modelRuns(r) == [["chat", "model", "son"]], "\(r.stub.started)")
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        await r.rig.spin(0.3)
        #expect(modelRuns(r).count == 1, "Return with the text it already committed runs nothing")
        // Tab commits a changed text and lets the focus move on (AppKit's own key-view move ends the editing); Shift-Tab does too.
        let tab = try typeInModel(r, content, "tab")
        tab.doCommand(by: #selector(NSResponder.insertTab(_:)))
        await r.rig.spin(until: { modelRuns(r).count == 2 }, limit: 60)
        #expect(modelRuns(r).last == ["chat", "model", "tab"], "\(r.stub.started)")
        let back = try typeInModel(r, content, "back")
        back.doCommand(by: #selector(NSResponder.insertBacktab(_:)))
        await r.rig.spin(until: { modelRuns(r).count == 3 }, limit: 60)
        #expect(modelRuns(r).last == ["chat", "model", "back"])
        let same = try typeInModel(r, content, "back")
        same.doCommand(by: #selector(NSResponder.insertTab(_:)))
        await r.rig.spin(0.3)
        #expect(modelRuns(r).count == 3, "Tab with an unchanged text runs nothing")
        // A left mouse-down that moves the first responder away from the field commits; one that leaves it where it is does not.
        // The click goes through `route`, the body of SettingsWindow.sendEvent, with a dispatch that does what the clicked view's mouse-down
        // would: a synthetic event sent to this off-screen window reaches no view, and showing or keying a window is banned here (SA4 M-1).
        // SettingsWindow_sendEventIsOnlyTheRouteAroundAppKitsDispatch checks that sendEvent's body is `route` around AppKit's dispatch.
        let down = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: NSPoint(x: 5, y: 5), modifierFlags: [], timestamp: 300,
                                                   windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        let clicked = try typeInModel(r, content, "click")
        window.route(down) { _ in }
        await r.rig.spin(0.3)
        #expect(modelRuns(r).count == 3, "a click that did not move the focus commits nothing")
        #expect(window.firstResponder === clicked, "the field editor still has the focus")
        var moved = false
        window.route(down) { _ in moved = window.makeFirstResponder(content.sidebar) }
        #expect(moved)
        await r.rig.spin(until: { modelRuns(r).count == 4 }, limit: 60)
        #expect(modelRuns(r).last == ["chat", "model", "click"], "\(r.stub.started)")
        #expect(content.modelField.stringValue == "click")
        // Whitespace around the name is not part of it.
        let spaced = try typeInModel(r, content, "  haiku \n")
        spaced.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        await r.rig.spin(until: { modelRuns(r).count == 5 }, limit: 60)
        #expect(modelRuns(r).last == ["chat", "model", "haiku"], "\(r.stub.started)")
        // Editing that ends for any other reason commits nothing and leaves the text in the field: the input gate's release of the keyboard, the
        // window losing key, Clawd losing activation.
        let other = try typeInModel(r, content, "other")
        #expect(window.makeFirstResponder(nil))
        #expect(content.modelField.stringValue == "other", "the text stays in the field")
        _ = other
        let reedit = try typeInModel(r, content, "resign")
        r.post(NSWindow.didResignKeyNotification, window)
        r.resign()
        #expect(window.makeFirstResponder(nil) && content.modelField.stringValue == "resign")
        _ = reedit
        await r.rig.spin(0.4)
        #expect(modelRuns(r).count == 5, "no other end of editing commits: \(r.stub.started)")
        // A refused name puts the field back to what the pet runs with, with the CLI's one line under it.
        try r.stub.set("stub-exit", "2")
        let refused = try typeInModel(r, content, "bad name!")
        refused.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        #expect(content.isPending(.model))
        await r.rig.spin(until: { modelRuns(r).count == 6 && !content.isPending(.model) }, limit: 60)
        #expect(content.message(for: .model) == "the stub fails with 2", "\(content.message(for: .model))")
        #expect(window.makeFirstResponder(nil) && content.modelField.stringValue == "", "the refused text is gone: \(content.modelField.stringValue)")
        // Marked text: Return and Esc end the composition; they neither commit nor close Settings.
        try r.stub.set("stub-exit", "0")
        let composing = try typeInModel(r, content, "")
        composing.setMarkedText("か", selectedRange: NSRange(location: 1, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(composing.hasMarkedText())
        composing.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        composing.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        await r.rig.spin(0.3)
        #expect(modelRuns(r).count == 6 && r.settings.isOpen, "a composition's Return and Esc commit nothing and close nothing")
        composing.unmarkText()
        composing.string = ""
        composing.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(!r.settings.isOpen && r.lines("SETTINGS close reason=esc").count == 1, "Esc with no composition is the window's Esc: \(r.lines("SETTINGS"))")
    }

    @Test func ClaudeCodeSection_aCloseDiscardsUncommittedText() async throws {
        // Each way of closing, with the field holding text nobody committed: nothing is written, and the next open shows what the pet runs with.
        for reason in SettingsCloseReason.allCases where reason != .quit {
            let (r, content) = try opened(control: ["chatModel": "opus"])
            #expect(content.modelField.stringValue == "opus")
            let editor = try typeInModel(r, content, "son")
            #expect(editor.string == "son")
            r.settings.close(reason)
            await r.rig.spin(0.3)
            #expect(modelRuns(r).isEmpty && r.cliRuns.isEmpty, "\(reason): a close commits nothing: \(r.stub.started)")
            try r.openFromMenuBar()
            let again = try #require(r.settings.content)
            again.show(.claudeCode)
            #expect(again.modelField.stringValue == "opus", "\(reason): the text was discarded: \(again.modelField.stringValue)")
            #expect(modelRuns(r).isEmpty)
        }
        // Quit closes too (the runtime's quit follows).
        let (r, content) = try opened()
        _ = try typeInModel(r, content, "quit-text")
        r.settings.close(.quit)
        await r.rig.spin(0.3)
        #expect(modelRuns(r).isEmpty)
    }

    @Test func ClaudeCodeSection_theGateEndsEditingWithoutCommitting() async throws {
        let (r, content) = try opened()
        let window = try r.window()
        let editor = try typeInModel(r, content, "son")
        #expect(window.firstResponder === editor)
        // A key waits for the activation: the window holds the keyboard, so no text view holds it. Editing ends and nothing is committed.
        r.post(NSWindow.didBecomeKeyNotification, window)      // the open's own key spends the cause's key
        r.post(NSApplication.willBecomeActiveNotification, nil)
        r.post(NSWindow.didBecomeKeyNotification, window)
        #expect(window.firstResponder === window && content.modelField.currentEditor() == nil, "editing ended")
        #expect(content.modelField.stringValue == "son", "the text stays in the field")
        await r.rig.spin(0.3)
        #expect(modelRuns(r).isEmpty && r.cliRuns.isEmpty, "the gate committed nothing: \(r.stub.started)")
        // An exempt verdict puts the keyboard back in the field with its text, still uncommitted.
        r.focus.active = true
        r.post(NSApplication.didBecomeActiveNotification, nil)
        #expect(r.lines("SETTINGS active cause=open").count == 1, "\(r.lines("SETTINGS"))")
        #expect(content.modelField.currentEditor() != nil && window.firstResponder === content.modelField.currentEditor(), "the field is edited again")
        #expect(content.modelText == "son" && content.modelField.stringValue == "son")
        await r.rig.spin(0.3)
        #expect(modelRuns(r).isEmpty && r.cliRuns.isEmpty, "the verdict committed nothing: \(r.stub.started)")
        // An uncaused verdict leaves the window as its own first responder, the text in the field, and nothing written.
        let u = try opened()
        let held = try u.0.window()
        _ = try typeInModel(u.0, u.1, "son")
        u.0.post(NSWindow.didBecomeKeyNotification, held)
        u.0.advance(2)
        u.0.post(NSApplication.willBecomeActiveNotification, nil)
        u.0.post(NSWindow.didBecomeKeyNotification, held)
        u.0.focus.drain()
        #expect(u.0.violations == 1 && held.firstResponder === held && u.1.modelField.stringValue == "son", "\(u.0.lines("SETTINGS"))")
        await u.0.rig.spin(0.3)
        #expect(modelRuns(u.0).isEmpty && u.0.cliRuns.isEmpty)
    }

    // MARK: the text contract

    @Test func ClaudeCodeSection_theModelFieldTakesTheChatsTextContract() throws {
        let (r, content) = try opened()
        let editor = try typeInModel(r, content, "x")
        #expect(editor === (try r.window()).fieldEditor(true, for: content.modelField), "Settings' own editor serves the field")
        #expect(editor.contractViolations.isEmpty, "\(editor.contractViolations)")
        #expect(editor.menu == nil && editor.assignedMenu == nil)
        let probe = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil,
                                                    eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(editor.menu(for: probe) == nil, "no context menu")
        #expect(!editor.isAutomaticSpellingCorrectionEnabled && !editor.isAutomaticQuoteSubstitutionEnabled && !editor.isAutomaticDashSubstitutionEnabled)
        #expect(!editor.isAutomaticTextReplacementEnabled && !editor.isAutomaticTextCompletionEnabled && !editor.isContinuousSpellCheckingEnabled && !editor.isGrammarCheckingEnabled)
        editor.menu = NSMenu(title: "x")
        #expect(editor.contractViolations.contains { $0.contains("context menu") } && editor.menu == nil, "an assigned menu is found and never shown")
        editor.menu = nil
    }
}
