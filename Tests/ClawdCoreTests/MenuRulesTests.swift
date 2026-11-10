import Testing
import Foundation
import AppKit
import ClawdCore
import ClawdRendering
import ClawdDesktop

// The menu's rules with a fake host, a fake clock and timer, and a fake outside-click source: when it opens and closes, which opening a
// click or a late callback belongs to, what is logged. No window is made; nothing here shows anything.

final class MenuFakeSurface: MenuSurface {
    let gen: Int
    private(set) var armed = 0, disarmed = 0
    private(set) var flashes: [MenuItem?] = []
    private(set) var selections: [MenuSelection] = []
    init(gen: Int) { self.gen = gen }
    func update(selection: MenuSelection) { selections.append(selection) }
    func flash(_ item: MenuItem?) { flashes.append(item) }
    func armTracking() { armed += 1 }
    func disarmTracking() { disarmed += 1 }
}

final class MenuFakeHost: MenuHost {
    var selection = MenuSelection()
    var placement: CGRect? = CGRect(x: 640, y: 100, width: 236, height: 257)
    var refuse = false
    private(set) var shows: [(gen: Int, rect: CGRect)] = []
    /// One entry per `menuHide`: whether it drew.
    private(set) var hides: [Bool] = []
    private(set) var surfaces: [MenuFakeSurface] = []
    var order: (String) -> Void = { _ in }
    func menuSelection() -> MenuSelection { selection }
    func menuPlacement() -> CGRect? { placement }
    func menuShow(gen: Int, rect: CGRect) -> MenuSurface? {
        if refuse { return nil }
        shows.append((gen, rect)); order("show gen=\(gen)")
        let surface = MenuFakeSurface(gen: gen)
        surfaces.append(surface)
        return surface
    }
    func menuHide(render: Bool) { hides.append(render); order("hide render=\(render)") }
    /// One entry per `menuToggleChat`: the pick's event time.
    private(set) var chatToggles: [TimeInterval] = []
    func menuToggleChat(eventTime: TimeInterval) { chatToggles.append(eventTime); order("chat toggle") }
    /// One entry per `menuOpenSettings` (the pick's event time) and per `menuQuit`.
    private(set) var settingsOpens: [TimeInterval] = []
    private(set) var quits = 0
    func menuOpenSettings(eventTime: TimeInterval) { settingsOpens.append(eventTime); order("settings open") }
    func menuQuit() { quits += 1; order("quit") }
}

final class MenuFakeTimer: MenuTimerSource {
    var onFire: (() -> Void)?
    private let clock: PetClock
    private(set) var fireAt: TimeInterval?
    private(set) var armCount = 0
    init(clock: PetClock) { self.clock = clock }
    func arm(after delay: TimeInterval, leeway: TimeInterval) { fireAt = clock.now + delay; armCount += 1 }
    func cancel() { fireAt = nil }
}

final class MenuFakeToken {}
/// Keeps every handler it was ever given, removed ones included, and can call any of them at any time (a copy queued before a removal).
final class MenuFakeSource: MenuOutsideClickSource {
    struct Entry { let handler: (TimeInterval) -> Void; let token: MenuFakeToken; var removed = false }
    private(set) var entries: [Entry] = []
    var installs: Int { entries.count }
    var removals: Int { entries.filter(\.removed).count }
    var live: Int { entries.filter { !$0.removed }.count }
    func install(_ handler: @escaping (TimeInterval) -> Void) -> AnyObject? {
        let token = MenuFakeToken()
        entries.append(Entry(handler: handler, token: token))
        return token
    }
    func remove(_ token: AnyObject) {
        guard let index = entries.firstIndex(where: { $0.token === token }) else { return }
        entries[index].removed = true
    }
    func deliver(to index: Int, at time: TimeInterval) { entries[index].handler(time) }
}

/// A controller, its fakes and the lines it logs.
final class MenuRig {
    let clock = VirtualClock(now: 1000)
    let host = MenuFakeHost()
    let timer: MenuFakeTimer
    let source = MenuFakeSource()
    let home: URL
    let writer: MenuWriter
    private(set) var lines: [String] = []
    private(set) var onMainThread: [Bool] = []
    private(set) var controller: MenuController!
    /// Menu items of the layout the fakes stand for: three looks, styles 1, 6 and 10 drawn.
    let layout = MenuLayout(looks: ["plain", "helmet", "sunglasses"], drawnStyles: [1, 6, 10])

    init(stub: MenuStubHome? = nil) throws {
        timer = MenuFakeTimer(clock: clock)
        home = try stub?.root ?? artifactStore().root
        var sink: ((String) -> Void)!
        writer = MenuWriter(home: home, log: { sink($0) })
        controller = MenuController(host: host, clock: clock, timer: timer, source: source, writer: writer, log: { sink($0) })
        sink = { [unowned self] line in self.lines.append(line); self.onMainThread.append(Thread.isMainThread) }
        host.order = { [unowned self] text in self.lines.append("(host) " + text) }
    }

    /// The lines that start with `prefix`.
    func lines(_ prefix: String) -> [String] { lines.filter { menuLineHasPrefix($0, prefix) } }
    var menuLines: [String] { lines.filter { $0.hasPrefix("MENU") } }

    func mouseDown(time: TimeInterval = 5, _ type: NSEvent.EventType = .leftMouseDown) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: .zero, modifierFlags: [], timestamp: time, windowNumber: 0, context: nil,
                                        eventNumber: 0, clickCount: 1, pressure: 1))
    }
    func item(_ key: String, _ value: String) -> MenuItem { menuItem(layout, key, value) }

    @discardableResult
    func open(how: MenuOpenHow = .right, at time: TimeInterval = 5) -> MenuRequestResult { controller.request(how: how, eventTime: time) }
    func click(_ item: MenuItem, gen: Int? = nil, time: TimeInterval = 6, kind: String = "mouseDown") throws {
        controller.menuView(gen: gen ?? controller.liveGeneration ?? 0, mouseDown: try mouseDown(time: time), kind: kind, hit: .item(item))
    }
    func click(_ hit: MenuHit, gen: Int, time: TimeInterval = 6) throws {
        controller.menuView(gen: gen, mouseDown: try mouseDown(time: time), kind: "mouseDown", hit: hit)
    }

    /// Moves the clock, firing the menu's one timer at its own instant.
    func advance(_ seconds: TimeInterval) {
        let target = clock.now + seconds
        while let fire = timer.fireAt, fire <= target {
            clock.advance(max(0, fire - clock.now)); timer.cancel(); controller.timerFired()
        }
        clock.advance(max(0, target - clock.now))
    }
}

@Suite("MenuTests rules", .serialized)
@MainActor
struct MenuTestsRules {
    // MARK: opening

    @Test func Menu_openingsAreNumberedFromOneAndARefusedRightClickTakesNoNumber() throws {
        let rig = try MenuRig()
        rig.host.refuse = true
        #expect(rig.open() == .busy)
        #expect(rig.controller.generation == 0 && !rig.controller.isOpen && rig.source.installs == 0, "a refused right-click opens nothing, installs nothing")
        rig.host.refuse = false
        #expect(rig.open(at: 10.25) == .opened)
        #expect(rig.controller.generation == 1 && rig.controller.liveGeneration == 1 && rig.host.shows.map(\.gen) == [1])
        try #require(rig.host.shows.count > 0, "rig.host.shows needs 1 elements: \(rig.host.shows.count)")
        #expect(rig.host.shows[0].rect == CGRect(x: 640, y: 100, width: 236, height: 257), "the host is told where")
        #expect(rig.lines("MENU open") == ["MENU open et=10.250000 how=right gen=1"])
        rig.controller.close(.toggle, et: 11)
        rig.host.refuse = true
        #expect(rig.open() == .busy)
        rig.host.refuse = false
        #expect(rig.open(how: .control, at: 12) == .opened)
        #expect(rig.lines("MENU open").last == "MENU open et=12.000000 how=control gen=2", "a refusal between two openings took no number")
        #expect(rig.host.surfaces.map(\.gen) == [1, 2] && rig.host.surfaces.allSatisfy { $0.armed == 1 }, "tracking is armed once per opening")
    }

    @Test func Menu_nothingOnScreenMeansNothingToOpen() throws {
        let rig = try MenuRig()
        rig.host.placement = nil
        #expect(rig.open() == .busy && rig.host.shows.isEmpty && rig.source.installs == 0 && rig.controller.generation == 0)
    }

    @Test func Menu_theOpenLineComesAfterThePresentationOfTheWindow() throws {
        let rig = try MenuRig()
        rig.open()
        let order = rig.lines.filter { $0.hasPrefix("(host) show") || $0.hasPrefix("MENU open") }
        #expect(order == ["(host) show gen=1", "MENU open et=5.000000 how=right gen=1"], "GEOM is written by the render that shows the window, so before MENU open")
    }

    // MARK: picking

    @Test func Menu_aPickIsLoggedFlashesForOneHundredFortyMillisecondsThenClosesAndOnlyThenRuns() throws {
        let rig = try MenuRig()
        rig.open()
        let item = rig.item("motion", "normal")
        try rig.click(item, time: 7.5)
        #expect(rig.lines("MENU pick") == ["MENU pick id=1 et=7.500000 key=motion value=normal gen=1"])
        try #require(rig.host.surfaces.count > 0, "rig.host.surfaces needs 1 elements: \(rig.host.surfaces.count)")
        #expect(rig.host.surfaces[0].flashes == [item], "the item flashes")
        #expect(rig.controller.isOpen && rig.host.hides.isEmpty)
        rig.advance(0.139)
        #expect(rig.controller.isOpen, "139 ms: still open")
        #expect(rig.lines("MENU write").isEmpty, "nothing runs before the close")
        rig.advance(0.002)
        #expect(!rig.controller.isOpen && rig.host.hides == [true], "140 ms: closed, and drawn")
        #expect(rig.lines("MENU close") == ["MENU close reason=pick gen=1"])
        func tag(_ line: String) -> String { line.hasPrefix("MENU pick") ? "pick" : line.hasPrefix("MENU close") ? "close" : line.hasPrefix("(host) hide") ? "hide" : line.hasPrefix("MENU cli") ? "cli" : "write" }
        let order = rig.lines.filter { $0.hasPrefix("MENU pick") || $0.hasPrefix("MENU close") || $0.hasPrefix("(host) hide") || $0.hasPrefix("MENU write") || $0.hasPrefix("MENU cli") }
        #expect(order.map(tag) == ["pick", "close", "hide", "cli", "write"],
                "the close render comes first, the child starts after it (no CLI in this home: the write is refused, and says so)")
        #expect(rig.lines("MENU write") == ["MENU write id=1 key=motion verb=motion+normal exit=none gen=1"])
    }

    @Test func Menu_aClickWhileTheFlashRunsIsLoggedAndPicksNothing() throws {
        let rig = try MenuRig()
        rig.open()
        try rig.click(rig.item("walk", "on"), time: 7)
        try rig.click(rig.item("walk", "off"), time: 7.05)
        #expect(rig.lines("MENU pick").count == 1)
        #expect(rig.lines("MOUSE-IGNORED").count == 1 && rig.lines("MOUSE-IGNORED")[0].hasSuffix("why=menu-flash et=7.050000 gen=1"), "\(rig.lines("MOUSE-IGNORED"))")
        rig.advance(0.2)
        #expect(rig.lines("MENU write").count == 1, "one pick, one write")
    }

    @Test func Menu_clicksOnMutedStylesSeparatorsAndGapsAreLoggedNeverPicks() throws {
        let rig = try MenuRig()
        rig.open()
        let muted = rig.item("style", "3")
        try rig.click(.muted(muted), gen: 1, time: 6.1)
        try rig.click(.separator, gen: 1, time: 6.2)
        try rig.click(.gap, gen: 1, time: 6.3)
        try rig.click(rig.item("walk", "on"), gen: 1, time: 6.4, kind: "rightMouseDown")
        let ignored = rig.lines("MOUSE-IGNORED")
        #expect(ignored.count == 4)
        for (line, (why, et)) in zip(ignored, zip(["menu-muted", "menu-separator", "menu-gap", "menu-gap"], ["6.100000", "6.200000", "6.300000", "6.400000"])) {
            #expect(line.hasSuffix("why=\(why) et=\(et) gen=1"), "\(line)")
        }
        #expect(ignored[3].hasPrefix("MOUSE-IGNORED kind=rightMouseDown tag="), "a right-click on an item is not a pick")
        try #require(rig.host.surfaces.count > 0, "rig.host.surfaces needs 1 elements: \(rig.host.surfaces.count)")
        #expect(rig.lines("MENU pick").isEmpty && rig.controller.isOpen && rig.timer.fireAt != nil && rig.host.surfaces[0].flashes.isEmpty)
    }

    @Test func Menu_aClickForAnOldWindowIsLoggedWithItsOwnNumberAndIsNeverAPick() throws {
        let rig = try MenuRig()
        rig.open(); rig.controller.close(.toggle, et: 6)
        rig.open(at: 7)
        #expect(rig.controller.liveGeneration == 2)
        let item = rig.item("walk", "off")
        // The click was queued for the gen-1 window and is handled after the gen-2 menu opened.
        try rig.click(item, gen: 1, time: 6.9)
        #expect(rig.lines("MENU pick").isEmpty && rig.controller.isOpen, "no pick, no state change")
        #expect(rig.lines("MOUSE-IGNORED").last?.hasSuffix("why=menu-stale et=6.900000 gen=1") == true, "\(rig.lines("MOUSE-IGNORED"))")
        try #require(rig.host.surfaces.count > 1, "rig.host.surfaces needs 2 elements: \(rig.host.surfaces.count)")
        #expect(rig.host.surfaces[1].flashes.isEmpty && rig.timer.fireAt.map { $0 - rig.clock.now > 7 } == true, "the live menu is untouched (only its away deadline is armed)")
        // The same click while the gen-2 window is live and over an item is a pick, with gen 2.
        try rig.click(item, gen: 2, time: 7.1)
        #expect(rig.lines("MENU pick") == ["MENU pick id=1 et=7.100000 key=walk value=off gen=2"])
        // A click for a window of an opening that has closed, with no menu open at all.
        rig.advance(0.2)
        try rig.click(item, gen: 2, time: 8)
        #expect(rig.lines("MOUSE-IGNORED").last?.hasSuffix("why=menu-stale et=8.000000 gen=2") == true)
        #expect(rig.lines("MENU pick").count == 1)
        // Negative control: a window that read the agent's live number instead of its own would turn the old click into a pick.
        let rig2 = try MenuRig()
        rig2.open(); rig2.controller.close(.toggle, et: 6); rig2.open(at: 7)
        try rig2.click(rig2.item("walk", "off"), gen: rig2.controller.liveGeneration, time: 6.9)
        negativeControl("a-panel-reading-the-live-gen-turns-a-stale-click-into-a-pick", expectationHolds: rig2.lines("MENU pick").isEmpty)
    }

    // MARK: closing

    @Test func Menu_aMouseDownOutsideClosesItAndNamesTheEventThatDidIt() throws {
        let rig = try MenuRig()
        rig.open()
        #expect(rig.source.installs == 1 && rig.source.live == 1, "one monitor for the opening")
        rig.source.deliver(to: 0, at: 9.5)
        #expect(rig.lines("MENU close") == ["MENU close reason=outside et=9.500000 gen=1"])
        #expect(!rig.controller.isOpen && rig.host.hides == [true] && rig.source.live == 0 && rig.source.removals == 1)
        try #require(rig.host.surfaces.count > 0, "rig.host.surfaces needs 1 elements: \(rig.host.surfaces.count)")
        #expect(rig.host.surfaces[0].disarmed == 1, "its tracking areas are removed")
    }

    @Test func Menu_aSecondRightClickOnClawdClosesIt() throws {
        let rig = try MenuRig()
        rig.open()
        #expect(rig.open(at: 8.75) == .toggled)
        #expect(rig.lines("MENU close") == ["MENU close reason=toggle et=8.750000 gen=1"])
        #expect(!rig.controller.isOpen && rig.source.live == 0 && rig.controller.generation == 1, "a toggle opens nothing")
    }

    @Test func Menu_closesAfterEightSecondsWithThePointerAwayAndNotBefore() throws {
        let rig = try MenuRig()
        rig.open()
        rig.advance(7.9)
        #expect(rig.controller.isOpen, "7.9 s")
        rig.advance(0.2)
        #expect(!rig.controller.isOpen && rig.lines("MENU close") == ["MENU close reason=away gen=1"], "8 s")
        // The pointer comes onto the menu: the count stops; it leaves: a fresh 8 s starts.
        let again = try MenuRig()
        again.open()
        again.advance(5)
        again.controller.menuView(gen: 1, pointerInside: true)
        again.advance(100)
        #expect(again.controller.isOpen, "with the pointer on the menu nothing closes it")
        again.controller.menuView(gen: 1, pointerInside: false)
        again.advance(7.9)
        #expect(again.controller.isOpen)
        again.controller.menuView(gen: 1, pointerInside: false)      // the pointer is still out: the deadline does not move
        again.advance(0.2)
        #expect(!again.controller.isOpen && again.lines("MENU close") == ["MENU close reason=away gen=1"])
        // And it leaves and comes back inside the 8 s: the count is cancelled.
        let back = try MenuRig()
        back.open()
        back.advance(1)
        back.controller.menuView(gen: 1, pointerInside: true)
        back.advance(0.5)
        back.controller.menuView(gen: 1, pointerInside: false)
        back.advance(7)
        #expect(back.controller.isOpen, "the 8 s count started again when the pointer left the second time")
        back.advance(1.1)
        #expect(!back.controller.isOpen)
    }

    @Test func Menu_everyCloseReasonRemovesTheMonitorDisarmsTheWindowAndTellsTheHostOnce() throws {
        let reasons: [(String, (MenuRig) throws -> Void)] = [
            ("pick", { rig in try rig.click(rig.item("walk", "on")); rig.advance(0.2) }),
            ("outside", { rig in rig.source.deliver(to: rig.source.installs - 1, at: 9) }),
            ("away", { rig in rig.advance(8.5) }),
            ("dictation", { rig in rig.controller.closeForDictation() }),
            ("hidden", { rig in rig.controller.closeForHidden() }),
            ("drag", { rig in rig.controller.closeForDrag() }),
            ("toggle", { rig in rig.open(at: 9) }),
            ("geometry", { rig in rig.controller.close(.geometry) }),
            ("chat", { rig in rig.controller.close(.chat) }),
        ]
        #expect(Set(reasons.map(\.0)) == Set(MenuCloseReason.allCases.map(\.rawValue)), "every reason is covered")
        for (reason, close) in reasons {
            let rig = try MenuRig()
            rig.open()
            #expect(rig.source.live == 1)
            try close(rig)
            #expect(!rig.controller.isOpen, "\(reason)")
            #expect(rig.lines("MENU close").count == 1 && rig.lines("MENU close")[0].hasPrefix("MENU close reason=\(reason)"), "\(reason): \(rig.lines("MENU close"))")
            #expect(rig.lines("MENU close")[0].hasSuffix(" gen=1"))
            #expect(rig.source.live == 0 && rig.source.removals == 1 && rig.source.installs == 1, "\(reason): the monitor is removed, and none is left")
            #expect(rig.host.hides == [reason != "hidden"], "\(reason): the host hears of one close; a hide draws nothing (the windows are going)")
            try #require(rig.host.surfaces.count > 0, "rig.host.surfaces needs 1 elements: \(rig.host.surfaces.count)")
            #expect(rig.host.surfaces[0].armed == 1 && rig.host.surfaces[0].disarmed == 1, "\(reason): tracking areas removed")
            #expect(rig.timer.fireAt == nil, "\(reason): no deadline is left armed")
            // a second close, or a late timer, changes nothing
            rig.controller.close(.outside, et: 1); rig.controller.timerFired(); rig.advance(60)
            #expect(rig.lines("MENU close").count == 1 && rig.host.hides.count == 1, "\(reason): closed once")
        }
    }

    @Test func Menu_aCloseWithNothingOpenIsANoOp() throws {
        let rig = try MenuRig()
        rig.controller.closeForDictation(); rig.controller.closeForDrag(); rig.controller.closeForHidden()
        #expect(rig.lines.isEmpty && rig.host.hides.isEmpty && rig.source.installs == 0)
    }

    // MARK: late copies (R-GEN)

    @Test func Menu_aCopyOfAnEarlierOpeningChangesNothingAndTheMenuItBelongsToIsTheOnlyOneItCloses() throws {
        let rig = try MenuRig()
        rig.open()                                         // gen 1: handler index 0
        rig.source.deliver(to: 0, at: 6)                   // closes gen 1 (its own copy)
        #expect(rig.lines("MENU close") == ["MENU close reason=outside et=6.000000 gen=1"])
        // (1) the gen-1 handler again after gen 1 closed, with no menu open: at most one stale line, no close, no state change
        let hidesBefore = rig.host.hides.count
        rig.source.deliver(to: 0, at: 6.5)
        #expect(rig.lines("MENU close").count == 1 && rig.host.hides.count == hidesBefore)
        #expect(rig.lines("MENU stale") == ["MENU stale kind=outside et=6.500000 gen=1 live=none"])
        // (2) the gen-1 handler after gen 2 opened: gen 2 stays open, no close of any kind, at most one stale line
        rig.open(at: 7)                                    // gen 2: handler index 1
        rig.source.deliver(to: 0, at: 7.2)
        #expect(rig.controller.isOpen && rig.controller.liveGeneration == 2, "the newer menu is untouched")
        #expect(rig.lines("MENU close").count == 1, "no close line, least of all `reason=outside ... gen=2`")
        #expect(rig.lines("MENU stale").last == "MENU stale kind=outside et=7.200000 gen=1 live=2")
        #expect(rig.host.hides.count == hidesBefore, "the host is not told")
        // (3) the positive control: gen 2's own handler closes gen 2, with gen=2
        rig.source.deliver(to: 1, at: 7.4)
        #expect(rig.lines("MENU close").last?.hasSuffix(" gen=2") == true && rig.lines("MENU close").last?.hasPrefix("MENU close reason=outside et=7.400000") == true)
        #expect(!rig.controller.isOpen)
        // (4) negative control: a handler that tests only "a menu is open" (the v3 rule) is flagged by (2)
        let bad = try MenuRig()
        bad.open(); bad.source.deliver(to: 0, at: 6); bad.open(at: 7)
        let legacy: (TimeInterval) -> Void = { time in if bad.controller.isOpen { bad.controller.close(.outside, et: time) } }
        legacy(7.2)       // what the first opening's handler would do under the old rule
        negativeControl("a-handler-that-only-asks-whether-a-menu-is-open-closes-the-newer-menu", expectationHolds: bad.controller.isOpen && bad.lines("MENU close").count == 1)
    }

    @Test func Menu_theMonitorOfTheOldOpeningIsGoneWhenTheNewOneOpensAndNoTwoAreEverLive() throws {
        let rig = try MenuRig()
        for round in 1...5 {
            rig.open(at: Double(round))
            #expect(rig.source.live == 1, "round \(round)")
            rig.controller.close(.toggle, et: Double(round) + 0.5)
            #expect(rig.source.live == 0, "round \(round): none while the menu is closed")
        }
        #expect(rig.source.installs == 5 && rig.source.removals == 5 && rig.controller.generation == 5)
    }

    // MARK: lines

    @Test func Menu_everyLineNamesItsOpeningNumbersCountUpAndAllAreWrittenOnTheMainThread() throws {
        let rig = try MenuRig()
        for round in 1...3 {
            rig.open(at: Double(round * 10))
            try rig.click(rig.item("walk", round % 2 == 0 ? "on" : "off"), time: Double(round * 10) + 1)
            rig.advance(0.2)
        }
        let menu = rig.menuLines
        #expect(menu.allSatisfy { $0.contains(" gen=") }, "\(menu.filter { !$0.contains(" gen=") })")
        #expect(menu.filter { $0.hasPrefix("MENU open") }.compactMap { Int($0.split(separator: "=").last ?? "") } == [1, 2, 3])
        #expect(rig.lines("MENU pick").map { $0.hasSuffix("gen=1") ? 1 : $0.hasSuffix("gen=2") ? 2 : 3 } == [1, 2, 3])
        #expect(rig.lines("MENU pick").map { $0.components(separatedBy: " ")[2] } == ["id=1", "id=2", "id=3"], "picks count from 1 in the process")
        #expect(rig.lines("MENU write").count == 3)
        #expect(rig.onMainThread.allSatisfy { $0 }, "every line is written on the main thread")
        #expect(!rig.lines.contains { $0.hasPrefix("MENU") && $0.contains(" t=") }, "no MENU line carries an agent time")
    }

    @Test func Menu_hoverIsLoggedOncePerChangeOfTheHighlightedItem() throws {
        let rig = try MenuRig()
        rig.open()
        let a = rig.item("motion", "off"), b = rig.item("motion", "quiet")
        rig.controller.menuView(gen: 1, hover: a)
        rig.controller.menuView(gen: 1, hover: a)
        rig.controller.menuView(gen: 1, hover: b)
        rig.controller.menuView(gen: 1, hover: nil)
        rig.controller.menuView(gen: 1, hover: b)
        #expect(rig.lines("MENU hover") == ["MENU hover key=motion value=off gen=1", "MENU hover key=motion value=quiet gen=1", "MENU hover key=motion value=quiet gen=1"])
        rig.controller.menuView(gen: 7, hover: a)
        #expect(rig.lines("MENU hover").count == 3, "a hover for another opening says nothing")
    }

    @Test func Menu_theSettingsAppliedWhileItIsOpenUpdateTheWindow() throws {
        let rig = try MenuRig()
        rig.open()
        var changed = MenuSelection(); changed.walk = false
        rig.host.selection = changed
        rig.controller.settingsApplied()
        try #require(rig.host.surfaces.count > 0, "rig.host.surfaces needs 1 elements: \(rig.host.surfaces.count)")
        #expect(rig.host.surfaces[0].selections == [changed], "the menu always shows the truth")
        rig.controller.close(.toggle, et: 6)
        rig.controller.settingsApplied()
        try #require(rig.host.surfaces.count > 0, "rig.host.surfaces needs 1 elements: \(rig.host.surfaces.count)")
        #expect(rig.host.surfaces[0].selections.count == 1, "a closed menu is not updated")
    }

    @Test func Menu_twoPicksOfTheSameStyleSettleOnTheSelectionAtTheTimeOfTheClick() throws {
        let rig = try MenuRig()
        rig.open()
        var excluded = MenuSelection(); excluded.excludedStyles = [6]
        rig.host.selection = excluded
        try rig.click(rig.item("style", "6"), time: 6)
        rig.advance(0.2)
        #expect(rig.lines("MENU write") == ["MENU write id=1 key=style verb=bubble+include+6 exit=none gen=1"], "style 6 is excluded now, so the chip includes it")
    }

    // MARK: SA5-1b: a selection and a restart

    @Test func MenuController_aSelectionWhileARestartRunsIsRefusedAtOnce() async throws {
        let stub = try MenuStubHome(); try menuInstallGatedCLI(stub)
        let rig = try MenuRig(stub: stub)
        let restart = MenuPick(id: 100, action: MenuAction(key: "overFullScreen", value: "on", queueKey: "overFullScreen", arguments: ["full-screen", "on"]), gen: 0, restarts: true)
        rig.writer.submit(restart)
        #expect(rig.writer.restartRunning)
        rig.open()
        try rig.click(rig.item("walk", "off"), time: 7)
        #expect(rig.lines("MENU refuse") == ["MENU refuse id=1 why=restarting by=100 gen=1"], "\(rig.lines)")
        rig.advance(1)
        #expect(await menuWait { stub.started.count == 1 })
        #expect(rig.lines("MENU close").count == 1 && rig.writer.queuedCount == 0 && stub.started == [["full-screen", "on"]], "the menu closed and nothing was submitted")
        // Nothing is held: once the restart is over, a restart pick starts at once.
        menuRelease(stub, "full-screen-on")
        #expect(await menuWait(120) { !rig.writer.isRunning })
        rig.writer.submit(MenuPick(id: 101, action: MenuAction(key: "overFullScreen", value: "off", queueKey: "overFullScreen", arguments: ["full-screen", "off"]), gen: 0, restarts: true))
        #expect(rig.writer.isRunning, "no hold was left behind")
        menuRelease(stub, "full-screen-off")
        #expect(await menuWait(120) { !rig.writer.isRunning })
    }

    @Test func MenuController_aSelectionHoldsRestartsUntilTheMenuCloses() async throws {
        for byPick in [true, false] {
            let stub = try MenuStubHome(); try menuInstallGatedCLI(stub)
            let rig = try MenuRig(stub: stub)
            rig.writer.submit(MenuPick(id: 100, action: MenuAction(key: "bubble", value: "on", queueKey: "bubble", arguments: ["bubble", "on"]), gen: 0))
            rig.writer.submit(MenuPick(id: 101, action: MenuAction(key: "overFullScreen", value: "on", queueKey: "overFullScreen", arguments: ["full-screen", "on"]), gen: 0, restarts: true))
            rig.open()
            try rig.click(rig.item("walk", "off"), time: 7)               // the selection is held in the menu, not in the writer
            menuRelease(stub, "bubble-on")
            #expect(await menuWait(120) { !rig.writer.isRunning })
            #expect(rig.writer.queuedCount == 1 && stub.started == [["bubble", "on"]], "the restart pick does not start while the selection is pending: \(stub.started)")
            if byPick { rig.advance(1) } else { rig.controller.closeForDrag() }
            #expect(await menuWait { stub.started.count == 2 })
            #expect(rig.writer.isRunning && stub.started == [["bubble", "on"], ["walk", "off"]], "the selection is submitted first: \(stub.started)")
            menuRelease(stub, "walk-off")
            #expect(await menuWait(30) { stub.started.count == 3 })
            #expect(stub.started.last == ["full-screen", "on"], "and the release lets the restart pick follow")
            menuRelease(stub, "full-screen-on")
            #expect(await menuWait(120) { !rig.writer.isRunning })
        }
    }
}

// MARK: the scheduler's hold (R-HOLD, spec 6.1)

@Suite("MenuTests scheduler", .serialized)
struct MenuTestsScheduler {
    private static func lively(walk: Bool = true) -> SchedulerSettings { SchedulerFixture.settings { $0.motion = .lively; $0.walk = walk; $0.lookEveryHours = 2 } }

    /// The events that mean Clawd started something by himself or reacted.
    private static func starts(_ events: ArraySlice<Logged>) -> [SchedulerEvent] {
        events.map(\.event).filter {
            switch $0 {
            case .motionStart, .walkStart, .lookTransition, .touch, .multiTouch, .sleepStart: return true
            default: return false
            }
        }
    }
    private static func isWalking(_ rig: SchedulerRig) -> Bool {
        let frame = rig.frame
        return frame.playback?.use == "walk" || frame.playback?.use == "walk-pause" || frame.walkOffset != 0
    }

    /// What Clawd shows, for "nothing changed while the menu was open".
    private struct Shown: Equatable {
        var motion: String?; var offset: Double; var look: String; var displayed: String; var asleep: Bool; var transition: Double?
        init(_ frame: SchedulerFrame) {
            motion = frame.playback.map { $0.motionID ?? "\($0.source)" }
            offset = frame.walkOffset; look = frame.look; displayed = frame.displayedLook; asleep = frame.asleep; transition = frame.transitionProgress
        }
    }

    /// Opens the menu at random moments over simulated days and checks what R-HOLD says. Returns how many openings it made.
    private static func hold(seed: UInt64, days: Int, guards: SchedulerGuards = .all) -> (openings: Int, violations: [String]) {
        let rig = SchedulerRig(settings: lively(), seed: seed, guards: guards)
        rig.inputIdle = nil                       // SLEEP by real idle time, so the menu also opens over a sleeping Clawd
        let driver = SeededRandom(seed: seed &* 7919)
        var violations: [String] = []
        var openings = 0
        let end = rig.now + Double(days) * 86_400
        while rig.now < end, !rig.runaway {
            rig.advance(20 + driver.unit() * 880)
            let walking = isWalking(rig), offsetBefore = rig.frame.walkOffset
            guard rig.scheduler.menuOpened() else { continue }
            openings += 1
            rig.touchInput()                       // the right-click is input
            let atOpen = Shown(rig.frame), eventsAtOpen = rig.events.count
            if atOpen.motion != nil { violations.append("seed \(seed): something still plays right after the open: \(atOpen)") }
            if walking && abs(atOpen.offset - offsetBefore) > 1e-6 { violations.append("seed \(seed): a walk did not stop where it stood: \(offsetBefore) -> \(atOpen.offset)") }
            // Open for a random while, with a dictation-free, drag-free world and a click now and then: nothing may start or change.
            let stay = 5 + driver.unit() * 1500
            rig.advance(stay / 2)
            rig.scheduler.click(); rig.scheduler.click(); rig.scheduler.click()
            rig.advance(stay / 2)
            let started = starts(rig.events[eventsAtOpen...])
            if !started.isEmpty { violations.append("seed \(seed): \(started) started while the menu was open") }
            let after = Shown(rig.frame)
            if after != atOpen { violations.append("seed \(seed): the picture changed while the menu was open: \(atOpen) -> \(after)") }
            if rig.scheduler.nextWake != nil { violations.append("seed \(seed): a wake is armed while the menu is open") }
            rig.scheduler.menuClosed()
            if rig.scheduler.menuOpen { violations.append("menuOpen is still set after menuClosed()") }
            // A walk the menu stopped away from home goes home at once afterwards.
            if walking, abs(atOpen.offset) > 1e-6, rig.frame.playback?.use != "walk" { violations.append("seed \(seed): a stopped walk did not set off for home: \(rig.frame.playback as Any)") }
        }
        return (openings, violations)
    }

    @Test func Menu_holdsClawdStill() {
        var total = 0
        for seed in [1, 2, 3, 4, 5, 6] as [UInt64] {
            let result = Self.hold(seed: seed, days: 3)
            total += result.openings
            #expect(result.violations.isEmpty, "\(result.violations.prefix(3))")
        }
        #expect(total > 150, "the scenario opened the menu at many moments: \(total)")
        // Negative control: without the hold the same scenario breaks the expectation.
        let broken = Self.hold(seed: 1, days: 3, guards: SchedulerGuards.all.subtracting(.menuHold))
        negativeControl("menu-hold-removed", expectationHolds: broken.violations.isEmpty)
    }

    @Test func Menu_aMenuCannotOpenOverADictationSceneADragOrAQuietCondition() {
        let rig = SchedulerRig(settings: SchedulerFixture.settings { $0.motion = .off })
        rig.start()
        #expect(rig.scheduler.sceneActive)
        #expect(!rig.scheduler.menuOpened() && !rig.scheduler.menuOpen, "a dictation outranks the menu")
        rig.cancel(); rig.advance(3)
        rig.scheduler.dragStarted()
        #expect(!rig.scheduler.menuOpened() && !rig.scheduler.menuOpen, "a drag outranks the menu")
        rig.scheduler.dragEnded()
        rig.advance(3)
        #expect(rig.scheduler.menuOpened(), "at rest it opens")
        #expect(!rig.scheduler.menuOpened(), "and a second open is refused")
        rig.scheduler.menuClosed()
        rig.scheduler.setQuiet(.screenLocked, active: true)
        #expect(!rig.scheduler.menuOpened(), "a quiet condition outranks the menu")
    }

    @Test func Menu_aHigherStateThatStartsWhileItIsOpenEndsTheHold() {
        let rig = SchedulerRig(settings: SchedulerFixture.settings { $0.motion = .off })
        #expect(rig.scheduler.menuOpened())
        rig.start()
        #expect(!rig.scheduler.menuOpen, "a dictation scene ends the hold (the host closes the menu in the same batch)")
        rig.cancel(); rig.advance(5)
        #expect(rig.scheduler.menuOpened())
        rig.scheduler.dragStarted()
        #expect(!rig.scheduler.menuOpen && rig.scheduler.isDragging)
        rig.scheduler.dragCancelled()
        rig.advance(3)
        #expect(rig.scheduler.menuOpened())
        rig.scheduler.setQuiet(.systemAsleep, active: true)
        #expect(!rig.scheduler.menuOpen, "hiding or a quiet condition ends it too")
    }

    @Test func Menu_aWalkStopsWhereItStandsAndGoesHomeAfterTheClose() throws {
        let rig = SchedulerRig(settings: Self.lively(), seed: 11)
        let walking = rig.run(upTo: 8 * 3600) { rig.frame.playback?.use == "walk" && rig.frame.walkOffset != 0 }
        try #require(walking, "a walk started")
        let offset = rig.frame.walkOffset
        #expect(rig.scheduler.menuOpened())
        #expect(rig.frame.playback == nil && abs(rig.frame.walkOffset - offset) < 1e-9, "Clawd stands in the rest pose where he was")
        rig.advance(120)
        #expect(abs(rig.frame.walkOffset - offset) < 1e-9 && rig.frame.playback == nil, "and stays there for as long as the menu is open")
        rig.scheduler.menuClosed()
        #expect(rig.frame.playback?.use == "walk", "he sets off for home at once")
        #expect(rig.run(upTo: 120) { rig.frame.walkOffset == 0 && rig.frame.playback == nil }, "and gets there")
        #expect(rig.events.contains { if case .walkEnd = $0.event { return true } else { return false } })
    }

    @Test func Menu_aMotionEndsAtTheRestPoseOfTheLookWorn() throws {
        let rig = SchedulerRig(settings: Self.lively(walk: false), seed: 3)
        let playing = rig.run(upTo: 8 * 3600) { rig.frame.playback?.motionID != nil }
        try #require(playing)
        #expect(rig.scheduler.menuOpened() && rig.frame.playback == nil, "the motion ended at once")
        #expect(rig.events.contains { if case .motionEnd = $0.event { return true } else { return false } })
    }

    @Test func Menu_aLookTransitionKeepsTheLookItHasReached() throws {
        func rig() -> SchedulerRig { SchedulerRig(settings: SchedulerFixture.settings { $0.motion = .off; $0.lookEveryHours = 2 }, seed: 5) }
        let before = rig()
        let started = before.run(upTo: 6 * 3600) { before.frame.transitionProgress != nil }
        try #require(started)
        let from = before.frame.look
        #expect(before.scheduler.menuOpened())
        #expect(before.frame.transitionProgress == nil && before.frame.look == from && before.frame.displayedLook == from, "cut before the swap: the old look")
        let after = rig()
        _ = after.run(upTo: 6 * 3600) { after.frame.transitionProgress != nil }
        after.advance(1.0)
        #expect(after.frame.transitionProgress != nil && after.frame.look != from, "the swap has happened")
        let reached = after.frame.look
        #expect(after.scheduler.menuOpened())
        #expect(after.frame.transitionProgress == nil && after.frame.look == reached && after.frame.displayedLook == reached, "cut after the swap: the new look")
    }

    @Test func Menu_aSleepingClawdWakesAndStaysAwakeWhileItIsOpen() throws {
        let rig = SchedulerRig(settings: SchedulerFixture.settings { $0.motion = .off })
        rig.inputIdle = nil
        rig.advance(700)
        #expect(rig.frame.asleep, "ten minutes without input: asleep")
        let sleeps = rig.events.filter { $0.event == .sleepStart }.count
        #expect(rig.scheduler.menuOpened())
        #expect(!rig.frame.asleep)
        rig.advance(3600)
        #expect(!rig.frame.asleep && rig.events.filter { $0.event == .sleepStart }.count == sleeps, "no sleep entry while the menu is open")
        rig.scheduler.menuClosed()
    }
}

@Suite("MenuTests settings and quit rows", .serialized)
@MainActor
struct MenuTestsSettingsAndQuit {
    @Test func MenuRules_settingsAndQuitRunAtTheFlashClose() throws {
        let rig = try MenuRig()
        // Settings…: picked on a mouse-down, held, and run only at the 140 ms flash's close.
        rig.open()
        try rig.click(rig.item("settings", "open"), time: 6)
        #expect(rig.lines("MENU pick").last?.hasPrefix("MENU pick id=1 et=6.000000 key=settings value=open gen=1") == true, "\(rig.menuLines)")
        #expect(rig.host.settingsOpens.isEmpty && rig.controller.isOpen, "not before the flash close")
        rig.advance(0.2)
        #expect(rig.host.settingsOpens == [6] && !rig.controller.isOpen && rig.host.quits == 0, "\(rig.menuLines)")
        // The menu's window is gone before Settings opens.
        let order = rig.lines.filter { $0.hasPrefix("(host)") }
        #expect(order.suffix(2) == ["(host) hide render=true", "(host) settings open"], "\(order)")
        // Quit Clawd: the same.
        rig.open()
        try rig.click(rig.item("quit", "quit"), time: 8)
        #expect(rig.host.quits == 0)
        rig.advance(0.2)
        #expect(rig.host.quits == 1 && rig.host.settingsOpens == [6])
        // A held pick is dropped on any close but the flash's, and the line says so.
        for (reason, close) in [("outside", { (c: MenuController) in c.close(.outside, et: 9) }), ("toggle", { c in c.close(.toggle, et: 9) }),
                                ("hidden", { c in c.close(.hidden, render: false) }), ("away", { c in c.close(.away) })] as [(String, (MenuController) -> Void)] {
            let quits = rig.host.quits, opens = rig.host.settingsOpens.count
            rig.open()
            let gen = rig.controller.liveGeneration ?? 0
            try rig.click(rig.item("settings", "open"))
            close(rig.controller)
            #expect(rig.host.settingsOpens.count == opens && rig.lines("MENU settings-dropped reason=\(reason) gen=\(gen)").count == 1, "\(reason): \(rig.menuLines)")
            rig.open()
            let quitGen = rig.controller.liveGeneration ?? 0
            try rig.click(rig.item("quit", "quit"))
            close(rig.controller)
            #expect(rig.host.quits == quits && rig.lines("MENU quit-dropped reason=\(reason) gen=\(quitGen)").count == 1, "\(reason): \(rig.menuLines)")
        }
    }
}
