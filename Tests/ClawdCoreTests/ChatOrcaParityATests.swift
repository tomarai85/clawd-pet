import Testing
import Foundation
import AppKit
import ClawdCore
import ClawdDesktop

// Orca parity round A: the window behaves like Orca's. An outside press decided at its mouse-up (P1), the pet's frames never override the user's
// gesture (P6), the panel's own display (P7), maximize (P8) and the title bar's press rules (P9). Every focus request goes through the fake
// seams and every mouse gesture is a direct call: no test activates an application, makes a window key or posts an event.

@Suite("ChatOrcaParityA", .serialized)
@MainActor
struct ChatOrcaParityATests {
    private static let dia = ChatAppRef(pid: 4242, launchDate: Date(timeIntervalSince1970: 7), bundleID: "company.thebrowser.dia")
    private static let here = CGPoint(x: 800, y: 500)

    // MARK: P1: the press is decided at its mouse-up

    private func pressed(_ r: ControllerRig, owner: String = "com.apple.Safari", button: ChatPressButton = .left, pid: Int32? = 321) -> ControllerRig {
        r.focus.surfaceOwner = { _ in owner }
        r.focus.outsidePress(ChatOutsidePress(time: 5, location: Self.here, button: button, ownerPid: pid))
        return r
    }

    @Test func ChatOrca_aPlainClickClosesAtItsUpAndNotAtItsDown() throws {
        let r = ControllerRig()
        r.open()
        _ = pressed(r)
        #expect(r.controller.isOpen && r.focus.liveFollowUps == 1 && r.lines("CHAT close").isEmpty, "the down only opens a press: \(r.lines("CHAT"))")
        r.focus.followUp(.up, Self.here)
        #expect(!r.controller.isOpen, "\(r.lines("CHAT"))")
        #expect(r.lines("CHAT close reason=outside gen=1").first?.hasSuffix(" by=press:com.apple.Safari") == true, "\(r.lines("CHAT close"))")
        #expect(r.lines("CHAT press gen=1 button=left decided=click owner=com.apple.Safari pid=321").count == 1, "\(r.lines("CHAT press"))")
    }

    @Test func ChatOrca_aPressThatMovedUnderFourPointsIsStillAClick() throws {
        let r = ControllerRig()
        r.open()
        _ = pressed(r)
        r.focus.followUp(.dragged, CGPoint(x: Self.here.x + 2, y: Self.here.y))
        r.focus.followUp(.up, CGPoint(x: Self.here.x + 2, y: Self.here.y))
        #expect(!r.controller.isOpen && r.lines("CHAT press").first?.contains("decided=click") == true, "\(r.lines("CHAT"))")
    }

    @Test func ChatOrca_aPressThatReachedFourPointsIsADragAndAtThreePointNineIsAClick() throws {
        let drag = ControllerRig()
        drag.open()
        _ = pressed(drag)
        drag.focus.followUp(.dragged, CGPoint(x: Self.here.x + 4, y: Self.here.y))
        drag.focus.followUp(.up, CGPoint(x: Self.here.x + 4, y: Self.here.y))
        #expect(drag.controller.isOpen && drag.lines("CHAT press").first?.contains("decided=drag") == true, "exactly 4 pt is a drag: \(drag.lines("CHAT"))")
        let click = ControllerRig()
        click.open()
        _ = pressed(click)
        click.focus.followUp(.dragged, CGPoint(x: Self.here.x + 3.9, y: Self.here.y))
        click.focus.followUp(.up, CGPoint(x: Self.here.x + 3.9, y: Self.here.y))
        #expect(!click.controller.isOpen && click.lines("CHAT press").first?.contains("decided=click") == true, "3.9 pt is a click: \(click.lines("CHAT"))")
        // The threshold is hypot, not one axis, and a drag stays a drag when the pointer comes back.
        let diagonal = ControllerRig()
        diagonal.open()
        _ = pressed(diagonal)
        diagonal.focus.followUp(.dragged, CGPoint(x: Self.here.x + 3, y: Self.here.y + 3))
        diagonal.focus.followUp(.dragged, Self.here)
        diagonal.focus.followUp(.up, Self.here)
        #expect(diagonal.controller.isOpen && diagonal.lines("CHAT press").first?.contains("decided=drag") == true, "\(diagonal.lines("CHAT"))")
    }

    @Test func ChatOrca_anUpTenPointsAwayWithNoDraggedEventIsADrag() throws {
        let r = ControllerRig()
        r.open()
        _ = pressed(r)
        r.focus.followUp(.up, CGPoint(x: Self.here.x + 10, y: Self.here.y))
        #expect(r.controller.isOpen && r.lines("CHAT press").first?.contains("decided=drag") == true, "\(r.lines("CHAT"))")
    }

    @Test func ChatOrca_aFileDragThatComesToAClawdDropTargetMakesThePendingPressADrag() throws {
        let r = ControllerRig()
        r.open()
        _ = pressed(r)
        r.controller.fileDragEntered()
        r.focus.followUp(.up, CGPoint(x: Self.here.x + 1, y: Self.here.y))
        #expect(r.controller.isOpen && r.lines("CHAT press").first?.contains("decided=drag") == true, "\(r.lines("CHAT"))")
        // With no press pending it does nothing.
        r.controller.fileDragEntered()
        #expect(r.controller.isOpen && r.lines("CHAT press").count == 1)
    }

    @Test func ChatOrca_anotherApplicationsActivationWithNoButtonDownKeepsThePanelAndSpendsTheToken() throws {
        let r = ControllerRig()
        r.open()
        let target = try #require(r.focus.frontmost)
        #expect(r.controller.handBackTarget == target)
        r.focus.otherAppBecomesActive(Self.dia)
        #expect(r.controller.isOpen && r.lines("CHAT close").isEmpty, "\(r.lines("CHAT"))")
        #expect(r.controller.handBackTarget == Self.dia, "the target is Dia now")
        #expect(r.lines("CHAT activate-spent gen=1 cause=other-app").count == 1)
        #expect(r.lines("CHAT app-active gen=1 app=company.thebrowser.dia buttons=0 pending=none").count == 1, "\(r.lines("CHAT"))")
        #expect(r.focus.liveFollowUps == 0 && r.focus.liveObservers == 1 && r.focus.livePressObservers == 1)
    }

    @Test func ChatOrca_anActivationThatComesWhileAButtonIsDownOpensThePressAndTheLateDownMergesIntoIt() throws {
        // The click's down was handled after the activation: the activation opened the press, the down merges, a drag keeps the panel open.
        let drag = ControllerRig()
        drag.open()
        drag.focus.pressed = 1
        drag.focus.pointer = Self.here
        drag.focus.otherAppBecomesActive(Self.dia)
        #expect(drag.controller.isOpen && drag.focus.liveFollowUps == 1 && drag.lines("CHAT app-active").first?.hasSuffix("buttons=1 pending=press") == true, "\(drag.lines("CHAT"))")
        drag.focus.surfaceOwner = { _ in "com.example.Clicked" }
        drag.focus.outsidePress(ChatOutsidePress(time: 5, location: Self.here, ownerPid: 555))
        #expect(drag.focus.liveFollowUps == 1, "merged, not a second press")
        drag.focus.followUp(.dragged, CGPoint(x: Self.here.x + 10, y: Self.here.y))
        drag.focus.followUp(.up, CGPoint(x: Self.here.x + 10, y: Self.here.y))
        #expect(drag.controller.isOpen && drag.lines("CHAT press").first?.contains("decided=drag") == true, "\(drag.lines("CHAT"))")
        #expect(drag.lines("CHAT press").first?.hasSuffix("owner=com.example.Clicked pid=555") == true, "the down's owner and pid replace the activation's: \(drag.lines("CHAT press"))")
        // The same with no movement closes at the up, and the close names the activated application.
        let click = ControllerRig()
        click.open()
        click.focus.pressed = 1
        click.focus.pointer = Self.here
        click.focus.otherAppBecomesActive(Self.dia)
        click.focus.outsidePress(ChatOutsidePress(time: 5, location: Self.here, ownerPid: 4242))
        #expect(click.controller.isOpen)
        click.focus.followUp(.up, Self.here)
        #expect(!click.controller.isOpen && click.lines("CHAT close reason=outside gen=1").first?.hasSuffix(" by=press:company.thebrowser.dia") == true, "\(click.lines("CHAT"))")
        // An activation with the button down and the down never seen is still decided by its up.
        let lone = ControllerRig()
        lone.open()
        lone.focus.pressed = 1
        lone.focus.pointer = Self.here
        lone.focus.otherAppBecomesActive(Self.dia)
        lone.focus.followUp(.up, Self.here)
        #expect(!lone.controller.isOpen, "\(lone.lines("CHAT"))")
    }

    @Test func ChatOrca_anActivationAfterADragWasDecidedStillDoesNotClose() throws {
        let r = ControllerRig()
        r.open()
        _ = pressed(r)
        r.focus.followUp(.dragged, CGPoint(x: Self.here.x + 12, y: Self.here.y))
        r.focus.followUp(.up, CGPoint(x: Self.here.x + 12, y: Self.here.y))
        r.clock.advance(0.2)
        r.focus.otherAppBecomesActive(Self.dia)
        #expect(r.controller.isOpen && r.lines("CHAT close").isEmpty, "\(r.lines("CHAT"))")
    }

    @Test func ChatOrca_aPressWithNoUpInTenSecondsIsATimeoutAndNeverALateClose() throws {
        let r = ControllerRig()
        r.open()
        _ = pressed(r)
        #expect(r.focus.timers.live.contains(ChatController.pressDeadline) && r.focus.liveFollowUps == 1)
        r.focus.timers.fire(atLeast: ChatController.pressDeadline)
        #expect(r.controller.isOpen && r.lines("CHAT press").first?.contains("decided=timeout") == true, "\(r.lines("CHAT"))")
        #expect(r.focus.liveFollowUps == 0 && !r.focus.timers.live.contains(ChatController.pressDeadline), "no monitor and no deadline are left")
        r.focus.followUp(.up, Self.here)
        #expect(r.controller.isOpen && r.lines("CHAT press").count == 1, "a later up is not seen")
    }

    @Test func ChatOrca_aRightPressIsDecidedByItsOwnUpAndOtherButtonsAreIgnored() throws {
        let click = ControllerRig()
        click.open()
        _ = pressed(click, button: .right)
        click.focus.followUp(.up, Self.here, button: .left)
        #expect(click.controller.isOpen, "a left up during a right press is ignored")
        click.focus.followUp(.up, Self.here, button: .right)
        #expect(!click.controller.isOpen && click.lines("CHAT press").first?.contains("button=right decided=click") == true, "\(click.lines("CHAT"))")
        let drag = ControllerRig()
        drag.open()
        _ = pressed(drag, button: .right)
        drag.focus.followUp(.dragged, CGPoint(x: Self.here.x + 6, y: Self.here.y), button: .right)
        drag.focus.followUp(.up, CGPoint(x: Self.here.x + 6, y: Self.here.y), button: .right)
        #expect(drag.controller.isOpen && drag.lines("CHAT press").first?.contains("button=right decided=drag") == true, "\(drag.lines("CHAT"))")
        // A second down of another button while one press is pending is ignored.
        let two = ControllerRig()
        two.open()
        _ = pressed(two)
        _ = pressed(two, button: .right)
        two.focus.followUp(.up, Self.here, button: .right)
        #expect(two.controller.isOpen && two.focus.liveFollowUps == 1)
        two.focus.followUp(.up, Self.here, button: .left)
        #expect(!two.controller.isOpen)
    }

    @Test func ChatOrca_aDownHandledAfterItsUpIsDecidedAtOnceByWhereThePointerIs() throws {
        let click = ControllerRig()
        click.open()
        click.focus.pointer = Self.here
        click.focus.surfaceOwner = { _ in "com.apple.Safari" }
        click.focus.outsidePress(ChatOutsidePress(time: 5, location: Self.here), held: false)
        #expect(!click.controller.isOpen && click.focus.liveFollowUps == 0 && click.lines("CHAT press").first?.contains("decided=click") == true, "\(click.lines("CHAT"))")
        let drag = ControllerRig()
        drag.open()
        drag.focus.pointer = CGPoint(x: Self.here.x + 8, y: Self.here.y)
        drag.focus.surfaceOwner = { _ in "com.apple.Safari" }
        drag.focus.outsidePress(ChatOutsidePress(time: 5, location: Self.here), held: false)
        #expect(drag.controller.isOpen && drag.focus.liveFollowUps == 0 && drag.lines("CHAT press").first?.contains("decided=drag") == true, "\(drag.lines("CHAT"))")
    }

    @Test func ChatOrca_theFollowUpMonitorAndTheDeadlineExistOnlyWhileAPressIsPendingAndOpeningTwoNeverSeesOpeningOnesUp() throws {
        let r = ControllerRig()
        r.open()
        #expect(r.focus.liveFollowUps == 0 && !r.focus.timers.live.contains(ChatController.pressDeadline), "none before any press")
        _ = pressed(r)
        #expect(r.focus.liveFollowUps == 1 && r.focus.timers.live.contains(ChatController.pressDeadline), "one while pending")
        // A close during the pending press removes both.
        r.controller.close(.toggle)
        #expect(r.focus.liveFollowUps == 0 && !r.focus.timers.live.contains(ChatController.pressDeadline))
        // Opening 2 does not see the up of opening 1's press.
        r.focus.followUp(.up, Self.here)
        r.open(at: 2)
        #expect(r.controller.isOpen && r.lines("CHAT press").isEmpty)
        r.focus.followUp(.up, Self.here)
        #expect(r.controller.isOpen && r.lines("CHAT press").isEmpty, "\(r.lines("CHAT"))")
        _ = pressed(r)
        r.focus.followUp(.up, Self.here)
        #expect(!r.controller.isOpen && r.focus.liveFollowUps == 0 && !r.focus.timers.live.contains(ChatController.pressDeadline), "after the decision")
    }

    @Test func ChatOrca_aPressOnAnExemptSurfaceOpensNoPendingPress() throws {
        let r = ControllerRig()
        r.open()
        r.focus.surfaceOwner = { _ in "com.apple.inputmethod.Kotoeri.RomajiTyping" }
        r.focus.outsidePress(ChatOutsidePress(time: 5, location: Self.here))
        #expect(r.focus.liveFollowUps == 0 && r.lines("CHAT press").isEmpty && r.focus.timers.live == [ChatController.activationDeadline])
        r.focus.followUp(.up, Self.here)
        r.focus.surfaceOwner = { _ in "com.apple.Safari" }
        r.focus.frontLabel = "com.apple.screencaptureui"
        r.focus.outsidePress(ChatOutsidePress(time: 6, location: Self.here))
        #expect(r.focus.liveFollowUps == 0 && r.controller.isOpen)
    }

    @Test func ChatOrca_withChatOutsideClickStayAPlainClickIsLoggedAndClosesNothing() throws {
        let r = ControllerRig()
        r.chatSettings.outsideClick = .stay
        r.open()
        _ = pressed(r)
        r.focus.followUp(.up, Self.here)
        #expect(r.controller.isOpen && r.lines("CHAT press").first?.contains("decided=click") == true && r.focus.liveFollowUps == 0, "\(r.lines("CHAT"))")
        // The setting reads `close` and `stay` and nothing else.
        #expect(ChatSettings(object: ["chatOutsideClick": "stay"]).outsideClick == .stay)
        #expect(ChatSettings(object: ["chatOutsideClick": "close"]).outsideClick == .close)
        #expect(ChatSettings(object: ["chatOutsideClick": "never"]).outsideClick == .close && ChatSettings(object: ["chatOutsideClick": true]).outsideClick == .close)
        #expect(ChatSettings().outsideClick == .close)
    }

    @Test func ChatOrca_aResignNamesTheOwnerOfTheWindowUnderThePointer() throws {
        let r = ControllerRig()
        r.open()
        let panel = try #require(r.controller.livePanel)
        r.focus.pointer = CGPoint(x: 10, y: 10)
        r.focus.surfaceOwner = { $0 == CGPoint(x: 10, y: 10) ? "company.thebrowser.dia" : nil }
        r.controller.resigned(panel)
        r.focus.surfaceOwner = { _ in nil }
        r.controller.resigned(panel)
        #expect(r.lines("CHAT resign gen=1") == ["CHAT resign gen=1 keyOwner=company.thebrowser.dia", "CHAT resign gen=1 keyOwner=own"], "\(r.lines("CHAT resign"))")
    }

    // MARK: P8 with P1: the web kind, maximize, then another application's activation (T1.15)

    private static let visible = CGRect(x: 0, y: 25, width: 1440, height: 875)

    private func webRig(geometry: ChatGeometryStoring? = nil, screens: [ChatScreen]? = nil) -> WebKindRig {
        let r = WebKindRig(geometry: geometry)
        r.rig.host.visible = Self.visible
        r.rig.host.screens = screens
        r.rig.host.rect = CGRect(x: 300, y: 100, width: 520, height: 340)
        return r
    }

    @Test func ChatOrca_maximizingTheWebChatAndThenAnotherAppsActivationKeepsItOpen() throws {
        let r = webRig()
        r.rig.open()
        let panel = try #require(r.panel)
        let container = try #require(panel.terminal)
        let keys = r.rig.keys.count
        container.maximizeButton.performClick(nil)
        #expect(panel.frame == Self.visible.insetBy(dx: 12, dy: 12) && container.isMaximized)
        r.rig.focus.otherAppBecomesActive(Self.dia)
        r.rig.focus.drain()
        #expect(r.controller.isOpen && r.rig.lines("CHAT close").isEmpty, "\(r.rig.lines("CHAT"))")
        #expect(panel.frame == Self.visible.insetBy(dx: 12, dy: 12) && container.isMaximized && r.rig.keys.count == keys)
    }

    // MARK: P6: the pet's frames never override the user's gesture

    @Test func ChatOrca_aPetFrameBetweenTwoStepsOfTheFirstDragLeavesThePanelWhereTheDragPutIt() throws {
        let geometry = MemoryChatGeometry()
        let r = webRig(geometry: geometry)
        r.rig.open()
        let bar = try #require(r.panel?.terminal).titleBarView
        let before = try #require(r.panel).frame
        bar.beginDrag(at: CGPoint(x: 400, y: 300))
        bar.drag(to: CGPoint(x: 450, y: 270))
        let after = try #require(r.panel).frame
        #expect(after == before.offsetBy(dx: 50, dy: -30))
        r.rig.host.rect = CGRect(x: 10, y: 10, width: 520, height: 340)
        r.controller.replace()
        #expect(r.panel?.frame == after, "the pet's frame moved the panel mid-gesture: \(String(describing: r.panel?.frame))")
        bar.drag(to: CGPoint(x: 460, y: 260))
        bar.endDrag()
        #expect(geometry.saves == 1 && geometry.rect(in: Self.visible) == r.panel?.frame)
    }

    @Test func ChatOrca_aClickOnTheBarWithNoMovementLeavesThePanelFollowingThePet() throws {
        let geometry = MemoryChatGeometry()
        let r = webRig(geometry: geometry)
        r.rig.open()
        let bar = try #require(r.panel?.terminal).titleBarView
        bar.beginDrag(at: CGPoint(x: 400, y: 300))
        bar.endDrag()
        #expect(geometry.saves == 0)
        r.rig.host.rect = CGRect(x: 10, y: 60, width: 520, height: 340)
        r.controller.replace()
        #expect(r.panel?.frame == CGRect(x: 10, y: 60, width: 520, height: 340), "a click detached the panel from the pet: \(String(describing: r.panel?.frame))")
        // A drag that moves detaches it and saves.
        bar.beginDrag(at: CGPoint(x: 400, y: 300))
        bar.drag(to: CGPoint(x: 420, y: 300))
        bar.endDrag()
        let moved = try #require(r.panel).frame
        r.rig.host.rect = CGRect(x: 600, y: 60, width: 520, height: 340)
        r.controller.replace()
        #expect(r.panel?.frame == moved && geometry.saves == 1)
        // A click on a panel that was already the user's keeps it theirs.
        bar.beginDrag(at: .zero); bar.endDrag()
        r.controller.replace()
        #expect(r.panel?.frame == moved)
    }

    // MARK: P7: the panel's own display

    private static let screenA = ChatScreen(id: "A", frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visible: CGRect(x: 0, y: 25, width: 1440, height: 875))
    private static let screenB = ChatScreen(id: "B", frame: CGRect(x: 1440, y: 0, width: 1000, height: 800), visible: CGRect(x: 1440, y: 0, width: 1000, height: 780))

    private func twoScreens(geometry: ChatGeometryStoring? = nil, only: [ChatScreen]? = nil) -> WebKindRig {
        webRig(geometry: geometry, screens: only ?? [Self.screenA, Self.screenB])
    }

    @Test func ChatOrca_aDragWhosePointerGoesOntoTheOtherDisplayEndsThereAndSavesThere() throws {
        let geometry = MemoryChatGeometry()
        let r = twoScreens(geometry: geometry)
        r.rig.open()
        let bar = try #require(r.panel?.terminal).titleBarView
        let start = try #require(r.panel).frame
        bar.beginDrag(at: CGPoint(x: 400, y: 300))
        bar.drag(to: CGPoint(x: 1700, y: 300))
        bar.endDrag()
        let end = try #require(r.panel).frame
        #expect(end == start.offsetBy(dx: 1300, dy: 0) && Self.screenB.visible.contains(end), "\(end)")
        #expect(geometry.rect(in: Self.screenB.visible) == end)
        // Far past B's edge, it stops at B's margin.
        bar.beginDrag(at: CGPoint(x: 1700, y: 300))
        bar.drag(to: CGPoint(x: 9000, y: 300))
        #expect(r.panel?.frame.maxX == Self.screenB.visible.maxX - 8, "\(String(describing: r.panel?.frame))")
        bar.endDrag()
    }

    @Test func ChatOrca_aDragWhosePointerStaysOnItsDisplayStopsAtThatDisplaysMargin() throws {
        let r = twoScreens()
        r.rig.open()
        let bar = try #require(r.panel?.terminal).titleBarView
        bar.beginDrag(at: CGPoint(x: 400, y: 300))
        bar.drag(to: CGPoint(x: 1400, y: 300))
        let frame = try #require(r.panel).frame
        #expect(frame.maxX == Self.screenA.visible.maxX - 8 && frame.minX < 1440, "\(frame)")
        bar.endDrag()
    }

    @Test func ChatOrca_anEastResizeWhosePointerCrossesToTheOtherDisplayKeepsTheLeftEdgeAndStopsAtItsOwnMargin() throws {
        let r = twoScreens()
        r.rig.open()
        let container = try #require(r.panel?.terminal)
        let start = try #require(r.panel).frame
        let handle = container.handle(.e)
        handle.beginDrag(at: CGPoint(x: 800, y: 300))
        handle.drag(to: CGPoint(x: 2000, y: 300))
        let frame = try #require(r.panel).frame
        #expect(frame.minX == start.minX && frame.maxX == Self.screenA.visible.maxX - 8, "\(frame)")
        handle.endDrag()
    }

    @Test func ChatOrca_maximizeFillsThePanelsOwnDisplayLessTwelve() throws {
        let r = twoScreens()
        r.rig.open()
        let bar = try #require(r.panel?.terminal).titleBarView
        bar.beginDrag(at: CGPoint(x: 400, y: 300))
        bar.drag(to: CGPoint(x: 1700, y: 300))
        bar.endDrag()
        try #require(r.panel?.terminal).maximizeButton.performClick(nil)
        #expect(r.panel?.frame == Self.screenB.visible.insetBy(dx: 12, dy: 12), "\(String(describing: r.panel?.frame))")
        // A re-measure keeps it on B; when B is gone, on the screen of its restore rect, else Clawd's display.
        r.controller.replace()
        #expect(r.panel?.frame == Self.screenB.visible.insetBy(dx: 12, dy: 12))
        r.rig.host.screens = [Self.screenA]
        r.controller.replace()
        #expect(r.panel?.frame == Self.screenA.visible.insetBy(dx: 12, dy: 12), "\(String(describing: r.panel?.frame))")
    }

    @Test func ChatOrca_removingTheOtherDisplayReclampsThePanelOntoClawdsDisplay() throws {
        let r = twoScreens()
        r.rig.open()
        let bar = try #require(r.panel?.terminal).titleBarView
        bar.beginDrag(at: CGPoint(x: 400, y: 300))
        bar.drag(to: CGPoint(x: 1700, y: 300))
        bar.endDrag()
        #expect(try #require(r.panel).frame.minX > 1440)
        r.rig.host.screens = [Self.screenA]
        r.controller.replace()
        let frame = try #require(r.panel).frame
        #expect(Self.screenA.visible.contains(frame), "\(frame)")
    }

    @Test func ChatOrca_aRectSavedOnTheOtherDisplayOrOnNoDisplayOpensBesideClawdOnClawdsDisplay() throws {
        let onB = CGRect(x: 1700, y: 200, width: 520, height: 340)
        let b = twoScreens(geometry: MemoryChatGeometry(onB))
        b.rig.open()
        #expect(b.panel?.frame == CGRect(x: 300, y: 100, width: 520, height: 340), "\(String(describing: b.panel?.frame))")
        let nowhere = twoScreens(geometry: MemoryChatGeometry(CGRect(x: 9000, y: 9000, width: 520, height: 340)))
        nowhere.rig.open()
        let frame = try #require(nowhere.panel).frame
        #expect(Self.screenA.visible.contains(frame), "\(frame)")
    }

    // MARK: P8: maximize

    @Test func ChatOrca_maximizeAndRestoreOnTheWebChatKeepTheBodyFilledAndTheKeyStateUnchanged() throws {
        let r = webRig()
        r.rig.open()
        let panel = try #require(r.panel)
        let container = try #require(panel.terminal)
        let body = try #require(r.body)
        let web = try #require(body.page?.view)
        let keys = r.rig.keys.count
        func filled(_ label: String) {
            container.layoutSubtreeIfNeeded()
            let area = CGRect(x: 1, y: 1, width: container.bounds.width - 2, height: container.bounds.height - 2 - ChatLook.titleBarHeight)
            #expect(body.frame == area, "\(label): body \(body.frame) in \(area)")
            #expect(web.frame.width == body.bounds.width && web.frame.maxY == body.bounds.height, "\(label): web view \(web.frame) in \(body.bounds)")
        }
        filled("opened")
        let start = panel.frame
        container.maximizeButton.performClick(nil)
        filled("maximized")
        #expect(panel.frame == Self.visible.insetBy(dx: 12, dy: 12) && r.controller.isOpen)
        container.maximizeButton.performClick(nil)
        filled("restored")
        #expect(panel.frame == start && r.controller.isOpen && r.rig.keys.count == keys && !panel.isKeyWindow)
    }

    @Test func ChatOrca_theHandlesAreHiddenWhileMaximizedAndBackAfterRestore() throws {
        let r = webRig()
        r.rig.open()
        let container = try #require(r.panel?.terminal)
        container.layoutSubtreeIfNeeded()
        let east = container.handle(.e)
        let probe = CGPoint(x: container.bounds.width - 4, y: 100)
        #expect(!container.handles.contains { $0.isHidden } && container.hitTest(probe) === east)
        container.maximizeButton.performClick(nil)
        container.layoutSubtreeIfNeeded()
        #expect(container.handles.allSatisfy { $0.isHidden }, "Orca unmounts the handles while maximized")
        #expect(container.hitTest(CGPoint(x: container.bounds.width - 4, y: 100)) !== east)
        container.maximizeButton.performClick(nil)
        container.layoutSubtreeIfNeeded()
        #expect(container.handles.allSatisfy { !$0.isHidden } && container.hitTest(CGPoint(x: container.bounds.width - 4, y: 100)) === container.handle(.e))
    }

    @Test func ChatOrca_theMaximizeControlsTooltipIsMaximizeOrRestoreAndItsLabelsAreUnchanged() throws {
        let r = webRig()
        r.rig.open()
        let container = try #require(r.panel?.terminal)
        #expect(container.maximizeButton.toolTip == "Maximize" && container.maximizeButton.accessibilityLabel() == "Maximize chat")
        container.maximizeButton.performClick(nil)
        #expect(container.maximizeButton.toolTip == "Restore" && container.maximizeButton.accessibilityLabel() == "Restore chat")
        container.maximizeButton.performClick(nil)
        #expect(container.maximizeButton.toolTip == "Maximize")
    }

    @Test func ChatOrca_theToggleSavesTheFlagAndNotTheRect() throws {
        let geometry = MemoryChatGeometry()
        let r = webRig(geometry: geometry)
        r.rig.open()
        let container = try #require(r.panel?.terminal)
        container.maximizeButton.performClick(nil)
        #expect(geometry.saves == 0 && geometry.maximizedSaves == [true] && geometry.anchor == nil, "the flag is saved, the rect is not")
        container.maximizeButton.performClick(nil)
        #expect(geometry.saves == 0 && geometry.maximizedSaves == [true, false])
    }

    @Test func ChatOrca_aReopenWithTheFlagOpensMaximizedAndRestoreLandsBesideClawdAtTheSavedSize() throws {
        let saved = CGRect(x: 200, y: 120, width: 600, height: 400)
        let geometry = MemoryChatGeometry(saved, maximized: true)
        let r = webRig(geometry: geometry)
        r.rig.open()
        let panel = try #require(r.panel)
        let container = try #require(panel.terminal)
        #expect(panel.frame == Self.visible.insetBy(dx: 12, dy: 12) && container.isMaximized && container.handles.allSatisfy { $0.isHidden }, "\(panel.frame)")
        #expect(container.maximizeButton.toolTip == "Restore" && geometry.saves == 0)
        container.maximizeButton.performClick(nil)
        #expect(panel.frame == CGRect(x: 300, y: 100, width: 600, height: 400) && !container.isMaximized, "\(panel.frame)")
        #expect(geometry.maximizedSaves == [false])
        // With no saved rect, Restore returns to the placement beside Clawd, and the panel stays the pet's.
        let bare = webRig(geometry: MemoryChatGeometry(nil, maximized: true))
        bare.rig.open()
        let bareContainer = try #require(bare.panel?.terminal)
        bareContainer.maximizeButton.performClick(nil)
        #expect(bare.panel?.frame == CGRect(x: 300, y: 100, width: 520, height: 340), "\(String(describing: bare.panel?.frame))")
        bare.rig.host.rect = CGRect(x: 40, y: 40, width: 520, height: 340)
        bare.controller.replace()
        #expect(bare.panel?.frame == CGRect(x: 40, y: 40, width: 520, height: 340), "restoring a panel that had no saved rect hands it back to the pet")
    }

    @Test func ChatOrca_aFileWithoutTheFlagOpensNotMaximizedAndTheTwoFieldsAreIndependent() throws {
        let plain = webRig(geometry: MemoryChatGeometry(CGRect(x: 200, y: 120, width: 600, height: 400)))
        plain.rig.open()
        #expect(plain.panel?.terminal?.isMaximized == false && plain.panel?.frame == CGRect(x: 300, y: 100, width: 600, height: 400))
        let store = try artifactStore()
        let file = FileChatGeometry(store: store)
        #expect(file.loadAnchor() == nil && !file.loadMaximized())
        file.saveMaximized(true)
        #expect(file.load() == nil && file.loadAnchor() == nil && file.loadMaximized(), "a file with only the flag holds no rect")
        let anchor = ChatAnchor(display: nil, anchorX: .left, anchorY: .top, offsetX: 12, offsetY: 34, width: 560, height: 360)
        file.saveAnchor(anchor)
        #expect(file.loadAnchor() == anchor && file.loadMaximized(), "saving the anchor keeps the flag")
        file.saveMaximized(false)
        #expect(file.loadAnchor() == anchor && !file.loadMaximized(), "saving the flag keeps the anchor")
        try store.write(Data("{\"x\":1,\"y\":2,\"width\":300,\"height\":200}".utf8), to: FileChatGeometry.privateFileName)
        #expect(file.load() == CGRect(x: 1, y: 2, width: 300, height: 200) && !file.loadMaximized(), "a file written before the flag reads false")
    }

    @Test func ChatOrca_theGestureLinesAreLoggedWithIntegerFrames() throws {
        let r = webRig(geometry: MemoryChatGeometry())
        r.rig.open()
        let container = try #require(r.panel?.terminal)
        container.titleBarView.beginDrag(at: CGPoint(x: 400, y: 300))
        container.titleBarView.drag(to: CGPoint(x: 450, y: 270))
        container.titleBarView.endDrag()
        #expect(r.rig.lines("CHAT gesture move-end gen=1") == ["CHAT gesture move-end gen=1 frame=350,70,520,340 anchor=lb"], "\(r.rig.lines("CHAT gesture"))")
        container.handle(.e).beginDrag(at: CGPoint(x: 800, y: 300))
        container.handle(.e).drag(to: CGPoint(x: 840, y: 300))
        container.handle(.e).endDrag()
        #expect(r.rig.lines("CHAT gesture resize-end gen=1") == ["CHAT gesture resize-end gen=1 frame=350,70,560,340 anchor=lb"], "\(r.rig.lines("CHAT gesture"))")
        container.maximizeButton.performClick(nil)
        container.maximizeButton.performClick(nil)
        #expect(r.rig.lines("CHAT gesture maximize gen=1") == ["CHAT gesture maximize gen=1 frame=12,37,1416,851"], "\(r.rig.lines("CHAT gesture"))")
        #expect(r.rig.lines("CHAT gesture restore gen=1") == ["CHAT gesture restore gen=1 frame=350,70,560,340"], "\(r.rig.lines("CHAT gesture"))")
        // A click with no movement logs nothing.
        container.titleBarView.beginDrag(at: .zero); container.titleBarView.endDrag()
        #expect(r.rig.lines("CHAT gesture").count == 4)
    }

    // MARK: P9: the title bar's press semantics

    private func mouse(_ type: NSEvent.EventType, clicks: Int = 1) -> NSEvent {
        NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: clicks, pressure: 1)!
    }

    @Test func ChatOrca_aPressOnTheTabIsTheTabsAndDoesNothing() throws {
        let r = webRig()
        r.rig.open()
        let container = try #require(r.panel?.terminal)
        container.layoutSubtreeIfNeeded()
        container.setTitle("\u{2733} Claude Code")
        container.layoutSubtreeIfNeeded()
        let bar = container.titleBarView
        let tab = container.tab
        // Over the label, over the tab's corner and past its right edge.
        let overLabel = CGPoint(x: bar.frame.minX + 20, y: bar.frame.midY)
        #expect(bar.hitTest(overLabel) === tab, "the press is the tab's, not its label's: \(String(describing: bar.hitTest(overLabel)))")
        #expect(bar.hitTest(CGPoint(x: bar.frame.minX + tab.frame.maxX - 1, y: bar.frame.midY)) === tab)
        #expect(bar.hitTest(CGPoint(x: bar.frame.minX + tab.frame.maxX + 4, y: bar.frame.midY)) === bar, "the empty bar keeps its press")
        #expect(bar.hitTest(CGPoint(x: bar.frame.minX + container.closeButton.frame.midX, y: bar.frame.midY)) === container.closeButton)
        var gestures: [ChatPanelGesture] = []
        bar.onGesture = { gestures.append($0) }
        tab.mouseDown(with: mouse(.leftMouseDown))
        tab.mouseDragged(with: mouse(.leftMouseDragged))
        tab.mouseUp(with: mouse(.leftMouseUp))
        tab.mouseDown(with: mouse(.leftMouseDown, clicks: 2))
        #expect(gestures.isEmpty, "a press on the tab reached the title bar: \(gestures)")
        // The empty bar still moves the panel and a double-click on it toggles maximize.
        bar.mouseDown(with: mouse(.leftMouseDown, clicks: 2))
        #expect(gestures == [.toggleMaximize])
        bar.beginDrag(at: .zero); bar.drag(to: CGPoint(x: 10, y: 0)); bar.endDrag()
        #expect(gestures.count == 4 && gestures.first == .toggleMaximize && gestures[1] == .begin, "\(gestures)")
        container.onGesture = nil
    }

    @Test func ChatOrca_theEmptyBarShowsTheOpenHandAndTheTabAndButtonsDoNot() throws {
        let r = webRig()
        r.rig.open()
        let container = try #require(r.panel?.terminal)
        container.layoutSubtreeIfNeeded()
        let bar = container.titleBarView
        #expect(ChatTitleBarView.barCursor === NSCursor.openHand)
        let rects = bar.emptyBarRects
        #expect(!rects.isEmpty)
        let taken = [container.tab.frame, container.maximizeButton.frame, container.closeButton.frame]
        for rect in rects { for other in taken { #expect(!rect.intersects(other), "\(rect) overlaps \(other)") } }
        #expect(rects.contains { $0.minX >= container.tab.frame.maxX && $0.maxX <= container.maximizeButton.frame.minX && $0.width > 8 }, "\(rects)")
    }
}
