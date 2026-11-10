import Testing
import Foundation
import AppKit
import ClawdCore
import ClawdRendering
import ClawdDesktop

// The menu inside the real AgentRuntime: the real scheduler, stage, panel set and view, driven with synthetic events and fake displays. The
// panels are never ordered on screen (`present` only counts), the outside-click source and the timer are fakes, and the CLI the menu runs is
// a stub in a temporary HOME.

@MainActor
private struct MenuRuntimeRig {
    let rig: RuntimeRig
    let timer: MenuFakeTimer
    let source: MenuFakeSource
    let stub: MenuStubHome

    init(control: [String: Any]? = nil) throws {
        let timer = MenuFakeTimer(clock: SystemPetClock()), source = MenuFakeSource(), stub = try MenuStubHome()
        self.timer = timer; self.source = source; self.stub = stub
        rig = try RuntimeRig(control: control, prepare: { machine in machine.menuTimer = timer; machine.menuSource = source; machine.home = stub.root })
    }
    var runtime: AgentRuntime { rig.runtime }
    var panels: PanelSet { rig.runtime.panels }
    var scheduler: PetScheduler { rig.stage.scheduler }
    var lines: [String] { rig.log.split(separator: "\n").map { String($0.drop { $0 != " " }.dropFirst()) } }
    func lines(_ prefix: String) -> [String] { lines.filter { menuLineHasPrefix($0, prefix) } }
    func index(_ prefix: String, last: Bool = false) -> Int? { last ? lines.lastIndex { $0.hasPrefix(prefix) } : lines.firstIndex { $0.hasPrefix(prefix) } }

    func bodyPoint() throws -> CGPoint { try rig.points().body }
    func menuEvent(_ type: NSEvent.EventType, at windowPoint: CGPoint, flags: NSEvent.ModifierFlags = [], time: TimeInterval = 0,
                   clicks: Int = 1) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: windowPoint, modifierFlags: flags, timestamp: time, windowNumber: 0, context: nil,
                                        eventNumber: 0, clickCount: clicks, pressure: 1))
    }
    /// A left mouse-down on Clawd's body at `down` (and, with `up`, its button-up at that time), as the body window's view gets them.
    func leftPress(down: TimeInterval, up: TimeInterval? = nil, clicks: Int = 1) throws {
        let point = try bodyPoint()
        rig.machine.pointer = point
        rig.view.mouseDown(with: try menuEvent(.leftMouseDown, at: rig.window(point), time: down, clicks: clicks))
        if let up { try leftRelease(at: up) }
    }
    func leftRelease(at time: TimeInterval) throws {
        rig.view.mouseUp(with: try menuEvent(.leftMouseUp, at: rig.window(try bodyPoint()), time: time))
    }
    func rightClick(time: TimeInterval = 4.5) throws {
        let point = try bodyPoint()
        rig.machine.pointer = point
        rig.view.rightMouseDown(with: try menuEvent(.rightMouseDown, at: rig.window(point), time: time))
    }
    func controlClick(time: TimeInterval = 4.5) throws {
        let point = try bodyPoint()
        rig.machine.pointer = point
        rig.view.mouseDown(with: try menuEvent(.leftMouseDown, at: rig.window(point), flags: [.control], time: time))
    }
    /// A mouse-down on one item of the open menu's window, at the item's middle.
    func clickItem(_ key: String, _ value: String, time: TimeInterval = 5.5) throws {
        let view = try #require(panels.menu?.menuView)
        let item = menuItem(view.layout, key, value)
        let point = CGPoint(x: item.rect.midX, y: view.bounds.height - item.rect.midY)
        view.mouseDown(with: try menuEvent(.leftMouseDown, at: point, time: time))
    }
    var menuRect: CGRect? { rig.stage.lastFrame?.layout.menuRect }

    /// A display change as the system makes it: the fake display is replaced, then the REAL notification is posted on the default center,
    /// so the runtime's own observer runs (amendment R-GEOM: a `scale` write never stands in for this).
    func changeDisplay(width: Double = 1440, height: Double = 900, dock: Double = 25) {
        rig.machine.display = DisplayInfo(uuid: "D", frame: CGRect(x: 0, y: 0, width: width, height: height),
                                          visibleFrame: CGRect(x: 0, y: dock, width: width, height: height - dock), backingScaleFactor: 2)
        postDisplayChange()
    }
    func postDisplayChange() { NotificationCenter.default.post(name: NSApplication.didChangeScreenParametersNotification, object: nil) }
    func geomLineIndices() -> [Int] { lines.indices.filter { lines[$0].hasPrefix("GEOM") } }
}

@Suite("MenuTests runtime", .serialized)
@MainActor
struct MenuTestsRuntime {
    // MARK: opening

    @Test func Menu_aRightClickOnClawdOpensTheMenuWindowBesideHimWhichTakesClicksWhileTheRestStillPassesThrough() throws {
        let r = try MenuRuntimeRig()
        let frame0 = try #require(r.rig.stage.lastFrame)
        try r.rightClick(time: 4.5)
        let menu = try #require(r.panels.menu)
        let frame = try #require(r.rig.stage.lastFrame)
        #expect(menu.gen == 1 && r.scheduler.menuOpen)
        #expect(menu.frame == frame.layout.menuRect && menu.frame.size == CGSize(width: 236, height: 335))
        #expect(menu.frame.minX == frame.canvas.maxX + 8, "to the right of Clawd's canvas with an 8 pt gap")
        // Ruling 4: vertically centred on Clawd's canvas, then kept 8 pt inside the visible frame (Clawd stands low on the screen, so the margin wins here).
        let visible = r.rig.machine.display.visibleFrame
        let centredY = frame.canvas.midY - menu.frame.height / 2
        let wantY = min(max(centredY, visible.minY + 8), visible.maxY - 8 - menu.frame.height).rounded()
        #expect(menu.frame.minY == wantY, "centred on him (wanted y \(wantY), canvas midY \(frame.canvas.midY), visible \(visible))")
        #expect(abs(menu.frame.midY - frame.canvas.midY) <= 0.5 || menu.frame.minY == visible.minY + 8 || menu.frame.maxY == visible.maxY - 8, "centred unless the margin moved it")
        #expect(r.rig.machine.display.visibleFrame.insetBy(dx: 8, dy: 8).contains(menu.frame), "inside the visible frame with an 8 pt margin")
        #expect(!menu.ignoresMouseEvents && !menu.isKeyWindow && !menu.canBecomeKey && !menu.canBecomeMain && !menu.isVisible, "takes clicks, never key, never shown here")
        #expect(r.panels.violations() == [] && FocusAudit.violations(of: menu) == [], "\(r.panels.violations())")
        // which window takes a click where
        let centre = CGPoint(x: menu.frame.midX, y: menu.frame.midY)
        #expect(r.rig.takers(at: centre) == ["menu"], "an item takes the click")
        #expect(r.rig.takers(at: try r.bodyPoint()) == ["body"], "Clawd still takes his own")
        #expect(r.rig.takers(at: CGPoint(x: frame.canvas.maxX + 4, y: menu.frame.midY)).isEmpty, "the 8 pt gap between them passes through")
        #expect(r.rig.takers(at: CGPoint(x: menu.frame.maxX + 3, y: menu.frame.midY)).isEmpty && r.rig.takers(at: CGPoint(x: menu.frame.midX, y: menu.frame.maxY + 3)).isEmpty)
        #expect(frame.hit.contains(centre) && !frame.hit.containsBody(centre), "the menu's rectangle is part of the hit region only while it is open")
        #expect(frame.hit.bounds == frame0.hit.bounds, "and Clawd's body does not move")
        #expect(frame.canvas == frame0.canvas, "Clawd stays where he was")
        // no INPUT or MOUSE-IGNORED line: the open line is the delivery line
        #expect(r.lines("INPUT").isEmpty && r.lines("MOUSE-IGNORED").isEmpty)
        #expect(r.lines("MENU open") == ["MENU open et=4.500000 how=right gen=1"])
    }

    @Test func Menu_theGeometryLineThatShowsTheMenuNamesItsBodyItsRectangleAndItsOpeningAndComesBeforeTheOpenLine() throws {
        let r = try MenuRuntimeRig()
        try r.rightClick()
        let geom = try #require(r.lines("GEOM").last)
        let frame = try #require(r.rig.stage.lastFrame), menu = try #require(frame.layout.menuRect), body = try #require(frame.hit.bounds)
        func text(_ rect: CGRect) -> String { String(format: "%.1f,%.1f,%.1f,%.1f", rect.minX, rect.minY, rect.width, rect.height) }
        #expect(geom.contains(" body=\(text(body)) "), "\(geom)")
        #expect(geom.contains(" menu=\(text(menu)) menugen=1"), "\(geom)")
        #expect(geom.contains(" hit=\(text(body.union(menu))) "), "hit is the union: \(geom)")
        #expect(try #require(r.index("GEOM", last: true)) < #require(r.index("MENU open")), "GEOM first, then MENU open")
        // with it closed again the line says so
        try r.rightClick(time: 6.25)
        let closed = try #require(r.lines("GEOM").last)
        #expect(closed.hasSuffix(" menu=none menugen=none chat=none chatgen=none") && closed.contains(" body="), "\(closed)")
        #expect(try #require(r.index("MENU close")) < #require(r.index("GEOM", last: true)), "MENU close before the GEOM line that removes the window")
        #expect(r.lines("MENU close") == ["MENU close reason=toggle et=6.250000 gen=1"])
        #expect(r.panels.menu == nil && r.rig.stage.menuRect == nil && !r.scheduler.menuOpen, "the window is dropped, the rectangle and the hold are gone")
    }

    @Test func Menu_aControlClickOpensTheMenuAndNeverStartsAPressOrADrag() throws {
        let r = try MenuRuntimeRig()
        let home = try r.rig.state.position
        try r.controlClick(time: 3.5)
        #expect(r.panels.menu?.gen == 1 && r.lines("MENU open") == ["MENU open et=3.500000 how=control gen=1"])
        let point = try r.bodyPoint()
        // what a press would continue with: a drag and the release. None of it is a press.
        r.rig.view.mouseDragged(with: try r.menuEvent(.leftMouseDragged, at: r.rig.window(point)))
        r.rig.machine.pointer = CGPoint(x: point.x + 60, y: point.y + 30)
        r.rig.view.mouseDragged(with: try r.menuEvent(.leftMouseDragged, at: r.rig.window(point)))
        r.rig.view.mouseUp(with: try r.menuEvent(.leftMouseUp, at: r.rig.window(point)))
        #expect(r.lines("INPUT").isEmpty, "no press began: \(r.lines("INPUT"))")
        #expect(!r.scheduler.isDragging && r.lines("TOUCH").isEmpty && r.panels.menu != nil, "no drag, no touch reaction, the menu is still open")
        #expect(try r.rig.state.position == home, "Clawd's home is the same")
        #expect(r.lines("MOUSE-IGNORED").allSatisfy { $0.contains("why=untracked") }, "the loose drag and up are logged as ignored: \(r.lines("MOUSE-IGNORED"))")
    }

    @Test func Menu_aRightClickOnATransparentPixelOrWhileADictationRunsIsLoggedAsIgnoredAndOpensNothing() throws {
        let r = try MenuRuntimeRig()
        let clear = try r.rig.points().clear
        r.rig.view.rightMouseDown(with: try r.menuEvent(.rightMouseDown, at: r.rig.window(clear), time: 2.5))
        #expect(r.panels.menu == nil && r.lines("MOUSE-IGNORED").last?.contains("kind=rightMouseDown") == true)
        #expect(r.lines("MOUSE-IGNORED").last?.hasSuffix("why=transparent et=2.500000") == true, "\(r.lines("MOUSE-IGNORED"))")
        // a dictation scene holds: the right-click is refused with why=busy, and it takes no number
        r.rig.runtime.controller.receive(line: startLine(SystemPetClock()).trimmingCharacters(in: .newlines))
        #expect(r.scheduler.sceneActive)
        try r.rightClick(time: 3.5)
        #expect(r.panels.menu == nil && !r.scheduler.menuOpen)
        #expect(r.lines("MOUSE-IGNORED").last?.contains("kind=rightMouseDown") == true && r.lines("MOUSE-IGNORED").last?.hasSuffix("why=busy et=3.500000") == true,
                "\(r.lines("MOUSE-IGNORED"))")
        #expect(r.lines("MENU").isEmpty && r.source.installs == 0 && r.timer.armCount == 0, "nothing was opened, installed or armed")
    }

    @Test func Menu_aRightClickDuringADragIsRefusedAndTheDragGoesOn() throws {
        let r = try MenuRuntimeRig()
        let point = try r.bodyPoint()
        r.rig.machine.pointer = point
        r.rig.view.mouseDown(with: try r.menuEvent(.leftMouseDown, at: r.rig.window(point)))
        r.rig.machine.pointer = CGPoint(x: point.x + 50, y: point.y + 5)
        r.rig.view.mouseDragged(with: try r.menuEvent(.leftMouseDragged, at: r.rig.window(point)))
        #expect(r.scheduler.isDragging)
        let moved = try r.bodyPoint()                       // Clawd is under the pointer in his new place
        r.rig.view.rightMouseDown(with: try r.menuEvent(.rightMouseDown, at: r.rig.window(moved), time: 8.5))
        #expect(r.panels.menu == nil && r.scheduler.isDragging && r.lines("MENU").isEmpty)
        #expect(r.lines("MOUSE-IGNORED").last?.hasSuffix("et=8.500000") == true, "\(r.lines("MOUSE-IGNORED"))")
    }

    // MARK: closing

    @Test func Menu_aMouseDownOutsideClosesItAndDropsItsWindowAndAnEarlyTimerChangesNothing() throws {
        // outside
        let a = try MenuRuntimeRig()
        try a.rightClick()
        #expect(a.source.live == 1)
        a.source.deliver(to: 0, at: 9.5)
        #expect(a.lines("MENU close") == ["MENU close reason=outside et=9.500000 gen=1"])
        #expect(a.panels.menu == nil && !a.scheduler.menuOpen && a.source.live == 0 && a.rig.stage.menuRect == nil)
        // the next opening is a new window with the next number, and a late copy for the first changes nothing
        try a.rightClick(time: 10.5)
        #expect(a.panels.menu?.gen == 2 && a.lines("MENU open").last == "MENU open et=10.500000 how=right gen=2")
        a.source.deliver(to: 0, at: 10.6)
        #expect(a.panels.menu?.gen == 2 && a.lines("MENU close").count == 1, "the old opening's copy closes nothing")
        // away: the fake timer is the menu's only timer; real time passes, then it fires
        let b = try MenuRuntimeRig()
        try b.rightClick()
        #expect(b.timer.fireAt != nil, "the away deadline is armed while the menu is open")
        b.timer.onFire?()
        #expect(b.panels.menu != nil, "fired early: nothing is due")
    }

    @Test func Menu_aDictationStartClosesItInTheBatchThatStartsTheSceneSoOnePictureShowsBothChanges() throws {
        let r = try MenuRuntimeRig()
        try r.rightClick()
        let renders = r.rig.stage.renderCount
        r.rig.runtime.controller.receive(line: startLine(SystemPetClock()).trimmingCharacters(in: .newlines))
        #expect(r.lines("MENU close") == ["MENU close reason=dictation gen=1"])
        #expect(r.panels.menu == nil && !r.scheduler.menuOpen && r.scheduler.sceneActive && r.rig.stage.menuRect == nil)
        let frame = try #require(r.rig.stage.lastFrame)
        #expect(frame.layout.menuRect == nil && frame.bubble != nil, "the bubble is shown and the menu is gone in the same picture")
        let geom = try #require(r.lines("GEOM").last)
        #expect(!geom.contains("bubble=none") && geom.hasSuffix("menu=none menugen=none chat=none chatgen=none"), "\(geom)")
        #expect(try #require(r.index("MENU close")) < #require(r.index("GEOM", last: true)))
        #expect(r.rig.stage.renderCount <= renders + 2, "the close and the scene did not each draw a picture of their own: \(r.rig.stage.renderCount - renders)")
        #expect(r.source.live == 0)
    }

    @Test func Menu_theStartOfADragClosesItAndLeavesTheDragRunning() throws {
        let r = try MenuRuntimeRig()
        try r.rightClick()
        let point = try r.bodyPoint()
        r.rig.machine.pointer = point
        r.rig.view.mouseDown(with: try r.menuEvent(.leftMouseDown, at: r.rig.window(point), time: 7.5))
        #expect(r.panels.menu != nil && r.lines("MENU close").isEmpty, "a plain press on Clawd does not close it")
        #expect(r.lines("INPUT").count == 1 && r.lines("INPUT")[0].hasSuffix("et=7.500000"), "the press is an ordinary one: \(r.lines("INPUT"))")
        r.rig.machine.pointer = CGPoint(x: point.x + 40, y: point.y)
        r.rig.view.mouseDragged(with: try r.menuEvent(.leftMouseDragged, at: r.rig.window(point)))
        #expect(r.lines("MENU close") == ["MENU close reason=drag gen=1"])
        #expect(r.panels.menu == nil && r.scheduler.isDragging && !r.scheduler.menuOpen)
        r.rig.view.mouseUp(with: try r.menuEvent(.leftMouseUp, at: r.rig.window(point)))
        #expect(!r.scheduler.isDragging)
    }

    // MARK: a click on Clawd's body while the menu is open (amendment R-BODY)

    @Test func Menu_bodyClick1_aLeftPressReleasedOnClawdWithoutMovingClosesTheMenuItBeganUnderAndIsNoTouch() throws {
        let r = try MenuRuntimeRig()
        try r.rightClick(time: 4.5)
        try r.leftPress(down: 7.25, up: 7.5)
        #expect(r.lines("MENU close") == ["MENU close reason=toggle et=7.250000 gen=1"], "one close, with the mouse-down's time stamp: \(r.lines("MENU"))")
        #expect(r.panels.menu == nil && !r.scheduler.menuOpen && r.source.live == 0 && r.rig.stage.menuRect == nil, "the hold ended and the window is gone")
        #expect(r.lines("TOUCH").isEmpty, "a press that began under the menu is never a touch: \(r.lines("TOUCH"))")
        #expect(r.lines("INPUT kind=mouseDown").count == 1 && r.lines("INPUT kind=mouseUp").count == 1, "both ends of the press are still logged")
        #expect(try #require(r.index("INPUT kind=mouseUp")) < #require(r.index("MENU close")), "the close is the release's")
    }

    @Test func Menu_bodyClick2_aPressThatDragsThreePointsOrMoreClosesTheMenuAsADragAndTheDragGoesOn() throws {
        let r = try MenuRuntimeRig()
        try r.rightClick()
        let point = try r.bodyPoint()
        try r.leftPress(down: 7.5)
        #expect(r.panels.menu != nil && r.lines("MENU close").isEmpty, "the mouse-down alone closes nothing")
        r.rig.machine.pointer = CGPoint(x: point.x + 3, y: point.y)
        r.rig.view.mouseDragged(with: try r.menuEvent(.leftMouseDragged, at: r.rig.window(point)))
        #expect(r.lines("MENU close") == ["MENU close reason=drag gen=1"])
        #expect(r.scheduler.isDragging && r.panels.menu == nil && !r.scheduler.menuOpen)
        try r.leftRelease(at: 8.5)
        #expect(!r.scheduler.isDragging && r.lines("MENU close").count == 1 && r.lines("TOUCH").isEmpty, "the release lands the drag: no second close, no touch")
    }

    @Test func Menu_bodyClick3_aMenuThatClosedByAnotherPathDuringThePressLeavesTheReleaseNoCloseAndNoTouch() throws {
        // Closed by a dictation start while the left button is down (not by the 8 s away rule, whose run on the real clock would put 8.3 s of
        // waiting into the suite: the property is "closed by a path other than the press").
        let r = try MenuRuntimeRig()
        try r.rightClick()
        try r.leftPress(down: 6.5)
        r.rig.runtime.controller.receive(line: startLine(SystemPetClock()).trimmingCharacters(in: .newlines))
        #expect(r.lines("MENU close") == ["MENU close reason=dictation gen=1"] && r.panels.menu == nil, "premise: gen 1 closed by the dictation start")
        try r.leftRelease(at: 15)
        #expect(r.lines("MENU close") == ["MENU close reason=dictation gen=1"], "the release closes nothing more: \(r.lines("MENU"))")
        #expect(r.lines("TOUCH").isEmpty, "and it is no touch: a press that began under a menu never becomes one: \(r.lines("TOUCH"))")
        // The same with a hide: the press is lost with the window (cancelPress), so its release is not tracked and closes and touches nothing.
        let h = try MenuRuntimeRig()
        try h.rightClick()
        let bodyWindowPoint = h.rig.window(try h.bodyPoint())
        try h.leftPress(down: 6.5)
        h.rig.stage.apply(settings: { var s = h.rig.stage.settings; s.hiddenUntil = -1; return s }())
        #expect(h.lines("MENU close") == ["MENU close reason=hidden gen=1"] && h.panels.menu == nil, "premise: gen 1 closed by the hide")
        h.rig.view.mouseUp(with: try h.menuEvent(.leftMouseUp, at: bodyWindowPoint, time: 15))     // nothing is on screen to take a body point from
        #expect(h.lines("MENU close") == ["MENU close reason=hidden gen=1"], "the release closes nothing more: \(h.lines("MENU"))")
        #expect(h.lines("TOUCH").isEmpty, "and it is no touch: \(h.lines("TOUCH"))")
        // And by a second right-click during the press. A dictation scene and a hide would swallow a touch anyway (the scene ignores a click, the
        // hidden view tracks no release), so this case is the one in which Clawd is idle and visible afterwards: a release that fell through to
        // `scheduler.click()` would show as a TOUCH here (negative-control row rbody-release-of-a-closed-openings-press-is-a-touch).
        let t = try MenuRuntimeRig()
        try t.rightClick(time: 4.5)
        try t.leftPress(down: 5.5)
        try t.rightClick(time: 6.5)
        #expect(t.lines("MENU close") == ["MENU close reason=toggle et=6.500000 gen=1"] && t.panels.menu == nil && !t.scheduler.menuOpen, "premise: gen 1 closed by the right-click")
        try t.leftRelease(at: 7.5)
        #expect(t.lines("MENU close") == ["MENU close reason=toggle et=6.500000 gen=1"], "the release closes nothing more: \(t.lines("MENU"))")
        #expect(t.lines("TOUCH").isEmpty, "and it is no touch: \(t.lines("TOUCH"))")
    }

    @Test func Menu_bodyClick4_aPressReleasedAfterANewerOpeningLeavesTheNewerOpeningOpen() throws {
        let r = try MenuRuntimeRig()
        try r.rightClick(time: 4.5)                                 // gen 1
        try r.leftPress(down: 5.5)
        try r.rightClick(time: 6.5)                                 // a second right-click: closes gen 1
        try r.rightClick(time: 7.5)                                 // and a third opens gen 2
        #expect(r.panels.menu?.gen == 2 && r.lines("MENU open").last == "MENU open et=7.500000 how=right gen=2")
        try r.leftRelease(at: 8.5)
        #expect(r.lines("MENU close") == ["MENU close reason=toggle et=6.500000 gen=1"], "no close line names gen 2: \(r.lines("MENU"))")
        #expect(r.panels.menu?.gen == 2 && r.scheduler.menuOpen, "gen 2 stays open")
        #expect(r.lines("TOUCH").isEmpty, "and the release is no touch")
    }

    @Test func Menu_bodyClick5_aPressBeganWithNoMenuAndAMenuOpenedDuringItLeavesTheMenuOpenAndMakesNoTouch() throws {
        let r = try MenuRuntimeRig()
        try r.leftPress(down: 5.5)
        try r.rightClick(time: 6.5)
        #expect(r.panels.menu?.gen == 1, "a right-click while the left button is held opens the menu")
        try r.leftRelease(at: 7.5)
        #expect(r.lines("MENU close").isEmpty && r.panels.menu?.gen == 1 && r.scheduler.menuOpen, "the down came before the menu existed: it stays open")
        #expect(r.lines("TOUCH").isEmpty, "and the hold gives no reaction")
    }

    @Test func Menu_bodyClick6_aRepeatedClickOnClawdClosesTheMenuAndIsNoTouch() throws {
        let r = try MenuRuntimeRig()
        try r.rightClick()
        try r.leftPress(down: 8.25, clicks: 2)
        let inputs = r.lines("INPUT kind=mouseDown")
        #expect(inputs.count == 1 && inputs[0].hasSuffix("et=8.250000"), "its INPUT line as before: \(inputs)")
        #expect(r.lines("MENU close") == ["MENU close reason=toggle et=8.250000 gen=1"])
        #expect(r.panels.menu == nil && !r.scheduler.menuOpen && r.lines("TOUCH").isEmpty, "no touch, no multi-touch: \(r.lines("TOUCH"))")
        #expect(try #require(r.index("INPUT kind=mouseDown")) < #require(r.index("MENU close")), "the INPUT line first")
    }

    @Test func Menu_bodyClick7_aMiddleClickOnClawdAndAMouseDownOnATransparentPixelEachCloseTheMenuAfterTheirIgnoredLine() throws {
        let r = try MenuRuntimeRig()
        try r.rightClick()
        let point = try r.bodyPoint()
        r.rig.view.otherMouseDown(with: try r.menuEvent(.otherMouseDown, at: r.rig.window(point), time: 9.5))
        let ignored = r.lines("MOUSE-IGNORED")
        #expect(ignored.count == 1 && ignored[0].hasPrefix("MOUSE-IGNORED kind=otherMouseDown") && ignored[0].hasSuffix("why=unused et=9.500000"), "\(ignored)")
        #expect(r.lines("MENU close") == ["MENU close reason=toggle et=9.500000 gen=1"] && r.panels.menu == nil)
        #expect(try #require(r.index("MOUSE-IGNORED")) < #require(r.index("MENU close")), "its ignored line first")
        // a second click count on a transparent pixel of the body window is ignored too (why=clickcount) and closes the menu as well
        let t = try MenuRuntimeRig()
        try t.rightClick()
        let clear = try t.rig.points().clear
        t.rig.view.mouseDown(with: try t.menuEvent(.leftMouseDown, at: t.rig.window(clear), time: 10.5, clicks: 2))
        let second = t.lines("MOUSE-IGNORED")
        #expect(second.count == 1 && second[0].hasPrefix("MOUSE-IGNORED kind=mouseDown") && second[0].hasSuffix("why=clickcount et=10.500000"), "\(second)")
        #expect(t.lines("MENU close") == ["MENU close reason=toggle et=10.500000 gen=1"] && t.panels.menu == nil)
    }

    @Test func Menu_bodyClick8_anIgnoredMouseUpAnIgnoredDragAndAScrollCloseNothing() throws {
        let r = try MenuRuntimeRig()
        try r.rightClick()
        let at = r.rig.window(try r.bodyPoint())
        r.rig.view.mouseUp(with: try r.menuEvent(.leftMouseUp, at: at))
        r.rig.view.mouseDragged(with: try r.menuEvent(.leftMouseDragged, at: at))
        let wheel = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 3, wheel2: 0, wheel3: 0))
        r.rig.view.scrollWheel(with: try #require(NSEvent(cgEvent: wheel)))
        let kinds = r.lines("MOUSE-IGNORED").compactMap { $0.split(separator: " ").dropFirst().first }
        #expect(kinds == ["kind=mouseUp", "kind=mouseDragged", "kind=scrollWheel"], "all three were received and ignored: \(r.lines("MOUSE-IGNORED"))")
        #expect(r.lines("MENU close").isEmpty && r.panels.menu?.gen == 1 && r.scheduler.menuOpen, "none of them closes the menu")
    }

    @Test func Menu_bodyClick9_withNoMenuOpenALeftClickIsATouchAsBefore() throws {
        let r = try MenuRuntimeRig()
        try r.rig.click(at: try r.bodyPoint())
        #expect(r.lines("TOUCH") == ["TOUCH"], "the control that the tests above can fail: \(r.lines("TOUCH"))")
        #expect(r.lines("MENU").isEmpty && r.panels.menu == nil)
    }

    @Test func Menu_hidingOrAQuietConditionClosesItWithoutDrawingAndItDoesNotComeBack() throws {
        let r = try MenuRuntimeRig()
        try r.rightClick()
        let dismissed = r.rig.machine.dismissed
        r.rig.stage.setQuiet(.screenLocked, active: true)
        #expect(r.lines("MENU close") == ["MENU close reason=hidden gen=1"])
        #expect(r.panels.menu == nil && r.rig.stage.menuRect == nil && !r.scheduler.menuOpen && r.source.live == 0)
        #expect(r.rig.machine.dismissed > dismissed, "the windows went")
        #expect(try #require(r.index("MENU close")) < #require(r.index("GEOM", last: true)) && r.lines("GEOM").last?.contains("hit=none body=none menu=none menugen=none chat=none chatgen=none") == true,
                "MENU close comes before the GEOM line of the hide: \(r.lines("GEOM").last ?? "")")
        r.rig.stage.setQuiet(.screenLocked, active: false)
        #expect(r.panels.menu == nil && r.rig.stage.lastFrame?.layout.menuRect == nil, "when Clawd is back the menu is not")
        // a timed hide ends it too
        let h = try MenuRuntimeRig()
        try h.rightClick()
        h.rig.stage.apply(settings: { var s = h.rig.stage.settings; s.hiddenUntil = -1; return s }())
        #expect(h.lines("MENU close") == ["MENU close reason=hidden gen=1"] && h.panels.menu == nil)
    }

    // MARK: the geometry changes under the open menu (amendment R-GEOM)

    @Test func Menu_geometryG1_aDisplayChangeWhileOpenClosesItWithReasonGeometryBeforeAnyPictureInTheNewGeometry() throws {
        let r = try MenuRuntimeRig()
        try r.rightClick()
        let view = try #require(r.panels.menu?.menuView)
        let canvasBefore = try #require(r.rig.stage.lastFrame).canvas
        let geomBefore = r.geomLineIndices().count
        #expect(r.timer.fireAt != nil && r.source.live == 1 && view.armed, "premise: the menu is open with its deadline, monitor and tracking areas")
        r.changeDisplay()
        #expect(r.lines("MENU close") == ["MENU close reason=geometry gen=1"], "exactly one close, with no et: \(r.lines("MENU"))")
        let closeAt = try #require(r.index("MENU close"))
        let geoms = r.geomLineIndices()
        #expect(geoms.count > geomBefore && geoms[geomBefore] > closeAt, "the close line comes before the next GEOM line (the first one drawn in the new geometry): close \(closeAt), geoms \(geoms)")
        #expect(try #require(r.rig.stage.lastFrame).canvas != canvasBefore, "premise: Clawd really moved to the new display")
        #expect(r.lines("GEOM").last?.hasSuffix("menu=none menugen=none chat=none chatgen=none") == true, "and that line has no menu: \(r.lines("GEOM").last ?? "")")
        #expect(!r.scheduler.menuOpen && r.panels.menu == nil && r.rig.stage.menuRect == nil)
        #expect(r.source.live == 0 && !view.armed && view.trackingAreas.isEmpty, "the outside-click token is removed and the tracking is disarmed")
        #expect(r.timer.fireAt == nil, "no deadline is left armed (the 8 s away rule cannot fire a second close)")
        r.timer.onFire?()
        #expect(r.lines("MENU close").count == 1, "a timer callback that was already queued closes nothing")
    }

    @Test func Menu_geometryG2_theSameNotificationWithTheDisplayUnchangedClosesNothing() throws {
        let r = try MenuRuntimeRig()
        try r.rightClick()
        let deadline = try #require(r.timer.fireAt)
        r.postDisplayChange()
        #expect(r.lines("MENU close").isEmpty && r.panels.menu?.gen == 1 && r.scheduler.menuOpen, "the menu is still open as gen 1: \(r.lines("MENU"))")
        #expect(r.timer.fireAt == deadline, "and its away deadline did not move")
        #expect(r.source.live == 1)
    }

    @Test func Menu_geometryG3_anAppliedSizeClosesItBeforeTheNewSizeIsDrawnAndAnAppliedWalkSettingDoesNot() async throws {
        let r = try MenuRuntimeRig()
        try r.rightClick()
        let geomBefore = r.geomLineIndices().count
        let sideBefore = try #require(r.rig.stage.lastFrame).canvas.width
        try writeControlLikeTheCLI(r.rig.store.root, ["scale": 2])
        await r.rig.spin(until: { (try? r.rig.status.appliedGeneration) == 1 })
        #expect(r.lines("MENU close") == ["MENU close reason=geometry gen=1"], "\(r.lines("MENU"))")
        let closeAt = try #require(r.index("MENU close"))
        let geoms = r.geomLineIndices()
        #expect(geoms.count > geomBefore && geoms[geomBefore] > closeAt, "the close line comes before the GEOM of the new size")
        #expect(try #require(r.rig.stage.lastFrame).canvas.width > sideBefore, "premise: the size changed")
        #expect(r.lines("GEOM").last?.hasSuffix("menu=none menugen=none chat=none chatgen=none") == true && r.panels.menu == nil && !r.scheduler.menuOpen)
        // A write that leaves the geometry as it was (walk off) closes nothing, and the menu shows it.
        try r.rightClick(time: 9)
        #expect(r.panels.menu?.gen == 2, "premise: opened again")
        try writeControlLikeTheCLI(r.rig.store.root, ["walk": false])
        await r.rig.spin(until: { (try? r.rig.status.appliedGeneration) == 2 })
        #expect(r.lines("MENU close") == ["MENU close reason=geometry gen=1"], "no second close: \(r.lines("MENU"))")
        #expect(r.panels.menu?.gen == 2 && r.scheduler.menuOpen, "still open")
        #expect(r.panels.menu?.menuView.visual.selection.walk == false, "and its selection shows walk off")
    }

    @Test func Menu_geometryG4_aMenuOpenedDuringAWalkClosesBeforeTheWalkEndsAndNoWalkStepIsDrawnUnderIt() async throws {
        final class Drawn { var rows: [(menu: Bool, offset: Double, use: String?)] = [] }
        let r = try MenuRuntimeRig(control: ["motion": "lively", "generation": 1])
        await r.rig.spin(until: { (try? r.rig.status.appliedGeneration) == 1 })
        // The idle slot is due now (random 0, no lower bound) and takes the walk (0 < the walk probability); the pointer is far from Clawd.
        r.rig.machine.pointer = CGPoint(x: 1900, y: 1000)
        r.scheduler.random = { 0 }
        r.scheduler.guards.remove(.idleLowerBound)
        r.rig.stage.apply(settings: { var s = r.rig.stage.settings; s.motion = .normal; return s }())
        await r.rig.spin(until: { !r.lines("WALK start").isEmpty }, limit: 10)
        try #require(!r.lines("WALK start").isEmpty, "premise: a walk started")
        let drawn = Drawn()
        let original = r.rig.stage.present
        r.rig.stage.present = { frame in
            let sample = r.rig.stage.lastRequest?.frame
            drawn.rows.append((frame.layout.menuRect != nil, sample?.walkOffset ?? 0, sample?.playback?.use))
            original(frame)
        }
        try r.rightClick()
        try #require(r.panels.menu?.gen == 1 && r.lines("WALK end").isEmpty, "premise: the menu opened during the walk")
        let standing = r.scheduler.frame().walkOffset
        await r.rig.spin(0.3)
        #expect(abs(r.scheduler.frame().walkOffset - standing) < 1e-9 && r.scheduler.frame().playback == nil, "the walk is frozen where it stood while the menu is open")
        r.changeDisplay()
        let close = try #require(r.index("MENU close")), end = try #require(r.index("WALK end"))
        #expect(r.lines("MENU close") == ["MENU close reason=geometry gen=1"] && close < end, "the close line comes before the walk's end line: close \(close), walk end \(end)")
        let under = drawn.rows.filter(\.menu)
        #expect(!under.isEmpty && under.allSatisfy { abs($0.offset - standing) < 1e-9 && $0.use != "walk" }, "no walk step was drawn while the menu window was on screen: \(under)")
        #expect(r.panels.menu == nil && !r.scheduler.menuOpen)
    }

    @Test func Menu_geometryG5_aSizePickInItsFlashIsSubmittedOnceWhenAGeometryChangeClosesTheMenuAndThenApplies() async throws {
        let r = try MenuRuntimeRig()
        try r.rightClick()
        try r.clickItem("size", "1.5", time: 5.5)
        #expect(r.lines("MENU pick") == ["MENU pick id=1 et=5.500000 key=size value=1.5 gen=1"] && r.panels.menu != nil, "premise: the pick is flashing")
        r.changeDisplay()
        #expect(r.lines("MENU close") == ["MENU close reason=geometry gen=1"], "one close, not a pick close: \(r.lines("MENU"))")
        #expect(r.panels.menu == nil && !r.scheduler.menuOpen && r.source.live == 0 && r.timer.fireAt == nil, "the teardown is complete")
        await r.rig.spin(until: { r.lines("MENU write").count == 1 }, limit: 30)
        #expect(r.stub.started == [["size", "1.5"]], "the pick's write was submitted once, as the CLI verb the user would type: \(r.stub.started)")
        r.timer.onFire?()
        #expect(r.lines("MENU close").count == 1, "no close line when the flash deadline passes")
        // Let the write apply, as the CLI would have made it: the new size is drawn, with no menu and no second close.
        let sideBefore = try #require(r.rig.stage.lastFrame).canvas.width
        try writeControlLikeTheCLI(r.rig.store.root, ["scale": 1.5])
        await r.rig.spin(until: { (try? r.rig.status.appliedGeneration) == 1 })
        let frame = try #require(r.rig.stage.lastFrame)
        #expect(abs(frame.canvas.width / sideBefore - 1.5) < 0.001, "Clawd has the new size: \(sideBefore) -> \(frame.canvas.width)")
        #expect(r.lines("GEOM").last?.hasSuffix("menu=none menugen=none chat=none chatgen=none") == true)
        #expect(r.lines("MENU close").count == 1 && r.lines("MENU pick").count == 1, "no second close, no second pick: \(r.lines("MENU"))")
        #expect(r.panels.menu == nil && !r.scheduler.menuOpen && r.source.live == 0, "the teardown is still complete")
    }

    @Test func Menu_geometryG6_twoGeometryChangesInARowCloseItOnce() throws {
        let r = try MenuRuntimeRig()
        try r.rightClick()
        r.changeDisplay(width: 1440, height: 900)
        r.changeDisplay(width: 1280, height: 800)
        #expect(r.lines("MENU close") == ["MENU close reason=geometry gen=1"], "\(r.lines("MENU"))")
        #expect(r.panels.menu == nil && !r.scheduler.menuOpen)
    }

    @Test func Menu_geometryG7_whenEveryDisplayIsGoneItClosesAsHiddenNeverAsGeometry() throws {
        let r = try MenuRuntimeRig()
        try r.rightClick()
        r.rig.machine.displaysGone = true
        r.postDisplayChange()
        #expect(r.lines("MENU close") == ["MENU close reason=hidden gen=1"], "\(r.lines("MENU"))")
        #expect(!r.scheduler.menuOpen && r.panels.menu == nil && r.source.live == 0)
    }

    // MARK: picking

    @Test func Menu_aPickFlashesThenClosesAndOnlyThenRunsTheInstalledCLIWithTheVerbTheUserWouldType() async throws {
        let r = try MenuRuntimeRig()
        try r.rightClick()
        try r.clickItem("look", "sunglasses", time: 5.5)
        #expect(r.lines("MENU pick") == ["MENU pick id=1 et=5.500000 key=look value=sunglasses gen=1"])
        let view = try #require(r.panels.menu?.menuView)
        #expect(view.visual.flashItem != nil && r.panels.menu != nil && r.timer.fireAt != nil)
        #expect(r.stub.started.isEmpty, "nothing runs while the menu is open")
        await r.rig.spin(0.2)
        r.timer.onFire?()
        #expect(r.panels.menu == nil && !r.scheduler.menuOpen)
        #expect(r.lines("MENU close") == ["MENU close reason=pick gen=1"])
        #expect(await menuWait { r.lines("MENU write").count == 1 })
        #expect(r.stub.started == [["look", "sunglasses"]])
        #expect(r.lines("MENU write") == ["MENU write id=1 key=look verb=look+sunglasses exit=0 gen=1"])
        let order = ["MENU open", "MENU pick", "MENU close", "MENU write"].compactMap { r.index($0) }
        #expect(order == order.sorted() && order.count == 4)
    }

    @Test func Menu_aSecondClickDuringTheFlashAndAClickOnAMutedChipArePickedByNobody() throws {
        let r = try MenuRuntimeRig()
        try r.rightClick()
        try r.clickItem("walk", "off", time: 5.5)
        try r.clickItem("motion", "lively", time: 5.55)
        #expect(r.lines("MENU pick").count == 1)
        #expect(r.lines("MOUSE-IGNORED").last?.hasSuffix("why=menu-flash et=5.550000 gen=1") == true)
        let m = try MenuRuntimeRig()
        try m.rightClick()
        let view = try #require(m.panels.menu?.menuView)
        let muted = view.layout.items.first { $0.key == "style" && !$0.clickable }
        if let muted {
            view.mouseDown(with: try m.menuEvent(.leftMouseDown, at: CGPoint(x: muted.rect.midX, y: view.bounds.height - muted.rect.midY), time: 3.5))
            #expect(m.lines("MENU pick").isEmpty && m.lines("MOUSE-IGNORED").last?.hasSuffix("why=menu-muted et=3.500000 gen=1") == true)
        }
        // a right-click on the menu is never a pick
        let item = menuItem(view.layout, "walk", "off")
        view.rightMouseDown(with: try m.menuEvent(.rightMouseDown, at: CGPoint(x: item.rect.midX, y: view.bounds.height - item.rect.midY), time: 4.5))
        #expect(m.lines("MENU pick").isEmpty && m.lines("MOUSE-IGNORED").last?.hasPrefix("MOUSE-IGNORED kind=rightMouseDown") == true)
    }

    @Test func Menu_aClickQueuedForTheClosedMenusWindowIsNeverAPickEvenWhenAnotherMenuIsOpen() throws {
        let r = try MenuRuntimeRig()
        try r.rightClick()
        let first = try #require(r.panels.menu), firstView = first.menuView
        r.source.deliver(to: 0, at: 6)                              // closes gen 1
        try r.rightClick(time: 7)                                   // gen 2: a new window
        let second = try #require(r.panels.menu)
        #expect(second !== first && second.gen == 2 && firstView.gen == 1)
        let item = menuItem(firstView.layout, "walk", "off")
        firstView.mouseDown(with: try r.menuEvent(.leftMouseDown, at: CGPoint(x: item.rect.midX, y: firstView.bounds.height - item.rect.midY), time: 7.1))
        #expect(r.lines("MENU pick").isEmpty && r.panels.menu === second, "no pick, no state change")
        #expect(r.lines("MOUSE-IGNORED").last?.hasSuffix("why=menu-stale et=7.100000 gen=1") == true, "it names the window it hit: \(r.lines("MOUSE-IGNORED"))")
        try r.clickItem("walk", "off", time: 7.2)
        #expect(r.lines("MENU pick") == ["MENU pick id=1 et=7.200000 key=walk value=off gen=2"], "the same click on the live window is a pick of gen 2")
    }

    // MARK: the truth, and the monitor and the tracking areas

    @Test func Menu_theWindowShowsTheSettingsTheAgentRunsWithAndFollowsThemWhileOpen() async throws {
        let r = try MenuRuntimeRig(control: ["scale": 2, "walk": false, "motion": "lively", "generation": 1])
        await r.rig.spin(until: { (try? r.rig.status.appliedGeneration) == 1 })
        try r.rightClick()
        let view = try #require(r.panels.menu?.menuView)
        #expect(view.visual.selection.walk == false && view.visual.selection.motion == .lively && view.visual.selection.scale == 2, "\(view.visual.selection)")
        // another writer (the user's terminal) changes a setting while the menu is open
        try JSONSerialization.data(withJSONObject: ["scale": 2, "walk": true, "motion": "lively", "bubble": false, "generation": 2]).write(to: try r.rig.store.url("control.json"), options: .atomic)
        await r.rig.spin(until: { r.panels.menu?.menuView.visual.selection.bubble == false })
        #expect(r.panels.menu?.menuView.visual.selection.walk == true && r.panels.menu?.menuView.visual.selection.bubble == false, "the menu always shows the truth")
    }

    @Test func Menu_theMonitorAndTheTrackingAreasExistOnlyWhileTheMenuIsOpen() throws {
        let r = try MenuRuntimeRig()
        #expect(r.source.installs == 0 && r.timer.armCount == 0, "nothing at rest")
        try r.rightClick()
        let view = try #require(r.panels.menu?.menuView)
        #expect(r.source.live == 1 && view.armed && !view.trackingAreas.isEmpty)
        for area in view.trackingAreas { #expect(area.options == [.mouseEnteredAndExited, .activeAlways], "\(area.options)") }
        let expected = 1 + view.layout.rows.count + view.layout.items.filter(\.clickable).count
        #expect(view.trackingAreas.count == expected, "one over the panel, one per row, one per clickable item")
        view.updateTrackingAreas()
        #expect(view.trackingAreas.count == expected, "AppKit asking again adds none")
        r.source.deliver(to: 0, at: 9)
        #expect(r.source.live == 0 && !view.armed && view.trackingAreas.isEmpty, "removed on the close")
        view.updateTrackingAreas()
        #expect(view.trackingAreas.isEmpty, "and not added again by AppKit while the menu is closed")
    }

    @Test func Menu_hoverComesFromEnteredAndExitedEventsAndIsLoggedOncePerItem() throws {
        let r = try MenuRuntimeRig()
        try r.rightClick()
        let view = try #require(r.panels.menu?.menuView)
        func move(_ type: NSEvent.EventType, to item: MenuItem?) throws {
            let p = item.map { CGPoint(x: $0.rect.midX, y: view.bounds.height - $0.rect.midY) } ?? CGPoint(x: -20, y: -20)
            let event = try #require(NSEvent.enterExitEvent(with: type, location: p, modifierFlags: [], timestamp: 1, windowNumber: 0, context: nil, eventNumber: 0, trackingNumber: 0, userData: nil))
            if type == .mouseEntered { view.mouseEntered(with: event) } else { view.mouseExited(with: event) }
        }
        let normal = menuItem(view.layout, "motion", "normal"), quiet = menuItem(view.layout, "motion", "quiet")
        try move(.mouseEntered, to: normal)
        #expect(view.visual.hoverItem == view.layout.items.firstIndex(of: normal) && view.visual.hoverRow == normal.row)
        try move(.mouseEntered, to: quiet)
        try move(.mouseExited, to: nil)
        #expect(view.visual.hoverItem == nil && view.visual.hoverRow == nil)
        #expect(r.lines("MENU hover") == ["MENU hover key=motion value=normal gen=1", "MENU hover key=motion value=quiet gen=1"])
        // the pointer leaving the panel starts the away count; coming back stops it
        #expect(r.timer.fireAt != nil)
        try move(.mouseEntered, to: normal)
        #expect(r.timer.fireAt == nil, "the pointer is on the menu: no away deadline")
        try move(.mouseExited, to: nil)
        #expect(r.timer.fireAt != nil, "and a fresh one once it leaves")
    }

    // MARK: the hold

    @Test func Menu_theBlinkIsHeldWhileTheMenuIsOpenSoTheBodyBoundsNeverChange() throws {
        let clock = VirtualClock(), timer = FakeScheduler(clock: clock)
        var options = HeadlessOptions(); options.motion = .off; options.walk = false
        let run = try IdleRenderRun(clock: clock, scheduler: timer, art: artDirectory, options: options, pixelScale: 2)
        var blinks = 0, bounds: Set<String> = []
        let original = run.runtime.present
        run.runtime.present = { stage in
            if run.runtime.lastRequest?.blink == true { blinks += 1 }
            bounds.insert("\(stage.hit.bounds as Any)")
            original(stage)
        }
        run.controller.randomUnit = { 0 }                   // the first blink after exactly 3 s
        run.controller.machine.onChange = { _ in run.runtime.sceneChanged() }
        run.runtime.setQuiet(.aquaNotRunning, active: false)
        run.runtime.start()
        advanceVirtual(clock: clock, scheduler: timer, runtime: run.runtime, by: 10)
        #expect(blinks > 0, "the blink happens when the menu is closed (the control that the next check can fail)")
        // open the menu: the blink is held, and Clawd's bounds never change
        let blinksBefore = blinks
        let canvas = try #require(run.runtime.lastFrame).canvas
        run.runtime.perform {
            _ = run.runtime.scheduler.menuOpened()
            run.runtime.menuRect = CGRect(x: canvas.maxX + 8, y: canvas.midY - 128, width: 236, height: 257)
            run.runtime.renderNow()
        }
        bounds = ["\(run.runtime.lastFrame?.hit.bounds as Any)"]
        advanceVirtual(clock: clock, scheduler: timer, runtime: run.runtime, by: 120)
        #expect(blinks == blinksBefore, "no blink pose is drawn while the menu is open")
        #expect(bounds.count == 1, "and the body bounds are the same on every picture: \(bounds)")
        run.runtime.perform { run.runtime.scheduler.menuClosed(); run.runtime.menuRect = nil; run.runtime.renderNow() }
        advanceVirtual(clock: clock, scheduler: timer, runtime: run.runtime, by: 30)
        #expect(blinks > blinksBefore, "and it blinks again once the menu is closed")
    }

    @Test func Menu_theBlinkAndTheRestPoseHaveTheSameBodyBoundsForEveryLookAtEverySize() throws {
        // The blink hold above is what ships; this records why it is cheap insurance: where the bounds are equal there was nothing to hold.
        let looks = stageRenderer.art.catalog.looks.map(\.id)
        var different: [String] = []
        for look in looks {
            for scale in [1.0, 1.5, 2, 3, 4] {
                let rest = try #require(try stageRenderer.compose(StageRequest(frame: Frames.rest(look: look), now: 0, blink: false, geometry: Screens.geometry(scale: scale))))
                let blink = try #require(try stageRenderer.compose(StageRequest(frame: Frames.rest(look: look), now: 0, blink: true, geometry: Screens.geometry(scale: scale))))
                if rest.hit.bounds != blink.hit.bounds { different.append("\(look)@\(scale)") }
            }
        }
        // Not an assertion about the art: the report goes to the progress notes.
        emit("BLINK-BOUNDS: \(different.isEmpty ? "equal for every look and size" : "differ for \(different.prefix(5))")")
    }
}
