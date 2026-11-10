import Testing
import Foundation
import ClawdCore

// Amendment "aqua-diag coalesce": an application-list record that changed nothing and repeats, byte for byte, the last application-list record
// written in full is counted, and the count is written as one `kvo-repeat` line just before the next line of any kind.

@Suite("Aqua diagnostics: repeated list records", .serialized)
struct AquaDiagCoalesce {
    private final class Clock { var t = Date(timeIntervalSince1970: 1_800_000_000) }
    private func makeDiag(cap: Int = AquaDiag.defaultCap, store existing: OwnState? = nil, clock existingClock: Clock? = nil) throws -> (AquaDiag, OwnState, Clock) {
        let store = try existing ?? artifactStore(), clock = existingClock ?? Clock()
        let diag = AquaDiag(store: store, until: Date(timeIntervalSince1970: 1_800_000_000).addingTimeInterval(AquaDiag.window), now: { clock.t },
                            capBytes: cap)
        return (diag, store, clock)
    }
    private func lines(_ store: OwnState) -> [String] {
        let text = String(decoding: (try? ReadOnlyFile.data(try store.url(AquaDiag.fileName).path)) ?? Data(), as: UTF8.self)
        return text.split(separator: "\n").map(String.init)
    }
    private func size(_ store: OwnState) throws -> Int { try ReadOnlyFile.data(try store.url(AquaDiag.fileName).path).count }
    private func sequence(_ lines: [String]) -> [Int] { lines.compactMap { Int($0.dropFirst().prefix { $0.isNumber }) } }
    /// The record kind of each line: the first word after the sequence number and the time.
    private func kinds(_ lines: [String]) -> [String] { lines.map { $0.split(separator: " ").dropFirst(2).first.map(String.init) ?? "" } }
    private let kvo = "trigger=kvo src=- live=500:1 exited=0 quiet=none controller_aqua=yes window=presented changed=no"
    private func other(_ name: String, _ kind: String = "launch") -> String {
        "trigger=\(kind) src=bundle=com.example.\(name) name=\(name) pid=9 payload=present live=500:1 exited=0 quiet=none controller_aqua=yes window=presented changed=no"
    }

    @Test func AquaDiag_repeatedUnchangedKvoTriggersAreCountedInOneLine() throws {
        let (diag, store, clock) = try makeDiag()
        for _ in 0..<50 { diag.append(kvo, repeatable: true, kvo: true); clock.t.addTimeInterval(10) }
        diag.append("trigger=terminate src=bundle=com.example.app name=App pid=9 payload=present live=500:1 exited=0 quiet=none controller_aqua=yes window=presented changed=no")
        let all = lines(store)
        #expect(kinds(all) == ["trigger=kvo", "kvo-repeat", "trigger=terminate"], "\(all)")
        try #require(all.count == 3, "the lines above are indexed below")
        #expect(sequence(all) == [1, 2, 3])
        #expect(all[0].hasSuffix(kvo))
        #expect(all[1].contains(" kvo-repeat count=49 first=2027-01-15T08:00:10.000Z last=2027-01-15T08:08:10.000Z"), "\(all[1])")
        #expect(all[2].contains("2027-01-15T08:08:20.000Z"), "the next record keeps its own time: \(all[2])")
    }

    @Test func AquaDiag_aKvoWithADifferentStateOrAChangeIsWrittenInFull() throws {
        let (diag, store, clock) = try makeDiag()
        diag.append(kvo, repeatable: true, kvo: true); clock.t.addTimeInterval(1)
        diag.append(kvo, repeatable: true, kvo: true); clock.t.addTimeInterval(1)
        // Aqua exits: the exit record, then the reconcile that saw it (changed, so not repeatable), then list changes in the new state.
        diag.append("trigger=exit src=pid=500 gen=1 stale=no live=none exited=1 quiet=aqua-not-running controller_aqua=yes window=none changed=yes")
        let changed = "trigger=kvo src=- live=none exited=1 quiet=aqua-not-running controller_aqua=yes window=none changed=yes"
        diag.append(changed, repeatable: false, kvo: true); clock.t.addTimeInterval(1)
        let after = "trigger=kvo src=- live=none exited=1 quiet=aqua-not-running controller_aqua=yes window=none changed=no"
        diag.append(after, repeatable: true, kvo: true); clock.t.addTimeInterval(1)
        diag.append(after, repeatable: true, kvo: true); clock.t.addTimeInterval(1)
        diag.append(after, repeatable: true, kvo: true)
        diag.append("observers workspace=installed kvo=installed logwatch=armed kqueue=ok")
        let all = lines(store)
        #expect(kinds(all) == ["trigger=kvo", "kvo-repeat", "trigger=exit", "trigger=kvo", "trigger=kvo", "kvo-repeat", "observers"], "\(all)")
        try #require(all.count == 7, "the lines above are indexed below")
        #expect(all[2].contains("08:00:02.000Z"), "the exit keeps its own time")
        #expect(all[3].hasSuffix(changed) && all[3].contains("08:00:02.000Z"), "the changed record is written at its own time")
        #expect(all[4].hasSuffix(after) && all[4].contains("08:00:03.000Z"), "the first record of the new state is written in full at its own time")
        #expect(all[1].contains("count=1 ") && all[5].contains("count=2 "))
        #expect(sequence(all) == Array(1...7))
    }

    @Test func AquaDiag_aNotificationBetweenRepeatsKeepsTheOrderAndTheRunGoesOn() throws {
        let (diag, store, clock) = try makeDiag()
        diag.append(kvo, repeatable: true, kvo: true)
        for _ in 0..<3 { clock.t.addTimeInterval(10); diag.append(kvo, repeatable: true, kvo: true) }
        clock.t.addTimeInterval(5); diag.append(other("quitter", "terminate"))
        for _ in 0..<4 { clock.t.addTimeInterval(10); diag.append(kvo, repeatable: true, kvo: true) }
        clock.t.addTimeInterval(5); diag.append(other("launch-me"))
        let all = lines(store)
        #expect(kinds(all) == ["trigger=kvo", "kvo-repeat", "trigger=terminate", "kvo-repeat", "trigger=launch"], "no full kvo line after a notification: \(all)")
        try #require(all.count == 5, "the lines above are indexed below")
        #expect(all[1].contains("count=3 first=2027-01-15T08:00:10.000Z last=2027-01-15T08:00:30.000Z"), "\(all[1])")
        #expect(all[3].contains("count=4 first=2027-01-15T08:00:45.000Z last=2027-01-15T08:01:15.000Z"), "\(all[3])")
    }

    /// The installed file measured 131,275 bytes at 19:00 on 2026-10-22, with one unchanged list change about every 10 s and 7 other
    /// triggers in 2.6 h (one every 22 min). A week of that, started from that size, stays under half of the cap.
    @Test func AquaDiag_aWeekAtTheMeasuredRateFromTheInstalledSizeStaysUnderHalfTheCap() throws {
        let store = try artifactStore()
        var seed = ""
        for n in 1...800 { seed += "#\(n) 2026-10-22T21:24:03.331Z \(kvo) pad=\(String(repeating: "x", count: 30))\n" }
        while seed.utf8.count < 131_275 { seed += "x" }
        seed = String(seed.prefix(131_274)) + "\n"
        try store.append(seed, to: AquaDiag.fileName)
        #expect(try size(store) == 131_275)
        let (diag, _, clock) = try makeDiag(store: store)
        // The whole window (it closes at exactly 7 days: a record at that instant is not written), leaving its last 10 s for one more trigger
        // that writes the last count. The agent itself writes nothing at the close, so a count still pending then is never written.
        let end = clock.t.addingTimeInterval(AquaDiag.window - 10)
        var nextOther = clock.t.addingTimeInterval(22 * 60), n = 0
        while clock.t < end {
            if clock.t >= nextOther { diag.append(other("app\(n)")); n += 1; nextOther = clock.t.addingTimeInterval(22 * 60) }
            diag.append(kvo, repeatable: true, kvo: true)
            clock.t.addTimeInterval(10)
        }
        diag.append(other("last"))          // writes the last pending count
        let tail = Array(lines(store).suffix(2))
        #expect(kinds(tail) == ["kvo-repeat", "trigger=launch"] && tail.last?.contains("name=last ") == true, "the last count, then the last record: \(tail)")
        let final = try size(store)
        #expect(final < AquaDiag.defaultCap / 2, "\(final) bytes after a week")
        #expect(!lines(store).contains { $0.contains(" CAP ") })
        #expect(n > 400, "the other triggers ran: \(n)")
    }

    /// Aqua quits while list changes repeat: the count before the exit, the exit, the count after it (the same list record as before, so it is
    /// counted, not written), and Aqua's terminate notification, in that order.
    @Test func AquaDiag_anAquaQuitBetweenRepeatsKeepsItsOrder() throws {
        let (diag, store, clock) = try makeDiag()
        diag.append(kvo, repeatable: true, kvo: true)
        for _ in 0..<2 { clock.t.addTimeInterval(10); diag.append(kvo, repeatable: true, kvo: true) }
        clock.t.addTimeInterval(1)
        diag.append("trigger=exit src=pid=500 gen=1 stale=no live=500:1 exited=0 quiet=none controller_aqua=yes window=presented changed=no")
        for _ in 0..<3 { clock.t.addTimeInterval(1); diag.append(kvo, repeatable: true, kvo: true) }
        clock.t.addTimeInterval(1)
        diag.append("trigger=terminate src=bundle=com.electron.aqua-voice name=Aqua_Voice pid=500 payload=present live=500:1 exited=0 quiet=none controller_aqua=yes window=presented changed=no")
        let all = lines(store)
        #expect(kinds(all) == ["trigger=kvo", "kvo-repeat", "trigger=exit", "kvo-repeat", "trigger=terminate"], "\(all)")
        try #require(all.count == 5, "the lines above are indexed below")
        #expect(all[1].contains("count=2 ") && all[3].contains("count=3 "))
        #expect(all[2].contains("08:00:21.000Z") && all[4].contains("08:00:25.000Z"), "the exit and the notification keep their own times: \(all)")
        #expect(all[3].contains("first=2027-01-15T08:00:22.000Z last=2027-01-15T08:00:24.000Z"), "\(all[3])")
    }

    /// The other side of the cap: the repeat line fits, the record after it does not and is replaced by the cap line; a restart stays stopped.
    @Test func AquaDiag_aRecordAfterTheRepeatLineCanBeTheOneTheCapReplaces() throws {
        // 600 bytes: the kvo line (124), one launch line (177) and the repeat line (108) fit (409 + 160 kept for the cap line = 569); the exit
        // record after them does not.
        let (diag, store, clock) = try makeDiag(cap: 600)
        diag.append(kvo, repeatable: true, kvo: true)
        diag.append(other("a"))
        for _ in 0..<5 { clock.t.addTimeInterval(1); diag.append(kvo, repeatable: true, kvo: true) }
        diag.append("trigger=exit src=pid=500 gen=1 stale=no live=500:1 exited=0 quiet=none controller_aqua=yes window=presented changed=no")
        let capped = lines(store)
        #expect(kinds(capped) == ["trigger=kvo", "trigger=launch", "kvo-repeat", "CAP"], "\(capped)")
        #expect(try size(store) <= 600)
        let (restarted, _, _) = try makeDiag(cap: 600, store: store, clock: clock)
        restarted.append("observers workspace=installed kvo=installed logwatch=armed kqueue=ok")
        #expect(lines(store) == capped, "a restart after the cap writes nothing")
    }

    @Test func AquaDiag_theRepeatCountRespectsTheCap() throws {
        // 520 bytes: the kvo line (124) and one launch line (177) fit; the repeat line before the next launch would leave no room for the cap line.
        let (diag, store, clock) = try makeDiag(cap: 520)
        diag.append(kvo, repeatable: true, kvo: true)
        diag.append(other("a"))
        #expect(lines(store).count == 2)
        for _ in 0..<5 { clock.t.addTimeInterval(1); diag.append(kvo, repeatable: true, kvo: true) }
        diag.append(other("c"))
        let capped = lines(store)
        #expect(capped.last?.contains(" CAP ") == true, "the repeat line that no longer fits is replaced by the cap line: \(capped)")
        #expect(!capped.contains { $0.contains("name=c ") }, "and the body after it is not written")
        #expect(kinds(capped) == ["trigger=kvo", "trigger=launch", "CAP"], "\(capped)")
        #expect(try size(store) <= 520)
        diag.append(kvo, repeatable: true, kvo: true); diag.append(other("d"))
        #expect(lines(store) == capped, "nothing after the cap")
        let (restarted, _, _) = try makeDiag(cap: 520, store: store, clock: clock)
        restarted.append("observers workspace=installed kvo=installed logwatch=armed kqueue=ok"); restarted.append(kvo, repeatable: true, kvo: true)
        #expect(lines(store) == capped, "a restart after the cap writes nothing")
    }

    @Test func AquaDiag_aRestartWithACountPendingStartsAFreshRun() throws {
        let (first, store, clock) = try makeDiag()
        first.append(kvo, repeatable: true, kvo: true)
        for _ in 0..<3 { clock.t.addTimeInterval(10); first.append(kvo, repeatable: true, kvo: true) }
        // The agent ends here: the count of 3 is lost (it counted lines identical to one already written).
        let (second, _, _) = try makeDiag(store: store, clock: clock)
        clock.t.addTimeInterval(10)
        second.append("observers workspace=installed kvo=installed logwatch=armed kqueue=ok")
        second.append(kvo, repeatable: true, kvo: true)
        let all = lines(store)
        #expect(kinds(all) == ["trigger=kvo", "observers", "trigger=kvo"], "\(all)")
        try #require(all.count == 3, "the lines above are indexed below")
        #expect(sequence(all) == [1, 2, 3], "the sequence continues across the restart")
    }

    @Test func AquaDiag_equalStringsWithDifferentBytesAreNotMerged() throws {
        let (diag, store, _) = try makeDiag()
        let precomposed = "trigger=kvo src=- live=500:1 exited=0 quiet=caf\u{00E9} controller_aqua=yes window=presented changed=no"
        let combining = "trigger=kvo src=- live=500:1 exited=0 quiet=cafe\u{0301} controller_aqua=yes window=presented changed=no"
        #expect(precomposed == combining, "Swift's String == treats them as equal")
        diag.append(precomposed, repeatable: true, kvo: true)
        diag.append(combining, repeatable: true, kvo: true)
        #expect(kinds(lines(store)) == ["trigger=kvo", "trigger=kvo"], "different bytes, so both are written")
    }
}
