import Testing
import Foundation
import AppKit
import ClawdCore
import ClawdRendering
import ClawdDesktop

// Sprint 3e: the chat panel is an ordinary window of an active application while the user uses it. The activation token, the exemption while
// active, the hand-back on every close. Every request goes through the fake focus seams: no test activates, deactivates or brings forward anything.

@Suite("ChatActivate", .serialized)
@MainActor
struct ChatActivateSuite {
    private static let appA = ChatAppRef(pid: 4001, launchDate: Date(timeIntervalSince1970: 1_000))
    private static let appB = ChatAppRef(pid: 5002, launchDate: Date(timeIntervalSince1970: 2_000))
    private static let appS = ChatAppRef(pid: 6006, launchDate: Date(timeIntervalSince1970: 3_000))

    /// An open stream-path controller whose activation token has been used (Clawd is active as the open's activation made it).
    private func activeOpening() throws -> (ControllerRig, ChatPanel) {
        let r = ControllerRig()
        r.open()
        let panel = try #require(r.controller.livePanel)
        r.clock.advance(0.1)
        #expect(r.controller.activationVerdict() == .exempt)
        r.focus.active = true
        return (r, panel)
    }

    @Test func ChatActivate_theOpenRequestsActivationOnceAndRecordsTheFrontmostApplication() async throws {
        let r = ControllerRig()
        r.focus.frontmost = ChatAppRef(pid: 777, launchDate: Date(timeIntervalSince1970: 5))
        r.open()
        #expect(r.focus.activationRequests == 1 && r.lines("CHAT activate gen=1 cause=open").count == 1, "\(r.logs)")
        #expect(r.controller.handBackTarget == ChatAppRef(pid: 777, launchDate: Date(timeIntervalSince1970: 5)))
        #expect(r.focus.liveObservers == 1, "the workspace observer exists while the panel is open")
        r.controller.close(.toggle)
        #expect(r.focus.liveObservers == 0 && r.controller.handBackTarget == nil)

        // The menu path: the pick toggles after the menu has closed, through the same open.
        let m = try ChatRuntimeRig()
        m.focus.frontmost = ChatAppRef(pid: 888, launchDate: nil)
        m.runtime.menuToggleChat(eventTime: 1)
        #expect(m.runtime.chatPanelIsOpen && m.focus.activationRequests == 1 && m.runtime.chatController.handBackTarget == ChatAppRef(pid: 888, launchDate: nil))

        // The terminal path.
        let t = try TermControllerRig()
        t.focus.frontmost = ChatAppRef(pid: 999, launchDate: Date(timeIntervalSince1970: 9))
        t.open()
        #expect(t.focus.activationRequests == 1 && t.controller.handBackTarget == ChatAppRef(pid: 999, launchDate: Date(timeIntervalSince1970: 9)))
        await t.finish()
    }

    @Test func ChatActivate_anActivationAfterTheOpenCallReturnedIsTheOpensUntilTheDeadline() throws {
        let r = ControllerRig()
        r.open()
        let panel = try #require(r.controller.livePanel)
        r.clock.advance(0.99)
        #expect(r.controller.keyVerdict(for: panel) == .exempt, "a key at 0.99 s is the open's")
        #expect(r.controller.activationVerdict() == .exempt)
        #expect(r.lines("CHAT active gen=1 cause=open after=990").count == 1, "\(r.lines("CHAT"))")
        r.controller.close(.toggle)
        // Another opening: an activation at 1.01 s is a violation that closes and hands back.
        r.open(at: 2)
        r.focus.active = true
        r.clock.advance(1.01)
        #expect(r.controller.activationVerdict() == .answeredByClose)
        #expect(r.lines("CHAT active gen=2").isEmpty)
        r.focus.drain()
        #expect(!r.controller.isOpen && r.lines("CHAT close reason=outside gen=2").count == 1)
        #expect(r.focus.handBacks == [Self.appA] && r.lines("CHAT handback gen=2").count == 1)
    }

    @Test func ChatActivate_noActivationByTheDeadlineLogsRefusedAndWaitsForAClickInside() throws {
        let r = ControllerRig()
        r.open()
        let panel = try #require(r.controller.livePanel)
        #expect(panel.headerText == "Claude Code")
        r.focus.timers.fire(atLeast: ChatController.activationDeadline)
        #expect(r.lines("CHAT activate-refused gen=1").count == 1)
        #expect(r.controller.isOpen && r.focus.activationRequests == 1, "the panel stays open, and nothing asks again")
        #expect(panel.headerText == "Click here to type", "the header says how to type while the activation is refused")
        r.currentEvent = ChatCurrentEvent(isMouseDown: true, window: panel)
        #expect(r.controller.activationVerdict() == .exempt)
        #expect(r.lines("CHAT active gen=1 cause=click").count == 1 && panel.headerText == "Claude Code", "the title is back after the click")
    }

    @Test func ChatActivate_aClickInsideThePanelWhileInactiveIsTheCause() throws {
        let r = ControllerRig()
        r.open()
        let panel = try #require(r.controller.livePanel)
        r.clock.advance(2)
        r.currentEvent = ChatCurrentEvent(isMouseDown: true, window: panel)
        #expect(r.controller.activationVerdict() == .exempt && r.lines("CHAT active gen=1 cause=click").count == 1)
        r.focus.drain()
        #expect(r.controller.isOpen)
        // A mouse-down in another window is no cause.
        r.currentEvent = ChatCurrentEvent(isMouseDown: true, window: nil)
        #expect(r.controller.activationVerdict() == .answeredByClose)
    }

    @Test func ChatActivate_whileActiveAKeyWithNoUserEventIsAReturnNotAViolation() throws {
        let (r, panel) = try activeOpening()
        r.clock.advance(30)
        r.currentEvent = nil
        #expect(r.controller.keyVerdict(for: panel) == .exempt)
        #expect(r.lines("CHAT key-returned gen=1").count == 1 && r.lines("CHAT key-uncaused").isEmpty)
        r.currentEvent = ChatCurrentEvent(isMouseDown: false, window: nil, isMouse: false)
        #expect(r.controller.keyVerdict(for: panel) == .exempt)
        #expect(r.lines("CHAT key gen=1").count == 1, "a key with a user event is a plain `CHAT key`: \(r.lines("CHAT key"))")
        r.focus.drain()
        #expect(r.controller.isOpen)
    }

    @Test func ChatActivate_afterResigningActiveAKeyWithNoUserEventClosesThePanel() throws {
        let (r, panel) = try activeOpening()
        r.clock.advance(30)
        r.controller.appResigned()
        r.focus.active = false
        #expect(r.lines("CHAT inactive gen=1").count == 1)
        r.currentEvent = nil
        #expect(r.controller.keyVerdict(for: panel) == .uncaused)
        r.focus.drain()
        #expect(!r.controller.isOpen && r.lines("CHAT close reason=outside gen=1").count == 1)
        #expect(r.focus.handBacks.isEmpty && r.focus.deactivationRequests == 0, "Clawd is not active, so the close does nothing about activation")
    }

    @Test func ChatActivate_anyOtherActivationIsAViolationThatClosesAndHandsBack() throws {
        let r = ControllerRig()
        r.open()
        r.clock.advance(2)
        r.focus.active = true
        #expect(r.controller.activationVerdict() == .answeredByClose, "while open")
        r.focus.drain()
        #expect(!r.controller.isOpen && r.focus.handBacks == [Self.appA] && r.lines("CHAT handback gen=1").count == 1)
        // While closed it is the plain violation that the monitor answers with its onViolation.
        #expect(r.controller.activationVerdict() == .violation)
    }

    @Test func ChatActivate_eachClosePathHandsBackWhileActiveAndNothingWhileInactive() throws {
        for reason in ChatCloseReason.allCases where reason != .exam && reason != .hidden {
            let r = ControllerRig()
            var orderedOutBeforeHandBack = false
            r.focus.onHandBack = { orderedOutBeforeHandBack = r.dismissed == 1 }
            r.open()
            r.focus.active = true
            r.controller.close(reason)
            #expect(r.focus.handBacks == [Self.appA], "\(reason): a hand-back")
            #expect(orderedOutBeforeHandBack, "\(reason): the order-out comes first")
            let inactive = ControllerRig()
            inactive.open()
            inactive.controller.close(reason)
            #expect(inactive.focus.handBacks.isEmpty && inactive.focus.deactivationRequests == 0 && inactive.lines("CHAT handback").isEmpty,
                    "\(reason): nothing while Clawd is not active")
        }
    }

    @Test func ChatActivate_aRefusedOrImpossibleHandBackDeactivatesThenReportsFailure() throws {
        // The recorded application is alive but refuses: the hand-back is asked, then the deactivation.
        let refused = ControllerRig()
        refused.focus.acceptsHandBack = false
        refused.open(); refused.focus.active = true
        refused.controller.close(.toggle)
        #expect(refused.focus.handBacks == [Self.appA] && refused.focus.deactivationRequests == 1)
        #expect(refused.lines("CHAT handback gen=1").count == 1 && refused.lines("CHAT deactivate gen=1").count == 1)
        refused.focus.active = false
        refused.focus.timers.fire(atLeast: ChatController.handbackDeadline)
        #expect(refused.lines("CHAT deactivate gen=1 ok=1").count == 1)

        // The application is gone (no target): no hand-back is asked.
        let none = ControllerRig()
        none.focus.frontmost = nil
        none.open(); none.focus.active = true
        none.controller.close(.toggle)
        #expect(none.focus.handBacks.isEmpty && none.focus.deactivationRequests == 1 && none.lines("CHAT handback gen=1").isEmpty)

        // A hand-back that is accepted and works: ok=1 on the hand-back line.
        let worked = ControllerRig()
        worked.open(); worked.focus.active = true
        worked.controller.close(.toggle)
        worked.focus.active = false
        worked.focus.timers.fire(atLeast: ChatController.handbackDeadline)
        #expect(worked.lines("CHAT handback gen=1 ok=1").count == 1 && worked.focus.deactivationRequests == 0)

        // The deactivation leaves Clawd active: Finder is asked next, ok=1 when that works and the failure line when it does not.
        let finderWorks = ControllerRig()
        finderWorks.focus.acceptsHandBack = false
        finderWorks.open(); finderWorks.focus.active = true
        finderWorks.controller.close(.toggle)
        finderWorks.focus.timers.fire(atLeast: ChatController.handbackDeadline)
        #expect(finderWorks.focus.finderRequests == 1 && finderWorks.lines("CHAT handback-finder gen=1").count == 1)
        finderWorks.focus.active = false
        finderWorks.focus.timers.fire(atLeast: ChatController.handbackDeadline)
        #expect(finderWorks.lines("CHAT handback-finder gen=1 ok=1").count == 1 && finderWorks.lines("CHAT handback-failed").isEmpty)

        let failing = ControllerRig()
        failing.focus.acceptsHandBack = false
        failing.open(); failing.focus.active = true
        failing.controller.close(.toggle)
        failing.focus.timers.fire(atLeast: ChatController.handbackDeadline)
        failing.focus.timers.fire(atLeast: ChatController.handbackDeadline)
        #expect(failing.focus.finderRequests == 1 && failing.lines("CHAT handback-failed gen=1").count == 1, "\(failing.lines("CHAT"))")
        #expect(failing.lines("CHAT handback-failed").count == 1, "nothing more is tried")
    }

    @Test func ChatActivate_theAuditRefusesANonActivatingChatPanel() throws {
        let fresh = ChatPanel(overFullScreen: false, gen: 1, view: ChatPanelView(height: 480))
        #expect(!fresh.styleMask.contains(.nonactivatingPanel) && ChatPanelAudit.violations(of: fresh).isEmpty)
        let broken = ChatPanel(overFullScreen: false, gen: 1, view: ChatPanelView(height: 480))
        broken.styleMask.insert(.nonactivatingPanel)
        #expect(ChatPanelAudit.violations(of: broken).contains { $0.contains("nonactivatingPanel") }, "\(ChatPanelAudit.violations(of: broken))")
        let r = ControllerRig()
        r.controller.panelPrepared = { $0.styleMask.insert(.nonactivatingPanel) }
        r.open()
        #expect(!r.controller.isOpen && r.focus.activationRequests == 0 && r.lines("CHAT contract-violation").count == 1 && r.lines("CHAT open").isEmpty)
    }

    @Test func ChatActivate_anotherAppsActivationOrAPressElsewhereSpendsTheOpensToken() throws {
        // (a) Another application's activation notification at 0.3 s spends the token. It closes nothing (orca parity round A, D1): the panel
        // stays open, and the open's activation is gone, so Clawd's own later activation is judged like any other.
        let a = ControllerRig()
        a.open()
        a.clock.advance(0.3)
        a.focus.otherAppBecomesActive(Self.appB)
        #expect(a.lines("CHAT activate-spent gen=1 cause=other-app").count == 1)
        a.focus.drain()
        #expect(a.controller.isOpen && a.lines("CHAT close").isEmpty, "\(a.logs)")
        #expect(a.controller.activationVerdict() == .answeredByClose && a.lines("CHAT active gen=1 cause=open").isEmpty, "a later activation of Clawd is a plain violation")

        // (b) No workspace notification; a mouse-down in the session that no Clawd window received.
        // The press is 0.6 s after the double-click's own time stamp, outside its click series (the series window is 0.5 s).
        let b = ControllerRig()
        b.clock.now = 10
        b.open(at: 10)
        b.clock.advance(0.6)
        b.focus.pressAt = b.clock.now
        b.clock.advance(0.1)
        b.focus.active = true
        #expect(b.controller.activationVerdict() == .answeredByClose)
        #expect(b.lines("CHAT activate-spent gen=1 cause=outside-press").count == 1 && b.lines("CHAT active gen=1 cause=open").isEmpty)
        b.focus.drain()
        #expect(!b.controller.isOpen && b.focus.deactivationRequests == 1 && b.focus.handBacks.isEmpty, "deactivate only: the open's target is not where the user went")

        // (c) The same press, received by Clawd's pet panel: the token holds.
        let c = ControllerRig()
        c.open()
        c.clock.advance(0.3)
        c.controller.windowPresses.record(0.3)
        c.focus.pressAt = 0.3
        c.clock.advance(0.2)
        #expect(c.controller.activationVerdict() == .exempt)
        #expect(c.lines("CHAT active gen=1 cause=open").count == 1 && c.lines("CHAT activate-spent").isEmpty)
    }

    @Test func ChatActivate_aClickBackIsJudgedByThePanelsOwnMouseDownAndAnEarlyKeyWaitsForTheActivation() throws {
        func resigned(_ r: ControllerRig) throws -> ChatPanel {
            r.open()
            let panel = try #require(r.controller.livePanel)
            r.clock.advance(0.1)
            #expect(r.controller.activationVerdict() == .exempt)
            r.focus.active = true
            r.clock.advance(5)
            r.controller.appResigned()
            r.focus.active = false
            r.clock.advance(5)
            return panel
        }
        // The panel recorded a left mouse-down; the key comes after willBecomeActive with an application-defined current event; the
        // activation follows 0.2 s after the mouse-down.
        let r = ControllerRig()
        var late = 0
        r.controller.lateViolation = { late += 1 }
        let panel = try resigned(r)
        panel.recordMouseDown(at: r.clock.now, left: true)
        r.controller.appWillBecomeActive()
        r.currentEvent = ChatCurrentEvent(isMouseDown: false, window: nil, isMouse: false)
        #expect(r.controller.keyVerdict(for: panel) == .deferred, "the key's verdict waits for the activation")
        r.clock.advance(0.2)
        r.focus.active = true
        #expect(r.controller.activationVerdict() == .exempt)
        #expect(r.lines("CHAT active gen=1 cause=click").count == 1 && r.lines("CHAT key gen=1").count == 1 && r.lines("CHAT key-uncaused").isEmpty, "\(r.lines("CHAT"))")
        r.focus.drain()
        #expect(r.controller.isOpen && late == 0)

        // Without the panel's recorded mouse-down the same sequence is uncaused and closes.
        let other = ControllerRig()
        var otherLate = 0
        other.controller.lateViolation = { otherLate += 1 }
        let second = try resigned(other)
        other.controller.appWillBecomeActive()
        other.currentEvent = ChatCurrentEvent(isMouseDown: false, window: nil, isMouse: false)
        #expect(other.controller.keyVerdict(for: second) == .deferred)
        other.clock.advance(0.2)
        other.focus.active = true
        #expect(other.controller.activationVerdict() == .answeredByClose)
        #expect(other.lines("CHAT key-uncaused gen=1").count == 1 && otherLate == 1)
        other.focus.drain()
        #expect(!other.controller.isOpen && other.lines("CHAT close reason=outside").count == 1)

        // A deferred key with no activation at all ends with the next main-queue turn: uncaused.
        let none = ControllerRig()
        let third = try resigned(none)
        none.controller.appWillBecomeActive()
        none.currentEvent = nil
        #expect(none.controller.keyVerdict(for: third) == .deferred)
        none.focus.drain()
        #expect(none.lines("CHAT key-uncaused gen=1").count == 1)
        none.focus.drain()
        #expect(!none.controller.isOpen)
    }

    @Test func ChatActivate_theExamAndHiddenClosesOnlyDeactivate() throws {
        for reason in [ChatCloseReason.exam, .hidden] {
            let r = ControllerRig()
            r.open(); r.focus.active = true
            r.controller.close(reason)
            #expect(r.focus.handBacks.isEmpty && r.focus.finderRequests == 0, "\(reason): no hand-back and no Finder")
            #expect(r.focus.deactivationRequests == 1 && r.lines("CHAT deactivate gen=1").count == 1)
            r.focus.active = false
            r.focus.timers.fire(atLeast: ChatController.handbackDeadline)
            #expect(r.lines("CHAT deactivate gen=1 ok=1").count == 1)
            let stuck = ControllerRig()
            stuck.open(); stuck.focus.active = true
            stuck.controller.close(reason)
            stuck.focus.timers.fire(atLeast: ChatController.handbackDeadline)
            #expect(stuck.lines("CHAT handback-failed gen=1").count == 1 && stuck.focus.finderRequests == 0, "\(reason): still active gives the failure, not Finder")
        }
    }

    @Test func ChatActivate_theHandBackGoesToTheAppFrontmostBeforeTheLatestActivation() throws {
        let r = ControllerRig()
        r.open()
        let panel = try #require(r.controller.livePanel)
        #expect(r.controller.handBackTarget == Self.appA)
        r.clock.advance(0.1)
        #expect(r.controller.activationVerdict() == .exempt)
        r.focus.active = true
        // The user's activation of Safari reaches Clawd while it is still active: the panel stays open and Safari is the target now, so a later
        // close by the button hands the keyboard to Safari.
        r.focus.otherAppBecomesActive(Self.appS)
        r.focus.drain()
        #expect(r.controller.isOpen && r.lines("CHAT close").isEmpty, "\(r.logs)")
        #expect(r.controller.handBackTarget == Self.appS)
        r.controller.close(.button)
        #expect(r.focus.handBacks == [Self.appS], "the keyboard goes to Safari, not to the application of the open: \(r.focus.handBacks)")
        #expect(r.focus.liveObservers == 0, "no observer once the panel is closed")
        _ = panel
        // Clawd's own activation notification is not a target.
        let own = ControllerRig()
        own.open()
        own.focus.otherAppBecomesActive(ChatAppRef(pid: ProcessInfo.processInfo.processIdentifier, launchDate: nil))
        #expect(own.controller.handBackTarget == Self.appA)
    }
}
