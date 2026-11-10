import Testing
import Foundation
import AppKit
import ClawdCore
import ClawdRendering
import ClawdDesktop

// v3-orca-look round 2: the chat panel behaves and sizes like Orca's floating terminal. Close on a click elsewhere, the first open that must not
// close itself, the default and minimum size, the eight resize handles, the remembered geometry, the title-bar drag and the maximize toggle.
// Every focus request goes through the fake seams and every mouse gesture is a direct call: no test activates an application, makes a window
// key, posts an event or touches the pasteboard.

@Suite("ChatOrca", .serialized)
@MainActor
struct ChatOrcaBehaviorTests {
    private static let visible = CGRect(x: 0, y: 25, width: 1440, height: 875)
    private static let dia = ChatAppRef(pid: 4242, launchDate: Date(timeIntervalSince1970: 7), bundleID: "company.thebrowser.dia")

    private func terminalRig(saved: CGRect? = nil, store: MemoryChatGeometry? = nil, words: [String] = []) throws -> (TermControllerRig, MemoryChatGeometry) {
        let geometry = store ?? MemoryChatGeometry(saved)
        let r = try TermControllerRig(words: words, geometry: geometry)
        r.host.visible = Self.visible
        r.host.rect = CGRect(x: 300, y: 100, width: 520, height: 340)
        return (r, geometry)
    }

    // MARK: item 2: the first open

    @Test func ChatOrca_aQuickThirdPressOfTheOpeningSeriesDoesNotSpendTheOpensToken() throws {
        // The live log of gen 1, 2026-10-26 18:45:32: the double-click was handled 139 ms after its press (open at event time 100.0, handled at
        // 100.14); a third press 154 ms after the second sat in the queue and the window server had it already when the activation came.
        let r = ControllerRig()
        r.clock.now = 100.14
        r.open(at: 100.0)
        let panel = try #require(r.controller.livePanel)
        r.clock.advance(0.078)
        r.focus.pressAt = 100.154
        r.focus.active = true
        #expect(r.controller.activationVerdict() == .exempt, "\(r.lines("CHAT"))")
        #expect(r.lines("CHAT activate-spent").isEmpty && r.lines("CHAT active gen=1 cause=open").count == 1, "\(r.lines("CHAT"))")
        r.focus.drain()
        #expect(r.controller.isOpen && r.lines("CHAT close").isEmpty && r.controller.livePanel === panel, "the open stays")
        // A press well after the series is still another press: the next opening's token is spent by it.
        r.controller.close(.toggle)
        r.clock.now = 200.14
        r.open(at: 200.0)
        r.clock.advance(0.9)
        r.focus.pressAt = 200.9
        #expect(r.controller.activationVerdict() == .answeredByClose && r.lines("CHAT activate-spent gen=2 cause=outside-press").count == 1)
    }

    @Test func ChatOrca_theOpenSeriesIsDecidedByTheDoubleClickIntervalAndByWhereThePressWent() throws {
        // A real click elsewhere inside the interval: the press went to another application, so it spends the open's token whatever the clock says.
        let elsewhere = ControllerRig()
        elsewhere.clock.now = 300.14
        elsewhere.open(at: 300.0)
        elsewhere.clock.advance(0.078)
        elsewhere.focus.pressAt = 300.154
        elsewhere.focus.pressWentToClawd = false
        elsewhere.focus.active = true
        #expect(elsewhere.controller.activationVerdict() == .answeredByClose && elsewhere.lines("CHAT activate-spent gen=1 cause=outside-press").count == 1, "\(elsewhere.lines("CHAT"))")
        // A user whose double-click interval is 1 s: a slow third press at 0.9 s that went to Clawd is still the open's series.
        let slow = ControllerRig()
        slow.focus.doubleClick = 1.0
        slow.clock.now = 400.14
        slow.open(at: 400.0)
        slow.clock.advance(0.9)
        slow.focus.pressAt = 400.9
        slow.focus.active = true
        #expect(slow.controller.activationVerdict() == .exempt && slow.lines("CHAT activate-spent").isEmpty && slow.lines("CHAT active gen=1 cause=open").count == 1, "\(slow.lines("CHAT"))")
    }

    // MARK: item 1: close on a click elsewhere

    @Test func ChatOrca_anotherApplicationsActivationDoesNotClosePanel() throws {
        let r = ControllerRig()
        r.open()
        #expect(r.focus.liveObservers == 1 && r.focus.livePressObservers == 1 && r.focus.liveFollowUps == 0, "exactly today's two observers, and no follow-up monitor, while the panel is open")
        r.focus.otherAppBecomesActive(Self.dia)
        #expect(r.controller.isOpen && r.lines("CHAT close").isEmpty, "\(r.lines("CHAT"))")
        #expect(r.focus.liveObservers == 1 && r.focus.livePressObservers == 1 && r.focus.liveFollowUps == 0 && r.dismissed == 0)
        r.controller.close(.toggle)
        #expect(r.focus.liveObservers == 0 && r.focus.livePressObservers == 0, "both monitors are removed at the close")
    }

    @Test func ChatOrca_aClickInAnotherApplicationClosesThePanelAtItsUpAndHandsNothingBack() throws {
        let r = ControllerRig()
        r.clock.now = 50
        r.open(at: 50)
        r.focus.active = true
        r.focus.surfaceOwner = { $0 == CGPoint(x: 10, y: 10) ? "com.apple.inputmethod.Kotoeri.RomajiTyping" : "com.apple.Safari" }
        // A press on an exempt surface (an input method's candidate window, the dictation overlay) is not a click elsewhere.
        r.focus.outsidePress(ChatOutsidePress(time: 52, location: CGPoint(x: 10, y: 10)))
        r.focus.followUp(.up, CGPoint(x: 10, y: 10))
        #expect(r.controller.isOpen && r.focus.liveFollowUps == 0 && r.lines("CHAT press").isEmpty, "an exempt surface opens no press and closes nothing: \(r.lines("CHAT"))")
        // Nor is one while the frontmost application is an exempt one (the screenshot crosshair).
        r.focus.frontLabel = "com.apple.screencaptureui"
        r.focus.outsidePress(ChatOutsidePress(time: 52.2, location: CGPoint(x: 800, y: 500)))
        r.focus.followUp(.up, CGPoint(x: 800, y: 500))
        #expect(r.controller.isOpen && r.focus.liveFollowUps == 0 && r.lines("CHAT press").isEmpty, "the screenshot UI in front: the press is its own: \(r.lines("CHAT"))")
        r.focus.frontLabel = nil
        // The open's click series is not looked at here: a press the global monitor reports went to another application.
        r.focus.outsidePress(ChatOutsidePress(time: 50.3, location: CGPoint(x: 800, y: 500)))
        #expect(r.controller.isOpen, "the down only opens a press")
        r.focus.followUp(.up, CGPoint(x: 800, y: 500))
        #expect(!r.controller.isOpen && r.lines("CHAT close reason=outside gen=1").count == 1, "\(r.lines("CHAT"))")
        #expect(r.lines("CHAT close reason=outside gen=1").first?.hasSuffix(" by=press:com.apple.Safari") == true, "\(r.lines("CHAT close"))")
        #expect(r.focus.handBacks.isEmpty && r.focus.deactivationRequests == 1, "the click's own application takes the activation")
        #expect(r.focus.livePressObservers == 0)
        // Closed: a press does nothing at all.
        r.focus.outsidePress(ChatOutsidePress(time: 60))
        r.focus.followUp(.up, .zero)
        #expect(r.lines("CHAT close").count == 1)
    }

    @Test func ChatOrca_anExemptSurfaceAbsorbsOnlyTheReturnToTheApplicationBeforeIt() throws {
        let shot = ChatAppRef(pid: 301, bundleID: "com.apple.screencaptureui")
        // Clawd was not in front: the recorded target (pid 4001) is. The screenshot UI, then another application: an ordinary activation (which
        // closes nothing: only the mouse-up of a click does).
        let other = ControllerRig()
        other.clock.now = 10
        other.open(at: 10)
        other.focus.otherAppBecomesActive(shot)
        #expect(other.controller.isOpen, "Cmd+Shift+4 takes the activation and the panel stays")
        other.focus.otherAppBecomesActive(Self.dia)
        #expect(other.controller.isOpen && other.lines("CHAT close").isEmpty && other.lines("CHAT exempt-return").isEmpty, "\(other.lines("CHAT"))")
        #expect(other.lines("CHAT app-active gen=1 app=company.thebrowser.dia").count == 1 && other.controller.handBackTarget == Self.dia, "\(other.lines("CHAT"))")

        // The screenshot UI gives the activation back to the application that was in front: absorbed, once.
        let back = ControllerRig()
        back.clock.now = 10
        back.open(at: 10)
        let target = try #require(back.focus.frontmost)
        back.focus.otherAppBecomesActive(shot)
        back.focus.otherAppBecomesActive(target)
        #expect(back.controller.isOpen && back.lines("CHAT exempt-return gen=1").count == 1, "\(back.lines("CHAT"))")
        #expect(back.lines("CHAT app-active").isEmpty && back.controller.handBackTarget == target, "the return is absorbed: no ordinary activation, the target stays")
        back.focus.otherAppBecomesActive(Self.dia)
        #expect(back.controller.isOpen && back.lines("CHAT exempt-return gen=1").count == 1, "\(back.lines("CHAT"))")
        #expect(back.lines("CHAT app-active gen=1 app=company.thebrowser.dia").count == 1 && back.controller.handBackTarget == Self.dia, "the next activation is an ordinary one")

        // Clawd was in front (its open activation landed): the return is Clawd's own activation, and another application's is an ordinary one.
        func clawdInFront() -> ControllerRig {
            let r = ControllerRig()
            r.clock.now = 10
            r.open(at: 10)
            r.focus.active = true
            #expect(r.controller.activationVerdict() == .exempt)
            r.clock.advance(5)
            r.controller.appResigned()
            r.focus.active = false
            r.focus.otherAppBecomesActive(shot)
            return r
        }
        let toOther = clawdInFront()
        toOther.focus.otherAppBecomesActive(Self.dia)
        #expect(toOther.controller.isOpen && toOther.lines("CHAT close").isEmpty && toOther.lines("CHAT app-active gen=1").count == 1, "\(toOther.lines("CHAT"))")
        let toClawd = clawdInFront()
        toClawd.focus.active = true
        #expect(toClawd.controller.activationVerdict() == .exempt && toClawd.lines("CHAT active gen=1 cause=return").count == 1, "\(toClawd.lines("CHAT"))")
        toClawd.focus.drain()
        #expect(toClawd.controller.isOpen)

        // Presses: after an exempt surface took the activation, a press whose frontmost application is not exempt is still a click elsewhere.
        let press = ControllerRig()
        press.clock.now = 10
        press.open(at: 10)
        press.focus.surfaceOwner = { _ in "com.apple.Safari" }
        press.focus.otherAppBecomesActive(shot)
        press.focus.frontLabel = "com.electron.aqua-voice"
        press.focus.outsidePress(ChatOutsidePress(time: 12, location: CGPoint(x: 700, y: 400)))
        press.focus.followUp(.up, CGPoint(x: 700, y: 400))
        #expect(press.controller.isOpen && press.lines("CHAT press").isEmpty, "Aqua Voice in front: the press is not a click elsewhere")
        press.focus.frontLabel = "com.apple.Safari"
        press.focus.outsidePress(ChatOutsidePress(time: 13, location: CGPoint(x: 700, y: 400)))
        press.focus.followUp(.up, CGPoint(x: 700, y: 400))
        #expect(!press.controller.isOpen && press.lines("CHAT close reason=outside").count == 1, "\(press.lines("CHAT"))")
    }

    @Test func ChatOrca_aSystemDialogThatComesForwardWhileOpenDoesNotCloseThePanel() throws {
        // 2026-10-27 08:24: the user's chat closed 1.4 s after its open with by=app:com.apple.UserNotificationCenter.
        let dialog = ChatAppRef(pid: 302, bundleID: "com.apple.UserNotificationCenter")
        let r = ControllerRig()
        r.clock.now = 10
        r.open(at: 10)
        let target = try #require(r.focus.frontmost)
        r.focus.otherAppBecomesActive(dialog)
        #expect(r.controller.isOpen, "the dialog takes the activation and the panel stays: \(r.lines("CHAT"))")
        r.focus.otherAppBecomesActive(target)
        #expect(r.controller.isOpen && r.lines("CHAT exempt-return gen=1").count == 1, "the dialog hands the activation back: \(r.lines("CHAT"))")
        // A press on a dialog (its Allow or OK button) is not a click elsewhere either.
        r.focus.surfaceOwner = { _ in "com.apple.SecurityAgent" }
        r.focus.frontLabel = "com.apple.SecurityAgent"
        r.focus.outsidePress(ChatOutsidePress(time: 12, location: CGPoint(x: 700, y: 400)))
        r.focus.followUp(.up, CGPoint(x: 700, y: 400))
        #expect(r.controller.isOpen && r.lines("CHAT close").isEmpty && r.lines("CHAT press").isEmpty, "\(r.lines("CHAT"))")
        // Another application's activation after it closes nothing either; its click does, at the mouse-up.
        r.focus.surfaceOwner = { _ in "company.thebrowser.dia" }
        r.focus.frontLabel = nil
        r.focus.otherAppBecomesActive(Self.dia)
        #expect(r.controller.isOpen && r.lines("CHAT close").isEmpty, "\(r.lines("CHAT"))")
        r.focus.outsidePress(ChatOutsidePress(time: 14, location: CGPoint(x: 700, y: 400)))
        r.focus.followUp(.up, CGPoint(x: 700, y: 400))
        #expect(!r.controller.isOpen && r.lines("CHAT close reason=outside").first?.hasSuffix(" by=press:company.thebrowser.dia") == true, "\(r.lines("CHAT"))")
    }

    @Test func ChatOrca_theExemptionListCoversThisMacsSurfacesAndTheOwnerIsFoundFromThePath() throws {
        // Each is a bundle identifier read from an Info.plist on this Mac (see ChatController.exemptBundlePrefixes).
        let exempt = ["com.apple.screencaptureui", "com.apple.screenshot.launcher", "com.apple.inputmethod.Kotoeri.RomajiTyping", "com.apple.inputmethod.Kotoeri.KanaTyping",
                      "com.apple.inputmethod.ironwood", "com.apple.CharacterPaletteIM", "com.apple.50onPaletteIM", "com.apple.PressAndHold", "com.apple.TextInputSwitcher",
                      "com.apple.TextInputMenuAgent", "com.apple.TextInputUI.xpc.CursorUIViewService", "com.electron.aqua-voice", "com.electron.aqua-voice.helper",
                      "aquavoice.macOSBridge", "com.tomarai.aquaringbridge", "com.apple.UserNotificationCenter", "com.apple.SecurityAgent",
                      "com.apple.LocalAuthentication.UIAgent", "com.apple.LocalAuthenticationRemoteService", "com.apple.tcc.AuthorizationPromptService",
                      "com.apple.coreservices.uiagent"]
        for bundle in exempt { #expect(ChatController.isExempt(bundleID: bundle), "\(bundle) is exempt") }
        for bundle in ["com.apple.finder", "com.apple.Safari", "company.thebrowser.dia", "com.apple.TextInputUIAgent", "com.apple.CharacterPicker",
                       "com.apple.systempreferences", "com.apple.notificationcenterui"] {
            #expect(!ChatController.isExempt(bundleID: bundle), "\(bundle) is not")
        }
        #expect(!ChatController.isExempt(bundleID: nil))

        // The owner of an `.appex` or `.xpc` process is its innermost bundle, not the application around it.
        func bundle(_ path: String) -> String? { ChatProcessOwner.enclosingBundle(ofExecutable: path)?.path }
        #expect(bundle("/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder") == "/System/Library/CoreServices/Finder.app")
        #expect(bundle("/System/Library/Input Methods/JapaneseIM-RomajiTyping.app/Contents/PlugIns/JapaneseIM-RomajiTyping.appex/Contents/MacOS/JapaneseIM-RomajiTyping")
                == "/System/Library/Input Methods/JapaneseIM-RomajiTyping.app/Contents/PlugIns/JapaneseIM-RomajiTyping.appex")
        #expect(bundle("/System/Library/PrivateFrameworks/TextInputUIMacHelper.framework/Versions/A/XPCServices/CursorUIViewService.xpc/Contents/MacOS/CursorUIViewService")
                == "/System/Library/PrivateFrameworks/TextInputUIMacHelper.framework/Versions/A/XPCServices/CursorUIViewService.xpc")
        #expect(bundle("/sbin/launchd") == nil)
        // Read from the Mac's own bundles when they are there.
        for (path, id) in [("/System/Library/CoreServices/Finder.app/Contents/MacOS/Finder", "com.apple.finder"),
                           ("/System/Library/PrivateFrameworks/TextInputUIMacHelper.framework/Versions/A/XPCServices/CursorUIViewService.xpc/Contents/MacOS/CursorUIViewService",
                            "com.apple.TextInputUI.xpc.CursorUIViewService")] where FileManager.default.fileExists(atPath: path) {
            #expect(ChatProcessOwner.bundleID(ofExecutable: path) == id, "\(path)")
        }
        // A real process is found from proc_pidpath; the label is a bundle identifier or a file name, never a path.
        let label = try #require(ChatProcessOwner.label(pid: getpid()))
        #expect(!label.contains("/") && !label.isEmpty && label.count <= 80, "\(label)")
        #expect(ChatProcessOwner.sanitized("/Users/someone/My App 2") == "_Users_someone_My_App_2")
    }

    @Test func ChatOrca_anOutsideCloseSaysWhatClosedIt() throws {
        // An activation closes nothing, so no close line says `by=app:`; the click that caused it closes at its up and names the application.
        let app = ControllerRig()
        app.open()
        app.focus.pressed = 1
        app.focus.otherAppBecomesActive(ChatAppRef(pid: 77, bundleID: nil, executableName: "My Helper"))
        app.focus.followUp(.up, .zero)
        #expect(app.lines("CHAT close reason=outside gen=1").first?.hasSuffix(" by=press:exe:My_Helper") == true, "\(app.lines("CHAT close"))")
        let press = ControllerRig()
        press.open()
        press.focus.surfaceOwner = { _ in "com.apple.dock" }
        press.focus.outsidePress(ChatOutsidePress(time: 5, location: CGPoint(x: 3, y: 4)))
        press.focus.followUp(.up, CGPoint(x: 3, y: 4))
        #expect(press.lines("CHAT close reason=outside gen=1").first?.hasSuffix(" by=press:com.apple.dock") == true, "\(press.lines("CHAT close"))")
        let uncaused = ControllerRig()
        uncaused.open()
        uncaused.focus.active = true
        uncaused.clock.advance(5)
        _ = uncaused.controller.activationVerdict()
        uncaused.focus.drain()
        #expect(uncaused.lines("CHAT close reason=outside gen=1").first?.hasSuffix(" by=uncaused") == true, "\(uncaused.lines("CHAT"))")
    }

    @Test func ChatOrca_aCloseAsOutsideKeepsClaudeRunningAndTheNextOpenReattaches() async throws {
        let (r, _) = try terminalRig()
        r.open()
        #expect(await r.waitScreen("tty="))
        let pid = try #require(r.path.childPid)
        r.focus.surfaceOwner = { _ in "company.thebrowser.dia" }
        r.focus.outsidePress(ChatOutsidePress(time: 5, location: CGPoint(x: 800, y: 500)))
        r.focus.followUp(.up, CGPoint(x: 800, y: 500))
        #expect(!r.controller.isOpen)
        #expect(r.lines("CHAT close reason=outside gen=1 keys=0").count == 1, "\(r.lines("CHAT close"))")
        #expect(r.path.hasLiveChild && r.path.childPid == pid, "claude keeps running")
        r.open(at: 2)
        #expect(r.lines("CHAT reattach gen=2 pid=\(pid)").count == 1)
        await r.finish()
    }

    // MARK: item 3: size

    @Test func ChatOrca_theDefaultIs360By240AndTheMinimumIs300By200() throws {
        #expect(ChatPanelPlacement.terminalWidth == 360 && ChatPanelPlacement.terminalMaxHeight == 240)
        let canvas = CGRect(x: 600, y: 100, width: 60, height: 48)
        let rect = ChatPanelPlacement.rect(canvas: canvas, bubbleSide: .below, visible: Self.visible,
                                           width: ChatPanelPlacement.terminalWidth, maxHeight: ChatPanelPlacement.terminalMaxHeight)
        #expect(rect.size == CGSize(width: 360, height: 240), "\(rect)")
        #expect(ChatPanelGeometry.minSize == CGSize(width: 300, height: 200))
        // Below the minimum, the minimum wins; above the screen, the screen less 8 pt each side wins.
        let small = ChatPanelGeometry.clamp(CGRect(x: 100, y: 100, width: 250, height: 150), in: Self.visible)
        #expect(small.size == CGSize(width: 300, height: 200))
        let huge = ChatPanelGeometry.clamp(CGRect(x: -50, y: -50, width: 4000, height: 4000), in: Self.visible)
        #expect(huge == CGRect(x: 8, y: 33, width: 1424, height: 859), "\(huge)")
    }

    // MARK: item 4: resize

    @Test func ChatOrca_theEightHandlesSitWhereOrcasDo() throws {
        let size = CGSize(width: 520, height: 340)
        #expect(ChatPanelGeometry.handleFrame(.n, in: size) == CGRect(x: 8, y: 332, width: 504, height: 8))
        #expect(ChatPanelGeometry.handleFrame(.s, in: size) == CGRect(x: 8, y: 0, width: 504, height: 8))
        #expect(ChatPanelGeometry.handleFrame(.w, in: size) == CGRect(x: 0, y: 8, width: 8, height: 324))
        #expect(ChatPanelGeometry.handleFrame(.e, in: size) == CGRect(x: 512, y: 8, width: 8, height: 324))
        #expect(ChatPanelGeometry.handleFrame(.nw, in: size) == CGRect(x: 0, y: 328, width: 12, height: 12))
        #expect(ChatPanelGeometry.handleFrame(.se, in: size) == CGRect(x: 508, y: 0, width: 12, height: 12))
        let (r, _) = try terminalRig()
        r.open()
        let container = try #require(r.panel.terminal)
        #expect(container.handles.count == 8)
        for edge in ChatPanelGeometry.Edge.allCases {
            #expect(container.handle(edge).frame == ChatPanelGeometry.handleFrame(edge, in: container.bounds.size), "\(edge)")
        }
        r.controller.close(.toggle)
    }

    @Test func ChatOrca_draggingAnEdgeResizesThePanelAndTheChildGetsTheNewWindowSize() async throws {
        let (r, geometry) = try terminalRig()
        r.open()
        #expect(await r.waitScreen("tty="))
        let before = r.panel.frame
        let container = try #require(r.panel.terminal)
        let handle = container.handle(.se)
        // The south-east corner dragged 120 right and 60 down (y up: dy = -60).
        handle.beginDrag(at: CGPoint(x: 1000, y: 500))
        handle.drag(to: CGPoint(x: 1120, y: 440))
        handle.endDrag()
        #expect(r.panel.frame == CGRect(x: before.minX, y: before.minY - 60, width: before.width + 120, height: before.height + 60), "\(r.panel.frame)")
        let dims = try #require(r.terminalView.terminalDimensions)
        #expect(dims.cols > 0 && dims.rows > 0)
        #expect(await r.waitScreen("W \(dims.cols)x\(dims.rows)"), "the stub saw SIGWINCH with the grid's size \(dims): \(r.screen)")
        #expect(geometry.saves == 1 && geometry.rect(in: Self.visible) == r.panel.frame, "the size is remembered when the gesture ends")
        // The minimum stops a drag that goes below it, pinning the opposite edge (north-west corner pulled far inwards).
        let nw = container.handle(.nw)
        let start = r.panel.frame
        nw.beginDrag(at: CGPoint(x: 0, y: 0))
        nw.drag(to: CGPoint(x: 900, y: -900))
        nw.endDrag()
        #expect(r.panel.frame.size == CGSize(width: 300, height: 200) && r.panel.frame.maxX == start.maxX && r.panel.frame.minY == start.minY, "\(r.panel.frame)")
        await r.finish()
    }

    @Test func ChatOrca_aResizeStopsAtTheScreensEdgeMargin() throws {
        let start = CGRect(x: 600, y: 100, width: 520, height: 340)
        let wide = ChatPanelGeometry.resized(start, edge: .e, dx: 5000, dy: 0, in: Self.visible)
        #expect(wide.maxX == Self.visible.maxX - 8 && wide.minX == 600)
        let tall = ChatPanelGeometry.resized(start, edge: .n, dx: 0, dy: 5000, in: Self.visible)
        #expect(tall.maxY == Self.visible.maxY - 8 && tall.minY == 100)
        let low = ChatPanelGeometry.resized(start, edge: .s, dx: 0, dy: -5000, in: Self.visible)
        #expect(low.minY == Self.visible.minY + 8 && low.maxY == 440)
    }

    @Test func ChatOrca_theSizeAndPositionAreRestoredAtTheNextOpenInsideTheScreen() async throws {
        let store = MemoryChatGeometry()
        let (r, _) = try terminalRig(store: store)
        r.open()
        let container = try #require(r.panel.terminal)
        container.titleBarView.beginDrag(at: CGPoint(x: 500, y: 500))
        container.titleBarView.drag(to: CGPoint(x: 560, y: 450))
        container.titleBarView.endDrag()
        let moved = r.panel.frame
        #expect(store.rect(in: Self.visible) == moved)
        r.controller.close(.toggle)
        r.open(at: 2)
        #expect(r.panel.frame == CGRect(x: 300, y: 100, width: 520, height: 340), "the next open is beside Clawd at the size the user left, not where it was dragged")
        r.controller.close(.toggle)
        await r.finish()

        // A saved position off the screen, and a saved size under the minimum, are pulled in.
        let (off, _) = try terminalRig(saved: CGRect(x: 5000, y: -300, width: 300, height: 100))
        off.open()
        let frame = off.panel.frame
        #expect(frame == CGRect(x: 300, y: 100, width: 300, height: 200), "\(frame)")
        off.controller.close(.toggle)
        await off.finish()

        // Nothing saved: beside Clawd, at the host's placement.
        let (fresh, _) = try terminalRig()
        fresh.open()
        #expect(fresh.panel.frame == CGRect(x: 300, y: 100, width: 520, height: 340))
        fresh.controller.close(.toggle)
        await fresh.finish()
    }

    @Test func ChatOrca_theGeometryFileLivesInTheAgentsPrivateStateAndSurvivesAReload() throws {
        let store = try artifactStore()
        let file = FileChatGeometry(store: store)
        #expect(file.load() == nil && file.loadAnchor() == nil)
        let anchor = ChatAnchor(display: "UUID-A", anchorX: .right, anchorY: .bottom, offsetX: 12, offsetY: 34, width: 560, height: 360)
        #expect(file.saveAnchor(anchor))
        #expect(FileChatGeometry(store: store).loadAnchor() == anchor && FileChatGeometry(store: store).load() == nil)
        #expect(FileChatGeometry.fileName == "chat-panel.json" && FileChatGeometry.privateFileName == "chat-private/chat-panel.json")
        #expect(FileManager.default.fileExists(atPath: try store.url(FileChatGeometry.privateFileName).path))
        #expect(!FileManager.default.fileExists(atPath: try store.url(FileChatGeometry.fileName).path))
        try store.write(Data("{\"version\":2,\"anchorX\":\"left\",\"anchorY\":\"top\",\"offsetX\":1,\"offsetY\":2,\"width\":-5,\"height\":9}".utf8), to: FileChatGeometry.privateFileName)
        #expect(file.loadAnchor() == nil, "a width under zero is no geometry")
        try store.write(Data("{\"x\":1,\"y\":2,\"width\":-5,\"height\":9}".utf8), to: FileChatGeometry.privateFileName)
        #expect(file.load() == nil, "a width under zero is no geometry")
    }

    // MARK: item 5: move

    @Test func ChatOrca_dragTheTitleBarMovesThePanelAndKeepsItOnTheScreen() async throws {
        let (r, geometry) = try terminalRig()
        r.open()
        let before = r.panel.frame
        let bar = try #require(r.panel.terminal).titleBarView
        bar.beginDrag(at: CGPoint(x: 400, y: 300))
        bar.drag(to: CGPoint(x: 450, y: 270))
        #expect(r.panel.frame == before.offsetBy(dx: 50, dy: -30), "\(r.panel.frame)")
        bar.drag(to: CGPoint(x: 9000, y: 9000))
        #expect(r.panel.frame.maxX == Self.visible.maxX - 8 && r.panel.frame.maxY == Self.visible.maxY - 8 && r.panel.frame.size == before.size, "\(r.panel.frame)")
        bar.endDrag()
        #expect(geometry.saves == 1 && geometry.rect(in: Self.visible) == r.panel.frame)
        // A press with no movement saves nothing.
        bar.beginDrag(at: .zero); bar.endDrag()
        #expect(geometry.saves == 1)
        // A re-measure (a walk's end) leaves a panel the user placed where it is.
        r.host.rect = CGRect(x: 10, y: 10, width: 520, height: 340)
        r.controller.replace()
        #expect(r.panel.frame.maxX == Self.visible.maxX - 8)
        r.controller.close(.toggle)
        await r.finish()
    }

    // MARK: item 6: the title bar

    @Test func ChatOrca_theTitleBarHasOneTabMaximizeAndCloseOnly() throws {
        let (r, _) = try terminalRig()
        r.open()
        let container = try #require(r.panel.terminal)
        #expect(container.headerText == "Claude Code", "the fallback title")
        container.setTitle("\u{2733} Claude Code")
        #expect(container.headerText == "\u{2733} Claude Code", "the title claude set")
        container.setTitle("")
        #expect(container.headerText == "Claude Code")
        let buttons = container.titleBarView.subviews.compactMap { $0 as? NSButton }
        #expect(buttons.count == 2 && buttons.contains { $0 === container.maximizeButton } && buttons.contains { $0 === container.closeButton }, "no new-agent control")
        #expect(container.maximizeButton.frame.maxX < container.closeButton.frame.minX && container.closeButton.frame.width == 18 && container.maximizeButton.frame.width == 18, "Orca's 24 pt buttons at the 0.75 text scale")
        #expect(container.maximizeButton.acceptsFirstMouse(for: nil) && container.titleBarView.acceptsFirstMouse(for: nil))
        #expect(ChatLook.tabWidth == 135 && ChatLook.dark.tabFill == ChatLook.RGB(0x252525) && ChatLook.light.tabFill == ChatLook.RGB(0xf0f0f0))
        r.controller.close(.toggle)
    }

    @Test func ChatOrca_maximizeTogglesToTheVisibleFrameAndBack() async throws {
        let (r, geometry) = try terminalRig()
        r.open()
        let before = r.panel.frame
        let container = try #require(r.panel.terminal)
        container.maximizeButton.performClick(nil)
        #expect(r.panel.frame == Self.visible.insetBy(dx: 12, dy: 12), "\(r.panel.frame)")
        #expect(container.isMaximized && container.maximizeButton.accessibilityLabel() == "Restore chat")
        #expect(container.handles.allSatisfy { $0.isHidden }, "Orca unmounts the handles while maximized")
        // A drag of the bar does nothing while maximized.
        container.titleBarView.beginDrag(at: .zero); container.titleBarView.drag(to: CGPoint(x: 80, y: 80)); container.titleBarView.endDrag()
        #expect(r.panel.frame == Self.visible.insetBy(dx: 12, dy: 12))
        // A re-measure keeps it maximized.
        r.host.visible = CGRect(x: 0, y: 25, width: 1000, height: 700)
        r.controller.replace()
        #expect(r.panel.frame == CGRect(x: 0, y: 25, width: 1000, height: 700).insetBy(dx: 12, dy: 12))
        // The bar's double-click toggles it back.
        container.titleBarView.onGesture?(.toggleMaximize)
        #expect(r.panel.frame == before && !container.isMaximized && container.maximizeButton.accessibilityLabel() == "Maximize chat", "\(r.panel.frame)")
        #expect(geometry.saves == 0 && geometry.maximizedSaves == [true, false], "the flag is saved, the rect is not")
        #expect(container.handles.allSatisfy { !$0.isHidden }, "the handles are back after Restore")
        r.controller.close(.toggle)
        await r.finish()
    }

    // MARK: round 3: one window size per resize drag, handles and the tab label

    /// The "W <C>x<R>" lines the stub has printed on the screen so far (one per SIGWINCH it received).
    private func windowSizeLines(_ screen: String) -> [Substring] {
        screen.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { $0.hasPrefix("W ") }.map { Substring($0) }
    }

    @Test func ChatOrca_aTwentyStepResizeDragSendsTheChildExactlyOneWindowSizeAtItsEnd() async throws {
        let (r, geometry) = try terminalRig()
        r.open()
        #expect(await r.waitScreen("tty="))
        let container = try #require(r.panel.terminal)
        let handle = container.handle(.se)
        let dimsBefore = try #require(r.terminalView.terminalDimensions)
        let seen = windowSizeLines(r.screen).count
        // The south-east corner dragged 200 pt to the right in twenty steps: about forty columns of a 10 pt face are crossed.
        handle.beginDrag(at: CGPoint(x: 1000, y: 500))
        for step in 1...20 {
            handle.drag(to: CGPoint(x: 1000 + 10 * CGFloat(step), y: 500))
            let held = try #require(r.terminalView.terminalDimensions)
            #expect(held.cols == dimsBefore.cols && held.rows == dimsBefore.rows, "step \(step): the grid keeps its size while the drag runs: \(held)")
        }
        #expect(r.panel.frame.width == 720, "the panel itself follows every step")
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(windowSizeLines(r.screen).count == seen, "no window size reaches the child during the drag: \(r.screen)")
        handle.endDrag()
        let dims = try #require(r.terminalView.terminalDimensions)
        #expect(dims.cols > dimsBefore.cols, "the grid is wider at the end: \(dims) from \(dimsBefore)")
        #expect(await r.waitScreen("W \(dims.cols)x\(dims.rows)"), "the stub saw the end size: \(r.screen)")
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(windowSizeLines(r.screen).count == seen + 1, "exactly one SIGWINCH for the whole drag: \(windowSizeLines(r.screen))")
        #expect(geometry.saves == 1)
        // The terminal sits under the title bar again at the new size.
        #expect(r.terminalView.frame.width == container.bounds.width - 2 - ChatLook.terminalPadding
            && r.terminalView.frame.maxY == container.titleBarView.frame.minY - ChatLook.terminalPadding)
        // Maximize and restore are one resize each.
        let beforeMax = windowSizeLines(r.screen).count
        container.maximizeButton.performClick(nil)
        let maxDims = try #require(r.terminalView.terminalDimensions)
        #expect(await r.waitScreen("W \(maxDims.cols)x\(maxDims.rows)"))
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(windowSizeLines(r.screen).count == beforeMax + 1, "\(windowSizeLines(r.screen))")
        await r.finish()
    }

    @Test func ChatOrca_theHandlesTakeAllTheirEightPointsAndTheTerminalSitsInOrcasPadding() throws {
        let (r, _) = try terminalRig()
        r.open()
        let container = try #require(r.panel.terminal)
        container.layoutSubtreeIfNeeded()
        let size = container.bounds.size
        // Every handle takes the mouse over all of its frame, as Orca's do (FloatingTerminalResizeHandles.tsx:9-16), also where e, w and s run
        // over the terminal.
        let east = container.handle(.e)
        #expect(east.hitTest(CGPoint(x: east.frame.maxX - 1, y: 100)) === east && east.hitTest(CGPoint(x: east.frame.minX + 1, y: 100)) === east)
        #expect(container.hitTest(CGPoint(x: size.width - 6, y: 100)) === east, "the outer 8 pt on the right resize")
        let south = container.handle(.s)
        #expect(south.hitTest(CGPoint(x: 100, y: south.frame.minY + 1)) === south && south.hitTest(CGPoint(x: 100, y: south.frame.maxY - 1)) === south)
        let west = container.handle(.w)
        #expect(west.hitTest(CGPoint(x: west.frame.minX + 1, y: 100)) === west && west.hitTest(CGPoint(x: west.frame.maxX - 1, y: 100)) === west)
        let north = container.handle(.n)
        #expect(north.hitTest(CGPoint(x: 100, y: north.frame.minY + 1)) === north && north.hitTest(CGPoint(x: 100, y: north.frame.maxY - 1)) === north)
        let corner = container.handle(.se)
        #expect(corner.hitTest(CGPoint(x: corner.frame.midX, y: corner.frame.midY)) === corner)
        #expect(east.hitTest(CGPoint(x: 5, y: 5)) == nil, "a point outside a handle's frame never hits it")
        #expect(east.scrollTarget === r.terminalView, "the wheel over a handle goes to the terminal")
        // Past the handles the terminal takes the mouse.
        #expect(container.hitTest(CGPoint(x: size.width / 2, y: 100)).map { $0.isDescendant(of: r.terminalView) } == true)
        // Orca's padding (terminal.css .xterm-container): 4 pt left of the first column and above the first row, none on the right or below.
        let border = ChatLook.borderWidth, pad = ChatLook.terminalPadding
        #expect(pad == 4)
        let frame = r.terminalView.frame
        #expect(frame.minX == border + pad && frame.maxX == size.width - border, "\(frame) in \(size)")
        #expect(frame.maxY == container.titleBarView.frame.minY - pad && frame.minY == border, "\(frame) under \(container.titleBarView.frame)")
        // The padding shows the terminal's background, not the title bar's fill.
        let inPadding = CGPoint(x: size.width / 2, y: container.titleBarView.frame.minY - pad / 2)
        let backing = try #require(container.hitTest(inPadding))
        #expect(!backing.isDescendant(of: r.terminalView) && backing !== container)
        #expect(backing.layer?.backgroundColor == container.look.background.color.cgColor)
        r.controller.close(.toggle)
    }

    @Test func ChatOrca_aPressOnTheTabLabelBelongsToTheTabAndNotToTheTitleBar() throws {
        let (r, _) = try terminalRig()
        r.open()
        let container = try #require(r.panel.terminal)
        container.layoutSubtreeIfNeeded()
        container.setTitle("\u{2733} Claude Code")
        container.layoutSubtreeIfNeeded()
        let bar = container.titleBarView
        // A point over the title text, in the container's coordinates.
        let overLabel = CGPoint(x: bar.frame.minX + 20, y: bar.frame.midY)
        #expect(bar.hitTest(overLabel) === container.tab, "the press is the tab's: \(String(describing: bar.hitTest(overLabel)))")
        // The buttons still take theirs.
        #expect(bar.hitTest(CGPoint(x: bar.frame.minX + container.closeButton.frame.midX, y: bar.frame.midY)) === container.closeButton)
        r.controller.close(.toggle)
    }
}
