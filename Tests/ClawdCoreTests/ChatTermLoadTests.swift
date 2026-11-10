import Testing
import Foundation
import AppKit
import Darwin
import ClawdProcess
import ClawdCore
import ClawdDesktop
@testable import ClawdCore

/// Part E: the load mechanisms of R9.5 (what the terminal path keeps armed, held or resident).
@Suite("ChatTermLoad", .serialized)
@MainActor
struct ChatTermLoadTests {
    private func row(_ pid: Int32, start: UInt64, parent: Int32 = 1, group: Int32 = 777) -> ChatProc.Row {
        ChatProc.Row(identity: ProcessIdentity(ClawdIdentity(pid: pid, uid: getuid(), seconds: start, microseconds: 0)), parent: parent, group: group)
    }

    @Test func ChatTermLoad_aClosedPanelHoldsTheTerminalViewInNoWindow() async throws {
        let r = try TermControllerRig()
        r.open()
        #expect(await r.waitScreen("tty="))
        let view = r.terminalView
        #expect(view.window === r.panel && view.superview != nil, "open: the view is in the panel")
        r.controller.close(.toggle)
        #expect(view.window == nil && view.superview == nil, "closed: the view has no window and no superview, so SwiftTerm draws nothing")
        r.open(at: 2)
        #expect(view.window === r.panel && r.panel.terminal?.terminalView === view, "after the reopen it is in the new panel")
        await r.finish()
    }

    @Test func ChatTermLoad_noChatTimerIsArmedWhileClosedWithoutAChild() async throws {
        let r = try TermControllerRig()
        #expect(r.timers.live.isEmpty && !r.path.memorySourceInstalled && r.memorySources.isEmpty, "before any open")
        r.open()
        #expect(await r.waitScreen("tty="))
        #expect(r.timers.live.isEmpty, "an open panel arms none")
        r.control("exit 0")
        #expect(await r.waitScreen("Claude Code exited"))
        r.controller.close(.shortcut)
        #expect(await r.wait { r.child?.hasEnded == true })
        #expect(r.timers.live.isEmpty && !r.path.memorySourceInstalled, "closed with no child: no one-shot, no memory-pressure source: \(r.timers.live)")
        #expect(r.memorySources.allSatisfy { $0.cancelled })
    }

    @Test func ChatTermLoad_theTrackerReadsAnEnvironmentOncePerIdentityAndExecutable() {
        var table = [row(201, start: 1), row(202, start: 2)]
        var reads: [Int32: Int] = [:]
        var environment: [Int32: ChatProc.EnvironmentRead] = [201: .readable, 202: .hidden, 203: .readable]
        var paths: [Int32: String] = [201: "/opt/homebrew/bin/node", 202: "/usr/bin/nohup", 203: "/opt/homebrew/bin/node"]
        let set = ChatSweepSet(token: "t", pid: 1, identity: nil, table: { table }, environment: { pid in reads[pid, default: 0] += 1; return environment[pid] ?? .hidden },
                               path: { paths[$0] })
        _ = set.grow(.tracking); _ = set.grow(.tracking); _ = set.grow(.tracking)
        #expect(reads[201] == 1, "a readable environment without the token is read once over three growths: \(reads)")
        #expect(reads[202] == 1, "a hidden one with an unchanged path is read once: \(reads)")
        table.append(row(203, start: 3))
        _ = set.grow(.tracking)
        #expect(reads[203] == 1 && reads[201] == 1, "a new identity is read once, the old ones not again: \(reads)")
        // growth 3 of identity 202: it execs into node and carries the token; the path changed, so it is read again and is a member.
        paths[202] = "/opt/homebrew/bin/node"; environment[202] = .carrier
        let grown = set.grow(.tracking)
        #expect(reads[202] == 2, "the changed path made the tracker read it again: \(reads)")
        #expect(grown.map(\.pid) == [202], "and it is a member: \(grown.map(\.pid))")
        // The records of identities gone from the table are dropped, so the record never outgrows the table.
        table = [row(202, start: 2)]
        _ = set.grow(.tracking)
        table = [row(201, start: 1), row(202, start: 2)]      // pid 201 is back with its old start time: it is read as new
        _ = set.grow(.tracking)
        #expect(reads[201] == 2, "a dropped record is read again when the identity returns: \(reads)")
    }

    @Test func ChatTermLoad_theStopsEnumerationsReadEveryEnvironmentFresh() throws {
        // Z is hidden with the same path at every growth; its environment carries the token only from the stop's first enumeration on, the
        // case no executable key can see.
        var carrying = false
        let table = [row(301, start: 1)]
        let set = ChatSweepSet(token: "t", pid: 1, identity: nil, table: { table }, environment: { _ in carrying ? .carrier : .hidden }, path: { _ in "/usr/bin/env" })
        _ = set.grow(.tracking); _ = set.grow(.tracking)
        carrying = true
        #expect(set.grow(.tracking).isEmpty, "the tracking growth trusts its record: same path, no new read")
        #expect(set.grow(.fresh).map(\.pid) == [301], "the stop's enumeration reads fresh and finds it")
        // The stop's own enumerations, the guard's stop and the start sweep ask for the fresh mode, never the tracking one.
        let scans: [(file: String, from: String?)] = [("Sources/ClawdCore/ChatTermChild.swift", "static func execute"), ("Sources/ClawdCore/TermGuard.swift", nil),
                                                      ("Sources/ClawdCore/TermStartSweep.swift", nil), ("Sources/ClawdCore/ChatSession.swift", "static func executeStop")]
        for scan in scans {
            var text = String(decoding: try ReadOnlyFile.data(repository.appendingPathComponent(scan.file).path), as: UTF8.self)
            if let from = scan.from, let range = text.range(of: from) { text = String(text[range.lowerBound...]) }
            #expect(text.contains(".grow(.fresh)") && !text.contains(".grow(.tracking)"), "\(scan.file) enumerates fresh")
        }
    }
}
