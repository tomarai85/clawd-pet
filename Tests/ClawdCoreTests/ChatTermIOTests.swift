import Testing
import Foundation
import AppKit
import Darwin
import ClawdCore
import ClawdDesktop
@testable import ClawdCore
@testable import SwiftTerm

/// Part C, against the real PTY spawn with the stub as claude, in a panel that is never ordered front. Every test builds Clawd's subclass of the
/// terminal view; the pasteboard is an injected source; the keys are constructed events handed to the view's own methods.
@Suite("ChatTermIO", .serialized)
@MainActor
struct ChatTermIOTests {
    @Test func ChatTermIO_typedKeysReachTheChildAndItsOutputReachesTheScreen() async throws {
        let r = try TermControllerRig()
        r.open()
        #expect(await r.waitScreen("tty="), "the stub's report reached the screen: \(r.screen)")
        r.type("a")
        #expect(await r.waitScreen("H 61"), "the key reached the child and its answer the screen")
        await r.finish()
    }

    @Test func ChatTermIO_escAndControlKeysGoToTheChildAndNeverClose() async throws {
        let r = try TermControllerRig()
        r.open()
        #expect(await r.waitScreen("tty="))
        // One key at a time: the child may read two quick keys as one chunk.
        r.press("\u{1b}", code: 53)
        let escape = await r.waitScreen("H 1b", 20)
        r.press("\u{3}", code: 8, flags: .control, ignoring: "c")
        let interrupt = await r.waitScreen("H 03", 20)
        r.press("\u{4}", code: 2, flags: .control, ignoring: "d")
        let eof = await r.waitScreen("H 04", 20)
        #expect(escape && interrupt && eof, "Esc \(escape), Ctrl+C \(interrupt) and Ctrl+D \(eof) arrived: \(r.screen)")
        #expect(r.controller.isOpen && r.lines("CHAT close").isEmpty, "none of them closes the panel")
        await r.finish()
    }

    @Test func ChatTermIO_commandWClosesThePanelAndSendsTheChildNothing() async throws {
        let r = try TermControllerRig()
        r.open()
        #expect(await r.waitScreen("tty="))
        // By key code 13 with exactly the Command flag: a kana direct-input source changes the characters, not the key.
        #expect(r.panel.performKeyEquivalent(with: keyEvent("\u{ff57}", code: 13, flags: .command, ignoring: "\u{ff57}")), "Cmd+W with kana characters closes too")
        #expect(r.lines("CHAT close reason=shortcut gen=1").count == 1 && !r.controller.isOpen)
        r.open(at: 2)
        #expect(!r.panel.performKeyEquivalent(with: keyEvent("w", code: 13, flags: [.command, .shift])), "Cmd+Shift+W does not close")
        #expect(r.controller.isOpen)
        #expect(r.panel.performKeyEquivalent(with: keyEvent("w", code: 13, flags: .command)))
        try await Task.sleep(nanoseconds: 700_000_000)
        #expect(!r.screen.contains("H 77") && !r.screen.contains("H "), "no byte reached the stub: \(r.screen)")
        await r.finish()
    }

    @Test func ChatTermIO_aPasteIsBracketedWhenTheChildAsksAndCounted() async throws {
        let r = try TermControllerRig()
        r.open()
        #expect(await r.waitScreen("tty="))
        r.pasteboard.text = "hello"
        r.terminalView.paste(self)
        #expect(await r.waitScreen("H 68656c6c6f"), "without the bracket request the text arrives plain, once: \(r.screen)")
        r.control("bracketed")
        // The stub's DECSET 2004 reaches the emulator after the control line is read; under load that takes longer than any fixed pause.
        #expect(await r.wait { r.terminalView.terminal.bracketedPasteMode }, "the child's bracketed-paste request reached the terminal")
        r.terminalView.paste(self)
        #expect(await r.waitScreen("H 1b5b3230307e68656c6c6f1b5b3230317e"), "with DECSET 2004 it arrives between the markers, once: \(r.screen)")
        // Copy goes to the injected source, never to the system's.
        r.terminalView.selectAll(nil)
        r.terminalView.copy(self)
        #expect(r.pasteboard.sets.count == 1)
        r.controller.close(.toggle)
        #expect(r.lines("CHAT close reason=toggle").first?.contains("pastes=2 pasted=10") == true, "\(r.logs)")
        await r.finish()
    }

    @Test func ChatTermIO_anImeCompositionSendsOnlyTheCommittedText() async throws {
        let r = try TermControllerRig()
        r.open()
        #expect(await r.waitScreen("tty="))
        let view = r.terminalView
        view.setMarkedText("\u{306b}\u{307b}\u{3093}", selectedRange: NSRange(location: 3, length: 0), replacementRange: NSRange(location: NSNotFound, length: 0))
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(!r.screen.contains("H "), "marked text sends nothing: \(r.screen)")
        view.insertText("\u{65e5}\u{672c}", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(await r.waitScreen("H e697a5e69cac"), "the commit sends its UTF-8 once")
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(r.screen.components(separatedBy: "H e697a5e69cac").count == 2)
        await r.finish()
    }

    @Test func ChatTermIO_optionReturnIsMetaAndALayoutsOptionCharacterIsTyped() async throws {
        let r = try TermControllerRig()
        r.open()
        #expect(await r.waitScreen("tty="))
        #expect(!r.terminalView.optionAsMetaKey && r.terminalView.optionAsMetaKeyForFunctionalKeys, "Option is Meta only on keys that type nothing")
        r.press("\r", code: 36, flags: .option)
        #expect(await r.waitScreen("H 1b0d"), "Option+Return reaches Claude Code as Meta-Return: \(r.screen)")
        // Cmd+Option+O is the panel's and does nothing: SwiftTerm never toggles optionAsMetaKey.
        #expect(r.panel.performKeyEquivalent(with: keyEvent("o", code: 31, flags: [.command, .option])))
        #expect(!r.terminalView.optionAsMetaKey)
        await r.finish()
    }

    @Test func ChatTermIO_reopenWhileTheChildLivesReattachesTheSameScreenAndProcess() async throws {
        let r = try TermControllerRig()
        r.open()
        #expect(await r.waitScreen("tty="))
        let pid = try #require(r.path.childPid)
        let view = r.terminalView
        r.controller.close(.toggle)
        #expect(view.superview == nil && view.window == nil, "the closed panel holds the view in no window")
        r.open(at: 2)
        #expect(r.lines("CHAT reattach gen=2 pid=\(pid)").count == 1)
        #expect(r.terminalView === view && r.screen.contains("tty="), "the same view with its buffer kept")
        #expect(r.spawns == 1, "nothing spawned")
        await r.finish()
    }

    @Test func ChatTermIO_anOpenWithNoChildResumesTheRecordedSessionInTheSameFolder() async throws {
        let r = try TermControllerRig(words: ["title=\u{25d0} Working"])
        r.open()
        #expect(await r.waitScreen("tty="))
        #expect(await r.wait { r.path.titleStateForTests == .working })
        #expect(await r.wait { r.argLines.count == 1 })
        let first = try #require(r.argLines.first)
        let id = try #require(first.split(separator: " ").dropFirst().first.map(String.init))
        #expect(first.hasPrefix("--session-id "))
        r.control("exit 0")
        #expect(await r.wait { r.exits == 1 })
        r.controller.close(.shortcut)
        r.open(at: 2)
        #expect(await r.wait { r.spawns == 2 && r.argLines.count == 2 })
        #expect(r.argLines.last?.hasPrefix("--resume \(id) ") == true, "the next open resumes the first spawn's id: \(r.argLines)")
        #expect(!r.argLines.contains { $0.contains("--continue") })
        #expect(await r.wait { r.path.titleStateForTests == .working })
        r.control("exit 0")
        #expect(await r.wait { r.exits == 2 })
        r.controller.close(.shortcut)
        // A different chatFolder starts fresh.
        let other = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()), create: true).path
        r.moveToFolder(other)
        r.open(at: 3)
        #expect(await r.wait { r.spawns == 3 && r.argLines.count == 3 })
        #expect(r.argLines.last?.hasPrefix("--session-id ") == true, "a different chatFolder starts fresh: \(r.argLines)")
        await r.finish()
    }

    @Test func ChatTermIO_returnAfterTheChildExitedStartsItAgain() async throws {
        let r = try TermControllerRig()
        r.open()
        #expect(await r.waitScreen("tty="))
        r.control("exit 0")
        #expect(await r.waitScreen("Claude Code exited. Press Return to start it again, or Cmd+W to close."))
        r.type("x")
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(r.spawns == 1, "another key spawns nothing")
        r.pressReturn()
        #expect(await r.wait { r.spawns == 2 }, "Return spawns by the open's rule")
        await r.finish()
    }

    @Test func ChatTermIO_aLinkOpensNothingAndTheBellIsSilent() async throws {
        let r = try TermControllerRig()
        r.open()
        #expect(await r.waitScreen("tty="))
        let missing = "/private/tmp/clawd-no-such-dir-\(UUID().uuidString)/file"
        #expect(!FileManager.default.fileExists(atPath: missing) && URL(string: missing)?.scheme == nil, "a link SwiftTerm's default cannot resolve")
        let witness: TerminalViewDelegate = r.path.delegate
        #expect(r.path.delegate.dropped == 0)
        witness.requestOpenLink(source: r.terminalView, link: missing, params: [:])
        #expect(r.path.delegate.dropped == 1, "Clawd's method is the witness, not the protocol's default")
        witness.bell(source: r.terminalView)
        #expect(r.path.delegate.bells == 1)
        await r.finish()
    }

    @Test func ChatTermIO_theTitleAndScreenTextNeverReachTheAgentLog() async throws {
        let marker = "MARKER" + UUID().uuidString.prefix(8)
        let r = try TermControllerRig(words: ["title=\(marker)"])
        r.open()
        #expect(await r.waitScreen("tty="))
        r.control("say \(marker)screen")
        #expect(await r.waitScreen("\(marker)screen"))
        r.type("typed\(marker)")
        r.controller.close(.toggle)
        r.open(at: 2)
        r.controller.close(.shortcut)
        for name in ["agent.log", "agent.log.1"] {
            let text = (try? String(contentsOf: try r.store.url(name), encoding: .utf8)) ?? ""
            #expect(!text.contains(marker), "\(name) holds no title, screen or typed text")
        }
        #expect(!r.logs.joined(separator: "\n").contains(marker))
        await r.finish()
    }

    @Test func ChatTermIO_theCloseLineCountsKeysAndPastes() async throws {
        let r = try TermControllerRig()
        r.open()
        #expect(await r.waitScreen("tty="))
        r.type("abcde")
        r.terminalView.insertText("\u{65e5}", replacementRange: NSRange(location: NSNotFound, length: 0))
        r.pasteboard.text = "123456789"
        r.terminalView.paste(self)
        // The keys are counted when SwiftTerm's sends reach the delegate (a later main-queue turn); the stub may read several sends as one chunk, so
        // the test waits on the count and not on the stub's echo.
        #expect(await r.wait { r.path.delegate.keys == 6 }, "keys: \(r.path.delegate.keys)")
        r.controller.close(.toggle)
        #expect(r.lines("CHAT close reason=toggle gen=1 keys=6 pastes=1 pasted=9 child=").count == 1, "\(r.logs)")

        // R9.12 item 2: two input-path sends under one current event count one; a send under a scroll-wheel event counts none.
        r.open(at: 2)
        let witness: TerminalViewDelegate = r.path.delegate
        let view = r.terminalView
        r.currentEvent = ChatCurrentEvent(isMouseDown: false, window: nil, isMouse: false, timestamp: 4242)
        witness.send(source: view, data: slice([0x61]))
        witness.send(source: view, data: slice([0x62]))
        #expect(r.path.delegate.keys == 1, "one event, two sends: \(r.path.delegate.keys)")
        r.currentEvent = ChatCurrentEvent(isMouseDown: false, window: nil, isMouse: true, timestamp: 4243)
        witness.send(source: view, data: slice([0x1B, 0x5B, 0x41]))
        #expect(r.path.delegate.keys == 1, "a send under a scroll-wheel event counts none")
        r.currentEvent = ChatCurrentEvent(isMouseDown: false, window: nil, isMouse: false, timestamp: 4244)
        witness.send(source: view, data: slice([0x63]))
        #expect(r.path.delegate.keys == 2, "the next key event counts again")
        r.currentEvent = nil
        await r.finish()
    }

    @Test func ChatTermIO_aSessionWithNoTurnIsNeverResumedAndAFailedResumeStartsFreshOnce() async throws {
        // (a) no working title was ever seen: the next open starts fresh.
        let a = try TermControllerRig()
        a.open()
        #expect(await a.waitScreen("tty="))
        a.control("exit 0")
        #expect(await a.waitScreen("Claude Code exited"))
        a.controller.close(.shortcut)
        a.open(at: 2)
        #expect(await a.wait { a.spawns == 2 })
        #expect(a.argLines.allSatisfy { $0.hasPrefix("--session-id ") }, "never --resume: \(a.argLines)")
        await a.finish()

        // (b) a working title was seen: the next open resumes; the resume fails at once; one fresh spawn follows in the same opening.
        let b = try TermControllerRig(words: ["title=\u{25d0} Working", "resume-fail"])
        b.open()
        #expect(await b.wait { b.path.titleStateForTests == .working })
        let id = try #require(b.argLines.first?.split(separator: " ").dropFirst().first.map(String.init))
        b.control("exit 0")
        #expect(await b.waitScreen("Claude Code exited"))
        b.controller.close(.shortcut)
        b.open(at: 2)
        #expect(await b.wait { b.spawns == 3 && b.argLines.count == 3 }, "the resume spawn and the fresh one: \(b.logs)")
        #expect(b.lines("CHAT notice kind=resume-failed").count == 1)
        #expect(b.argLines.count == 3 && b.argLines[1].hasPrefix("--resume \(id) ") && b.argLines[2].hasPrefix("--session-id ") && !b.argLines[2].contains(id))
        #expect(b.lines("CHAT term spawn").last?.contains("mode=fresh") == true)
        await b.finish()

        // (c) the fresh one fails at once too: the exit line, nothing more; Return spawns fresh with another id, never --resume U.
        let c = try TermControllerRig(words: ["title=\u{25d0} Working", "resume-fail"])
        c.open()
        #expect(await c.wait { c.path.titleStateForTests == .working })
        let u = try #require(c.argLines.first?.split(separator: " ").dropFirst().first.map(String.init))
        c.control("exit 0")
        #expect(await c.waitScreen("Claude Code exited"))
        c.controller.close(.shortcut)
        FileManager.default.createFile(atPath: c.folder + "/failfresh", contents: Data())
        c.open(at: 2)
        #expect(await c.waitScreen("boom"), "the fresh child failed too")
        #expect(await c.waitScreen("Claude Code exited. Press Return"))
        let spawnsBefore = c.argLines.count
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(c.argLines.count == spawnsBefore, "nothing more is spawned without Return")
        try FileManager.default.removeItem(atPath: c.folder + "/failfresh")
        c.pressReturn()
        #expect(await c.wait { c.argLines.count == spawnsBefore + 1 })
        #expect(c.argLines.last?.hasPrefix("--session-id ") == true && c.argLines.last?.contains(u) == false)
        #expect(!c.argLines.suffix(2).contains { $0.hasPrefix("--resume \(u)") && $0 == c.argLines.last })
        await c.finish()
    }

    @Test func ChatTermIO_shiftReturnIsANewlineWhileTheKittyProtocolIsOff() async throws {
        let r = try TermControllerRig()
        r.open()
        #expect(await r.waitScreen("tty="))
        r.pressReturn(flags: .shift)
        #expect(await r.waitScreen("H 1b0d"), "Shift+Return is ESC CR: \(r.screen)")
        r.pressReturn()
        #expect(await r.waitScreen("H 0d"), "Return alone is CR")
        // R9.12 item 3: one keyDown of Shift+Return with Caps Lock on is a newline too.
        let newlines = r.screen.components(separatedBy: "H 1b0d").count
        r.pressReturn(flags: [.shift, .capsLock])
        #expect(await r.wait { r.screen.components(separatedBy: "H 1b0d").count == newlines + 1 }, "Shift+Return with Caps Lock on is ESC CR: \(r.screen)")
        // Through the delegate with an injected current event: the flags are reduced to Shift, Control, Option and Command.
        let delegate = r.path.delegate
        let witness: TerminalViewDelegate = delegate
        let original = delegate.deliver
        var delivered: [[UInt8]] = []
        delegate.deliver = { delivered.append($0); return true }
        let cases: [NSEvent.ModifierFlags] = [[.shift, .capsLock], [.shift, .numericPad], [.shift, .control]]
        for flags in cases {
            r.currentEvent = ChatCurrentEvent(isMouseDown: false, window: nil, isMouse: false, modifiers: flags)
            witness.send(source: r.terminalView, data: slice([0x0D]))
        }
        r.currentEvent = nil
        delegate.deliver = original
        #expect(delivered == [[0x1B, 0x0D], [0x1B, 0x0D], [0x0D]], "Caps Lock and the keypad flag are ignored, Control is not: \(delivered)")
        r.control("kitty")
        try await Task.sleep(nanoseconds: 500_000_000)
        let before = r.screen.components(separatedBy: "H 1b0d").count
        r.pressReturn(flags: .shift)
        try await Task.sleep(nanoseconds: 600_000_000)
        #expect(r.screen.components(separatedBy: "H 1b0d").count == before, "with the kitty protocol on, SwiftTerm's own encoding is sent, untouched")
        await r.finish()
    }

    @Test func ChatTermIO_aChildThatReadsNothingNeverBlocksTheMainQueue() async throws {
        // The cap is 16 MiB; this test lowers it to 2 MiB so that the refusal needs no 17 MiB paste (the encoding of one takes minutes unoptimised).
        #expect(ChatTermChild.maxPendingBytes == 16 * 1024 * 1024)
        let r = try TermControllerRig(maxPending: 2 * 1024 * 1024)
        r.open()
        #expect(await r.waitScreen("tty="))
        r.control("deaf")
        try await Task.sleep(nanoseconds: 500_000_000)
        r.pasteboard.text = String(repeating: "x", count: 1024 * 1024)
        let began = ProcessInfo.processInfo.systemUptime
        r.terminalView.paste(self)
        // SwiftTerm encodes the 1 MiB itself in this unoptimised build; what must not depend on the child is Clawd's hand-over to the write queue.
        let called = ProcessInfo.processInfo.systemUptime - began
        #expect(called < 60, "the paste call returns although the child reads nothing: \(called) s")
        #expect(await r.wait(30) { r.path.delegate.longestDelivery > 0 }, "the hand-over to the write queue happened")
        #expect(r.path.delegate.longestDelivery < 0.1, "and took under 100 ms on the main queue: \(r.path.delegate.longestDelivery)")
        // A paste that would take the pending bytes over the cap is refused whole.
        r.pasteboard.text = String(repeating: "y", count: 1_500_000)
        r.terminalView.paste(self)
        #expect(await r.wait(60) { r.lines("CHAT notice kind=paste-refused").count == 1 }, "\(r.logs)")
        // The exam path closes the panel in the same turn and leaves no token process at 3 s, although the master cannot be written.
        let stopBegan = ProcessInfo.processInfo.systemUptime
        r.host.examActive = true
        r.controller.batchEnded()
        #expect(!r.controller.isOpen, "closed in the same turn")
        #expect(await r.wait(15) { r.child?.hasEnded == true })
        #expect(ProcessInfo.processInfo.systemUptime - stopBegan < 10)
        #expect(r.carriers() == 0)

        // R9.12 item 5: with the cap lowered to 64 KiB, a 65 KiB paste is refused before SwiftTerm encodes anything.
        let small = try TermControllerRig(maxPending: 64 * 1024)
        small.open()
        #expect(await small.waitScreen("tty="))
        small.pasteboard.text = String(repeating: "z", count: 65 * 1024)
        let refusalBegan = ProcessInfo.processInfo.systemUptime
        small.terminalView.paste(self)
        let refusalTook = ProcessInfo.processInfo.systemUptime - refusalBegan
        #expect(refusalTook < 0.1, "the refused paste returns within 100 ms: \(refusalTook) s")
        #expect(small.terminalView.pasteTextCalls == 0, "pasteText was never called for it")
        #expect(small.lines("CHAT notice kind=paste-refused").count == 1, "\(small.logs)")
        // The queue's own check stays for the encoded bytes: bytes that would take the pending bytes over the cap are refused whole.
        #expect(small.child?.send(Data(repeating: 0x7A, count: 65 * 1024)) == false && small.child?.pendingBytes == 0, "the write queue refuses them")
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(!small.screen.contains("H "), "the stub received nothing: \(small.screen)")
        await small.finish()
    }

    @Test func ChatTermIO_theTerminalsOwnRepliesAndReportsAreNeverCountedAsKeys() async throws {
        let r = try TermControllerRig(words: ["focus"])
        r.open()
        #expect(await r.waitScreen("tty="))
        // DECSET 1004 is answered at once with the current focus state: a reply that reaches claude and counts for nothing.
        #expect(await r.waitScreen("H 1b5b4"), "the immediate focus report reached the stub: \(r.screen)")
        func reports() -> Int { r.screen.components(separatedBy: "H 1b5b4").count }
        let first = reports()
        r.terminalView.withTerminal { $0.setTerminalFocus(false) }
        #expect(await r.wait { reports() == first + 1 }, "focus-out reached the stub: \(r.screen)")
        r.terminalView.withTerminal { $0.setTerminalFocus(true) }
        #expect(await r.wait { reports() == first + 2 }, "and focus-in")
        #expect(r.screen.contains("H 1b5b4f") && r.screen.contains("H 1b5b49"), "ESC [ O and ESC [ I: \(r.screen)")
        r.control("query")
        #expect(await r.waitScreen("H 1b5b3f"), "a DA reply reached the stub: \(r.screen)")
        #expect(r.path.delegate.keys == 0 && !r.path.draftPending, "replies and reports count no key and leave no draft")
        r.type("abc")
        #expect(await r.wait { r.path.delegate.keys == 3 })
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(r.path.delegate.keys == 3 && r.path.draftPending, "three keys: \(r.path.delegate.keys)")
        r.controller.close(.toggle)
        #expect(r.lines("CHAT close reason=toggle gen=1 keys=3 pastes=0 pasted=0 child=").count == 1, "\(r.logs)")
        await r.finish()
    }

    /// A rig whose first child showed a working title and exited 0, so the next open resumes it (IO 13 (b)); the resumed child is running.
    private func resumed(words: [String] = [], resumeFailSeconds: TimeInterval = ChatTermPath.resumeFailSeconds) async throws -> (rig: TermControllerRig, id: String) {
        let r = try TermControllerRig(words: words, resumeFailSeconds: resumeFailSeconds)
        r.open()
        #expect(await r.waitScreen("tty="))
        r.control("title \u{25d0} Working")
        #expect(await r.wait { r.path.titleStateForTests == .working })
        let id = try #require(r.argLines.first?.split(separator: " ").dropFirst().first.map(String.init))
        r.control("exit 0")
        #expect(await r.wait { r.exits == 1 })
        r.controller.close(.shortcut)
        r.open(at: 2)
        #expect(await r.wait { r.spawns == 2 && r.argLines.count == 2 })
        #expect(r.argLines[1].hasPrefix("--resume \(id) "), "\(r.argLines)")
        // The view keeps the first child's screen across the opening, and each stub report holds "tty=" twice ("isatty=" and "tty="): the first
        // report alone makes 3 pieces, so the resumed child has reported (and set raw mode, which comes first) only at 5.
        #expect(await r.wait { r.screen.components(separatedBy: "tty=").count == 5 }, "the resumed child reported: \(r.screen)")
        return (r, id)
    }

    private static let exitLine = "Claude Code exited. Press Return to start it again, or Cmd+W to close."
    private static let reopenLine = "Claude Code could not reopen the earlier conversation. Press Return to start a new one, or Cmd+W to close."

    /// IO 18 (f): an exit key typed into the resumed child, then its exit with status 1: not a failed resume, so Return resumes U.
    private func exitKeyCase(kitty: Bool, characters: String, code: UInt16, ignoring: String, legacy: String) async throws {
        let (r, id) = try await resumed()
        if kitty {
            r.control("kitty 5")                      // claude 2.1.310's push: disambiguate plus alternate keys
            try await Task.sleep(nanoseconds: 500_000_000)
        }
        r.press(characters, code: code, flags: .control, ignoring: ignoring)
        if kitty {
            #expect(await r.wait { r.screen.contains("H 1b5b") }, "a CSI u line reached the stub: \(r.screen)")
            #expect(!r.screen.contains("H 03") && !r.screen.contains("H 04"), "not the legacy byte")
        } else {
            #expect(await r.waitScreen("H " + legacy), "the legacy byte reached the stub: \(r.screen)")
        }
        r.control("exit 1")
        #expect(await r.wait { r.exits == 2 })
        #expect(r.lines("CHAT notice kind=resume-failed").isEmpty, "the user's own exit key is no failed resume: \(r.logs)")
        let needle = String(Self.exitLine.filter { !$0.isWhitespace })
        #expect(await r.wait { r.squashed.components(separatedBy: needle).count == 3 }, "the plain exit line: \(r.screen)")
        r.pressReturn()
        #expect(await r.wait { r.argLines.count == 3 })
        #expect(r.argLines[2].hasPrefix("--resume \(id) "), "Return resumes U again: \(r.argLines)")
        await r.finish()
    }

    @Test func ChatTermIO_aResumeEndedBeforeWorkIsMarkedUnlessTheUserOrClawdEndedIt() async throws {
        // (d) another message and a non-zero status: marked at once, whatever the time and the text.
        let (d, idD) = try await resumed()
        d.control("say Error: transcript unreadable")
        #expect(await d.waitScreen("Error: transcript unreadable"))
        d.control("exit 2")
        #expect(await d.wait { d.exits == 2 })
        #expect(d.lines("CHAT notice kind=resume-failed").count == 1, "\(d.logs)")
        #expect(await d.waitScreen(Self.reopenLine), "the could-not-reopen line: \(d.screen)")
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(d.spawns == 2, "nothing is spawned without Return")
        d.pressReturn()
        #expect(await d.wait { d.argLines.count == 3 })
        #expect(d.argLines[2].hasPrefix("--session-id ") && !d.argLines[2].contains(idD), "Return starts fresh: \(d.argLines)")
        d.control("exit 0")
        #expect(await d.wait { d.exits == 3 })
        d.controller.close(.shortcut)
        d.open(at: 3)
        #expect(await d.wait { d.argLines.count == 4 })
        #expect(d.argLines[3].hasPrefix("--session-id "), "a later open never uses --resume U: \(d.argLines)")
        await d.finish()

        // (e) the known message after resumeFailSeconds (0.3 s in this rig, the virtual clock at 0.6 s): marked the same, without the fallback.
        let (e, _) = try await resumed(resumeFailSeconds: 0.3)
        e.clock.advance(0.6)
        e.control("say No conversation found")
        #expect(await e.waitScreen("No conversation found"))
        e.control("exit 1")
        #expect(await e.wait { e.exits == 2 })
        #expect(e.lines("CHAT notice kind=resume-failed").count == 1, "\(e.logs)")
        #expect(await e.waitScreen(Self.reopenLine), "\(e.screen)")
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(e.spawns == 2, "no spawn without Return")
        e.pressReturn()
        #expect(await e.wait { e.argLines.count == 3 })
        #expect(e.argLines[2].hasPrefix("--session-id "), "\(e.argLines)")
        await e.finish()

        // (f) the user's own exit key, in the legacy encoding and under claude's kitty push (flags 5): not marked.
        try await exitKeyCase(kitty: false, characters: "\u{3}", code: 8, ignoring: "c", legacy: "03")
        try await exitKeyCase(kitty: true, characters: "\u{3}", code: 8, ignoring: "c", legacy: "03")
        try await exitKeyCase(kitty: true, characters: "\u{4}", code: 2, ignoring: "d", legacy: "04")

        // (g) Clawd's own stop: the idle stop hangs the stub up and it exits 129; not marked, and the next open resumes U.
        let (g, idG) = try await resumed(words: ["hup-exit=129"])
        g.control("title \u{2733} Claude Code")
        #expect(await g.wait { g.path.titleStateForTests == .idle })
        g.controller.close(.toggle)
        #expect(g.timers.live == [600], "\(g.timers.live)")
        g.clock.advance(600)
        g.timers.fire(atLeast: 600)
        #expect(await g.wait { g.child?.hasEnded == true && g.exits == 2 })
        #expect(g.lines("CHAT stop reason=idle").count == 1 && g.lines("CHAT notice kind=resume-failed").isEmpty, "\(g.logs)")
        g.open(at: 3)
        #expect(await g.wait { g.argLines.count == 3 })
        #expect(g.argLines[2].hasPrefix("--resume \(idG) "), "the stop was Clawd's, so U is resumed again: \(g.argLines)")
        await g.finish()
    }

    @Test func ChatTermIO_theCloseButtonTakesTheFirstMouse() async throws {
        let r = try TermControllerRig()
        r.open()
        // A close control that does not take the first mouse makes the audit refuse the open: the test fails here, by name, not in a helper.
        let panel = try #require(r.controller.livePanel, "the open was refused: \(r.logs)")
        #expect(await r.waitScreen("tty="))
        let container = try #require(panel.terminal)
        #expect(container.closeButton.acceptsFirstMouse(for: nil), "a click on it while Clawd is inactive closes the panel")
        container.closeButton.performClick(nil)
        #expect(r.lines("CHAT close reason=button gen=1").count == 1 && !r.controller.isOpen)
        await r.finish()
    }
}

extension TermControllerRig {
    /// Points the next spawn at another folder (the chatFolder setting).
    func moveToFolder(_ path: String) { folderOverride = path }
}

/// A slice of bytes, for the delegate's `send(source:data:)`.
func slice(_ bytes: [UInt8]) -> ArraySlice<UInt8> { bytes[...] }
