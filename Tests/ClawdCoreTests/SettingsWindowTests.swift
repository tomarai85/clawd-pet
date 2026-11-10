import Testing
import Foundation
import AppKit
import ClawdCore
import ClawdRendering
import ClawdDesktop

// The Settings window (Stage SA, Sprint SA2): its contract, its geometry, its General and Claude Code sections and their writes through the one
// writer. Nothing here shows a window, makes one key or touches the real state directory: Settings goes on screen only through the runtime
// environment's `settingsPresent`, which every rig here records and nothing more.

/// A press of a button as AppKit makes it: the control's action on its target.
@MainActor func press(_ button: NSButton) { _ = button.sendAction(button.action, to: button.target) }

/// The Swift files of Sources/ClawdDesktop that make Settings content or rules: by name (a `Settings` prefix or a `Section.swift` suffix), any
/// other file there that names a content type (`Settings...Content|Section|Row|View`) declared in one of those, and any other file that declares
/// a type whose name starts with `Settings` (a helper moved out of its file), except AgentRuntime.swift and RuntimeEnvironment.swift.
func settingsFiles() throws -> [SourceFile] {
    settingsFiles(among: try swiftSources().filter { $0.path.contains("/Sources/ClawdDesktop/") })
}

func settingsFiles(among all: [SourceFile]) -> [SourceFile] {
    func name(_ file: SourceFile) -> String { (file.path as NSString).lastPathComponent }
    let named = all.filter { name($0).hasPrefix("Settings") || name($0).hasSuffix("Section.swift") }
    let declared = named.flatMap { file -> [String] in
        let expression = try! NSRegularExpression(pattern: #"(?:class|struct|enum|protocol)\s+(Settings\w*(?:Content|Section|Row|View|Choice|Button|Tile|Chip|Control))\b"#)
        let range = NSRange(file.text.startIndex..., in: file.text)
        return expression.matches(in: file.text, range: range).compactMap { Range($0.range(at: 1), in: file.text).map { String(file.text[$0]) } }
    }
    let others = all.filter { file in
        !named.contains { $0.path == file.path } && !["AgentRuntime.swift", "RuntimeEnvironment.swift"].contains(name(file))
            && (declared.contains { file.text.range(of: #"\b"# + $0 + #"\b"#, options: .regularExpression) != nil }
                || file.text.range(of: #"(?:class|struct|enum|protocol|actor|extension)\s+Settings\w*"#, options: .regularExpression) != nil)
    }
    return named + others
}

/// The words of `banned` that Settings files name, as `File: word`. The folder picker's seam is called `present(startingAt:)`, and that spelling is
/// let through only where it belongs: every use in SettingsFolderPicker.swift (the protocol and its two conformers) and ONE use in
/// SettingsController.swift (the call). Anywhere else, and a second use in the controller, it is a `present(` that opens a window of its own.
func settingsBannedHits(in files: [SourceFile], banned: [String]) -> [String] {
    var hits: [String] = []
    for file in files {
        let name = (file.path as NSString).lastPathComponent
        var text = file.text
        if name == "SettingsFolderPicker.swift" {
            text = text.replacingOccurrences(of: "present(startingAt:", with: "")
        } else if name == "SettingsController.swift", let first = text.range(of: "present(startingAt:") {
            text.replaceSubrange(first, with: "")
        }
        for word in banned where text.contains(word) { hits.append("\(name): \(word)") }
    }
    return hits
}

@Suite("SettingsWindow", .serialized)
@MainActor
struct SettingsWindowSuite {
    // MARK: the contract

    @Test func SettingsWindow_auditFindsNoMiniaturizeMainRestoreOrHideOnDeactivate() throws {
        let window = SettingsWindow(contentSize: CGSize(width: 960, height: 600))
        #expect(SettingsWindowAudit.violations(of: window).isEmpty, "\(SettingsWindowAudit.violations(of: window))")
        #expect(!window.canBecomeMain && !window.canBecomeKey && !window.hidesOnDeactivate && !window.isRestorable && !window.isReleasedWhenClosed)
        #expect(!window.styleMask.contains(.miniaturizable) && !window.styleMask.contains(.resizable) && window.styleMask.contains(.closable))
        #expect(window.collectionBehavior == [.auxiliary, .moveToActiveSpace, .fullScreenNone])
        #expect(window.title == "Clawd")
        // The audit sees each fault.
        func found(_ text: String, _ change: (SettingsWindow) -> Void, undo: (SettingsWindow) -> Void) {
            let probe = SettingsWindow(contentSize: CGSize(width: 960, height: 600))
            change(probe)
            #expect(SettingsWindowAudit.violations(of: probe).contains { $0.contains(text) }, "\(text): \(SettingsWindowAudit.violations(of: probe))")
            undo(probe)
        }
        found("miniaturizable", { $0.styleMask.insert(.miniaturizable) }, undo: { $0.styleMask.remove(.miniaturizable) })
        found("resizable", { $0.styleMask.insert(.resizable) }, undo: { $0.styleMask.remove(.resizable) })
        found("hidesOnDeactivate", { $0.hidesOnDeactivate = true }, undo: { $0.hidesOnDeactivate = false })
        found("isRestorable", { $0.isRestorable = true }, undo: { $0.isRestorable = false })
        found("isReleasedWhenClosed", { $0.isReleasedWhenClosed = true }, undo: { $0.isReleasedWhenClosed = false })
        found("canBecomeKey", { $0.allowKey() }, undo: { $0.disallowKey() })
        found("collectionBehavior lacks", { $0.collectionBehavior = [] }, undo: { $0.collectionBehavior = SettingsWindow.behavior })
        // The Model field's text contract (M-3), as the chat's: every text field of Settings is edited in the window's own field editor, which has no
        // context menu, no automatic completion or spelling correction, and no quote, dash or text substitution.
        let editor = try #require(window.fieldEditor(true, for: NSTextField()) as? SettingsFieldEditor, "Settings serves its own field editor")
        #expect(editor.isFieldEditor && editor.contractViolations.isEmpty && editor.menu == nil && editor.assignedMenu == nil, "\(editor.contractViolations)")
        func faulty(_ text: String, _ change: (SettingsFieldEditor) -> Void, undo: (SettingsFieldEditor) -> Void) {
            change(editor)
            #expect(SettingsWindowAudit.violations(of: window).contains { $0.contains(text) }, "\(text): \(SettingsWindowAudit.violations(of: window))")
            undo(editor)
        }
        faulty("context menu", { $0.menu = NSMenu(title: "x") }, undo: { $0.menu = nil })
        faulty("automatic spelling correction", { $0.isAutomaticSpellingCorrectionEnabled = true }, undo: { $0.isAutomaticSpellingCorrectionEnabled = false })
        faulty("automatic quote substitution", { $0.isAutomaticQuoteSubstitutionEnabled = true }, undo: { $0.isAutomaticQuoteSubstitutionEnabled = false })
        faulty("automatic dash substitution", { $0.isAutomaticDashSubstitutionEnabled = true }, undo: { $0.isAutomaticDashSubstitutionEnabled = false })
        faulty("automatic text replacement", { $0.isAutomaticTextReplacementEnabled = true }, undo: { $0.isAutomaticTextReplacementEnabled = false })
        faulty("continuous spell checking", { $0.isContinuousSpellCheckingEnabled = true }, undo: { $0.isContinuousSpellCheckingEnabled = false })
        #expect(!editor.isAutomaticTextCompletionEnabled, "inline completion stays off")
        #expect(SettingsWindowAudit.violations(of: window).isEmpty, "the faults are undone")
    }

    @Test func SettingsWindow_everyOpenLogsPolicyAccessory() throws {
        let r = try SettingsRig()
        try r.openFromMenuBar()
        r.settings.close(.button)
        r.runtime.menuOpenSettings(eventTime: 1)
        let opens = r.lines("SETTINGS open")
        #expect(opens == ["SETTINGS open policy=accessory cause=status-menu section=general", "SETTINGS open policy=accessory cause=right-click section=general"], "\(opens)")
    }

    @Test func SettingsWindow_keyableOnlyBetweenOpenAndClose() throws {
        let r = try SettingsRig()
        #expect(r.settings.window == nil)
        try r.openFromMenuBar()
        let window = try r.window()
        #expect(window.canBecomeKey && window.isKeyAllowed && !window.canBecomeMain)
        r.settings.close(.button)
        #expect(!window.canBecomeKey && !window.isKeyAllowed, "the key right ends with the first step of the close")
        #expect(SettingsWindowAudit.violations(of: SettingsWindow(contentSize: CGSize(width: 960, height: 600))).isEmpty,
                "a window that is not open can never be key")
    }

    // MARK: showing

    @Test func SettingsWindow_onlyRuntimeEnvironmentShowsOrHidesAWindow() throws {
        let patterns = [#"order[F]ront\w*\("#, #"order[B]ack\("#, #"order[W]indow\("#, #"order[O]ut\("#, #"make[K]eyAndOrderFront"#, #"setIs[V]isible\("#,
                        #"show[W]indow\("#, #"begin[S]heet"#, #"run[M]odal"#]
        let sources = try swiftSources()
        #expect(sources.count > 40)
        var hits: [String] = []
        for file in sources where !file.path.hasSuffix("Sources/ClawdDesktop/RuntimeEnvironment.swift") {
            for pattern in patterns where file.text.range(of: pattern, options: .regularExpression) != nil { hits.append("\((file.path as NSString).lastPathComponent): \(pattern)") }
        }
        #expect(hits.isEmpty, "a window is shown or hidden outside the runtime environment: \(hits)")
        let environment = try #require(sources.first { $0.path.hasSuffix("Sources/ClawdDesktop/RuntimeEnvironment.swift") })
        let presentCall = "settingsPresent: { $0.order" + "FrontRegardless() }", dismissCall = "settingsDismiss: { $0.order" + "Out(nil) }"
        #expect(environment.text.contains(presentCall) && environment.text.contains(dismissCall))
        // The Settings files never close their window themselves: it goes through `settingsDismiss`.
        let files = try settingsFiles()
        #expect(files.count >= 4)
        for file in files {
            #expect(!file.text.contains(".close()") && !file.text.contains("performClose("), "\(file.path) closes a window itself")
        }
    }

    @Test func SettingsWindow_aRigNeverPutsTheWindowOnScreen() throws {
        // A default rig: nothing is presented, and the window it made is not visible.
        let bare = try RuntimeRig(virtual: true)
        bare.runtime.settingsController.begin(cause: .statusMenu)
        let window = try #require(bare.runtime.settingsController.window)
        #expect(!window.isVisible, "an open in a default rig leaves the window off screen")
        // A rig whose seam records saw exactly one show.
        let r = try SettingsRig()
        try r.openFromMenuBar()
        #expect(r.box.presented.count == 1 && r.box.presented[0] === r.settings.window && !r.box.presented[0].isVisible, "\(r.box.order)")
        #expect(r.box.keyed.count == 1)
    }

    /// SA2 fix recheck N-3: real NSEvents (never posted to the system) go through the window's `sendEvent`. Only a left mouse-down is recorded, at the
    /// event's own time stamp.
    @Test func SettingsWindow_sendEventRecordsALeftMouseDownOnly() throws {
        let window = SettingsWindow(contentSize: CGSize(width: 960, height: 600))
        func send(_ type: NSEvent.EventType, at time: TimeInterval) throws {
            window.sendEvent(try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: 5, y: 5), modifierFlags: [], timestamp: time,
                                                             windowNumber: window.windowNumber, context: nil, eventNumber: 1, clickCount: 1, pressure: 1)))
        }
        #expect(window.lastLeftMouseDown == nil)
        for type in [NSEvent.EventType.rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .leftMouseDragged, .mouseMoved] {
            try send(type, at: 50)
            #expect(window.lastLeftMouseDown == nil, "\(type.rawValue) is not recorded")
        }
        try send(.leftMouseDown, at: 123.5)
        #expect(window.lastLeftMouseDown == 123.5, "a left mouse-down is recorded at its own time stamp: \(String(describing: window.lastLeftMouseDown))")
        try send(.rightMouseDown, at: 200)
        try send(.leftMouseUp, at: 201)
        #expect(window.lastLeftMouseDown == 123.5, "a later right-down or up does not move it")
        try send(.leftMouseDown, at: 130)
        #expect(window.lastLeftMouseDown == 130)
    }

    /// SA4 M-1 review N-1: sendEvent is only `route` around AppKit's own dispatch, so every event reaches AppKit once and a click-away reaches
    /// `clickMoved`. A test cannot send a real click to a view (the window stays off screen and never key), so this reads the source:
    /// `route(event) { _ in }` or `noteMouseDown(event); super.sendEvent(event)` keeps the recorded time that the test above checks.
    @Test func SettingsWindow_sendEventIsOnlyTheRouteAroundAppKitsDispatch() throws {
        let file = try #require(try swiftSources().first { $0.path.hasSuffix("/Sources/ClawdDesktop/SettingsWindow.swift") })
        let head = "public override func sendEvent(_ event: NSEvent) {"
        let start = try #require(file.text.range(of: head), "SettingsWindow overrides sendEvent")
        let end = try #require(file.text.range(of: "\n    }", range: start.upperBound..<file.text.endIndex))
        let body = file.text[start.upperBound..<end.lowerBound].trimmingCharacters(in: .whitespacesAndNewlines)
        #expect(body == "route(event) { super.sendEvent($0) }", "sendEvent's body: \(body)")
        #expect(file.text.components(separatedBy: "super.sendEvent").count - 1 == 1, "AppKit's dispatch is called in one place")
        #expect(file.text.components(separatedBy: head).count - 1 == 1)
    }

    @Test func SettingsWindow_noSettingsFileNamesAControlThatOpensAWindow() throws {
        let banned = ["NSPopUpButton", "NSComboBox", "NSPathControl", "NSTokenField", "NSSearchField", "NSColorWell", "NSDatePicker", "NSMenu(", ".menu =",
                      "setMenu(", "toolTip", "NSAlert", "NSPopover", "NSSavePanel", "present(", "presentAsSheet", "presentAsModalWindow", "activateFileViewerSelecting", "selectFile("]
        let files = try settingsFiles()
        let names = files.map { ($0.path as NSString).lastPathComponent }
        for required in ["SettingsController.swift", "SettingsWindow.swift", "SettingsGeometry.swift", "SettingsFolderPicker.swift", "SettingsSections.swift", "SettingsChoices.swift"] {
            #expect(names.contains(required), "the scan did not reach \(required): \(names)")
        }
        #expect(files.count >= 4)
        // A helper whose name starts with `Settings` is scanned wherever it is declared; a file that only names one is not.
        let planted = [SourceFile(path: "/Sources/ClawdDesktop/SettingsSections.swift", text: "enum SettingsRow {}"),
                       SourceFile(path: "/Sources/ClawdDesktop/SettingsChoices.swift", text: "final class SettingsChoiceButton {}"),
                       SourceFile(path: "/Sources/ClawdDesktop/LookTiles.swift", text: "func tiles() -> [SettingsChoiceButton] { _ = NSPopUpButton(); return [] }"),
                       SourceFile(path: "/Sources/ClawdDesktop/Elsewhere.swift", text: "enum SettingsStyle { static func pop() { _ = NSPopUpButton() } }"),
                       SourceFile(path: "/Sources/ClawdDesktop/Maker.swift", text: "extension SettingsStyle { static func popUp() -> NSPopUpButton { NSPopUpButton() } }"),
                       SourceFile(path: "/Sources/ClawdDesktop/Worker.swift", text: "actor SettingsWriter { func pop() { _ = NSPopUpButton() } }"),
                       SourceFile(path: "/Sources/ClawdDesktop/Mentions.swift", text: "// the SettingsWindow's own make-key call\nlet menu = NSMenu(title: \"Main\")")]
        let found = settingsFiles(among: planted).map { ($0.path as NSString).lastPathComponent }
        #expect(found.contains("Elsewhere.swift") && found.contains("Maker.swift") && found.contains("Worker.swift") && !found.contains("Mentions.swift"), "\(found)")
        #expect(found.contains("LookTiles.swift"), "a helper that returns a Settings control type is scanned: \(found)")
        // The folder picker's own seam is called `present(startingAt:)`; any other `present(` is a sheet or a popover without naming one.
        let hits = settingsBannedHits(in: files, banned: banned)
        #expect(hits.isEmpty, "a Settings file names a control or a call that opens a window of its own: \(hits)")
        let controllerCount = files.filter { ($0.path as NSString).lastPathComponent == "SettingsController.swift" }.map { $0.text.components(separatedBy: "present(startingAt:").count - 1 }
        #expect(controllerCount == [1], "SettingsController.swift makes exactly one use of the picker's seam: \(controllerCount)")
        // L-8a: the exemption is the picker file's and the controller's one use, nothing else. A `present(` planted anywhere else is found.
        let call = "let handle = environment.settingsFolderPicker().present(startingAt: nil) { _ in }"
        func plant(_ file: String, _ text: String) -> [String] { settingsBannedHits(in: [SourceFile(path: "/Sources/ClawdDesktop/" + file, text: text)], banned: banned) }
        #expect(plant("SettingsSections.swift", call) == ["SettingsSections.swift: present("], "a section file's picker call is found: \(plant("SettingsSections.swift", call))")
        #expect(plant("SettingsChoices.swift", "func f() { present(startingAt: nil) { _ in } }") == ["SettingsChoices.swift: present("])
        #expect(plant("SettingsWindow.swift", "func g(_ sheet: NSViewController) { presentAsSheet(sheet) }").contains("SettingsWindow.swift: presentAsSheet"))
        #expect(plant("SettingsController.swift", call).isEmpty, "the controller's one use is let through")
        #expect(plant("SettingsController.swift", call + "\n" + call) == ["SettingsController.swift: present("], "a second use in the controller is found")
        #expect(plant("SettingsFolderPicker.swift", "func a(startingAt: String?) {}\nfunc present(startingAt: String?) {}\nfunc present(startingAt: Int) {}").isEmpty)
        #expect(plant("SettingsFolderPicker.swift", "func h() { present(self) }") == ["SettingsFolderPicker.swift: present("], "any other present( in the picker file is found")
    }

    // MARK: General

    @Test func SettingsWindow_generalOffersOnlyHideForOneHourAndShow() async throws {
        let r = try SettingsRig()
        try r.openFromMenuBar()
        let content = try #require(r.settings.content)
        let titles = Set(allButtons(in: content.root).filter { !($0 is SettingsChoiceButton) }.map(\.title))
        #expect(titles == ["Hide for 1 hour", "Quit Clawd"], "General's own buttons: \(titles)")
        // SA5: General's one choice row is the restart-only "Show Clawd over full-screen apps" (Q4), On and Off.
        let choices = Set(allButtons(in: content.root).compactMap { ($0 as? SettingsChoiceButton)?.choice })
        #expect(choices == [.fullScreen(true), .fullScreen(false)], "General's choices: \(choices)")
        #expect(content.hideButton.title == "Hide for 1 hour")
        #expect(StatusMenu.hideMinutes == 60)
        press(content.hideButton)
        #expect(content.hideButton.title == "Show", "the control shows its new state at once")
        await r.rig.spin(until: { r.cliRuns.count >= 1 }, limit: 20)
        #expect(r.cliRuns == ["[hide] [60]"], "\(r.stub.calls)")
        press(content.hideButton)
        await r.rig.spin(until: { r.cliRuns.count >= 2 }, limit: 20)
        #expect(r.cliRuns == ["[hide] [60]", "[show]"], "the second press is a show, from the control's own new state: \(r.cliRuns)")
        #expect(r.lines("MENU write").allSatisfy { $0.contains("key=hide ") }, "both rows write under the queue key `hide`")
    }

    @Test func SettingsWindow_stateLineReadsHiddenUntilAndWaitingFor() throws {
        var utc = Calendar(identifier: .gregorian); utc.timeZone = TimeZone(identifier: "UTC")!
        let wall = Date(timeIntervalSince1970: 1_793_000_000)
        let later = wall.addingTimeInterval(3_600)
        let parts = utc.dateComponents([.hour, .minute], from: later)
        let expected = String(format: "Hidden until %02d:%02d", parts.hour!, parts.minute!)
        func line(_ until: Double = 0, _ quiet: QuietReason? = nil) -> String {
            SettingsStateLine.text(hiddenUntil: until, wall: wall, quiet: quiet, timeZone: TimeZone(identifier: "UTC")!)
        }
        #expect(line() == "Shown")
        #expect(line(-1) == "Hidden until you show it")
        #expect(line(later.timeIntervalSince1970) == expected, "\(line(later.timeIntervalSince1970)) vs \(expected)")
        #expect(line(wall.timeIntervalSince1970 - 5) == "Shown", "a hide that has ended reads as shown")
        let words: [QuietReason: String] = [.systemAsleep: "Paused while the Mac sleeps", .displayAsleep: "Paused while the display sleeps",
                                            .screenLocked: "Paused while the screen is locked", .sessionInactive: "Paused while another user is active",
                                            .notOnActiveSpace: "Not shown on this Space", .aquaNotRunning: "Waiting for " + DictationSources.aqua.displayName]
        for reason in QuietReason.allCases where reason != .examBrowser {
            #expect(line(0, reason) == words[reason], "\(reason)")
        }
        // The precedence: the user's hide first, then the quiet reason, else Shown.
        #expect(line(-1, .displayAsleep) == "Hidden until you show it" && line(later.timeIntervalSince1970, .screenLocked) == expected)
        #expect(line(wall.timeIntervalSince1970 - 5, .displayAsleep) == "Paused while the display sleeps")
        // `exam-browser` has no words, and never a raw reason id (Settings closes in the same batch).
        #expect(line(0, .examBrowser) == "" && !line(0, .examBrowser).contains("exam"))
        #expect(line(-1, .examBrowser) == "Hidden until you show it")
        for reason in QuietReason.allCases { #expect(!line(0, reason).contains(reason.rawValue), "\(reason)") }
    }

    @Test func SettingsWindow_theStateLineRefreshesAtTheEndOfABatchWithoutATimer() async throws {
        let r = try SettingsRig()
        try r.openFromMenuBar()
        let content = try #require(r.settings.content)
        #expect(content.stateLabel.stringValue == "Shown")
        let armed = r.rig.stage.wake.armedTimers, timers = r.focus.timers.live.count
        r.machine.sink?.setQuiet(.displayAsleep, active: true)
        #expect(content.stateLabel.stringValue == "Paused while the display sleeps", "the end of the batch recomputes the line")
        r.machine.sink?.setQuiet(.displayAsleep, active: false)
        #expect(content.stateLabel.stringValue == "Shown")
        #expect(r.rig.stage.wake.armedTimers <= max(armed, 1) && r.focus.timers.live.count == timers,
                "Settings arms no timer of its own for the line: \(r.focus.timers.live)")
        // A hide's end is a scheduler deadline: a batch runs at that time and the line follows, with no timer of Settings'.
        let wall = r.rig.virtualClock!.wallNow.timeIntervalSince1970
        try writeControlLikeTheCLI(r.rig.store.root, ["hiddenUntil": wall + 120])
        await r.rig.spin(until: { content.stateLabel.stringValue.hasPrefix("Hidden until ") }, limit: 20)
        #expect(content.stateLabel.stringValue.hasPrefix("Hidden until "), "\(content.stateLabel.stringValue)")
        r.rig.advance(130)
        #expect(content.stateLabel.stringValue == "Shown", "\(content.stateLabel.stringValue)")
    }

    @Test func SettingsWindow_refreshesFromTheAppliedSettings() async throws {
        let r = try SettingsRig()
        try r.openFromMenuBar()
        let content = try #require(r.settings.content)
        #expect(content.hideButton.title == "Hide for 1 hour")
        // A change made in the terminal or the right-click menu shows too.
        try writeControlLikeTheCLI(r.rig.store.root, ["hiddenUntil": -1, "chatFolder": "/private/tmp"])
        await r.rig.spin(until: { content.hideButton.title == "Show" }, limit: 20)
        #expect(content.hideButton.title == "Show" && content.stateLabel.stringValue == "Hidden until you show it")
        #expect(content.folderLabel.stringValue == "/private/tmp", "\(content.folderLabel.stringValue)")
        try writeControlLikeTheCLI(r.rig.store.root, ["hiddenUntil": 0])
        await r.rig.spin(until: { content.hideButton.title == "Hide for 1 hour" }, limit: 20)
        #expect(content.hideButton.title == "Hide for 1 hour" && content.stateLabel.stringValue == "Shown")
    }

    // MARK: writes

    @Test func SettingsWindow_aFailedWritePutsTheControlBackAndExitThreeSaysSavedPending() async throws {
        let r = try SettingsRig()
        try r.openFromMenuBar()
        let content = try #require(r.settings.content)
        try r.stub.set("stub-exit", "2")
        press(content.hideButton)
        #expect(content.hideButton.title == "Show" && content.isPending(.hide))
        await r.rig.spin(until: { !r.lines("MENU write").isEmpty && !content.isPending(.hide) }, limit: 20)
        #expect(content.hideButton.title == "Hide for 1 hour", "a failed write puts the control back")
        #expect(content.message(for: .hide) == "the stub fails with 2", "and shows the CLI's one line under it: \(content.message(for: .hide))")
        // Exit 3: saved, not confirmed: the new value stays.
        try r.stub.set("stub-exit", "3")
        press(content.hideButton)
        await r.rig.spin(until: { r.lines("MENU write").count >= 2 && !content.isPending(.hide) }, limit: 20)
        #expect(content.hideButton.title == "Show" && content.message(for: .hide) == "saved, pending", "\(content.hideButton.title) \(content.message(for: .hide))")
        // Success clears the line.
        try r.stub.set("stub-exit", "0")
        press(content.hideButton)
        await r.rig.spin(until: { r.lines("MENU write").count >= 3 && !content.isPending(.hide) }, limit: 20)
        #expect(content.message(for: .hide) == "")
    }

    @Test func SettingsWindow_aDroppedPickEndsItsPendingStateAtTheNextApply() async throws {
        let r = try SettingsRig()
        try r.openFromMenuBar()
        let content = try #require(r.settings.content)
        try r.stub.set("stub-delay", "1")
        // The icon's hide runs; Settings' hide waits behind it; the icon's next hide replaces the waiting one, which therefore never completes.
        r.surface.open(); try r.surface.pick("Hide Clawd for 1 Hour")
        press(content.hideButton)
        #expect(content.isPending(.hide))
        r.surface.open(); try r.surface.pick("Hide Clawd for 1 Hour")
        #expect(r.lines("MENU drop").count == 1, "\(r.lines("MENU"))")
        #expect(content.isPending(.hide), "the replaced pick has no completion of its own")
        // The next apply ends it.
        try writeControlLikeTheCLI(r.rig.store.root, ["motion": "lively"])
        await r.rig.spin(until: { !content.isPending(.hide) }, limit: 20)
        #expect(!content.isPending(.hide))
        await r.rig.spin(until: { r.lines("MENU write").count >= 2 }, limit: 20)
    }

    @Test func SettingsWindow_aCompletionAfterACloseOrAReopenTouchesNoRow() async throws {
        let r = try SettingsRig()
        try r.openFromMenuBar()
        let first = try #require(r.settings.content)
        try r.stub.set("stub-exit", "2")
        try r.stub.set("stub-delay", "0.5")
        press(first.hideButton)
        // A reopen while the write runs: the open has a new number.
        r.runtime.menuOpenSettings(eventTime: 2)
        #expect(r.settings.content === first)
        // The reopen shows what the pet runs with and ends the pending state of the write it straddles: the failed write leaves no row pending.
        #expect(first.hideButton.title == "Hide for 1 hour" && !first.isPending(.hide), "the reopen refreshed the rows and ended the pending write")
        await r.rig.spin(until: { !r.lines("MENU write").isEmpty }, limit: 20)
        await r.rig.spin(0.2)
        #expect(first.hideButton.title == "Hide for 1 hour" && first.message(for: .hide) == "" && !first.isPending(.hide),
                "the failed write's answer belongs to the earlier open: it touches nothing")
        // A close, then a new open: a window of its own, untouched by the old answer.
        try r.stub.set("stub-delay", "0.3")
        press(first.hideButton)
        r.settings.close(.button)
        try r.openFromMenuBar()
        let second = try #require(r.settings.content)
        #expect(second !== first)
        await r.rig.spin(until: { r.lines("MENU write").count >= 2 }, limit: 20)
        await r.rig.spin(0.2)
        #expect(second.message(for: .hide) == "" && !second.isPending(.hide))
    }

    @Test func SettingsWindow_theFolderRowRunsChatFolderAndLogsNoPath() async throws {
        let r = try SettingsRig()
        try r.openFromMenuBar()
        let content = try #require(r.settings.content)
        press(content.chooseButton)
        #expect(r.box.pickers.count == 1 && r.picker.isUp && r.picker.startedAt == [NSHomeDirectory()], "\(r.picker.startedAt)")
        let chosen = "/private/tmp/clawd-folder-9d41c7"
        r.picker.choose(chosen)
        #expect(content.folderLabel.stringValue == chosen, "the row shows the new folder at once")
        await r.rig.spin(until: { r.cliRuns.count >= 1 }, limit: 20)
        #expect(r.cliRuns == ["[chat] [folder] [\(chosen)]"], "\(r.stub.calls)")
        await r.rig.spin(until: { !r.lines("MENU write").isEmpty }, limit: 20)
        #expect(r.lines("MENU write").first?.contains("key=chatFolder verb=chat+folder exit=0") == true, "\(r.lines("MENU"))")
        #expect(!r.rig.log.contains("9d41c7"), "no agent.log line carries the chosen folder's path")
        // A cancel writes nothing.
        press(content.chooseButton)
        r.picker.choose(nil)
        await r.rig.spin(0.3)
        #expect(r.cliRuns.count == 1)
    }

    // MARK: closing

    @Test func SettingsWindow_cmdWEscAndTheCloseButtonClose() throws {
        func fire(_ r: SettingsRig, _ how: String) throws {
            let window = try r.window()
            switch how {
            case "shortcut":
                #expect(window.performKeyEquivalent(with: keyEvent("w", code: 13, flags: [.command])), "Cmd-W is taken")
            case "esc": window.cancelOperation(nil)
            default:
                let button = try #require(window.standardWindowButton(.closeButton))
                _ = button.sendAction(button.action, to: button.target)
            }
        }
        for (how, reason) in [("shortcut", "shortcut"), ("esc", "esc"), ("button", "button")] {
            let r = try SettingsRig()
            try r.openFromMenuBar()
            let window = try r.window()
            try fire(r, how)
            #expect(!r.settings.isOpen && r.lines("SETTINGS close reason=\(reason)").count == 1, "\(how): \(r.lines("SETTINGS"))")
            #expect(r.box.dismissed.count == 1 && r.box.dismissed[0] === window && !window.canBecomeKey)
        }
        // Command with another modifier is not Cmd-W.
        let r = try SettingsRig()
        try r.openFromMenuBar()
        #expect(try !r.window().performKeyEquivalent(with: keyEvent("w", code: 13, flags: [.command, .shift])) && r.settings.isOpen)
    }

    @Test func SettingsWindow_quitStopsTheChatChildThenExitsZero() throws {
        let r = try SettingsRig()
        r.runtime.chatController.toggle(eventTime: 1)
        #expect(r.runtime.chatPanelIsOpen)
        try r.openFromMenuBar()
        let content = try #require(r.settings.content)
        press(content.quitButton)
        #expect(r.lines("SETTINGS close reason=quit").count == 1 && !r.settings.isOpen, "the window closes first")
        #expect(r.box.exits.count == 1 && r.box.exits[0].code == 0 && r.box.exits[0].stops == [.agentQuit], "\(r.box.exits)")
        #expect(r.lines("STATUS quit queued=0").count == 1)
        #expect(!r.runtime.chatPanelIsOpen)
    }

    @Test func MenuRules_theRuntimesQuitRowStopsTheChatThenExits() throws {
        let r = try SettingsRig()
        r.runtime.chatController.toggle(eventTime: 1)
        #expect(r.runtime.chatPanelIsOpen)
        // The right-click menu's Quit row reaches the runtime's own `menuQuit()`: the chat child stops, then the exit.
        r.runtime.menuQuit()
        #expect(r.box.exits.count == 1 && r.box.exits[0].code == 0 && r.box.exits[0].stops == [.agentQuit], "\(r.box.exits)")
        #expect(r.lines("STATUS quit queued=0").count == 1, "\(r.lines("STATUS"))")
        #expect(!r.runtime.chatPanelIsOpen)
    }

    @Test func SettingsWindow_aStandDownClosesItAndItRefusesToOpen() throws {
        let r = try SettingsRig()
        try r.openFromMenuBar()
        let window = try r.window()
        r.machine.examRunning = true
        r.runtime.workspaceApplication(launched: true, bundleIdentifier: "com.Respondus.LockDownBrowser", name: "LockDown Browser", pid: 77)
        #expect(!r.settings.isOpen && r.lines("SETTINGS close reason=exam").count == 1, "\(r.lines("SETTINGS"))")
        #expect(r.box.dismissed.count == 1 && r.box.dismissed[0] === window)
        let presented = r.box.presented.count
        r.settings.begin(cause: .statusMenu)
        r.runtime.menuOpenSettings(eventTime: 3)
        #expect(!r.settings.isOpen && r.box.presented.count == presented && r.lines("SETTINGS refuse reason=exam").count == 2, "\(r.lines("SETTINGS"))")
        #expect(r.surface.removed, "the icon is gone, so no pick can reach it")
        // The end of the stand-down: it opens again.
        r.machine.examRunning = false
        r.runtime.workspaceApplication(launched: false, bundleIdentifier: "com.Respondus.LockDownBrowser", name: "LockDown Browser", pid: 77)
        r.rig.advance(200)
        r.settings.begin(cause: .statusMenu)
        #expect(r.settings.isOpen)
        // D10, second run (SA6): the same stand-down with `aquaReact` off.
        let off = try SettingsRig(control: ["aquaReact": false, "generation": 0])
        try off.openFromMenuBar()
        let offWindow = try off.window()
        off.machine.examRunning = true
        off.runtime.workspaceApplication(launched: true, bundleIdentifier: "com.Respondus.LockDownBrowser", name: "LockDown Browser", pid: 77)
        #expect(!off.settings.isOpen && off.lines("SETTINGS close reason=exam").count == 1, "react off: \(off.lines("SETTINGS"))")
        #expect(off.box.dismissed.count == 1 && off.box.dismissed[0] === offWindow)
        off.settings.begin(cause: .statusMenu)
        #expect(!off.settings.isOpen && off.lines("SETTINGS refuse reason=exam").count == 1, "react off: \(off.lines("SETTINGS"))")
        off.machine.examRunning = false
        off.runtime.workspaceApplication(launched: false, bundleIdentifier: "com.Respondus.LockDownBrowser", name: "LockDown Browser", pid: 77)
        off.rig.advance(200)
        off.settings.begin(cause: .statusMenu)
        #expect(off.settings.isOpen, "react off: it opens again after the stand-down")
    }

    @Test func SettingsWindow_aStandDownWithThePickerUpCancelsItAndWritesNothing() async throws {
        for reason in SettingsCloseReason.allCases.sorted(by: { $0 == .exam && $1 != .exam }) {
            let r = try SettingsRig(requestSeams: SettingsRestartSuite.rigSeams)
            try r.openFromMenuBar()
            let window = try r.window()
            let content = try #require(r.settings.content)
            press(content.chooseButton)
            let picker = r.picker
            #expect(picker.isUp, "\(reason)")
            switch reason {
            case .exam:
                r.machine.examRunning = true
                r.runtime.workspaceApplication(launched: true, bundleIdentifier: "com.Respondus.LockDownBrowser", name: "LockDown Browser", pid: 77)
            case .button: window.onClose?(.button)
            case .shortcut: window.onClose?(.shortcut)
            case .esc: window.onClose?(.esc)
            case .quit: press(content.quitButton)
            case .restart:
                // A restart-only key is applied while this window's own restart-only pick runs: the CLI restarts the agent next, so the window
                // closes (picker first) before the process ends.
                let gate = r.stub.root.appendingPathComponent("release")
                try r.stub.set("stub-release", gate.path)
                press(try #require(content.button(for: .fullScreen(true))))
                await r.rig.spin(until: { !r.stub.started.isEmpty }, limit: 20)
                try writeControlLikeTheCLI(r.rig.store.root, ["overFullScreen": true])
                await r.rig.spin(until: { !r.settings.isOpen }, limit: 20)
                FileManager.default.createFile(atPath: gate.path, contents: Data())
            }
            #expect(!r.settings.isOpen && r.lines("SETTINGS close reason=\(reason.rawValue)").count == 1, "\(reason): \(r.lines("SETTINGS"))")
            let cancel = try #require(r.box.order.firstIndex(of: "picker-cancel"), "\(reason): the picker came down: \(r.box.order)")
            let dismiss = try #require(r.box.order.firstIndex(of: "dismiss"))
            #expect(picker.cancels == 1 && cancel < dismiss, "\(reason): the picker's cancel comes before the window goes: \(r.box.order)")
            // A completion that arrives after the close writes nothing.
            picker.choose("/private/tmp/clawd-late-choice")
            await r.rig.spin(0.3)
            #expect(r.cliRuns.count == (reason == .restart ? 1 : 0) && r.stub.started.allSatisfy { $0.first == "full-screen" } && (reason == .restart || r.lines("MENU").isEmpty), "\(reason): \(r.stub.calls)")
        }
        // D10, second run (SA6): the exam stand-down with the picker up and `aquaReact` off.
        let off = try SettingsRig(control: ["aquaReact": false, "generation": 0], requestSeams: SettingsRestartSuite.rigSeams)
        try off.openFromMenuBar()
        press(try #require(off.settings.content).chooseButton)
        let offPicker = off.picker
        #expect(offPicker.isUp)
        off.machine.examRunning = true
        off.runtime.workspaceApplication(launched: true, bundleIdentifier: "com.Respondus.LockDownBrowser", name: "LockDown Browser", pid: 77)
        #expect(!off.settings.isOpen && offPicker.cancels == 1, "react off: \(off.box.order)")
        offPicker.choose("/private/tmp/clawd-late-choice")
        await off.rig.spin(0.3)
        #expect(off.cliRuns.isEmpty && off.lines("MENU").isEmpty, "react off: \(off.stub.calls)")
    }

    @Test func SettingsWindow_aClosedSettingsWithAPickQueuedIsFreed() async throws {
        let r = try SettingsRig()
        // Clawd is active at the open, so the open asks for no activation and no deadline of the fake clock holds the opening meanwhile.
        r.focus.active = true
        try r.openFromMenuBar()
        let gate = r.stub.root.appendingPathComponent("release")
        try r.stub.set("stub-release", gate.path)
        weak var weakContent: SettingsContent?
        do {
            let content = try #require(r.settings.content)
            weakContent = content
            // One pick runs and is held at the gate; another waits behind it. The writer keeps both completions until each pick has run.
            press(content.hideButton)
            content.show(.motion)
            press(try #require(content.button(for: .walk(false))))
            #expect(r.lines("MENU write").isEmpty, "both picks are still in the writer: \(r.lines("MENU"))")
        }
        r.settings.close(.button)
        await r.rig.spin(0.2)
        #expect(weakContent == nil, "the closed window's sections are freed while its picks still wait in the writer")
        try r.stub.set("release", "")
        await r.rig.spin(until: { r.lines("MENU write").count >= 2 }, limit: 60)
        #expect(r.lines("MENU write").count == 2, "the writer still ran both picks: \(r.lines("MENU"))")
    }

    @Test func SettingsWindow_ownsNoWindowViewObserverOrTimerWhileClosed() throws {
        let r = try SettingsRig()
        #expect(r.settings.window == nil && r.settings.content == nil && !r.settings.isOpen)
        let armed = r.rig.stage.wake.armedTimers
        try r.openFromMenuBar()
        #expect(r.settings.window != nil && r.settings.content != nil)
        r.settings.close(.button)
        #expect(r.settings.window == nil && r.settings.content == nil && !r.settings.isOpen, "closed, it holds no window and no view")
        r.focus.timers.fire(atLeast: 0)
        #expect(r.focus.timers.live.isEmpty && r.focus.liveObservers == 0 && r.focus.livePressObservers == 0 && r.focus.liveFollowUps == 0,
                "no timer and no observer is left: \(r.focus.timers.live)")
        #expect(r.rig.stage.wake.armedTimers <= max(armed, 1))
        // A close while Clawd is active hands activation back; its steps are bounded one-shots, and nothing is left once they have run.
        let active = try SettingsRig()
        active.focus.frontmost = ChatAppRef(pid: 4001, launchDate: Date(timeIntervalSince1970: 1_000))
        try active.openFromMenuBar()
        active.clawdBecomesActive()
        #expect(active.focus.liveObservers == 1, "open, Settings follows other applications' activations")
        active.settings.close(.button)
        #expect(active.focus.liveObservers == 0 && active.settings.window == nil)
        #expect(!active.focus.timers.live.isEmpty, "the hand-back's first step is armed")
        var fires = 0
        while !active.focus.timers.live.isEmpty && fires < 8 { active.focus.timers.fire(atLeast: 0); fires += 1 }
        #expect(active.focus.timers.live.isEmpty && fires <= 3, "the steps end by themselves: \(fires) fires, \(active.focus.timers.live), \(active.lines("SETTINGS"))")
        // The files hold no observer or timer of their own.
        for file in try settingsFiles() where ["SettingsController.swift", "SettingsWindow.swift", "SettingsGeometry.swift", "SettingsFolderPicker.swift", "SettingsSections.swift", "SettingsChoices.swift"].contains((file.path as NSString).lastPathComponent) {
            for word in ["addObserver", "NSEvent.add", "NSTrackingArea", "asyncAfter", "DispatchSource", "scheduledTimer"] {
                #expect(!file.text.contains(word), "\((file.path as NSString).lastPathComponent) names \(word)")
            }
        }
    }

    // MARK: place and look

    @Test func SettingsWindow_opensOnThePointersDisplayFromTheMenuBarElseOnClawdsDisplay() throws {
        let r = try SettingsRig()
        let second = DisplayInfo(uuid: "E", frame: CGRect(x: 1920, y: 0, width: 1280, height: 800), visibleFrame: CGRect(x: 1920, y: 0, width: 1280, height: 775),
                                 backingScaleFactor: 2)
        r.machine.otherDisplays = [second]
        r.machine.pointer = CGPoint(x: 2500, y: 400)
        try r.openFromMenuBar()
        let titleBar = SettingsWindow.titleBarHeight
        var frame = try r.window().frame
        #expect(frame == SettingsGeometry.frame(visible: second.visibleFrame, titleBar: titleBar).frame, "the pointer's display: \(frame)")
        r.settings.close(.button)
        // The right-click menu's pick opens on Clawd's own display wherever the pointer is.
        r.runtime.menuOpenSettings(eventTime: 4)
        let clawd = r.machine.display
        frame = try r.window().frame
        #expect(frame == SettingsGeometry.frame(visible: clawd.visibleFrame, titleBar: titleBar).frame, "Clawd's display: \(frame)")
        // A pointer in no display falls back to Clawd's.
        r.settings.close(.button)
        r.machine.pointer = CGPoint(x: -5000, y: -5000)
        try r.openFromMenuBar()
        frame = try r.window().frame
        #expect(frame == SettingsGeometry.frame(visible: clawd.visibleFrame, titleBar: titleBar).frame)
    }

    @Test func SettingsWindow_aDisplayChangeAppliesTheGeometryAgain() throws {
        let r = try SettingsRig()
        try r.openFromMenuBar()
        let titleBar = SettingsWindow.titleBarHeight
        let before = try r.window().frame
        #expect(before == SettingsGeometry.frame(visible: r.machine.display.visibleFrame, titleBar: titleBar).frame)
        r.machine.display = DisplayInfo(uuid: "D", frame: CGRect(x: 0, y: 0, width: 1024, height: 576), visibleFrame: CGRect(x: 0, y: 30, width: 1024, height: 546),
                                        backingScaleFactor: 2)
        NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil)
        let after = try r.window().frame
        #expect(after != before && after == SettingsGeometry.frame(visible: r.machine.display.visibleFrame, titleBar: titleBar).frame, "\(after)")
        #expect(r.box.presented.count == 1, "a display change shows nothing again")
    }

    @Test func SettingsWindow_eachOpenStartsAtGeneral() throws {
        let r = try SettingsRig()
        #expect(SettingsSection.listed == [.general, .look, .motion, .bubble, .voice, .claudeCode, .about], "a section is listed once it is built, in R7's order")
        try r.openFromMenuBar()
        let content = try #require(r.settings.content)
        #expect(r.settings.section == .general && content.sidebar.numberOfRows == 7)
        content.sidebar.selectRowIndexes(IndexSet(integer: 5), byExtendingSelection: false)
        #expect(r.settings.section == .claudeCode, "the sidebar's selection shows its section")
        r.settings.close(.button)
        try r.openFromMenuBar()
        #expect(r.settings.section == .general && r.lines("SETTINGS open").allSatisfy { $0.hasSuffix("section=general") })
        // A second pick while it is open starts at General again, in the same window.
        r.settings.content?.sidebar.selectRowIndexes(IndexSet(integer: 1), byExtendingSelection: false)
        let window = r.settings.window
        r.runtime.menuOpenSettings(eventTime: 9)
        #expect(r.settings.section == .general && r.settings.window === window)
    }

    @Test func SettingsWindow_staysLightInDarkMode() throws {
        #expect(SettingsWindow.forcedAppearance == .aqua)
        let r = try SettingsRig()
        try r.openFromMenuBar()
        let window = try r.window()
        #expect(window.appearance?.name == .aqua)
        #expect(window.appearance?.bestMatch(from: [.aqua, .darkAqua]) == .aqua, "a dark system does not darken it")
    }

    @Test func SettingsWindow_theContentLaysOutInsideTheWindow() throws {
        let r = try SettingsRig()
        try r.openFromMenuBar()
        let window = try r.window()
        let content = try #require(r.settings.content)
        window.contentView?.layoutSubtreeIfNeeded()
        let root = content.root.frame
        #expect(root.width >= 640 && root.height >= 400, "\(root)")
        for view in [content.stateLabel, content.hideButton, content.quitButton] {
            #expect(view.frame.width > 0 && view.frame.height > 0 && content.root.bounds.intersects(view.convert(view.bounds, to: content.root)), "\(view)")
        }
        let column = try #require(content.sidebar.enclosingScrollView?.superview)
        #expect(abs(column.frame.width - SettingsGeometry.sidebarWidth) < 0.5 && content.sidebar.frame.width <= column.frame.width, "sidebar column \(column.frame), table \(content.sidebar.frame), root \(content.root.frame)")
    }
}

@MainActor func allButtons(in view: NSView) -> [NSButton] {
    var found: [NSButton] = []
    if let button = view as? NSButton { found.append(button) }
    for sub in view.subviews { found += allButtons(in: sub) }
    return found
}

@Suite("SettingsGeometry")
struct SettingsGeometrySuite {
    @Test func SettingsGeometry_frameTable() {
        let title = 28.0
        func place(_ w: Double, _ h: Double) -> SettingsGeometry.Placement {
            SettingsGeometry.frame(visible: CGRect(x: 0, y: 0, width: w, height: h), titleBar: title)
        }
        // A 13-inch MacBook Air at its default scale gets the full 960 x 600.
        var p = place(1470, 919)
        #expect(p.content == CGSize(width: 960, height: 600) && p.frame == CGRect(x: 255, y: 146, width: 960, height: 628) && !p.wholeFrame, "\(p)")
        p = place(1280, 777)
        #expect(p.content == CGSize(width: 960, height: 600) && p.frame == CGRect(x: 160, y: 75, width: 960, height: 628) && !p.wholeFrame, "\(p)")
        // A small scaled mode: 960 by about 486, and the section scrolls.
        p = place(1024, 546)
        #expect(p.content == CGSize(width: 960, height: 486) && p.frame == CGRect(x: 32, y: 16, width: 960, height: 514) && !p.wholeFrame, "\(p)")
        // Even 640 x 400 does not fit with its title bar: the whole visible frame, and the content scrolls.
        p = place(700, 380)
        #expect(p.wholeFrame && p.frame == CGRect(x: 0, y: 0, width: 700, height: 380) && p.content == CGSize(width: 700, height: 352), "\(p)")
        // Narrow but tall enough: the width follows the display down to the minimum.
        p = place(700, 500)
        #expect(p.content == CGSize(width: 668, height: 440) && p.frame == CGRect(x: 16, y: 16, width: 668, height: 468) && !p.wholeFrame, "\(p)")
        // Never under 640 x 400 unless the window is the whole frame.
        for w in stride(from: 600.0, through: 1600, by: 37) {
            for h in stride(from: 380.0, through: 1000, by: 41) {
                let q = place(w, h)
                if q.wholeFrame { #expect(q.frame.size == CGSize(width: w, height: h)) } else {
                    #expect(q.content.width >= 640 && q.content.height >= 400 && q.frame.maxX <= w && q.frame.maxY <= h, "\(w) x \(h): \(q)")
                }
            }
        }
        #expect(SettingsGeometry.sidebarWidth == 178)
    }
}
