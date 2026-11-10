import Testing
import Foundation
import AppKit
import WebKit
@testable import ClawdCore
import ClawdDesktop

// Orca parity round D, sprint 1: the transcript page (Q1 copy code, Q2 scroll to top, Q3 timestamps, Q4 following and the jump button, Q5 the link
// popover). The page is the real one, loaded off screen as in ChatWebPageTests.

/// The probe results of a page row: a JSON object read back from a constant function body.
@MainActor
func pageObject(_ view: WKWebView, _ body: String, _ arguments: [String: Any] = [:]) async throws -> [String: Any] {
    let report = try #require(try await pageJS(view, body, arguments) as? String)
    return try #require(try JSONSerialization.jsonObject(with: Data(report.utf8)) as? [String: Any])
}

@MainActor
func applyEntries(_ view: WKWebView, _ entries: [[String: Any]], turn: String = "none") async throws {
    _ = try await pageJS(view, "return window.ClawdChat.apply({order: ids, upserts: entries, turn: turn});",
                         ["ids": entries.map { $0["id"] as! Int }, "entries": entries, "turn": turn])
}

/// Adds entries after the ones the page shows (the order is the page's own, then the new ids).
@MainActor
func appendEntries(_ view: WKWebView, _ entries: [[String: Any]]) async throws {
    _ = try await pageJS(view, """
    const ids = Array.from(document.querySelectorAll('#column > .row[data-id]')).map(function (e) { return Number(e.getAttribute('data-id')); });
    return window.ClawdChat.apply({order: ids.concat(entries.map(function (e) { return e.id; })), upserts: entries});
    """, ["entries": entries])
}

/// Entries tall enough that the transcript scrolls in a 700 pt window.
func tallEntries(_ count: Int, from first: Int = 1) -> [[String: Any]] {
    (first..<(first + count)).map { index in
        ["id": index, "kind": "assistant", "text": "Message \(index)\n\n" + String(repeating: "A line of the reply that wraps around. ", count: 12)]
    }
}

@Suite("Chat orca parity D, the transcript page", .serialized)
@MainActor
struct ChatOrcaParityDPageSuite {
    // MARK: Q1 copy code

    private static let fences = "```swift\nlet a = 1\n```\n\n```\nplain two\n```\n\n```\n```\n\n```js\n```"

    @Test func ChatOrcaD1_aFenceWithALanguageHasAHeaderAndOneCopyButtonAPlainFenceHasNoHeaderAndAnEmptyFenceHasNoButton() async throws {
        let r = WebPageRig()
        #expect(await r.loadAndWaitReady())
        try await applyEntries(r.page.view!, [["id": 1, "kind": "assistant", "text": Self.fences]])
        let parsed = try await pageObject(r.page.view!, """
        return JSON.stringify(Array.from(document.querySelectorAll('.code-block')).map(function (block) {
          const head = block.querySelector('.code-head');
          const buttons = Array.from(block.querySelectorAll('button'));
          return {head: head !== null, headHeight: head ? head.offsetHeight : 0, label: head ? head.querySelector('.code-lang').textContent : '',
                  buttons: buttons.length, buttonLabel: buttons.length ? buttons[0].getAttribute('aria-label') : '',
                  inHead: buttons.length > 0 && head !== null && head.contains(buttons[0]), floating: buttons.length > 0 && buttons[0].classList.contains('code-float'),
                  buttonSize: buttons.length ? buttons[0].offsetWidth : 0};
        }).reduce(function (all, one, index) { all['b' + index] = one; return all; }, {}));
        """)
        let swift = try #require(parsed["b0"] as? [String: Any]), plain = try #require(parsed["b1"] as? [String: Any])
        let empty = try #require(parsed["b2"] as? [String: Any]), emptyJS = try #require(parsed["b3"] as? [String: Any])
        #expect(swift["head"] as? Bool == true && PagePixels.length((swift["headHeight"] as? Int).map(Double.init), is: 30) && swift["label"] as? String == "Swift", "\(swift)")
        #expect(swift["buttons"] as? Int == 1 && swift["buttonLabel"] as? String == "Copy code" && swift["inHead"] as? Bool == true && swift["buttonSize"] as? Int == 24, "\(swift)")
        #expect(plain["head"] as? Bool == false, "a fence without a language has no header: \(plain)")
        #expect(plain["buttons"] as? Int == 1 && plain["buttonLabel"] as? String == "Copy code" && plain["floating"] as? Bool == true, "\(plain)")
        #expect(empty["head"] as? Bool == false && empty["buttons"] as? Int == 0, "an empty fence has no button: \(empty)")
        #expect(emptyJS["head"] as? Bool == true && emptyJS["buttons"] as? Int == 0, "an empty fence with a language has its header and no button: \(emptyJS)")
    }

    @Test func ChatOrcaD1_clickingTheSecondFenceOfAnEntryPostsItsOrdinalAndSwiftPullsExactlyThatFencesText() async throws {
        let r = WebPageRig()
        #expect(await r.loadAndWaitReady())
        var requests: [[Int]] = []
        r.page.onCopyCodeRequest = { requests.append([$0, $1]) }
        try await applyEntries(r.page.view!, [["id": 3, "kind": "assistant", "text": "x"], ["id": 7, "kind": "assistant", "text": Self.fences]])
        _ = try await pageJS(r.page.view!, "document.querySelectorAll('[data-id=\"7\"] .code-block')[1].querySelector('button').click(); return 1;")
        #expect(await webWait { requests.count == 1 })
        #expect(requests == [[7, 1]], "\(requests)")
        var pulled: String??
        r.page.codeText(id: 7, index: 1) { pulled = .some($0) }
        #expect(await webWait { pulled != nil })
        #expect(pulled == .some("plain two\n"), "\(String(describing: pulled))")
        var first: String??
        r.page.codeText(id: 7, index: 0) { first = .some($0) }
        #expect(await webWait { first != nil })
        #expect(first == .some("let a = 1\n"), "Orca's code text ends in a newline")
        for (id, index) in [(7, 2), (7, 9), (99, 0), (3, 0)] {
            var none: String??
            r.page.codeText(id: id, index: index) { none = .some($0) }
            #expect(await webWait { none != nil })
            #expect(none == .some(nil), "no fence \(id)/\(index) (an empty fence has no text to copy)")
        }
    }

    @Test func ChatOrcaD1_theCopiedLabelLastsFifteenHundredMillisecondsAndThenReverts() async throws {
        let r = WebPageRig()
        #expect(await r.loadAndWaitReady())
        try await applyEntries(r.page.view!, [["id": 7, "kind": "assistant", "text": Self.fences]])
        let parsed = try await pageObject(r.page.view!, """
        const button = document.querySelectorAll('[data-id="7"] .code-block')[0].querySelector('button');
        const delays = []; const real = window.setTimeout; let callback = null;
        window.setTimeout = function (f, d) { delays.push(d); callback = f; return 1; };
        window.ClawdChat.codeCopied(7, 0);
        window.setTimeout = real;
        const during = {label: button.getAttribute('aria-label'), copied: button.classList.contains('copied')};
        callback();
        return JSON.stringify({delays: delays, during: during, after: {label: button.getAttribute('aria-label'), copied: button.classList.contains('copied')}});
        """)
        #expect(parsed["delays"] as? [Int] == [1500], "\(parsed)")
        #expect((parsed["during"] as? [String: Any])?["label"] as? String == "Copied" && (parsed["during"] as? [String: Any])?["copied"] as? Bool == true, "\(parsed)")
        #expect((parsed["after"] as? [String: Any])?["label"] as? String == "Copy code" && (parsed["after"] as? [String: Any])?["copied"] as? Bool == false, "\(parsed)")
    }

    // MARK: Q2 scroll this message to top

    @Test func ChatOrcaD2_theAssistantControlsAreCopyThenScrollToTopThenTheTimeAndAnEmptyMessageHasNone() async throws {
        let r = WebPageRig()
        #expect(await r.loadAndWaitReady())
        try await applyEntries(r.page.view!, [["id": 1, "kind": "assistant", "text": "hello", "time": 1_700_000_000_000.0], ["id": 2, "kind": "assistant", "text": ""]])
        let parsed = try await pageObject(r.page.view!, """
        const rows = document.querySelectorAll('.assistant-row');
        const kids = function (row) { return Array.from(row.querySelector('.agent-controls').children).map(function (c) { return c.localName + ':' + (c.getAttribute('aria-label') || '').slice(0, 30); }); };
        return JSON.stringify({first: kids(rows[0]), emptyHidden: rows[1].querySelector('.agent-controls').hidden, firstHidden: rows[0].querySelector('.agent-controls').hidden,
                               title: rows[0].querySelectorAll('button')[1].title});
        """)
        let first = try #require(parsed["first"] as? [String])
        #expect(first.count == 3 && first[0] == "button:Copy message" && first[1] == "button:Scroll this message to top" && first[2].hasPrefix("time:"), "\(first)")
        #expect(parsed["title"] as? String == "Scroll this message to top")
        #expect(parsed["emptyHidden"] as? Bool == true && parsed["firstHidden"] as? Bool == false, "\(parsed)")
    }

    /// Waits until the transcript's scroll offset has stopped moving (a smooth scroll has landed).
    private func settled(_ view: WKWebView) async throws -> Double {
        var last = -1.0, still = 0
        for _ in 0..<150 {
            let top = try #require(try await pageJS(view, "return document.getElementById('scroller').scrollTop;") as? Double)
            if top == last { still += 1 } else { still = 0; last = top }
            if still >= 6 { return top }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        return last
    }

    @Test func ChatOrcaD2_aClickOnAnEarlyRowStopsFollowingAtOnceAndTheNextEntryDoesNotPullTheViewToTheEnd() async throws {
        let r = WebPageRig()
        #expect(await r.loadAndWaitReady())
        try await applyEntries(r.page.view!, tallEntries(30))
        _ = try await settled(r.page.view!)
        // One script task: the click, then a new entry. Following is state the click changes at once, before any scroll event arrives.
        let parsed = try await pageObject(r.page.view!, """
        const scroller = document.getElementById('scroller');
        const before = scroller.scrollTop;
        document.querySelectorAll('.assistant-row')[3].querySelector('button[aria-label="Scroll this message to top"]').click();
        window.ClawdChat.apply({upserts: [{id: 99, kind: 'assistant', text: 'A new entry. ' + 'More words. '.repeat(200)}], order: Array.from(document.querySelectorAll('[data-id]')).map(function (e) { return Number(e.getAttribute('data-id')); }).concat([99])});
        return JSON.stringify({before: before, after: scroller.scrollTop, max: scroller.scrollHeight - scroller.clientHeight});
        """)
        #expect(parsed["after"] as? Double == parsed["before"] as? Double, "the click stopped following: a new entry is not pinned: \(parsed)")
        #expect((parsed["max"] as? Double ?? 0) > (parsed["before"] as? Double ?? 0), "the new entry made the range longer: \(parsed)")
    }

    @Test func ChatOrcaD2_aClickOnAnEarlyRowAlignsItToTheTopAndTheJumpButtonShows() async throws {
        let r = WebPageRig()
        #expect(await r.loadAndWaitReady())
        try await applyEntries(r.page.view!, tallEntries(30))
        _ = try await settled(r.page.view!)
        let expected = try #require(try await pageJS(r.page.view!, """
        const scroller = document.getElementById('scroller');
        const row = document.querySelectorAll('.assistant-row')[3];
        const top = row.getBoundingClientRect().top - scroller.getBoundingClientRect().top + scroller.scrollTop;
        row.querySelector('button[aria-label="Scroll this message to top"]').click();
        return Math.max(0, Math.min(top, scroller.scrollHeight - scroller.clientHeight));
        """) as? Double)
        let landed = try await settled(r.page.view!)
        #expect(PagePixels.position(landed, is: expected), "the row's top meets the viewport's top: \(landed) vs \(expected)")
        let jump = try await pageObject(r.page.view!, "const j = document.querySelector('.jump'); return JSON.stringify({shown: j !== null && !j.hidden});")
        #expect(jump["shown"] as? Bool == true, "more than 48 px lies below: \(jump)")
    }

    // MARK: Q3 timestamps

    @Test func ChatOrcaD3_aTimeShowsHoursAndMinutesWithAFullLabelAndAnInvalidTimeShowsNothing() async throws {
        let r = WebPageRig()
        #expect(await r.loadAndWaitReady())
        // A fixed zone and locale: the page builds its formatters on the first message that has a time.
        _ = try await pageJS(r.page.view!, """
        const Original = Intl.DateTimeFormat;
        Intl.DateTimeFormat = function (locale, options) { return new Original('en-US', Object.assign({timeZone: 'UTC'}, options)); };
        return 1;
        """)
        try await applyEntries(r.page.view!, [
            ["id": 1, "kind": "user", "text": "hi", "time": 1_700_000_000_000.0],
            ["id": 2, "kind": "assistant", "text": "yo", "time": 1_700_003_600_000.0],
            ["id": 3, "kind": "assistant", "text": "bad", "time": 1e20],
            ["id": 4, "kind": "assistant", "text": "none"],
            ["id": 5, "kind": "assistant", "text": "str", "time": "noon"],
        ])
        let parsed = try await pageObject(r.page.view!, """
        const times = Array.from(document.querySelectorAll('time')).map(function (t) {
          return {id: t.closest('[data-id]').getAttribute('data-id'), text: t.textContent.replace(/\\s/g, ' '), label: t.getAttribute('aria-label'), datetime: t.getAttribute('datetime')};
        });
        return JSON.stringify({times: times});
        """)
        let times = try #require(parsed["times"] as? [[String: Any]])
        #expect(times.count == 2, "a time only for ids 1 and 2: \(times)")
        #expect(times.first?["id"] as? String == "1" && times.first?["text"] as? String == "10:13 PM" && times.first?["datetime"] as? String == "2023-11-14T22:13:20.000Z", "\(times)")
        #expect((times.first?["label"] as? String)?.contains("Tuesday, November 14, 2023") == true, "\(times)")
        #expect(times.last?["id"] as? String == "2" && times.last?["text"] as? String == "11:13 PM", "\(times)")
    }

    @Test func ChatOrcaD3_aTimeInTheBridgePayloadReachesThePage() async throws {
        let r = WebPageRig()
        #expect(await r.loadAndWaitReady())
        let view = try #require(r.page.view)
        // Through the real bridge and the real payload: a transcript entry with a time and one with "sending".
        r.page.bridge.update(entries: [ChatEntry(id: 1, kind: .user, text: "hi", time: 1_700_000_000_000, sending: true),
                                       ChatEntry(id: 2, kind: .assistant, text: "yo", time: 1_700_000_060_000)], turn: .none)
        for _ in 0..<100 {
            let count = try await pageJS(view, "return document.querySelectorAll('[data-id]').length;") as? Int
            if count == 2 { break }
            try await Task.sleep(nanoseconds: 50_000_000)
        }
        let parsed = try await pageObject(view, """
        return JSON.stringify({sending: document.querySelectorAll('.sending-label').length, times: document.querySelectorAll('time').length,
                               assistantTime: document.querySelector('[data-id="2"] time') !== null});
        """)
        #expect(parsed["sending"] as? Int == 1 && parsed["times"] as? Int == 1 && parsed["assistantTime"] as? Bool == true, "\(parsed)")
    }

    @Test func ChatOrcaD3_aSendingUserMessageShowsSendingInTheTimesPlaceAndTheTimeReturnsWhenItClears() async throws {
        let r = WebPageRig()
        #expect(await r.loadAndWaitReady())
        try await applyEntries(r.page.view!, [["id": 1, "kind": "user", "text": "hi", "time": 1_700_000_000_000.0, "sending": true]])
        let probe = """
        const meta = document.querySelector('.user-meta');
        const copy = meta.querySelector('.copy-btn');
        return JSON.stringify({sending: meta.classList.contains('sending'), label: (meta.querySelector('.sending-label') || {}).textContent || '', times: meta.querySelectorAll('time').length,
                               labelOpacity: getComputedStyle(meta.querySelector('.sending-label') || meta).opacity, metaOpacity: getComputedStyle(meta).opacity, copyOpacity: getComputedStyle(copy).opacity, height: meta.offsetHeight});
        """
        let sending = try await pageObject(r.page.view!, probe)
        #expect(sending["sending"] as? Bool == true && sending["label"] as? String == "Sending…" && sending["times"] as? Int == 0, "\(sending)")
        #expect(sending["labelOpacity"] as? String == "1" && sending["metaOpacity"] as? String == "1" && sending["copyOpacity"] as? String == "0" && sending["height"] as? Int == 24, "Sending… is visible without hover and the copy button is not: \(sending)")
        try await applyEntries(r.page.view!, [["id": 1, "kind": "user", "text": "hi", "time": 1_700_000_000_000.0]])
        let cleared = try await pageObject(r.page.view!, probe)
        #expect(cleared["sending"] as? Bool == false && cleared["label"] as? String == "" && cleared["times"] as? Int == 1 && cleared["height"] as? Int == 24, "\(cleared)")
    }

    @Test func ChatOrcaD13_aSendInDoubtShowsNotConfirmedInTheTimesPlaceAndTheTimeReturnsWhenAReplayNamesIt() async throws {
        let r = WebPageRig()
        #expect(await r.loadAndWaitReady())
        try await applyEntries(r.page.view!, [["id": 1, "kind": "user", "text": "hi", "time": 1_700_000_000_000.0, "unconfirmed": true]])
        let probe = """
        const meta = document.querySelector('.user-meta');
        const copy = meta.querySelector('.copy-btn');
        return JSON.stringify({sending: meta.classList.contains('sending'), label: (meta.querySelector('.sending-label') || {}).textContent || '', times: meta.querySelectorAll('time').length,
                               labelOpacity: getComputedStyle(meta.querySelector('.sending-label') || meta).opacity, copyOpacity: getComputedStyle(copy).opacity});
        """
        let doubt = try await pageObject(r.page.view!, probe)
        #expect(doubt["label"] as? String == "Not confirmed" && doubt["times"] as? Int == 0 && doubt["labelOpacity"] as? String == "1", "\(doubt)")
        try await applyEntries(r.page.view!, [["id": 1, "kind": "user", "text": "hi", "time": 1_700_000_000_000.0]])
        let confirmed = try await pageObject(r.page.view!, probe)
        #expect(confirmed["label"] as? String == "" && confirmed["times"] as? Int == 1 && confirmed["sending"] as? Bool == false, "\(confirmed)")
    }

    // MARK: Q4 following and the jump button

    private func scrollerState(_ view: WKWebView) async throws -> [String: Any] {
        try await pageObject(view, """
        const s = document.getElementById('scroller'); const j = document.querySelector('.jump');
        return JSON.stringify({top: s.scrollTop, max: s.scrollHeight - s.clientHeight, jump: j !== null && !j.hidden});
        """)
    }

    /// Moves the scroller as a reader would and returns once the page has handled the scroll event (under load the event can be late).
    private func readerScroll(_ view: WKWebView, fromEnd distance: Int) async throws {
        _ = try await pageJS(view, """
        const s = document.getElementById('scroller');
        const target = s.scrollHeight - s.clientHeight - distance;
        if (s.scrollTop !== target) {
          await new Promise(function (resolve) { s.addEventListener('scroll', function () { resolve(); }, {once: true}); s.scrollTop = target; });
        }
        await new Promise(function (resolve) { setTimeout(resolve, 60); });
        return 1;
        """, ["distance": distance])
    }

    @Test func ChatOrcaD4_aReaderScrollOfTenPxDetachesAndOneBackToThreePxReattaches() async throws {
        let r = WebPageRig()
        #expect(await r.loadAndWaitReady())
        let view = try #require(r.page.view)
        try await applyEntries(view, tallEntries(30))
        _ = try await settled(view)
        try await readerScroll(view, fromEnd: 10)
        let detached = try await scrollerState(view)
        let top = try #require(detached["top"] as? Double)
        try await appendEntries(view, tallEntries(1, from: 31))
        // The jump state is recomputed by the column's ResizeObserver, which a loaded machine can hold past a fixed 250 ms (seen at a load
        // average of 43): wait up to 5 s for the button, so the view's top is read after the observer ran, not before.
        _ = try await pageJS(view, "for (let i = 0; i < 250; i++) { const j = document.querySelector('.jump'); if (j !== null && !j.hidden) break; await new Promise(function (r) { setTimeout(r, 20); }); } return 1;")
        let grown = try await scrollerState(view)
        #expect(grown["top"] as? Double == top, "10 px up detached: a new entry does not move the view: \(detached) -> \(grown)")
        #expect(detached["jump"] as? Bool == false, "10 px is inside the 48 px band: no jump button: \(detached)")
        #expect(grown["jump"] as? Bool == true, "the new entry made it more than 48 px: the jump button shows: \(grown)")
        try await readerScroll(view, fromEnd: 3)
        try await appendEntries(view, tallEntries(1, from: 32))
        try await Task.sleep(nanoseconds: 250_000_000)
        let back = try await scrollerState(view)
        #expect(PagePixels.atEnd(back), "3 px from the end re-attached: the next entry is followed: \(back)")
    }

    @Test func ChatOrcaD4_thePagesOwnPinNeverDetachesWhileAReplyStreams() async throws {
        let r = WebPageRig()
        #expect(await r.loadAndWaitReady())
        let view = try #require(r.page.view)
        try await applyEntries(view, tallEntries(30))
        _ = try await settled(view)
        for step in 0..<40 {
            _ = try await pageJS(view, "return window.ClawdChat.apply({upserts: [{id: 30, kind: 'assistant', text: text}]});", ["text": "Message 30\n\n" + String(repeating: "More streamed words. ", count: 12 + step * 4)])
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let streamed = try await scrollerState(view)
        #expect(PagePixels.atEnd(streamed) && streamed["jump"] as? Bool == false, "still pinned after 40 growths: \(streamed)")
        try await appendEntries(view, tallEntries(1, from: 31))
        try await Task.sleep(nanoseconds: 300_000_000)
        let after = try await scrollerState(view)
        #expect(PagePixels.atEnd(after), "and still following: \(after)")
    }

    @Test func ChatOrcaD4_theJumpButtonExistsOnlyPastFortyEightPxAndAClickPinsAndHidesIt() async throws {
        let r = WebPageRig()
        #expect(await r.loadAndWaitReady())
        let view = try #require(r.page.view)
        try await applyEntries(view, tallEntries(30))
        _ = try await settled(view)
        let none = try await scrollerState(view)
        #expect(none["jump"] as? Bool == false, "following: no button: \(none)")
        try await readerScroll(view, fromEnd: 60)
        let shown = try await pageObject(view, """
        const j = document.querySelector('.jump');
        const box = j.getBoundingClientRect(); const wrap = document.querySelector('.scroller-wrap').getBoundingClientRect();
        return JSON.stringify({hidden: j.hidden, label: j.getAttribute('aria-label'), text: j.textContent, gap: wrap.bottom - box.bottom, centre: (box.left + box.right) / 2 - (wrap.left + wrap.right) / 2});
        """)
        #expect(shown["hidden"] as? Bool == false && shown["label"] as? String == "Jump to latest" && shown["text"] as? String == "Jump to latest", "\(shown)")
        #expect(abs((shown["gap"] as? Double ?? 99) - 12) <= 1 && abs(shown["centre"] as? Double ?? 99) <= 1, "12 pt above the bottom edge, centred: \(shown)")
        _ = try await pageJS(view, "document.querySelector('.jump').click(); return 1;")
        try await Task.sleep(nanoseconds: 300_000_000)
        let pinned = try await scrollerState(view)
        #expect(PagePixels.atEnd(pinned) && pinned["jump"] as? Bool == false, "a click pins and hides: \(pinned)")
        try await appendEntries(view, tallEntries(1, from: 31))
        try await Task.sleep(nanoseconds: 300_000_000)
        let followed = try await scrollerState(view)
        #expect(PagePixels.atEnd(followed), "and following is on again: \(followed)")
    }

    // MARK: Q5 the link popover

    private static let links = "[a](https://example.com/x) [b](javascript:alert(1)) [m](mailto:a@b.c)"

    private func click(_ view: WKWebView, link: Int, options: String = "") async throws {
        _ = try await pageJS(view, "document.querySelectorAll('a[data-href]')[\(link)].dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true, clientX: 140, clientY: 300, detail: 1\(options)})); return 1;")
    }

    @Test func ChatOrcaD5_aPlainClickOpensThePopoverAboveTheClickWithTheUrlAndOneRowAndOpensNothing() async throws {
        let r = WebPageRig()
        #expect(await r.loadAndWaitReady())
        let view = try #require(r.page.view)
        try await applyEntries(view, [["id": 1, "kind": "assistant", "text": Self.links]])
        try await click(view, link: 0)
        #expect(await webWait { r.page.layerOpen }, "the page said the layer is open")
        let parsed = try await pageObject(view, """
        const p = document.querySelector('.link-popover'); const box = p.getBoundingClientRect();
        return JSON.stringify({url: p.querySelector('.lp-url').textContent, title: p.querySelector('.lp-url').title, rows: p.querySelectorAll('.lp-row').length,
                               row: p.querySelector('.lp-row').textContent.replace(/\\u2318/, 'CMD'), rowHeight: p.querySelector('.lp-row').offsetHeight,
                               copy: p.querySelector('.lp-copy').getAttribute('aria-label'), left: box.left, bottom: box.bottom, top: box.top, width: box.width, count: document.querySelectorAll('.link-popover').length,
                               vw: document.documentElement.clientWidth, vh: document.documentElement.clientHeight, iw: window.innerWidth, ih: window.innerHeight});
        """)
        #expect(parsed["url"] as? String == "https://example.com/x" && parsed["title"] as? String == "https://example.com/x" && parsed["rows"] as? Int == 1 && parsed["count"] as? Int == 1, "\(parsed)")
        #expect(parsed["row"] as? String == "System BrowserCMDClick" && parsed["rowHeight"] as? Int == 32 && parsed["copy"] as? String == "Copy link", "\(parsed)")
        #expect(parsed["left"] as? Double == 140 && abs((parsed["bottom"] as? Double ?? 0) - 294) <= 1 && (parsed["width"] as? Double ?? 0) >= 208, "above the click, 6 pt away, start-aligned: \(parsed)")
        #expect(r.openedLinks.isEmpty && r.page.openedLinks == 0, "a plain click opens nothing")
        _ = try await pageJS(view, "document.querySelector('.lp-row').click(); return 1;")
        #expect(await webWait { r.openedLinks.count == 1 })
        #expect(r.openedLinks.first?.absoluteString == "https://example.com/x" && r.page.openedLinks == 1, "the row posts open once")
        #expect(await webWait { !r.page.layerOpen }, "and closes the popover")
        let gone = try await pageJS(view, "return document.querySelectorAll('.link-popover').length;") as? Int
        #expect(gone == 0)
    }

    @Test func ChatOrcaD5_aPopoverKeepsEightPointsInsideTheViewportAndFlipsBelowWhenThereIsNoRoomAbove() async throws {
        let r = WebPageRig()
        #expect(await r.loadAndWaitReady())
        let view = try #require(r.page.view)
        try await applyEntries(view, [["id": 1, "kind": "assistant", "text": Self.links]])
        _ = try await pageJS(view, "document.querySelectorAll('a[data-href]')[0].dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true, clientX: 515, clientY: 20, detail: 1})); return 1;")
        let parsed = try await pageObject(view, """
        const p = document.querySelector('.link-popover'); const box = p.getBoundingClientRect();
        return JSON.stringify({left: box.left, right: box.right, top: box.top, vw: document.documentElement.clientWidth});
        """)
        let right = try #require(parsed["right"] as? Double), vw = try #require(parsed["vw"] as? Double), top = try #require(parsed["top"] as? Double)
        #expect(right <= vw - 8 + 0.5 && (parsed["left"] as? Double ?? 0) >= 8, "8 pt inside the viewport: \(parsed)")
        #expect(top >= 8 && top >= 20, "no room above 20 pt: it sits below the click: \(parsed)")
    }

    @Test func ChatOrcaD5_aJavascriptOrMailtoLinkShowsNoPopoverAndShiftCmdAndCmdClickOpenAtOnce() async throws {
        let r = WebPageRig()
        #expect(await r.loadAndWaitReady())
        let view = try #require(r.page.view)
        try await applyEntries(view, [["id": 1, "kind": "assistant", "text": Self.links]])
        try await click(view, link: 1)
        try await click(view, link: 2)
        try await Task.sleep(nanoseconds: 250_000_000)
        let none = try await pageJS(view, "return document.querySelectorAll('.link-popover').length;") as? Int
        #expect(none == 0 && !r.page.layerOpen && r.openedLinks.isEmpty, "javascript: and mailto: stay inert")
        try await click(view, link: 0, options: ", metaKey: true, shiftKey: true")
        #expect(await webWait { r.openedLinks.count == 1 })
        try await click(view, link: 0, options: ", metaKey: true")
        #expect(await webWait { r.openedLinks.count == 2 })
        try await click(view, link: 0, options: ", shiftKey: true")
        try await click(view, link: 0, options: ", altKey: true")
        try await click(view, link: 0, options: ", ctrlKey: true")
        try await Task.sleep(nanoseconds: 250_000_000)
        let popovers = try await pageJS(view, "return document.querySelectorAll('.link-popover').length;") as? Int
        #expect(popovers == 0 && !r.page.layerOpen && r.openedLinks.count == 2, "Cmd-click opens with no popover; Shift, Alt and Ctrl clicks do nothing: \(r.openedLinks.count)")
    }

    @Test func ChatOrcaD5_aPressOutsideThePopoverClosesItAndDismissLayerAnswersWhetherItClosedOne() async throws {
        let r = WebPageRig()
        #expect(await r.loadAndWaitReady())
        let view = try #require(r.page.view)
        try await applyEntries(view, [["id": 1, "kind": "assistant", "text": Self.links]])
        try await click(view, link: 0)
        #expect(await webWait { r.page.layerOpen })
        _ = try await pageJS(view, "document.querySelector('.link-popover').dispatchEvent(new MouseEvent('mousedown', {bubbles: true})); return 1;")
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(r.page.layerOpen, "a press inside the popover keeps it")
        _ = try await pageJS(view, "document.getElementById('column').dispatchEvent(new MouseEvent('mousedown', {bubbles: true})); return 1;")
        #expect(await webWait { !r.page.layerOpen }, "a press elsewhere in the page closes it")
        try await click(view, link: 0)
        #expect(await webWait { r.page.layerOpen })
        var closed: Bool?
        r.page.dismissLayer { closed = $0 }
        #expect(await webWait { closed != nil })
        #expect(closed == true)
        #expect(await webWait { !r.page.layerOpen })
        var again: Bool?
        r.page.dismissLayer { again = $0 }
        #expect(await webWait { again != nil })
        #expect(again == false, "no popover: nothing closed")
    }

    @Test func ChatOrcaD5_theCopyLinkButtonAsksSwiftForTheUrlAndTheCheckShowsWhenSwiftSaysItWorked() async throws {
        let r = WebPageRig()
        #expect(await r.loadAndWaitReady())
        let view = try #require(r.page.view)
        var urls: [String] = []
        r.page.onCopyLinkRequest = { urls.append($0) }
        try await applyEntries(view, [["id": 1, "kind": "assistant", "text": Self.links]])
        try await click(view, link: 0)
        #expect(await webWait { r.page.layerOpen })
        _ = try await pageJS(view, "document.querySelector('.lp-copy').click(); return 1;")
        #expect(await webWait { urls.count == 1 })
        #expect(urls == ["https://example.com/x"], "\(urls)")
        r.page.linkCopied()
        #expect(await webWait { r.page.linkCopiedCount == 1 })
        try await Task.sleep(nanoseconds: 200_000_000)
        let label = try await pageJS(view, "return document.querySelector('.lp-copy').getAttribute('aria-label');") as? String
        #expect(label == "Copied")
    }

    // MARK: round D sprint 1 review fixes

    @Test func ChatOrcaD1_theFenceHeaderShowsOrcasLabelForALanguageAndTheRawValueOtherwise() async throws {
        let r = WebPageRig()
        #expect(await r.loadAndWaitReady())
        let text = "```bash\nls\n```\n\n```ts\nlet a\n```\n\n```typescript\nlet b\n```\n\n```cpp\nint c;\n```"
        try await applyEntries(r.page.view!, [["id": 1, "kind": "assistant", "text": text]])
        let labels = try await pageJS(r.page.view!, "return Array.from(document.querySelectorAll('.code-lang')).map(function (e) { return e.textContent; }).join('|');") as? String
        #expect(labels == "Bash|ts|TypeScript|C++", "\(String(describing: labels))")
    }

    @Test func ChatOrcaD1_aPressOnCopyCodeHoldsTheEntrysRerenderSoTheReleasePostsTheCopyOnceAndTheFlashSurvivesTheRerender() async throws {
        let r = WebPageRig()
        #expect(await r.loadAndWaitReady())
        let view = try #require(r.page.view)
        var requests: [[Int]] = []
        r.page.onCopyCodeRequest = { requests.append([$0, $1]) }
        try await applyEntries(view, [["id": 7, "kind": "assistant", "text": Self.fences]])
        let parsed = try await pageObject(view, """
        const button = document.querySelectorAll('[data-id="7"] .code-block')[0].querySelector('button');
        const fire = function (type) { button.dispatchEvent(new MouseEvent(type, {bubbles: true, cancelable: true, button: 0, detail: 1})); };
        fire('mousedown');
        window.ClawdChat.apply({order: [7], upserts: [{id: 7, kind: 'assistant', text: arguments_text}]});
        const heldConnected = button.isConnected;
        fire('mouseup');
        button.click();
        return JSON.stringify({heldConnected: heldConnected});
        """, ["arguments_text": Self.fences + "\n\nmore text"])
        #expect(parsed["heldConnected"] as? Bool == true, "the press holds the re-render: \(parsed)")
        #expect(await webWait { requests.count == 1 })
        #expect(requests == [[7, 0]], "\(requests)")
        var rerendered = false
        for _ in 0..<100 {
            rerendered = try await pageJS(view, "return document.querySelector('[data-id=\"7\"]').textContent.indexOf('more text') >= 0;") as? Bool ?? false
            if rerendered { break }
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        #expect(rerendered, "the held re-render runs after the release")
        r.page.codeCopied(7, 0)
        let flashed = try await pageJS(view, """
        window.ClawdChat.apply({order: [7], upserts: [{id: 7, kind: 'assistant', text: arguments_text}]});
        return document.querySelectorAll('[data-id="7"] .code-block')[0].querySelector('button').getAttribute('aria-label');
        """, ["arguments_text": Self.fences + "\n\nmore text and more"]) as? String
        #expect(flashed == "Copied", "a re-render puts the live flash on the new button: \(String(describing: flashed))")
    }

    @Test func ChatOrcaD5_theCopyLinkButtonHasItsTooltipFromCreationAndTheAssistantControlsCannotBeSelected() async throws {
        let r = WebPageRig()
        #expect(await r.loadAndWaitReady())
        let view = try #require(r.page.view)
        try await applyEntries(view, [["id": 1, "kind": "assistant", "text": Self.links]])
        try await click(view, link: 0)
        #expect(await webWait { r.page.layerOpen })
        let title = try await pageJS(view, "return document.querySelector('.lp-copy').title;") as? String
        #expect(title == "Copy link", "\(String(describing: title))")
        let select = try await pageJS(view, "const style = getComputedStyle(document.querySelector('.agent-controls')); return style.webkitUserSelect;") as? String
        #expect(select == "none", "\(String(describing: select))")
    }

    // MARK: Q25 the divider

    @Test func ChatOrcaD25_aDividerEntryIsASeparatorWithARuleOnEachSideOfAMutedTwelvePixelLabelAndEightPixelsAboveAndBelowAndTheEntriesAroundItStay() async throws {
        let r = WebPageRig()
        #expect(await r.loadAndWaitReady())
        try await applyEntries(r.page.view!, [["id": 1, "kind": "assistant", "text": "old"], ["id": 2, "kind": "divider", "text": "Conversation cleared"],
                                              ["id": 3, "kind": "user", "text": "new"]])
        let parsed = try await pageObject(r.page.view!, """
        const sep = document.querySelector('[data-id="2"] [role="separator"]');
        const kids = sep ? Array.from(sep.children) : [];
        const style = sep ? getComputedStyle(sep) : null;
        const rule = kids.length === 3 ? kids[0].getBoundingClientRect() : null;
        const label = kids.length === 3 ? getComputedStyle(kids[1]) : null;
        return JSON.stringify({found: sep !== null, count: kids.length, label: kids.length === 3 ? kids[1].textContent : '', aria: sep ? sep.getAttribute('aria-label') : '',
          ruleHeight: rule ? rule.height : 0, ruleWidth: rule ? rule.width : 0, padTop: style ? style.paddingTop : '', padBottom: style ? style.paddingBottom : '',
          fontSize: label ? label.fontSize : '', gap: style ? style.columnGap : '',
          order: Array.from(document.querySelectorAll('#column > .row[data-id]')).map(function (e) { return e.getAttribute('data-id'); })});
        """)
        #expect(parsed["found"] as? Bool == true && parsed["count"] as? Int == 3 && parsed["label"] as? String == "Conversation cleared" && parsed["aria"] as? String == "Conversation cleared", "\(parsed)")
        #expect(parsed["ruleHeight"] as? Double == 1 && (parsed["ruleWidth"] as? Double ?? 0) > 20, "a 1 pt rule on each side: \(parsed)")
        #expect(parsed["padTop"] as? String == "8px" && parsed["padBottom"] as? String == "8px" && parsed["fontSize"] as? String == "12px" && parsed["gap"] as? String == "12px", "\(parsed)")
        #expect(parsed["order"] as? [String] == ["1", "2", "3"], "the old entry stays above and the new one below: \(parsed)")
    }
}
