import Testing
import Foundation
import AppKit
import ClawdCore
import ClawdRendering
import ClawdDesktop

// The focus rules of the Settings window (design 4.5): who is asked about an activation and a key, in what order, with what cause, and how the
// window hands activation back. Tests post notifications on the rig's own centre and drive the chat's seams through FakeChatFocus; no window is
// ever made key or shown, and nothing activates an application.

/// A window that is a sheet on the picker's window.
final class SheetOnPicker: NSWindow {
    var pickerParent: NSWindow?
    override var sheetParent: NSWindow? { pickerParent }
}

@MainActor
extension SettingsRig {
    /// The chat open, its key posted as the system would at the open.
    func openChat(at time: TimeInterval = 1) throws {
        machine.onChatKey = { [unowned self] panel in self.post(NSWindow.didBecomeKeyNotification, panel) }
        runtime.chatController.toggle(eventTime: time)
        #expect(runtime.chatPanelIsOpen)
    }
    var chatPanel: ChatPanel? { runtime.chatPanel }
    var now: TimeInterval { rig.virtualClock?.now ?? 0 }
    func advance(_ seconds: TimeInterval) { rig.advance(seconds) }
    /// The number of log lines that are exactly `line` (`lines` matches a prefix, and "SETTINGS key" is the prefix of its two variants).
    func count(_ line: String) -> Int { lines(line).filter { $0 == line }.count }
    /// Settings open with the key posted at its open, as the system does.
    func openPostingKey() throws {
        box.onKey = { [unowned self] window in self.post(NSWindow.didBecomeKeyNotification, window) }
        try openFromMenuBar()
    }
}

@Suite("SettingsFocus", .serialized)
@MainActor
struct SettingsFocusSuite {
    /// One chat view's input gate (N2).
    private func gate(_ name: String, controller: ChatController, focus: FakeChatFocus, advance: (TimeInterval) -> Void, open: () -> Void,
                      input: (ChatPanel) -> NSResponder?, text: () -> String, prepare: () -> Void) throws {
        for exempt in [true, false] {
            open()
            prepare()
            let panel = try #require(controller.livePanel, "\(name)")
            let before = text()
            advance(2)
            controller.appWillBecomeActive()
            #expect(controller.keyVerdict(for: panel) == .deferred, "\(name): the key waits for the activation")
            #expect(panel.firstResponder === panel, "\(name): the panel is its own first responder while the key waits")
            #expect(panel.firstResponder?.tryToPerform(#selector(NSText.paste(_:)), with: nil) == false, "\(name): a paste finds no target")
            #expect(!(panel.firstResponder is NSText) && !(panel.firstResponder is NSTextView), "\(name): no text view holds the keyboard")
            #expect(text() == before, "\(name): the composer's text is unchanged")
            if exempt {
                controller.activationClaimedElsewhere()
                #expect(panel.firstResponder === input(panel), "\(name): an exempt verdict puts the input back")
                controller.close(.toggle)
            } else {
                #expect(controller.closeUnclaimedActivation() == .answeredByClose)
                focus.drain()
                #expect(!controller.isOpen, "\(name): an uncaused verdict closes the chat")
            }
        }
    }

    // MARK: claim order

    @Test func SettingsFocus_settingsIsAskedBeforeTheChatSoAPressOnSettingsIsNeverTheChats() throws {
        let r = try SettingsRig()
        try r.openChat()
        r.advance(2)
        try r.openFromMenuBar()
        r.advance(2)
        let window = try r.window()
        // A press of the session newer than the chat's open that went to one of Clawd's windows: the chat's own click test would take it.
        r.focus.pressAt = r.now - 0.1
        r.mouseDown(in: window)
        r.clawdBecomesActive()
        #expect(r.lines("SETTINGS active cause=click").count == 1, "\(r.lines("SETTINGS"))")
        #expect(r.lines("CHAT active").isEmpty && r.lines("CHAT close").isEmpty, "\(r.lines("CHAT"))")
        r.focus.drain()
        #expect(r.runtime.chatPanelIsOpen && r.violations == 0)
    }

    @Test func SettingsFocus_withSettingsCauseLiveAndTheChatOpenTheActivationIsSettings() throws {
        let r = try SettingsRig()
        try r.openChat()
        try r.openFromMenuBar()
        r.clawdBecomesActive()
        #expect(r.lines("SETTINGS active cause=open").count == 1, "\(r.lines("SETTINGS"))")
        #expect(r.lines("CHAT active").isEmpty && r.lines("CHAT close").isEmpty, "the chat's own token is not spent by Settings' activation: \(r.lines("CHAT"))")
        r.focus.drain()
        #expect(r.runtime.chatPanelIsOpen && r.violations == 0)
    }

    @Test func SettingsFocus_settingsFromTheMenuBarKeepsAnInactiveChatOpen() throws {
        let r = try SettingsRig()
        try r.openChat()
        r.advance(2)
        try r.openFromMenuBar()
        r.clawdBecomesActive()
        r.focus.drain()
        #expect(r.runtime.chatPanelIsOpen && r.lines("CHAT close").isEmpty && r.violations == 0, "\(r.lines("CHAT"))")
        // The chat's own answer, asked alone, declines and changes nothing: its close belongs to the unclaimed step.
        #expect(!r.runtime.chatController.activationClaim())
        r.focus.drain()
        #expect(r.runtime.chatPanelIsOpen && r.lines("CHAT close").isEmpty, "a declined claim closes nothing: \(r.lines("CHAT"))")
    }

    // MARK: the unclaimed step

    @Test func SettingsFocus_anActivationNoSurfaceClaimsStillClosesTheChatAndIsRecordedAtOnce() throws {
        let r = try SettingsRig()
        var handbacks = 0
        r.rig.monitor.onViolation = { handbacks += 1 }
        try r.openChat()
        r.advance(2)
        try r.openFromMenuBar()
        r.advance(2)
        r.clawdBecomesActive()
        #expect(r.violations == 1 && r.lines("FOCUS_VIOLATION trigger").count == 1, "recorded in the notification itself: \(r.lines("FOCUS"))")
        #expect(handbacks == 0, "the chat answers by closing, so the production hand-back does not run")
        r.focus.drain()
        #expect(!r.runtime.chatPanelIsOpen && r.lines("CHAT close reason=outside").count == 1, "\(r.lines("CHAT"))")
        #expect(r.lines("SETTINGS active").isEmpty && r.settings.isOpen)
    }

    @Test func SettingsFocus_withTheChatClosedAnUnclaimedActivationIsAViolationAndRunsOnViolation() throws {
        let r = try SettingsRig()
        var handbacks = 0
        r.rig.monitor.onViolation = { handbacks += 1 }
        try r.openFromMenuBar()
        r.advance(2)
        r.clawdBecomesActive()
        #expect(r.violations == 1 && handbacks == 1, "\(r.violations) \(handbacks)")
        #expect(r.settings.isOpen, "Settings stays open")
    }

    // MARK: step 2: the other surfaces are told

    @Test func SettingsFocus_aChatKeyThatWaitedOnSettingsClaimIsAReturn() throws {
        let r = try SettingsRig()
        try r.openChat()
        r.advance(2)
        try r.openFromMenuBar()
        let panel = try #require(r.chatPanel)
        r.post(NSApplication.willBecomeActiveNotification, nil)
        r.post(NSWindow.didBecomeKeyNotification, panel)
        #expect(r.violations == 0 && r.lines("CHAT key-uncaused").isEmpty, "the key waits for the activation")
        r.focus.active = true
        r.post(NSApplication.didBecomeActiveNotification, nil)
        #expect(r.lines("SETTINGS active cause=open").count == 1)
        #expect(r.lines("CHAT key gen=1").count == 2 && r.lines("CHAT key-uncaused").isEmpty, "the waiting key rode Settings' claim: \(r.lines("CHAT"))")
        r.focus.drain()
        #expect(r.runtime.chatPanelIsOpen && r.violations == 0 && r.lines("CHAT close").isEmpty)
    }

    @Test func SettingsFocus_afterSettingsClaimsTheChatKnowsClawdIsInFront() throws {
        let r = try SettingsRig()
        try r.openChat()
        r.advance(2)
        try r.openFromMenuBar()
        r.clawdBecomesActive()
        #expect(r.lines("SETTINGS active cause=open").count == 1)
        // An input method takes the activation and gives it back to Clawd.
        r.resign()
        r.focus.otherAppBecomesActive(ChatAppRef(pid: 5001, launchDate: nil, bundleID: "com.apple.inputmethod.Kotoeri.RomajiTyping"))
        r.advance(0.2)
        r.clawdBecomesActive()
        #expect(r.lines("CHAT active gen=1 cause=return").count == 1, "\(r.lines("CHAT"))")
        r.focus.drain()
        #expect(r.runtime.chatPanelIsOpen && r.lines("CHAT close").isEmpty && r.violations == 0, "\(r.lines("CHAT"))")
    }

    // MARK: the claim record

    @Test func SettingsFocus_insideSettingsClaimAKeyMovingToTheChatIsAReturnWhateverTheEvent() throws {
        let r = try SettingsRig()
        try r.openChat()
        r.advance(2)
        try r.openFromMenuBar()
        let settingsWindow = try r.window()
        r.clawdBecomesActive()
        let panel = try #require(r.chatPanel)
        let events: [(String, ChatCurrentEvent?)] = [
            ("Cmd-W", ChatCurrentEvent(isMouseDown: false, window: settingsWindow, isMouse: false, modifiers: [.command], timestamp: 5)),
            ("Esc", ChatCurrentEvent(isMouseDown: false, window: settingsWindow, isMouse: false, timestamp: 6)),
            ("the close button", ChatCurrentEvent(isMouseDown: true, window: settingsWindow, timestamp: 7)),
            ("no event", nil),
        ]
        for (name, event) in events {
            r.machine.chatEvent = event
            let before = r.lines("CHAT key").count
            r.post(NSWindow.didBecomeKeyNotification, panel)
            let added = Array(r.lines("CHAT key").dropFirst(before))
            #expect(added.count == 1 && !added[0].contains("key-uncaused"), "\(name): \(r.lines("CHAT"))")
            #expect(name == "no event" ? added[0].hasPrefix("CHAT key-returned") : added[0].hasPrefix("CHAT key gen=1"), "\(name): \(added)")
        }
        r.focus.drain()
        #expect(r.violations == 0 && r.runtime.chatPanelIsOpen && r.lines("CHAT close").isEmpty)
    }

    @Test func SettingsFocus_aChatOpenedAfterSettingsClaimInTheSameActivationTakesKeyAsAReturn() throws {
        let r = try SettingsRig()
        try r.openFromMenuBar()
        r.clawdBecomesActive()
        #expect(r.lines("SETTINGS active cause=open").count == 1)
        // The chat opens inside that activation: its own activation record starts inactive.
        try r.openChat(at: 3)
        r.advance(2)
        let panel = try #require(r.chatPanel)
        r.machine.chatEvent = nil
        r.post(NSWindow.didBecomeKeyNotification, panel)
        #expect(r.lines("CHAT key-returned gen=1").count == 1 && r.lines("CHAT key-uncaused").isEmpty, "\(r.lines("CHAT"))")
        #expect(r.violations == 0)
    }

    @Test func SettingsFocus_aKeyThatMovesToSettingsAfterResignActiveIsRecorded() throws {
        let r = try SettingsRig()
        try r.openFromMenuBar()
        r.clawdBecomesActive()
        r.advance(2)
        r.resign()
        r.focus.active = true
        r.machine.chatEvent = nil
        let window = try r.window()
        r.post(NSWindow.didBecomeKeyNotification, window)
        #expect(r.lines("SETTINGS key-uncaused").count == 1 && r.violations == 1, "the claim ended with the resign: \(r.lines("SETTINGS"))")
    }

    @Test func SettingsFocus_aKeySettingsGetsDuringTheChatsEscCloseIsAReturn() throws {
        let r = try SettingsRig()
        try r.openChat()
        try r.openFromMenuBar()
        r.clawdBecomesActive()
        r.advance(2)
        let panel = try #require(r.chatPanel)
        let window = try r.window()
        // Esc closes the chat; AppKit moves the key to Settings while Clawd is still active.
        panel.onEscape?()
        #expect(!r.runtime.chatPanelIsOpen)
        r.machine.chatEvent = nil
        r.post(NSWindow.didBecomeKeyNotification, window)
        #expect(r.lines("SETTINGS key-returned").count == 1 && r.lines("SETTINGS key-uncaused").isEmpty, "\(r.lines("SETTINGS"))")
        #expect(r.violations == 0)
    }

    // MARK: waiting keys and the input gate

    @Test func SettingsFocus_aWaitingKeyHoldsNoInputUntilTheVerdict() async throws {
        // The chat in each of its three views: while a key waits the panel is its own first responder, a paste finds no target and no text view
        // or terminal view holds the keyboard; an exempt verdict puts the input back, an uncaused one closes the chat.
        let stream = ControllerRig()
        stream.chatSettings.view = .stream
        try gate("stream", controller: stream.controller, focus: stream.focus, advance: { stream.clock.advance($0) }, open: { stream.open() },
                 input: { $0.chatView.inputView }, text: { stream.controller.livePanel?.chatView.inputText ?? "" }, prepare: { if stream.view.inputText.isEmpty { stream.type("typed") } })
        let web = WebKindRig()
        try gate("chat", controller: web.controller, focus: web.rig.focus, advance: { web.rig.clock.advance($0) }, open: { web.rig.open() },
                 input: { $0.terminal?.webBody?.inputView }, text: { web.body?.inputView.string ?? "" }, prepare: { if web.body?.inputView.string.isEmpty == true { web.type("typed") } })
        let term = try TermControllerRig()
        try gate("terminal", controller: term.controller, focus: term.focus, advance: { term.clock.advance($0) }, open: { term.open() },
                 input: { $0.terminal?.terminalView }, text: { "" }, prepare: {})
        await term.finish()
        // Settings: the sidebar table is the previous first responder.
        let r = try SettingsRig()
        try r.openFromMenuBar()
        let window = try r.window()
        let content = try #require(r.settings.content)
        #expect(window.firstResponder === content.sidebar)
        r.post(NSWindow.didBecomeKeyNotification, window)      // the open's own key spends the cause's key
        r.post(NSApplication.willBecomeActiveNotification, nil)
        r.post(NSWindow.didBecomeKeyNotification, window)
        #expect(r.violations == 0, "the second key waits for the activation")
        #expect(window.firstResponder === window, "the window is its own first responder while the key waits")
        #expect(window.firstResponder?.tryToPerform(#selector(NSText.paste(_:)), with: nil) == false, "a paste finds no target")
        #expect(!(window.firstResponder is NSText), "typed text finds no text view")
        r.focus.active = true
        r.post(NSApplication.didBecomeActiveNotification, nil)
        #expect(r.lines("SETTINGS active cause=open").count == 1 && window.firstResponder === content.sidebar, "an exempt verdict puts the input back: \(r.lines("SETTINGS"))")
        // An uncaused verdict leaves the window without a first responder of its own.
        let u = try SettingsRig()
        try u.openFromMenuBar()
        let held = try u.window()
        u.post(NSWindow.didBecomeKeyNotification, held)
        u.advance(2)
        u.post(NSApplication.willBecomeActiveNotification, nil)
        u.post(NSWindow.didBecomeKeyNotification, held)
        #expect(held.firstResponder === held)
        u.focus.drain()
        #expect(u.lines("SETTINGS key-uncaused").count == 1 && u.violations == 1 && held.firstResponder === held, "\(u.lines("SETTINGS"))")
        #expect(u.settings.isOpen, "Settings stays open")
        // SA4 (M-2): the same with the Model field as Settings' first responder. While a key waits the window holds the keyboard, the field's editing
        // has ended with its text still in it, and nothing was committed; an exempt verdict puts the field back; an uncaused one leaves it out.
        let m = try SettingsRig()
        try m.openFromMenuBar()
        let modelWindow = try m.window()
        let modelContent = try #require(m.settings.content)
        modelContent.show(.claudeCode)
        #expect(modelWindow.makeFirstResponder(modelContent.modelField))
        let editor = try #require(modelContent.modelField.currentEditor())
        editor.string = "son"
        #expect(modelWindow.firstResponder === editor)
        m.post(NSWindow.didBecomeKeyNotification, modelWindow)      // the open's own key spends the cause's key
        m.post(NSApplication.willBecomeActiveNotification, nil)
        m.post(NSWindow.didBecomeKeyNotification, modelWindow)
        #expect(m.violations == 0 && modelWindow.firstResponder === modelWindow, "the window is its own first responder while the key waits")
        #expect(!(modelWindow.firstResponder is NSText) && modelWindow.firstResponder?.tryToPerform(#selector(NSText.paste(_:)), with: nil) == false, "typed text and a paste find no target")
        #expect(modelContent.modelField.stringValue == "son" && m.cliRuns.isEmpty, "the text stays and nothing was committed: \(m.stub.calls)")
        m.focus.active = true
        m.post(NSApplication.didBecomeActiveNotification, nil)
        #expect(m.lines("SETTINGS active cause=open").count == 1 && modelWindow.firstResponder === modelContent.modelField.currentEditor(), "an exempt verdict puts the Model field back: \(m.lines("SETTINGS"))")
        #expect(modelContent.modelText == "son" && m.cliRuns.isEmpty)
    }

    @Test func SettingsFocus_aFolderChosenWhileAVerdictIsPendingWritesNothing() async throws {
        let r = try SettingsRig()
        try r.openFromMenuBar()
        let content = try #require(r.settings.content)
        press(content.chooseButton)
        let picker = r.picker
        r.post(NSApplication.willBecomeActiveNotification, nil)
        picker.choose("/private/tmp/clawd-pending-choice")
        await r.rig.spin(0.3)
        #expect(r.cliRuns.isEmpty, "nothing was written while the verdict was pending: \(r.stub.calls)")
        #expect(!picker.isUp)
        press(content.chooseButton)
        #expect(r.box.pickers.count == 2 && r.picker.isUp, "the picker can be opened again")
    }

    // MARK: causes

    @Test func SettingsFocus_theMenuBarPickArmsAOneShotCauseSpentByTheFirstKeyAndActivation() throws {
        // Keys: the first is the open's, the second has no cause.
        let keys = try SettingsRig()
        try keys.openFromMenuBar()
        let window = try keys.window()
        keys.post(NSWindow.didBecomeKeyNotification, window)
        #expect(keys.count("SETTINGS key") == 1 && keys.violations == 0)
        keys.post(NSWindow.didBecomeKeyNotification, window)
        #expect(keys.lines("SETTINGS key-uncaused").count == 1 && keys.violations == 1, "\(keys.lines("SETTINGS"))")
        // Activations: the first is the open's, the next has no cause.
        let activations = try SettingsRig()
        try activations.openFromMenuBar()
        activations.clawdBecomesActive()
        #expect(activations.lines("SETTINGS active cause=open").count == 1 && activations.violations == 0)
        activations.resign()
        activations.clawdBecomesActive()
        #expect(activations.lines("SETTINGS active").count == 1 && activations.violations == 1, "\(activations.lines("SETTINGS"))")
        #expect(activations.lines("SETTINGS open").first?.contains("cause=status-menu") == true)
    }

    @Test func SettingsFocus_theRightClickPickArmsTheSameCauseAtTheFlashClose() throws {
        let r = try SettingsRig()
        r.runtime.menuOpenSettings(eventTime: 3)
        #expect(r.lines("SETTINGS open").first?.contains("cause=right-click") == true)
        let window = try r.window()
        r.post(NSWindow.didBecomeKeyNotification, window)
        r.clawdBecomesActive()
        #expect(r.count("SETTINGS key") == 1 && r.lines("SETTINGS active cause=open").count == 1 && r.violations == 0, "\(r.lines("SETTINGS"))")
        #expect(r.focus.activationRequests == 1)
    }

    @Test func SettingsFocus_aCauseOlderThanOneSecondClaimsNothingAlsoWithTheChatOpen() throws {
        let r = try SettingsRig()
        try r.openChat()
        r.advance(2)
        try r.openFromMenuBar()
        r.advance(1.5)
        let window = try r.window()
        r.post(NSWindow.didBecomeKeyNotification, window)
        #expect(r.lines("SETTINGS key-uncaused").count == 1 && r.violations == 1, "\(r.lines("SETTINGS"))")
        r.clawdBecomesActive()
        #expect(r.lines("SETTINGS active").isEmpty, "\(r.lines("SETTINGS"))")
        #expect(r.lines("SETTINGS activate-refused").count <= 1)
    }

    @Test func SettingsFocus_anOpenWhileClawdIsActiveAsksForNoActivation() throws {
        let r = try SettingsRig()
        r.focus.active = true
        try r.openFromMenuBar()
        #expect(r.focus.activationRequests == 0, "no activation is asked")
        r.advance(2)
        r.focus.timers.fire(atLeast: 0)
        #expect(r.lines("SETTINGS active").isEmpty && r.lines("SETTINGS activate-refused").isEmpty, "\(r.lines("SETTINGS"))")
        // The first key is still the open's.
        let r2 = try SettingsRig()
        r2.focus.active = true
        try r2.openFromMenuBar()
        r2.post(NSWindow.didBecomeKeyNotification, try r2.window())
        #expect(r2.count("SETTINGS key") == 1 && r2.violations == 0, "\(r2.lines("SETTINGS"))")
    }

    @Test func SettingsFocus_aMouseDownInSettingsIsItsCause() throws {
        for button in [ChatPressButton.left, .right, .other] {
            let r = try SettingsRig()
            try r.openFromMenuBar()
            r.advance(2)
            let window = try r.window()
            r.mouseDown(in: window, button)
            r.post(NSWindow.didBecomeKeyNotification, window)
            #expect(r.count("SETTINGS key") == 1 && r.violations == 0, "\(button): \(r.lines("SETTINGS"))")
            r.clawdBecomesActive()
            #expect(r.lines("SETTINGS active cause=click").count == 1 && r.violations == 0, "\(button): \(r.lines("SETTINGS"))")
        }
        // Not a cause: a mouse-up, a drag or a scroll over Settings, a right mouse-down in another window.
        let r = try SettingsRig()
        try r.openFromMenuBar()
        r.advance(2)
        let window = try r.window()
        let other = r.rig.bodyPanel
        let events: [(String, ChatCurrentEvent)] = [
            ("a mouse-up", ChatCurrentEvent(isMouseDown: false, window: window, isMouse: true)),
            ("a drag", ChatCurrentEvent(isMouseDown: false, window: window, isMouse: true)),
            ("a scroll wheel", ChatCurrentEvent(isMouseDown: false, window: window, isMouse: true)),
            ("a right mouse-down in another window", ChatCurrentEvent(isMouseDown: false, window: other, mouseDownButton: .right)),
        ]
        var expected = 0, keys = 0
        for (name, event) in events {
            r.machine.chatEvent = event
            r.post(NSWindow.didBecomeKeyNotification, window)
            expected += 1; keys += 1
            #expect(r.violations == expected && r.lines("SETTINGS key-uncaused").count == keys, "\(name): \(r.lines("SETTINGS"))")
            // The activation answers by the same rule: none of these is the cause of Clawd's activation either.
            r.clawdBecomesActive()
            expected += 1
            #expect(r.lines("SETTINGS active").isEmpty && r.violations == expected, "\(name): \(r.lines("SETTINGS"))")
            r.resign()
        }
    }

    @Test func SettingsFocus_anUncausedKeyOnSettingsIsRecorded() throws {
        let r = try SettingsRig()
        try r.openFromMenuBar()
        r.advance(2)
        let window = try r.window()
        r.machine.chatEvent = nil
        r.post(NSWindow.didBecomeKeyNotification, window)
        r.keyEvent(in: window)
        r.post(NSWindow.didBecomeKeyNotification, window)
        #expect(r.violations == 2 && r.lines("SETTINGS key-uncaused").count == 2 && r.lines("FOCUS_VIOLATION trigger").count == 2, "\(r.lines("SETTINGS"))")
        #expect((r.count("SETTINGS key") == 0))
    }

    @Test func SettingsFocus_thePickerKeyAndActivationAreSettingsWhileThePickerIsUp() throws {
        let r = try SettingsRig()
        try r.openFromMenuBar()
        r.advance(2)
        press(try #require(r.settings.content).chooseButton)
        let picker = r.picker
        r.post(NSWindow.didBecomeKeyNotification, picker.pickerWindow)
        #expect(r.lines("SETTINGS picker-key").count == 1 && r.violations == 0)
        r.clawdBecomesActive()
        #expect(r.lines("SETTINGS active cause=picker").count == 1 && r.violations == 0, "\(r.lines("SETTINGS"))")
        picker.choose(nil)
        r.post(NSWindow.didBecomeKeyNotification, picker.pickerWindow)
        #expect(r.violations == 1, "once the picker is gone its window is nobody's")
    }

    @Test func SettingsFocus_aSheetOnThePickerIsSettingsOwnWindow() throws {
        let r = try SettingsRig()
        try r.openFromMenuBar()
        r.advance(2)
        press(try #require(r.settings.content).chooseButton)
        let sheet = SheetOnPicker(contentRect: NSRect(x: 0, y: 0, width: 100, height: 50), styleMask: [.titled], backing: .buffered, defer: true)
        sheet.isReleasedWhenClosed = false
        sheet.pickerParent = r.picker.pickerWindow
        r.post(NSWindow.didBecomeKeyNotification, sheet)
        #expect(r.lines("SETTINGS picker-key").count == 1 && r.violations == 0, "\(r.lines("SETTINGS"))")
        let stranger = SheetOnPicker(contentRect: NSRect(x: 0, y: 0, width: 100, height: 50), styleMask: [.titled], backing: .buffered, defer: true)
        stranger.isReleasedWhenClosed = false
        r.post(NSWindow.didBecomeKeyNotification, stranger)
        #expect(r.violations == 1, "a window with no parent is nobody's")
    }

    @Test func SettingsFocus_onlyAppKitCallsTheStatusMenuActions() throws {
        let sources = try swiftSources()
        func name(_ file: SourceFile) -> String { (file.path as NSString).lastPathComponent }
        // The menu's action selector is called by AppKit alone: only the status menu's file names it.
        for file in sources where name(file) != "StatusMenu.swift" {
            #expect(!file.text.contains("picked("), "\(name(file)) names the status menu's action")
        }
        // Its pick handler is wired once, as the menu's pick closure, and called by nothing else.
        let runtime = try #require(sources.first { name($0) == "AgentRuntime.swift" })
        let calls = runtime.text.components(separatedBy: "statusPick(").count - 1
        #expect(calls == 2, "statusPick( is defined once and wired once, found \(calls) times")
        for file in sources where name(file) != "AgentRuntime.swift" { #expect(!file.text.contains("statusPick("), "\(name(file))") }
        // The status-menu cause opens Settings in one place.
        let causes = sources.filter { name($0) != "SettingsController.swift" }.map { $0.text.components(separatedBy: "cause: .statusMenu").count - 1 }.reduce(0, +)
        #expect(causes == 1, "the status menu's cause is named \(causes) times outside Settings' own file")
    }

    @Test func SettingsFocus_aCauseOpensAndGivesTheFirstKeyOnlyToItsOwnWindow() throws {
        let r = try SettingsRig()
        try r.openChat()
        r.advance(2)
        try r.openFromMenuBar()
        let panel = try #require(r.chatPanel)
        r.machine.chatEvent = nil
        r.post(NSWindow.didBecomeKeyNotification, panel)
        #expect(r.lines("CHAT key-uncaused").count == 1 && (r.count("SETTINGS key") == 0), "Settings' cause is not the chat panel's: \(r.lines("SETTINGS")) \(r.lines("CHAT"))")
        // The cause is still Settings' own first key.
        r.post(NSWindow.didBecomeKeyNotification, try r.window())
        #expect(r.count("SETTINGS key") == 1)
    }

    // MARK: whose keys

    @Test func SettingsFocus_eachSurfaceAnswersKeysOnlyForItsOwnWindows() throws {
        let r = try SettingsRig()
        try r.openChat()
        r.advance(2)
        try r.openFromMenuBar()
        r.clawdBecomesActive()
        let panel = try #require(r.chatPanel)
        let window = try r.window()
        r.advance(2)
        r.machine.chatEvent = nil
        let settingsBefore = r.count("SETTINGS key")
        r.post(NSWindow.didBecomeKeyNotification, panel)
        #expect(r.count("SETTINGS key") == settingsBefore && r.lines("CHAT key-returned").count == 1, "the chat answers for its panel alone: \(r.lines("SETTINGS")) \(r.lines("CHAT"))")
        let chatReturned = r.lines("CHAT key-returned").count
        r.post(NSWindow.didBecomeKeyNotification, window)
        #expect(r.lines("SETTINGS key-returned").count == 1, "Settings answers for its window: \(r.lines("SETTINGS"))")
        #expect(r.lines("CHAT key-returned").count == chatReturned, "and the chat does not: \(r.lines("CHAT"))")
        #expect(r.violations == 0)
    }

    @Test func SettingsFocus_aWindowNoSurfaceOwnsIsAViolation() throws {
        let r = try SettingsRig()
        try r.openChat()
        try r.openFromMenuBar()
        r.clawdBecomesActive()
        r.machine.chatEvent = nil
        let settingsLines = r.lines("SETTINGS").count, chatLines = r.lines("CHAT").count
        r.post(NSWindow.didBecomeKeyNotification, r.rig.bodyPanel)
        #expect(r.violations == 1 && r.lines("SETTINGS").count == settingsLines && r.lines("CHAT").count == chatLines, "inside a claimed activation too: \(r.lines("FOCUS"))")
        r.post(NSWindow.didBecomeMainNotification, try r.window())
        #expect(r.violations == 2, "a main notification has no exemption")
    }

    // MARK: key right, close and hand-back

    @Test func SettingsFocus_closeEndsTheCauseAndKeyRightAtOnce() throws {
        let r = try SettingsRig()
        try r.openFromMenuBar()
        let window = try r.window()
        #expect(r.settings.causeIsArmed && window.canBecomeKey)
        var seen: (cause: Bool, key: Bool)?
        r.box.onDismiss = { [unowned r] dismissed in seen = (r.settings.causeIsArmed, dismissed.canBecomeKey) }
        r.settings.close(.button)
        #expect(seen?.cause == false && seen?.key == false, "both ended before the window went off screen: \(String(describing: seen))")
        r.post(NSWindow.didBecomeKeyNotification, window)
        #expect(r.violations == 1 && (r.count("SETTINGS key") == 0), "a key of the closed window is nobody's")
        r.clawdBecomesActive()
        #expect(r.lines("SETTINGS active").isEmpty, "and so is an activation")
    }

    @Test func SettingsFocus_closeHandsActivationBackToTheAppInFrontAtOpen() throws {
        let r = try SettingsRig()
        let front = ChatAppRef(pid: 4001, launchDate: Date(timeIntervalSince1970: 1_000))
        r.focus.frontmost = front
        try r.openFromMenuBar()
        #expect(r.settings.handBackTarget == front)
        r.clawdBecomesActive()
        r.settings.close(.esc)
        #expect(r.focus.handBacks == [front] && r.lines("SETTINGS handback").count == 1 && r.focus.deactivationRequests == 0, "\(r.lines("SETTINGS"))")
        let dismiss = try #require(r.box.order.firstIndex(of: "dismiss"), "\(r.box.order)")
        let handBack = try #require(r.box.order.firstIndex(of: "handback"), "\(r.box.order)")
        #expect(dismiss < handBack, "the window is off screen before activation goes back: \(r.box.order)")
        r.focus.active = false
        r.focus.timers.fire(exactly: SettingsController.handbackDeadline)
        #expect(r.lines("SETTINGS handback ok=1").count == 1)
    }

    @Test func SettingsFocus_closeWithTheChatClosedAndNothingRecordedDeactivates() throws {
        let r = try SettingsRig()
        r.focus.frontmost = nil
        try r.openFromMenuBar()
        r.clawdBecomesActive()
        r.settings.close(.button)
        #expect(r.focus.handBacks.isEmpty && r.focus.deactivationRequests == 1 && r.lines("SETTINGS deactivate").count == 1, "\(r.lines("SETTINGS"))")
        let dismiss = try #require(r.box.order.firstIndex(of: "dismiss"), "\(r.box.order)")
        let deactivate = try #require(r.box.order.firstIndex(of: "deactivate"), "\(r.box.order)")
        #expect(dismiss < deactivate, "the window is off screen before Clawd deactivates: \(r.box.order)")
        // Nothing while Clawd is not active.
        let idle = try SettingsRig()
        try idle.openFromMenuBar()
        idle.settings.close(.button)
        #expect(idle.focus.handBacks.isEmpty && idle.focus.deactivationRequests == 0 && idle.lines("SETTINGS handback").isEmpty)
    }

    @Test func SettingsFocus_aReopenWhileOpenKeepsTheFirstHandBackTarget() throws {
        let r = try SettingsRig()
        let first = ChatAppRef(pid: 4001, launchDate: Date(timeIntervalSince1970: 1_000))
        r.focus.frontmost = first
        try r.openFromMenuBar()
        r.focus.frontmost = nil                      // Clawd is in front at the second pick
        r.runtime.menuOpenSettings(eventTime: 5)
        #expect(r.settings.handBackTarget == first && r.lines("SETTINGS open").count == 2)
        r.clawdBecomesActive()
        r.settings.close(.button)
        #expect(r.focus.handBacks == [first], "the close hands back to the first open's application: \(r.focus.handBacks)")
    }

    @Test func SettingsFocus_closeWithTheChatOpenAndClawdInFrontPutsTheChatKeyThroughItsSeam() throws {
        let r = try SettingsRig()
        r.focus.frontmost = nil
        try r.openChat()
        try r.openFromMenuBar()
        r.clawdBecomesActive()
        r.advance(2)
        r.machine.onChatKey = { [unowned r] panel in r.focus.clawdKey = true; r.post(NSWindow.didBecomeKeyNotification, panel) }
        let keys = r.machine.chatKeys.count
        r.machine.chatEvent = nil
        r.settings.close(.button)
        #expect(r.machine.chatKeys.count == keys + 1, "chatMakeKey is called once")
        #expect(r.lines("CHAT key-returned").count == 1 && r.violations == 0, "\(r.lines("CHAT"))")
        #expect(r.focus.handBacks.isEmpty && r.focus.deactivationRequests == 0)
        r.focus.drain()
        #expect(r.focus.deactivationRequests == 0, "a Clawd window is key, so nothing deactivates")
    }

    @Test func SettingsFocus_ifNoClawdWindowIsKeyNextTurnSettingsDeactivates() throws {
        let r = try SettingsRig()
        r.focus.frontmost = nil
        try r.openChat()
        try r.openFromMenuBar()
        r.clawdBecomesActive()
        r.settings.close(.button)
        #expect(r.focus.deactivationRequests == 0, "not before the next turn")
        r.focus.drain()
        #expect(r.focus.deactivationRequests == 1 && r.lines("SETTINGS deactivate").count == 1, "\(r.lines("SETTINGS"))")
    }

    @Test func SettingsFocus_aSettingsOpenCancelsAPendingChatHandBackAlsoWhenClawdIsAlreadyActive() throws {
        let r = try SettingsRig()
        let front = ChatAppRef(pid: 4001, launchDate: Date(timeIntervalSince1970: 1_000))
        r.focus.frontmost = front
        try r.openChat()
        r.focus.active = true
        r.advance(2)
        r.chatPanel?.onEscape?()
        #expect(r.lines("CHAT handback gen=1").count == 1 && r.focus.handBacks == [front], "the chat's hand-back is in flight: \(r.lines("CHAT"))")
        // Clawd is still active (the hand-back has not landed), so Settings asks for no activation; its open still ends the hand-back's steps.
        try r.openFromMenuBar()
        r.focus.timers.fire(exactly: ChatController.handbackDeadline)
        #expect(r.lines("CHAT deactivate").isEmpty && r.lines("CHAT handback-finder").isEmpty && r.lines("CHAT handback gen=1 ok=1").isEmpty && r.focus.deactivationRequests == 0,
                "the cancelled steps do not deactivate Clawd under the window: \(r.lines("CHAT"))")
        #expect(r.settings.isOpen)
    }

    @Test func SettingsFocus_aChatOpenCancelsASettingsHandBackInFlight() throws {
        let r = try SettingsRig()
        r.focus.frontmost = ChatAppRef(pid: 4001, launchDate: Date(timeIntervalSince1970: 1_000))
        try r.openFromMenuBar()
        r.clawdBecomesActive()
        r.settings.close(.button)
        #expect(r.lines("SETTINGS handback").count == 1)
        try r.openChat(at: 5)
        r.focus.timers.fire(exactly: SettingsController.handbackDeadline)
        #expect(r.lines("SETTINGS deactivate").isEmpty && r.lines("SETTINGS handback-finder").isEmpty && r.lines("SETTINGS handback ok=1").isEmpty && r.focus.deactivationRequests == 0,
                "\(r.lines("SETTINGS"))")
    }

    // MARK: a click back, the hand-back target, the chat's open token (SA2 code review r1: H-1, M-1, L-5)

    /// Settings open and claimed, Clawd then resigned (another application was clicked); the chat optionally open first. No event is in hand.
    private func settingsAfterAResign(chat: Bool, settle: TimeInterval = 5) throws -> (rig: SettingsRig, window: SettingsWindow) {
        let r = try SettingsRig()
        if chat {
            try r.openChat()
            r.advance(2)
        }
        try r.openFromMenuBar()
        r.clawdBecomesActive()
        #expect(r.lines("SETTINGS active cause=open").count == 1, "\(r.lines("SETTINGS"))")
        let window = try r.window()
        r.resign()
        r.advance(settle)
        r.machine.chatEvent = nil
        if chat {
            // The chat's own click test would take a press of the session newer than its open that went to one of Clawd's windows.
            r.focus.pressAt = r.now - 0.1
        }
        return (r, window)
    }

    /// What is not a click back on Settings: each leaves the activation uncaused, so with the chat closed it is a violation.
    private func notSettingsClickBack() throws {
        let other = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 100, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
        other.isReleasedWhenClosed = false
        let cases: [(String, (SettingsRig, SettingsWindow) -> Void)] = [
            ("a press queued for another window", { r, _ in r.focus.pressAt = r.now - 0.05; r.focus.queuedPressWindow = other }),
            ("a press Settings recorded more than a second ago", { r, window in r.advance(1.5); window.recordMouseDown(at: r.now - 1.2) }),
            ("a press queued for no window", { r, _ in r.focus.pressAt = r.now - 0.05; r.focus.queuedPressWindow = nil }),
        ]
        for (name, setUp) in cases {
            let (r, window) = try settingsAfterAResign(chat: false)
            setUp(r, window)
            r.clawdBecomesActive()
            #expect(r.lines("SETTINGS active cause=click").isEmpty && r.violations == 1, "\(name): \(r.lines("SETTINGS")) \(r.lines("FOCUS"))")
        }
        // A press the window recorded before Clawd resigned belongs to the activation that ended there.
        let r = try SettingsRig()
        try r.openFromMenuBar()
        r.clawdBecomesActive()
        let window = try r.window()
        r.advance(2)
        window.recordMouseDown(at: r.now)
        r.advance(0.2)
        r.resign()
        r.advance(0.2)
        r.machine.chatEvent = nil
        r.clawdBecomesActive()
        #expect(r.lines("SETTINGS active cause=click").isEmpty && r.violations == 1, "\(r.lines("SETTINGS")) \(r.lines("FOCUS"))")
    }

    @Test func SettingsFocus_aClickBackOnSettingsIsItsCauseWhenTheActivationComesFirst() throws {
        enum Path: String, CaseIterable { case recorded, queued }
        for chat in [false, true] {
            for path in Path.allCases {
                let label = "\(path) chat=\(chat)"
                let (r, window) = try settingsAfterAResign(chat: chat)
                switch path {
                case .recorded: window.recordMouseDown(at: r.now - 0.05)
                case .queued: r.focus.pressAt = r.now - 0.05; r.focus.queuedPressWindow = window
                }
                r.clawdBecomesActive()
                #expect(r.lines("SETTINGS active cause=click via=\(path == .recorded ? "recorded" : "peek")").count == 1, "\(label): the line names its path: \(r.lines("SETTINGS"))")
                #expect(r.lines("SETTINGS active cause=click").count == 1 && r.violations == 0 && r.lines("FOCUS_VIOLATION").isEmpty,
                        "\(label): \(r.lines("SETTINGS")) \(r.lines("FOCUS"))")
                #expect(r.focus.deactivationRequests == 0, "\(label): Clawd stays active")
                #expect(r.lines("CHAT active").isEmpty && r.lines("CHAT close").isEmpty, "\(label): the chat does not take Settings' click: \(r.lines("CHAT"))")
                r.focus.drain()
                #expect(r.settings.isOpen && (!chat || r.runtime.chatPanelIsOpen), "\(label)")
                // The key that follows the activation is a return inside a claimed activation, not a violation.
                r.post(NSWindow.didBecomeKeyNotification, window)
                #expect(r.violations == 0, "\(label): \(r.lines("SETTINGS"))")
            }
        }
        let (h, handWindow) = try settingsAfterAResign(chat: false)
        h.mouseDown(in: handWindow)
        h.clawdBecomesActive()
        #expect(h.lines("SETTINGS active cause=click via=hand").count == 1 && h.violations == 0, "\(h.lines("SETTINGS"))")
        try notSettingsClickBack()
        try aClickOnTheChatIsNotSettingsCauseWhateverSettingsLastReceived()
    }

    /// The chat's own click (SA2 fix recheck N-2): Settings and the chat are both open and Clawd is inactive. A press Settings received that is not a
    /// left mouse-down is no record, and a left one is not taken when a mouse-down of another window is the event in hand.
    private func aClickOnTheChatIsNotSettingsCauseWhateverSettingsLastReceived() throws {
        func mouseEvent(_ type: NSEvent.EventType, _ window: NSWindow, at time: TimeInterval) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: 5, y: 5), modifierFlags: [], timestamp: time,
                                            windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1))
        }
        for (name, type, inHand) in [("a right-down, the chat's click not yet in hand", NSEvent.EventType.rightMouseDown, false),
                                     ("an other-down, the chat's click not yet in hand", .otherMouseDown, false),
                                     ("a left-down, the chat's click in hand", .leftMouseDown, true)] {
            let (r, window) = try settingsAfterAResign(chat: true)
            let panel = try #require(r.chatPanel)
            window.noteMouseDown(try mouseEvent(type, window, at: r.now - 0.3))
            if inHand { r.mouseDown(in: panel) }
            r.clawdBecomesActive()
            #expect(r.lines("SETTINGS active cause=click").isEmpty, "\(name): Settings does not take the chat's click: \(r.lines("SETTINGS"))")
            #expect(r.lines("CHAT active").filter { $0.contains("cause=click") }.count == 1 && r.violations == 0, "\(name): \(r.lines("CHAT")) \(r.lines("FOCUS"))")
        }
    }

    /// SA2 fix recheck N-1: Settings peeks the queue (a nested event pass that may run main-queue work) only after a recent press of the session, as
    /// the chat does, so an activation with no press never runs it and a key waiting for the activation is not resolved early.
    @Test func SettingsFocus_thePeekRunsOnlyAfterARecentPress() throws {
        // No recent press: a key waits between will and did, and the peek (which would drain the main queue) is never called.
        let (r, window) = try settingsAfterAResign(chat: false)
        r.focus.onPeek = { r.focus.drain() }
        r.focus.queuedPressWindow = window
        r.post(NSApplication.willBecomeActiveNotification, nil)
        r.focus.active = true
        r.post(NSWindow.didBecomeKeyNotification, window)
        r.post(NSApplication.didBecomeActiveNotification, nil)
        #expect(r.focus.peekCalls == 0, "no press, no peek: \(r.focus.peekCalls)")
        #expect(r.lines("SETTINGS active cause=click").isEmpty, "\(r.lines("SETTINGS"))")
        // A press too old, one that went to no window of Clawd, one before the resign: no claim either.
        // The count production makes: a press older than the click window is turned away on its age, before any peek. A recent one costs the peek that
        // asks whether it went to Clawd, and when it did not, or when it came before the resign (checked after that peek), the window's peek never runs.
        for (name, peeks, settle, setUp) in [("an old press", 0, 5.0, { (r: SettingsRig) in r.focus.pressAt = r.now - 1.5 }),
                                             ("a press elsewhere", 1, 5.0, { (r: SettingsRig) in r.focus.pressAt = r.now - 0.05; r.focus.pressWentToClawd = false }),
                                             ("a press before the resign, inside the click window", 1, 0.5, { (r: SettingsRig) in r.focus.pressAt = r.now - 0.8 })] {
            let (r, window) = try settingsAfterAResign(chat: false, settle: settle)
            r.focus.queuedPressWindow = window
            setUp(r)
            r.clawdBecomesActive()
            #expect(r.focus.peekCalls == peeks && r.lines("SETTINGS active cause=click").isEmpty, "\(name): \(r.focus.peekCalls) \(r.lines("SETTINGS"))")
        }
        // A recent press that Settings' own record already explains: claimed with no peek, and the waiting key is a return, not a violation.
        let (q, queuedWindow) = try settingsAfterAResign(chat: false)
        q.focus.onPeek = { q.focus.drain() }
        q.focus.pressAt = q.now - 0.05
        queuedWindow.recordMouseDown(at: q.now - 0.05)
        q.post(NSApplication.willBecomeActiveNotification, nil)
        q.focus.active = true
        q.post(NSWindow.didBecomeKeyNotification, queuedWindow)
        q.post(NSApplication.didBecomeActiveNotification, nil)
        #expect(q.focus.peekCalls == 0 && q.lines("SETTINGS active cause=click").count == 1 && q.violations == 0, "\(q.focus.peekCalls) \(q.lines("SETTINGS")) \(q.lines("FOCUS"))")
        // A recent press with the record empty: two peeks (whether the press went to Clawd, then its window) and the second's answer is the cause.
        let (p, peekedWindow) = try settingsAfterAResign(chat: false)
        p.focus.pressAt = p.now - 0.05
        p.focus.queuedPressWindow = peekedWindow
        p.clawdBecomesActive()
        #expect(p.focus.peekCalls == 2 && p.lines("SETTINGS active cause=click").count == 1 && p.violations == 0, "\(p.focus.peekCalls) \(p.lines("SETTINGS"))")
    }

    /// SA3 code review r1 L-5: a peek inside the claim step may run the main queue as a nested event pass, and so a waiting key's resolver. The key's
    /// verdict is the step's then: the claim resolves it, and the resolver judges nothing while the step runs.
    @Test func SettingsFocus_aKeyWaitingOnSettingsIsJudgedByTheClaimWhenAPeekDrainsTheQueue() throws {
        for chat in [false, true] {
            let (r, window) = try settingsAfterAResign(chat: chat)
            let content = try #require(r.settings.content)
            let before = r.lines("SETTINGS").count
            r.focus.onPeek = { r.focus.drain() }
            r.focus.pressAt = r.now - 0.05
            r.focus.queuedPressWindow = window
            r.post(NSApplication.willBecomeActiveNotification, nil)
            r.focus.active = true
            r.post(NSWindow.didBecomeKeyNotification, window)
            r.post(NSApplication.didBecomeActiveNotification, nil)
            let settings = Array(r.lines("SETTINGS").dropFirst(before))
            let active = settings.firstIndex(of: "SETTINGS active cause=click via=peek")
            let key = settings.firstIndex(of: "SETTINGS key")
            #expect(r.focus.peekCalls == 2, "chat \(chat): \(r.focus.peekCalls)")
            #expect(settings.filter { $0 == "SETTINGS active cause=click via=peek" }.count == 1 && settings.filter { $0 == "SETTINGS key" }.count == 1, "chat \(chat): \(settings)")
            #expect(active != nil && key != nil && active! < key!, "chat \(chat): the key is judged after the claim: \(settings)")
            #expect(r.lines("SETTINGS key-uncaused").isEmpty && r.violations == 0, "chat \(chat): \(r.lines("SETTINGS")) \(r.lines("FOCUS"))")
            #expect(window.firstResponder === content.sidebar, "chat \(chat): the input gate is released")
            r.focus.drain()
            #expect(r.violations == 0 && r.settings.isOpen, "chat \(chat): \(r.lines("FOCUS"))")
            if chat { #expect(r.runtime.chatPanelIsOpen && r.lines("CHAT close").isEmpty, "\(r.lines("CHAT"))") }
        }
    }

    /// The chat's key waits while Settings (open too) peeks twice before the chat is asked: neither peek's drain may judge the chat's key.
    @Test func SettingsFocus_aChatKeyWaitingThroughSettingsPeeksIsJudgedByTheChatsClaim() throws {
        let (r, _) = try settingsAfterAResign(chat: true)
        let panel = try #require(r.chatPanel)
        let chatBefore = r.lines("CHAT").count
        r.focus.onPeek = { r.focus.drain() }
        r.focus.pressAt = r.now - 0.05
        r.focus.queuedPressWindow = panel
        r.post(NSApplication.willBecomeActiveNotification, nil)
        r.focus.active = true
        r.post(NSWindow.didBecomeKeyNotification, panel)
        r.post(NSApplication.didBecomeActiveNotification, nil)
        let chat = Array(r.lines("CHAT").dropFirst(chatBefore))
        let active = chat.firstIndex(of: "CHAT active gen=1 cause=click")
        let key = chat.firstIndex(of: "CHAT key gen=1")
        #expect(r.focus.peekCalls == 3, "\(r.focus.peekCalls)")
        #expect(r.lines("SETTINGS active").filter { $0.contains("cause=click") }.isEmpty, "\(r.lines("SETTINGS"))")
        #expect(chat.filter { $0 == "CHAT active gen=1 cause=click" }.count == 1 && chat.filter { $0 == "CHAT key gen=1" }.count == 1, "\(chat)")
        #expect(active != nil && key != nil && active! < key!, "the chat's key is judged after its claim: \(chat)")
        #expect(r.lines("CHAT key-uncaused").isEmpty && r.violations == 0, "\(r.lines("CHAT")) \(r.lines("FOCUS"))")
        r.focus.drain()
        #expect(r.runtime.chatPanelIsOpen && r.lines("CHAT close").isEmpty && r.violations == 0, "\(r.lines("CHAT"))")
    }

    @Test func SettingsFocus_theHandBackTargetFollowsTheLastOtherApp() throws {
        let r = try SettingsRig()
        let first = ChatAppRef(pid: 4001, launchDate: Date(timeIntervalSince1970: 1_000))
        let second = ChatAppRef(pid: 4002, launchDate: Date(timeIntervalSince1970: 1_001))
        r.focus.frontmost = first
        try r.openFromMenuBar()
        r.clawdBecomesActive()
        #expect(r.settings.handBackTarget == first && r.focus.liveObservers == 1)
        r.focus.otherAppBecomesActive(second)
        #expect(r.settings.handBackTarget == second, "another application was activated: it is the target now")
        // Clawd itself, and a surface that gives the activation straight back, never are.
        r.focus.otherAppBecomesActive(ChatAppRef(pid: ProcessInfo.processInfo.processIdentifier, launchDate: nil))
        r.focus.otherAppBecomesActive(ChatAppRef(pid: 4003, launchDate: nil, bundleID: "com.apple.SecurityAgent"))
        #expect(r.settings.handBackTarget == second, "\(String(describing: r.settings.handBackTarget))")
        // A reopen from the icon keeps it (Clawd, or nothing, is in front then).
        r.focus.frontmost = nil
        r.runtime.menuOpenSettings(eventTime: 5)
        #expect(r.settings.handBackTarget == second)
        r.settings.close(.button)
        #expect(r.focus.handBacks == [second], "the second application comes forward, not the first: \(r.focus.handBacks)")
        #expect(r.focus.liveObservers == 0, "closed, Settings follows nothing")
        r.focus.otherAppBecomesActive(ChatAppRef(pid: 4004, launchDate: nil))
        #expect(r.settings.handBackTarget == nil)
    }

    @Test func SettingsFocus_aClaimElsewhereEndsTheChatsOpenTokenQuietly() throws {
        let r = try SettingsRig()
        try r.openChat()
        #expect(r.lines("CHAT activate gen=1 cause=open").count == 1, "the chat's token is open: \(r.lines("CHAT"))")
        try r.openFromMenuBar()
        r.clawdBecomesActive()
        #expect(r.lines("SETTINGS active cause=open").count == 1 && r.lines("CHAT active").isEmpty, "Settings' cause claims it: \(r.lines("CHAT")) \(r.lines("SETTINGS"))")
        r.advance(2)
        r.focus.timers.fire(atLeast: 0)
        r.focus.drain()
        #expect(r.lines("CHAT activate-refused").isEmpty && r.lines("CHAT activate-spent").isEmpty, "the token ended without a line: \(r.lines("CHAT"))")
        #expect(r.chatPanel?.headerText != "Click here to type", "no hint is shown while Clawd is active")
        #expect(r.runtime.chatPanelIsOpen && r.violations == 0)
    }

    // MARK: the status menu, fail closed

    @Test func SettingsFocus_aKeyOfAnUnownedWindowWhileTheStatusMenuIsOpenIsStillAViolation() throws {
        let r = try SettingsRig()
        r.surface.open()
        r.post(NSWindow.didBecomeKeyNotification, r.rig.bodyPanel)
        r.post(NSWindow.didBecomeKeyNotification, nil)
        #expect(r.violations == 2, "no exemption inside the menu's interval")
        #expect(r.lines("STATUS trace note=didBecomeKey").count == 2, "\(r.lines("STATUS"))")
    }

    @Test func SettingsFocus_anActivationAtAStatusMenuOpenIsAViolation() throws {
        let r = try SettingsRig()
        var handbacks = 0
        r.rig.monitor.onViolation = { handbacks += 1 }
        r.surface.open()
        r.post(NSApplication.willBecomeActiveNotification, nil)
        r.post(NSApplication.didBecomeActiveNotification, nil)
        #expect(r.violations == 1 && handbacks == 1, "an activation has no window to claim: it stays a violation")
        #expect(r.lines("STATUS trace note=didBecomeActive").count == 1 && r.lines("STATUS trace note=willBecomeActive").count == 1, "\(r.lines("STATUS"))")
    }

    @Test func SettingsFocus_theTraceRunsOnlyInsideTheMenusIntervalAndArmsNoTimer() throws {
        let r = try SettingsRig()
        let button = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 24, height: 24), styleMask: [.borderless], backing: .buffered, defer: true)
        button.isReleasedWhenClosed = false
        r.surface.buttonWindow = button
        let armed = r.rig.stage.wake.armedTimers, timers = r.focus.timers.live.count
        // Outside any interval: nothing is traced.
        r.post(NSWindow.didBecomeMainNotification, r.rig.bodyPanel)
        #expect(r.lines("STATUS trace").isEmpty)
        // A right mouse-down on the button's window opens the interval, before the menu opens.
        r.mouseDown(in: button, .right)
        r.post(NSWindow.didBecomeKeyNotification, button)
        #expect(r.lines("STATUS trace").count == 1 && r.lines("STATUS trace").first?.hasSuffix("how=mouse-right") == true, "\(r.lines("STATUS"))")
        r.machine.chatEvent = nil
        r.surface.open()
        #expect(r.lines("STATUS menu open how=mouse-right").count == 1, "\(r.lines("STATUS"))")
        r.post(NSWindow.didBecomeMainNotification, button)
        #expect(r.lines("STATUS trace").count == 2)
        r.surface.close()
        #expect(r.lines("STATUS menu close").count == 1)
        r.advance(1)
        r.post(NSWindow.didBecomeMainNotification, button)
        #expect(r.lines("STATUS trace").count == 3, "2 s after the close the interval still runs")
        r.advance(3)
        r.post(NSWindow.didBecomeMainNotification, button)
        #expect(r.lines("STATUS trace").count == 3, "and then it is over: \(r.lines("STATUS trace"))")
        #expect(r.rig.stage.wake.armedTimers <= max(armed, 1) && r.focus.timers.live.count == timers, "the trace arms nothing")
        let line = try #require(r.lines("STATUS trace").first)
        #expect(line.contains("settings=closed chat=closed active=0"), "\(line)")
        // A keyboard open: the menu's opening alone starts the interval.
        let k = try SettingsRig()
        k.machine.chatEvent = ChatCurrentEvent(isMouseDown: false, window: nil, isMouse: false, timestamp: 1)
        k.surface.open()
        #expect(k.lines("STATUS menu open how=key").count == 1)
    }
}

@Suite("StatusMenu settings row", .serialized)
@MainActor
struct StatusMenuSettingsSuite {
    @Test func StatusMenu_settingsRowOpensSettingsWithTheMenuBarCause() throws {
        let r = try SettingsRig()
        r.box.onKey = { [unowned r] window in r.post(NSWindow.didBecomeKeyNotification, window) }
        r.surface.open()
        #expect(r.surface.titles.first == "Settings\u{2026}")
        r.rig.monitor.context = "click"
        try r.surface.pick("Settings\u{2026}")
        #expect(r.settings.isOpen && r.rig.monitor.context == "status-menu")
        #expect(r.lines("STATUS pick row=settings").count == 1 && r.lines("SETTINGS open policy=accessory cause=status-menu section=general").count == 1, "\(r.lines("SETTINGS"))")
        #expect(r.focus.activationRequests == 1, "Settings asks for activation through the chat's seam")
        #expect(r.count("SETTINGS key") == 1 && r.violations == 0, "the menu-bar pick is the user's cause")
        r.clawdBecomesActive()
        #expect(r.lines("SETTINGS active cause=open").count == 1 && r.violations == 0)
        #expect(r.surface.titles.contains("Settings\u{2026}"))
    }
}
