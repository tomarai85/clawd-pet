import Testing
import Foundation
import AppKit
import WebKit
@testable import ClawdCore
import ClawdDesktop

// Orca parity round D, sprint 6 (Q18): close keeps the conversation view without keeping WebKit (D2). The page reports where the reader is
// (`view`), Swift keeps the latest in memory across a close, and the next open's page is put back there after its first reset. The page is the
// real one, loaded off screen as in ChatWebPageTests; the controller rows use the real controller with a fake session.

/// A page that reports its view into `states` (with the time each arrived), and a helper to move its reader.
@MainActor
private final class ViewRig {
    let rig = WebPageRig()
    var states: [ChatViewState] = []
    var stamps: [Date] = []
    var view: WKWebView { rig.page.view! }

    func start(_ entries: [[String: Any]], arm: Bool = true) async throws {
        #expect(await rig.loadAndWaitReady())
        rig.page.onViewState = { [unowned self] state in states.append(state); stamps.append(Date()) }
        try await applyEntries(view, entries)
        _ = try await pageJS(view, "await new Promise(function (r) { setTimeout(r, 150); }); return 1;")
        if arm { _ = try await pageJS(view, "return window.ClawdChat.restoreView(null);") }
    }

    /// The reader scrolls so that the viewport's top is `points` below the top of entry `id` (the scroll event is awaited).
    func readerScroll(toEntry id: Int, plus points: Int) async throws {
        _ = try await pageJS(view, """
        const s = document.getElementById('scroller');
        const row = document.querySelector('[data-id="' + id + '"]');
        const target = row.getBoundingClientRect().top - s.getBoundingClientRect().top + s.scrollTop + points;
        if (Math.abs(s.scrollTop - target) > 0.5) {
          await new Promise(function (resolve) { s.addEventListener('scroll', function () { resolve(); }, {once: true}); s.scrollTop = target; });
        }
        return 1;
        """, ["id": id, "points": points])
    }

    /// Where entry `id`'s top is, relative to the viewport's top, and the scroller's numbers.
    func place(of id: Int) async throws -> [String: Any] {
        try await pageObject(view, """
        const s = document.getElementById('scroller');
        const row = document.querySelector('[data-id="' + id + '"]');
        return JSON.stringify({rel: row ? row.getBoundingClientRect().top - s.getBoundingClientRect().top : null, top: s.scrollTop,
                               max: s.scrollHeight - s.clientHeight});
        """, ["id": id])
    }

    func restore(_ state: ChatViewState?) async -> String? {
        var answer: String?? = nil
        rig.page.restoreView(state) { answer = .some($0) }
        _ = await webWait { answer != nil }
        return answer ?? nil
    }
}

private func viewMessage(_ json: String) -> Any { try! JSONSerialization.jsonObject(with: Data(json.utf8)) }

@Suite("Chat orca parity D, the view state", .serialized)
@MainActor
struct ChatOrcaParityDViewSuite {
    // MARK: the page reports and restores

    @Test func ChatOrcaView18_aDetachedReaderAtEntrySevenPlusFortyPointsComesBackWithEntrySevenFortyPointsAboveTheTop() async throws {
        let first = ViewRig()
        try await first.start(tallEntries(30))
        try await first.readerScroll(toEntry: 7, plus: 40)
        #expect(await webWait { first.states.last.map { $0.anchor == 7 && (39...41).contains($0.offset) && !$0.following } == true }, "\(first.states)")
        let saved = try #require(first.states.last)
        let second = ViewRig()
        try await second.start(tallEntries(30), arm: false)
        #expect(await second.restore(saved) == "found")
        let place = try await second.place(of: 7)
        let rel = try #require(place["rel"] as? Double)
        #expect(PagePixels.position(rel, is: -40), "entry 7's top is 40 pt above the viewport top: \(place)")
        // Detached: the page does not pull itself to the end when an entry arrives.
        try await appendEntries(second.view, tallEntries(1, from: 31))
        try await Task.sleep(nanoseconds: 250_000_000)
        let after = try await second.place(of: 7)
        #expect(PagePixels.position(after["rel"] as? Double, is: -40), "still where the reader left it: \(after)")
    }

    @Test func ChatOrcaView18_aFollowingReaderComesBackPinnedToTheEnd() async throws {
        let first = ViewRig()
        try await first.start(tallEntries(30))
        #expect(await webWait { first.states.last?.following == true }, "\(first.states)")
        let saved = try #require(first.states.last)
        let second = ViewRig()
        try await second.start(tallEntries(30), arm: false)
        _ = await second.restore(saved)
        let place = try await second.place(of: 7)
        #expect(PagePixels.atEnd(place) && (place["max"] as? Double ?? 0) > 100, "\(place)")
        // Following wins over the anchor: a state that follows and names an early entry still pins.
        let stale = try #require(ChatViewState(following: true, anchor: 3, offset: 0))
        let third = ViewRig()
        try await third.start(tallEntries(30), arm: false)
        #expect(await third.restore(stale) == "found")
        let pinned = try await third.place(of: 3)
        #expect(PagePixels.atEnd(pinned) && (pinned["max"] as? Double ?? 0) > 100, "\(pinned)")
    }

    @Test func ChatOrcaView18_aSelectionAcrossEntriesThreeAndFourComesBackWithTheSameText() async throws {
        let first = ViewRig()
        try await first.start(tallEntries(30))
        _ = try await pageJS(first.view, """
        const a = document.querySelector('[data-id="3"] p:nth-of-type(2)').firstChild, b = document.querySelector('[data-id="4"] p:nth-of-type(2)').firstChild;
        const range = document.createRange(); range.setStart(a, 5); range.setEnd(b, 20);
        const selection = window.getSelection(); selection.removeAllRanges(); selection.addRange(range);
        return 1;
        """)
        #expect(await webWait { first.states.last?.sel != nil }, "\(first.states)")
        let saved = try #require(first.states.last)
        #expect(saved.sel?.count == 4 && saved.sel?[0] == 3 && saved.sel?[2] == 4, "\(saved)")
        let text = try #require(try await pageJS(first.view, "return window.getSelection().toString();") as? String)
        #expect(text.count > 20)
        let second = ViewRig()
        try await second.start(tallEntries(30), arm: false)
        _ = await second.restore(saved)
        let restored = try await pageJS(second.view, "return window.getSelection().toString();") as? String
        #expect(restored == text, "the same text is selected: \(String(describing: restored)) vs \(text)")
    }

    @Test func ChatOrcaView18_anAnchorThatTheCapPrunedGivesTheNextEntryAndNoLaterEntryPins() async throws {
        let saved = try #require(ChatViewState(following: false, anchor: 7, offset: 40))
        let pruned = ViewRig()
        try await pruned.start(tallEntries(30, from: 8), arm: false)
        #expect(await pruned.restore(saved) == "next")
        let place = try await pruned.place(of: 8)
        #expect(PagePixels.position(place["rel"] as? Double, is: 0), "the next entry's top is at the viewport's top: \(place)")
        let none = ViewRig()
        let long = (1...6).map { index -> [String: Any] in
            ["id": index, "kind": "assistant", "text": "Message \(index)\n\n" + String(repeating: "A line of the reply that wraps around. ", count: 40)]
        }
        try await none.start(long, arm: false)
        #expect(await none.restore(saved) == "none")
        let end = try await none.place(of: 1)
        #expect(PagePixels.atEnd(end) && (end["max"] as? Double ?? 0) > 100, "no later entry: pinned to the end: \(end)")
    }

    @Test func ChatOrcaView18_theAnchorIsFoundByIdWhenTheTrimNoticeSitsFirstWithTheHighestIdOrASteerSitsLast() async throws {
        let trimmed: [[String: Any]] = [["id": 40, "kind": "notice", "text": "Earlier messages trimmed"]] + tallEntries(23, from: 8)
        let present = try #require(ChatViewState(following: false, anchor: 12, offset: 40))
        let first = ViewRig()
        try await first.start(trimmed, arm: false)
        #expect(await first.restore(present) == "found", "an anchor that is on the page is found, not the marker above it")
        let place = try await first.place(of: 12)
        #expect(PagePixels.position(place["rel"] as? Double, is: -40), "entry 12's top is 40 pt above the viewport top: \(place)")
        let pruned = try #require(ChatViewState(following: false, anchor: 7, offset: 40))
        let second = ViewRig()
        try await second.start(trimmed, arm: false)
        #expect(await second.restore(pruned) == "next")
        let next = try await second.place(of: 8)
        #expect(PagePixels.position(next["rel"] as? Double, is: 0), "the next entry by id (8), not the marker, is at the top: \(next)")
        let steer: [[String: Any]] = [18, 19, 21, 22, 20].flatMap { tallEntries(1, from: $0) }
        let third = ViewRig()
        try await third.start(steer, arm: false)
        let moved = try #require(ChatViewState(following: false, anchor: 20, offset: 0))
        #expect(await third.restore(moved) == "found", "a steer's user entry sits last with a lower id than the entries above it")
    }

    @Test func ChatOrcaView18_aFollowingPageSendsNoViewMessagesForItsOwnPinsWhileAReplyStreams() async throws {
        let r = ViewRig()
        try await r.start(tallEntries(30))
        #expect(await webWait { r.states.last?.following == true }, "\(r.states)")
        try await Task.sleep(nanoseconds: 500_000_000)
        let startCount = r.states.count
        for index in 31..<51 {
            try await appendEntries(r.view, tallEntries(1, from: index))
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        let end = try await r.place(of: 50)
        #expect(PagePixels.atEnd(end), "the page kept following: \(end)")
        #expect(r.states.count - startCount <= 1, "its own pins are not reported: \(Array(r.states.dropFirst(startCount)))")
        // A click on Jump to latest still reports.
        try await r.readerScroll(toEntry: 7, plus: 10)
        #expect(await webWait { r.states.last.map { !$0.following } == true }, "\(r.states)")
        _ = try await pageJS(r.view, "document.querySelector('.jump').click(); return 1;")
        _ = try await pageJS(r.view, "await new Promise(function (resolve) { setTimeout(resolve, 600); }); return 1;")
        #expect(await webWait { r.states.last?.following == true }, "the jump reports following again: \(r.states)")
    }

    @Test func ChatOrcaView18_aJumpToLatestClickBetweenTheRestoreAndFontsReadyIsNotUndone() async throws {
        let saved = try #require(ChatViewState(following: false, anchor: 7, offset: 40))
        let r = ViewRig()
        try await r.start(tallEntries(30), arm: false)
        _ = try await pageJS(r.view, "window.__resolveFonts = null; Object.defineProperty(document, 'fonts', {configurable: true, value: {ready: new Promise(function (resolve) { window.__resolveFonts = resolve; })}}); return 1;")
        #expect(await r.restore(saved) == "found")
        _ = try await pageJS(r.view, "document.querySelector('.jump').click(); await new Promise(function (resolve) { setTimeout(resolve, 100); }); return 1;")
        _ = try await pageJS(r.view, "window.__resolveFonts(); await new Promise(function (resolve) { setTimeout(resolve, 300); }); return 1;")
        let after = try await r.place(of: 7)
        #expect(PagePixels.atEnd(after) && (after["max"] as? Double ?? 0) > 100, "the reader's jump to the end stays: \(after)")
    }

    @Test func ChatOrcaView18_noSavedViewJustPinsAndLetsThePageStartReporting() async throws {
        let r = ViewRig()
        try await r.start(tallEntries(30), arm: false)
        try await r.readerScroll(toEntry: 7, plus: 10)
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(r.states.isEmpty, "nothing is reported before the page is armed: \(r.states)")
        #expect(await r.restore(nil) == "none")
        #expect(await webWait { !r.states.isEmpty }, "armed: the page reports where it is")
    }

    @Test func ChatOrcaView18_aReaderScrollBetweenTheFirstRestoreAndFontsReadyIsNotUndone() async throws {
        let saved = try #require(ChatViewState(following: false, anchor: 7, offset: 40))
        let r = ViewRig()
        try await r.start(tallEntries(30), arm: false)
        _ = try await pageJS(r.view, "window.__resolveFonts = null; Object.defineProperty(document, 'fonts', {configurable: true, value: {ready: new Promise(function (resolve) { window.__resolveFonts = resolve; })}}); return 1;")
        #expect(await r.restore(saved) == "found")
        try await r.readerScroll(toEntry: 7, plus: 300)
        let before = try await r.place(of: 7)
        _ = try await pageJS(r.view, "window.__resolveFonts(); await new Promise(function (resolve) { setTimeout(resolve, 300); }); return 1;")
        let after = try await r.place(of: 7)
        #expect(after["top"] as? Double == before["top"] as? Double, "the reader's scroll stays: \(before) -> \(after)")
    }

    @Test func ChatOrcaView18_theRestoreIsAppliedOnceMoreAtFontsReadyWhenNoReaderScrollCameAfterIt() async throws {
        let saved = try #require(ChatViewState(following: false, anchor: 7, offset: 40))
        let r = ViewRig()
        try await r.start(tallEntries(30), arm: false)
        _ = try await pageJS(r.view, "window.__resolveFonts = null; Object.defineProperty(document, 'fonts', {configurable: true, value: {ready: new Promise(function (resolve) { window.__resolveFonts = resolve; })}}); return 1;")
        #expect(await r.restore(saved) == "found")
        // A late font changes the lines above the anchor: everything moves 80 pt down.
        _ = try await pageJS(r.view, "document.querySelector('[data-id=\"1\"]').style.marginTop = '80px'; await new Promise(function (resolve) { setTimeout(resolve, 100); }); return 1;")
        let shifted = try await r.place(of: 7)
        #expect(PagePixels.position(shifted["rel"] as? Double, is: -40 + 80), "the shift is in place before fonts are ready: \(shifted)")
        _ = try await pageJS(r.view, "window.__resolveFonts(); await new Promise(function (resolve) { setTimeout(resolve, 300); }); return 1;")
        let again = try await r.place(of: 7)
        #expect(PagePixels.position(again["rel"] as? Double, is: -40), "restored once more: \(again)")
    }

    // MARK: what the page may send

    @Test func ChatOrcaView18_viewMessagesWithAWrongTypeRangeOrKeyAreIgnored() async throws {
        let r = WebPageRig()
        var seen: [ChatViewState] = []
        r.page.onViewState = { seen.append($0) }
        let good = [
            #"{"type":"view","following":false,"anchor":7,"offset":40}"#,
            #"{"type":"view","following":true,"anchor":0,"offset":10000000,"sel":[3,2,4,10]}"#,
        ]
        let bad = [
            #"{"type":"view","following":1,"anchor":7,"offset":40}"#,
            #"{"type":"view","following":false,"anchor":-1,"offset":40}"#,
            #"{"type":"view","following":false,"anchor":10000001,"offset":40}"#,
            #"{"type":"view","following":false,"anchor":7,"offset":"40"}"#,
            #"{"type":"view","following":false,"anchor":7,"offset":4.5}"#,
            #"{"type":"view","following":false,"anchor":true,"offset":40}"#,
            #"{"type":"view","following":false,"anchor":7,"offset":40,"extra":1}"#,
            #"{"type":"view","following":false,"anchor":7}"#,
            #"{"type":"view","following":false,"anchor":7,"offset":40,"sel":[3,2,4]}"#,
            #"{"type":"view","following":false,"anchor":7,"offset":40,"sel":[3,2,4,10,1]}"#,
            #"{"type":"view","following":false,"anchor":7,"offset":40,"sel":[3,-2,4,10]}"#,
            #"{"type":"view","following":false,"anchor":7,"offset":40,"sel":[3,2,4,"x"]}"#,
            #"{"type":"view","following":false,"anchor":7,"offset":40,"sel":"3,2,4,10"}"#,
            #"{"type":"view","following":false,"anchor":7,"offset":40,"sel":[3,2,4,10],"more":1}"#,
        ]
        for text in bad { r.page.received(viewMessage(text)) }
        #expect(seen.isEmpty, "\(seen)")
        for text in good { r.page.received(viewMessage(text)) }
        #expect(seen.count == 2 && seen[0].anchor == 7 && seen[1].sel == [3, 2, 4, 10] && seen[1].offset == 10_000_000, "\(seen)")
    }

    @Test func ChatOrcaView18_noMoreThanFourViewMessagesAreSentInASecondAndTheLastChangeIsReported() async throws {
        let r = ViewRig()
        try await r.start(tallEntries(30))
        let startCount = r.states.count
        // A reader dragging for 1.5 s: a scroll every 25 ms to a new place. Each step waits for its scroll event, so a loaded machine stretches
        // the drag (25 s seen at a load average of 43); the cap is 4 a second of the drag as it ran, plus the first and the one after the quiet.
        let dragStart = Date()
        _ = try await pageJS(r.view, """
        const s = document.getElementById('scroller');
        for (let i = 0; i < 60; i++) {
          await new Promise(function (resolve) { s.addEventListener('scroll', function () { resolve(); }, {once: true}); s.scrollTop = 40 + i * 37; });
          await new Promise(function (resolve) { setTimeout(resolve, 25); });
        }
        return 1;
        """)
        let drag = Date().timeIntervalSince(dragStart)
        try await Task.sleep(nanoseconds: 700_000_000)
        let moved = Array(r.states.dropFirst(startCount))
        let stamps = Array(r.stamps.dropFirst(startCount))
        let cap = max(12, Int((drag * 4).rounded(.up)) + 2)
        #expect(moved.count >= 3 && moved.count <= cap, "a throttled stream, not one per scroll: \(moved.count) in a \(drag) s drag (cap \(cap))")
        for index in 0..<max(0, stamps.count - 4) {
            #expect(stamps[index + 4].timeIntervalSince(stamps[index]) >= 0.85, "five messages inside \(stamps[index + 4].timeIntervalSince(stamps[index])) s")
        }
        let end = try await pageObject(r.view, """
        const s = document.getElementById('scroller'); const rows = Array.from(document.querySelectorAll('#column > .row[data-id]'));
        const viewTop = s.getBoundingClientRect().top; const row = rows.find(function (e) { return e.getBoundingClientRect().bottom > viewTop; });
        return JSON.stringify({anchor: Number(row.getAttribute('data-id')), offset: Math.max(0, Math.round(viewTop - row.getBoundingClientRect().top))});
        """)
        let last = try #require(r.states.last)
        #expect(last.anchor == end["anchor"] as? Int && last.offset == end["offset"] as? Int, "the last change is reported after the quiet: \(last) vs \(end)")
    }

    @Test func ChatOrcaView18_anUnchangedViewIsNotReportedAgain() async throws {
        let r = ViewRig()
        try await r.start(tallEntries(30))
        #expect(await webWait { !r.states.isEmpty })
        try await Task.sleep(nanoseconds: 400_000_000)
        let count = r.states.count
        for _ in 0..<4 {
            _ = try await pageJS(r.view, "document.getElementById('scroller').dispatchEvent(new Event('scroll')); return 1;")
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        #expect(r.states.count == count, "scroll events that moved nothing report nothing: \(r.states)")
    }

    // MARK: the bridge says when the page first shows the conversation

    @Test func ChatOrcaView18_theBridgeSaysSyncedAfterTheFirstResetOnlyAndAgainAfterANewReady() {
        let r = ChatWebBridgeRig()
        var synced = 0
        r.bridge.onSynced = { synced += 1 }
        r.bridge.update(entries: [ChatWebBridgeRig.entry(1, "a")], turn: .none)
        r.bridge.pageReady()
        #expect(synced == 0, "the reset is out and not answered")
        r.transport.answer(true)
        #expect(synced == 1)
        r.bridge.update(entries: [ChatWebBridgeRig.entry(1, "ab")], turn: .none)
        r.transport.answer(true)
        #expect(synced == 1, "an apply is not a first show")
        r.bridge.pageLost()
        r.bridge.pageReady()
        r.transport.answer(true)
        #expect(synced == 2, "a reloaded page is put back again")
    }

    @Test func ChatOrcaView18_aResetAfterAFailedApplyDoesNotPutTheViewBackAgain() {
        let r = ChatWebBridgeRig()
        var synced = 0
        r.bridge.onSynced = { synced += 1 }
        r.bridge.update(entries: [ChatWebBridgeRig.entry(1, "a")], turn: .none)
        r.bridge.pageReady()
        r.transport.answer(true)
        #expect(synced == 1)
        r.bridge.update(entries: [ChatWebBridgeRig.entry(1, "ab")], turn: .none)
        r.transport.answer(false)
        #expect(r.transport.calls.last?.kind == .reset)
        r.transport.answer(true)
        #expect(synced == 1, "the reader moved since the first restore: a repair reset must not pull the view back")
    }

    @Test func ChatOrcaView18_aFailedFirstResetSaysNothingAndAnEmptyFreshPageSaysItAtOnce() {
        let failing = ChatWebBridgeRig()
        var synced = 0
        failing.bridge.onSynced = { synced += 1 }
        failing.bridge.update(entries: [ChatWebBridgeRig.entry(1, "a")], turn: .none)
        failing.bridge.pageReady()
        failing.transport.answer(false)
        #expect(synced == 0, "the page does not show the conversation yet")
        failing.transport.answer(true)
        #expect(synced == 1, "the retried reset does")
        let empty = ChatWebBridgeRig()
        var emptySynced = 0
        empty.bridge.onSynced = { emptySynced += 1 }
        empty.bridge.pageReady()
        #expect(emptySynced == 1 && empty.transport.calls.isEmpty, "an empty page needs no reset and is already what it should be")
    }

    // MARK: the controller keeps the view across a close

    /// Opens the web chat over a transcript of `count` long user messages, waits for the first reset, and wraps the page's view callback.
    private func openWithTranscript(_ count: Int, record: @escaping (ChatViewState) -> Void) async throws -> WebKindRig {
        let r = WebKindRig()
        for index in 1...count {
            r.rig.session.transcript.appendUser("Message \(index)\n\n" + String(repeating: "A line of the message that wraps around. ", count: 12))
        }
        r.rig.open()
        let page = try #require(r.body?.page)
        #expect(await webWait { page.bridge.resets >= 1 })
        let controllerHook = page.onViewState
        page.onViewState = { state in record(state); controllerHook?(state) }
        _ = try await pageJS(page.view!, "await new Promise(function (r) { setTimeout(r, 200); }); return 1;")
        return r
    }

    private func placeOf(_ id: Int, in page: ChatWebPage) async throws -> [String: Any] {
        try await pageObject(page.view!, """
        const s = document.getElementById('scroller'); const row = document.querySelector('[data-id="' + id + '"]');
        return JSON.stringify({rel: row ? row.getBoundingClientRect().top - s.getBoundingClientRect().top : null, top: s.scrollTop, max: s.scrollHeight - s.clientHeight});
        """, ["id": id])
    }

    private func readerScroll(_ page: ChatWebPage, toEntry id: Int, plus points: Int) async throws {
        _ = try await pageJS(page.view!, """
        const s = document.getElementById('scroller'); const row = document.querySelector('[data-id="' + id + '"]');
        const target = row.getBoundingClientRect().top - s.getBoundingClientRect().top + s.scrollTop + points;
        await new Promise(function (resolve) { s.addEventListener('scroll', function () { resolve(); }, {once: true}); s.scrollTop = target; });
        return 1;
        """, ["id": id, "points": points])
    }

    @Test func ChatOrcaView18_closeAndReopenPutsTheViewBackAndLogsOnlyIdsAndCounts() async throws {
        var seen: [ChatViewState] = []
        let r = try await openWithTranscript(30) { seen.append($0) }
        let page = try #require(r.body?.page)
        let id = 12
        try await readerScroll(page, toEntry: id, plus: 40)
        #expect(await webWait { seen.last.map { $0.anchor == id && !$0.following } == true }, "\(seen)")
        r.controller.close(.button)
        #expect(r.rig.lines("CHAT view saved following=0 sel=0").count == 1, "\(r.rig.logs)")
        #expect(page.view == nil, "the page went at close (D2)")
        r.rig.open(at: 2)
        let reopened = try #require(r.body?.page)
        #expect(reopened !== page)
        #expect(await webWait { !r.rig.lines("CHAT view restored anchor=found following=0").isEmpty }, "\(r.rig.logs)")
        let place = try await placeOf(id, in: reopened)
        #expect(PagePixels.position(place["rel"] as? Double, is: -40), "\(place)")
        // One restore call per open: later changes to the conversation do not restore again.
        r.rig.session.transcript.appendUser("one more")
        r.rig.session.onChange?()
        try await Task.sleep(nanoseconds: 400_000_000)
        #expect(r.rig.lines("CHAT view restored").count == 1, "\(r.rig.logs)")
        #expect(r.rig.logs.filter { $0.hasPrefix("CHAT view") }.allSatisfy { !$0.contains("Message") }, "ids and counts only")
    }

    @Test func ChatOrcaView18_theRestoreLineSaysWhetherTheViewPinned() async throws {
        var seen: [ChatViewState] = []
        let r = try await openWithTranscript(30) { seen.append($0) }
        #expect(await webWait { seen.last?.following == true }, "\(seen)")
        r.controller.close(.button)
        r.rig.open(at: 2)
        #expect(await webWait { !r.rig.lines("CHAT view restored").isEmpty }, "\(r.rig.logs)")
        #expect(r.rig.lines("CHAT view restored anchor=found following=1").count == 1, "a pinned restore says so: \(r.rig.logs)")
    }

    @Test func ChatOrcaView18_aClearDropsTheStoredViewSoTheReopenPins() async throws {
        var seen: [ChatViewState] = []
        let r = try await openWithTranscript(30) { seen.append($0) }
        let page = try #require(r.body?.page)
        try await readerScroll(page, toEntry: 12, plus: 40)
        #expect(await webWait { seen.last.map { $0.anchor == 12 && !$0.following } == true }, "\(seen)")
        r.rig.session.onConversationCleared?()
        r.controller.close(.button)
        #expect(r.rig.lines("CHAT view saved").isEmpty, "the view of the old conversation is not kept: \(r.rig.logs)")
        r.rig.open(at: 2)
        let reopened = try #require(r.body?.page)
        #expect(await webWait { reopened.bridge.resets >= 1 })
        try await Task.sleep(nanoseconds: 500_000_000)
        #expect(r.rig.lines("CHAT view restored").isEmpty, "\(r.rig.logs)")
        let place = try await placeOf(12, in: reopened)
        #expect(PagePixels.atEnd(place) && (place["max"] as? Double ?? 0) > 100, "pinned to the end: \(place)")
    }
}
