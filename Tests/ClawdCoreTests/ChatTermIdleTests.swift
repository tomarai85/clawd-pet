import Testing
import Foundation
import AppKit
import Darwin
import ClawdCore
import ClawdDesktop
@testable import ClawdCore

/// Part C, the idle stop with its holds (virtual clock; the controller's timer source is the tests' manual one).
@Suite("ChatTermIdle", .serialized)
@MainActor
struct ChatTermIdleTests {
    private static let idle = "\u{2733} Claude Code"
    private static let work = "\u{25d0} Working"

    @Test func ChatTermIdle_stopsTenMinutesAfterTheCloseWhenIdle() async throws {
        let r = try TermControllerRig(words: ["title=\(Self.idle)"])
        r.open()
        #expect(await r.wait { r.path.titleStateForTests == .idle })
        r.controller.close(.toggle)
        #expect(r.timers.live == [600], "one 600 s one-shot, nothing earlier: \(r.timers.live)")
        r.clock.advance(600)
        r.timers.fire(atLeast: 600)
        #expect(await r.wait { r.child?.hasEnded == true })
        #expect(r.lines("CHAT stop reason=idle").count == 1 && r.logs.contains { $0.hasPrefix("CHAT sweep n=") && $0.hasSuffix("left=0") })
        #expect(r.carriers() == 0)
    }

    @Test func ChatTermIdle_isHeldWhileTheTitleShowsWorkAndCountsFromTheEndOfWork() async throws {
        let r = try TermControllerRig(words: ["title=\(Self.work)"])
        r.open()
        #expect(await r.wait { r.path.titleStateForTests == .working })
        r.controller.close(.toggle)
        #expect(r.timers.live.isEmpty && r.lines("CHAT idle-held reason=working gen=1").count == 1, "held while the title spins: \(r.logs)")
        r.control("title \u{280b} still working")
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(r.timers.live.isEmpty, "a braille frame is work too")
        r.clock.advance(300)
        r.control("title \(Self.idle)")
        #expect(await r.wait { r.timers.live == [600] }, "the change to the sparkle title at t arms the stop for t + 600 s")
        r.clock.advance(600)
        r.timers.fire(atLeast: 600)
        #expect(await r.wait { r.child?.hasEnded == true } && r.lines("CHAT stop reason=idle").count == 1)
    }

    @Test func ChatTermIdle_aPendingDraftHoldsTheStopForAtMostAnHour() async throws {
        let r = try TermControllerRig(words: ["title=\(Self.idle)"])
        r.open()
        #expect(await r.wait { r.path.titleStateForTests == .idle })
        r.type("x")
        try await Task.sleep(nanoseconds: 300_000_000)
        r.controller.close(.toggle)
        #expect(r.lines("CHAT idle-held reason=draft gen=1").count == 1)
        #expect(r.timers.live == [3600], "the draft cap and no 600 s timer: \(r.timers.live)")
        r.clock.advance(3600)
        r.timers.fire(atLeast: 3600)
        #expect(await r.wait { r.child?.hasEnded == true })
        #expect(r.lines("CHAT stop reason=idle-cap").count == 1)
        #expect(r.terminalView.screenText.contains("tty="), "the view keeps its last screen")
        let spawns = r.spawns
        r.open(at: 2)
        #expect(r.spawns == spawns, "the next open spawns nothing")
        #expect(await r.waitScreen("Claude Code was stopped after an hour unused. Your unsent text is above. Press Return to start it again."))
        r.pressReturn()
        #expect(await r.wait { r.spawns == spawns + 1 }, "Return then spawns")
        await r.finish()
    }

    @Test func ChatTermIdle_withNoTitleRecentOutputHoldsTheStopForAMinute() async throws {
        let r = try TermControllerRig()
        r.open()
        #expect(await r.waitScreen("tty="))
        r.controller.close(.toggle)
        #expect(r.timers.live == [600])
        r.clock.advance(570)
        r.control("say tick")
        #expect(await r.wait { r.screenContains("tick") })
        r.clock.advance(30)
        r.timers.fire(atLeast: 600)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(r.lines("CHAT stop").isEmpty && r.timers.live == [60], "output 30 s before the 600 s mark holds it; one re-check 60 s later: \(r.timers.live)")
        r.clock.advance(60)
        r.timers.fire(atLeast: 60)
        #expect(await r.wait { r.child?.hasEnded == true } && r.lines("CHAT stop reason=idle").count == 1)
    }

    @Test func ChatTermIdle_anExamPathClosesThePanelAndStopsTheChildAtOnce() async throws {
        // Held by work, with the panel closed: the exam stops it anyway.
        let held = try TermControllerRig(words: ["title=\(Self.work)"])
        held.open()
        #expect(await held.wait { held.path.titleStateForTests == .working })
        held.controller.close(.toggle)
        held.host.examActive = true
        held.controller.batchEnded()
        #expect(await held.wait(15) { held.child?.hasEnded == true } && held.carriers() == 0)
        #expect(held.lines("CHAT stop reason=exam").count == 1)

        // Held by a draft, panel open: closed in the same turn.
        let draft = try TermControllerRig(words: ["title=\(Self.idle)"])
        draft.open()
        #expect(await draft.wait { draft.path.titleStateForTests == .idle })
        draft.type("x")
        draft.host.examActive = true
        draft.controller.batchEnded()
        #expect(!draft.controller.isOpen && draft.lines("CHAT close reason=exam").count == 1)
        #expect(await draft.wait(15) { draft.child?.hasEnded == true } && draft.carriers() == 0)
        #expect(draft.lines("CHAT stop reason=exam").count == 1)

        // An exam path during a running graceful stop upgrades it and says so (R9.12 VOCABULARY 1). The stub ignores the hang-up, so the idle
        // stop is still running when the exam arrives.
        let record = FileManager.default.temporaryDirectory.appendingPathComponent("hup-" + UUID().uuidString).path
        let upgrade = try TermControllerRig(words: ["title=\(Self.idle)", "record=" + record])
        upgrade.open()
        #expect(await upgrade.wait { upgrade.path.titleStateForTests == .idle })
        upgrade.controller.close(.toggle)
        upgrade.clock.advance(600)
        upgrade.timers.fire(atLeast: 600)
        #expect(upgrade.child?.isStopping == true, "the idle stop is running")
        upgrade.host.examActive = true
        upgrade.controller.batchEnded()
        #expect(await upgrade.wait(15) { upgrade.child?.hasEnded == true } && upgrade.carriers() == 0)
        #expect(upgrade.lines("CHAT stop reason=idle").count == 1)
        #expect(upgrade.lines("CHAT stop reason=exam upgraded=1").count == 1, "\(upgrade.logs)")
    }

    @Test func ChatTermIdle_aReopenDuringAStopStartsTheNextClaudeOnlyAfterTheStopHasEnded() async throws {
        // An open while the idle stop is still letting the old claude go spawned `--resume U` beside it: two claudes on one session (T1 code
        // review r1, OUT-OF-SCOPE 2). The stub ignores the hang-up, so the stop runs about 1 s and the open lands inside it.
        let record = FileManager.default.temporaryDirectory.appendingPathComponent("hup-" + UUID().uuidString).path
        let r = try TermControllerRig(words: ["title=\(Self.idle)", "record=" + record])
        r.open()
        #expect(await r.wait { r.path.titleStateForTests == .idle })
        r.controller.close(.toggle)
        r.clock.advance(600)
        r.timers.fire(atLeast: 600)
        let first = r.child
        #expect(first?.isStopping == true, "the idle stop is running")
        r.open(at: 2)
        #expect(r.spawns == 1, "no second claude while the first one's stop runs: \(r.logs)")
        #expect(await r.wait(15) { r.spawns == 2 }, "the reopen gets its claude once the stop has ended: \(r.logs)")
        #expect(first?.hasEnded == true)
        let sweep = r.logs.firstIndex { $0.hasPrefix("CHAT sweep n=") }
        let second = r.logs.lastIndex { $0.hasPrefix("CHAT term spawn") }
        #expect(sweep != nil && second != nil && sweep! < second!, "the first claude's sweep ends before the second spawn: \(r.logs)")
        #expect(!r.waitedScreen("Claude Code exited."), "Clawd's own stop is not reported as an exit")
        await r.finish()

        // The same through Return: a memory stop with a draft, the open during it writes the restart line, and Return waits for the stop's end.
        let m = try TermControllerRig(words: ["title=\(Self.idle)", "record=" + record + "-m"])
        m.open()
        #expect(await m.wait { m.path.titleStateForTests == .idle })
        m.type("x")
        try await Task.sleep(nanoseconds: 300_000_000)
        m.controller.close(.toggle)
        m.memoryHandler?()
        let stopping = m.child
        #expect(stopping?.isStopping == true, "the memory stop is running")
        m.open(at: 2)
        #expect(await m.waitScreen("Claude Code was stopped to free memory. Your unsent text is above. Press Return to start it again.", 5))
        m.pressReturn()
        #expect(m.spawns == 1, "Return during the stop starts nothing yet: \(m.logs)")
        #expect(await m.wait(15) { m.spawns == 2 }, "\(m.logs)")
        #expect(stopping?.hasEnded == true)
        await m.finish()

        // A close before the stop ends drops the waiting start: nothing is spawned for a panel that is gone.
        let c = try TermControllerRig(words: ["title=\(Self.idle)", "record=" + record + "-c"])
        c.open()
        #expect(await c.wait { c.path.titleStateForTests == .idle })
        c.controller.close(.toggle)
        c.clock.advance(600)
        c.timers.fire(atLeast: 600)
        let gone = c.child
        #expect(gone?.isStopping == true)
        c.open(at: 2)
        c.controller.close(.toggle)
        #expect(await c.wait(15) { gone?.hasEnded == true })
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(c.spawns == 1, "\(c.logs)")
        await c.finish()
    }

    @Test func ChatTermIdle_aMemoryPressureEventStopsAClosedIdleChild() async throws {
        // Idle, panel closed, no draft: a memory-pressure event stops it at once.
        let a = try TermControllerRig(words: ["title=\(Self.idle)"])
        a.open()
        #expect(await a.wait { a.path.titleStateForTests == .idle })
        #expect(!a.path.memorySourceInstalled, "the source exists only while the panel is closed")
        a.controller.close(.toggle)
        #expect(a.path.memorySourceInstalled && a.memorySources.count == 1)
        a.memoryHandler?()
        #expect(await a.wait { a.child?.hasEnded == true } && a.lines("CHAT stop reason=memory").count == 1)

        // With a draft: the next open writes the memory restart line and spawns nothing until Return.
        let b = try TermControllerRig(words: ["title=\(Self.idle)"])
        b.open()
        #expect(await b.wait { b.path.titleStateForTests == .idle })
        b.type("x")
        try await Task.sleep(nanoseconds: 300_000_000)
        b.controller.close(.toggle)
        b.memoryHandler?()
        #expect(await b.wait { b.child?.hasEnded == true })
        let spawns = b.spawns
        b.open(at: 2)
        #expect(await b.waitScreen("Claude Code was stopped to free memory. Your unsent text is above. Press Return to start it again."))
        #expect(b.spawns == spawns)
        b.pressReturn()
        #expect(await b.wait { b.spawns == spawns + 1 })
        await b.finish()

        // While the title shows work, the source does not exist and an event stops nothing.
        let c = try TermControllerRig(words: ["title=\(Self.work)"])
        c.open()
        #expect(await c.wait { c.path.titleStateForTests == .working })
        c.controller.close(.toggle)
        #expect(!c.path.memorySourceInstalled)
        c.memoryHandler?()
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(c.lines("CHAT stop").isEmpty)
        await c.finish()
    }

    @Test func ChatTermIdle_aPastedDraftHoldsTheStopLikeATypedOne() async throws {
        let r = try TermControllerRig(words: ["title=\(Self.idle)"])
        r.open()
        #expect(await r.wait { r.path.titleStateForTests == .idle })
        r.pasteboard.text = "hello"
        r.terminalView.paste(self)                      // nothing is typed
        #expect(await r.waitScreen("H 68656c6c6f"), "the stub shows the pasted bytes: \(r.screen)")
        r.controller.close(.toggle)
        #expect(r.lines("CHAT idle-held reason=draft gen=1").count == 1, "\(r.logs)")
        #expect(r.timers.live == [3600], "the draft cap and no 600 s timer: \(r.timers.live)")
        await r.finish()

        // A paste handled after the close (R38): the draft became pending after the 600 s one-shot was armed, so the one-shot holds instead of stopping.
        let late = try TermControllerRig(words: ["title=\(Self.idle)"])
        late.open()
        #expect(await late.wait { late.path.titleStateForTests == .idle })
        late.controller.close(.toggle)
        #expect(late.timers.live == [600])
        late.path.delegate.sent([0x68], true)
        late.clock.advance(600)
        late.timers.fire(atLeast: 600)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(late.lines("CHAT stop").isEmpty, "the one-shot stopped nothing: \(late.logs)")
        #expect(late.lines("CHAT idle-held reason=draft gen=1").count == 1 && late.timers.live == [3600], "\(late.logs) \(late.timers.live)")
        await late.finish()
    }
}

extension TermControllerRig {
    func screenContains(_ text: String) -> Bool { screen.contains(text) }
}
