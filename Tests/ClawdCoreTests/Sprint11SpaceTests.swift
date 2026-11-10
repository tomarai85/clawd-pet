import Testing
import Foundation
import AppKit
import ClawdCore
import ClawdRendering
import ClawdDesktop

// Sprint 11 (spec 9b item 16, item 3 of the brief): the Space is asked whenever the pet is put on screen (at the start, when it is shown
// again after a hide, after a lock), because the Space observer only hears a Space CHANGE and a window that is not on screen reports nothing.
// The runtime runs on its fake environment (fake displays, pointer and Space; no window is ever ordered on screen).

final class HardenMachine {
    var pointer = CGPoint.zero
    var presented = 0, dismissed = 0
    /// What the window server would answer about the pet's window: on the Space in front, not on it, or nothing (not on screen).
    var spaceAnswer: Bool? = true
    var spaceAsked = 0
    var sink: QuietSink?
    let display = DisplayInfo(uuid: "D", frame: CGRect(x: 0, y: 0, width: 1920, height: 1080),
                              visibleFrame: CGRect(x: 0, y: 40, width: 1920, height: 1040), backingScaleFactor: 2)
    func environment(aquaLog: String) -> RuntimeEnvironment {
        RuntimeEnvironment(displays: { [unowned self] in DisplaySet(all: [self.display]) },
                           pointer: { [unowned self] in self.pointer }, aquaLogPath: { aquaLog }, aquaRunning: { true },
                           present: { [unowned self] _ in self.presented += 1 }, dismiss: { [unowned self] _ in self.dismissed += 1 },
                           inputIdle: { 0 }, observeDesktop: { [unowned self] sink, _ in self.sink = sink; return nil },
                           onActiveSpace: { [unowned self] _ in self.spaceAsked += 1; return self.spaceAnswer })
    }
}

@MainActor
final class HardenRig {
    let machine = HardenMachine()
    let store: OwnState
    let runtime: AgentRuntime
    var stage: StageRuntime { runtime.stage }
    var view: PetView { runtime.view }
    let home = SavedPosition(displayUUID: "D", xFrac: 0.4, feetFrac: 0.1, scale: 1)

    /// `store`: the state directory of an earlier process (a restart); nil starts a new one.
    init(store existing: OwnState? = nil, state: AgentState? = nil, control: [String: Any]? = nil, spaceAnswer: Bool? = true) throws {
        machine.spaceAnswer = spaceAnswer
        store = try existing ?? artifactStore()
        if existing == nil || state != nil { try store.writeJSON(state ?? AgentState(position: home), to: "state.json") }
        if let control { try JSONSerialization.data(withJSONObject: control).write(to: try store.url("control.json")) }
        let monitor = FocusMonitor(store: store, center: NotificationCenter())
        let aquaLog = try artifactStore().url("aqua/main.log").path
        runtime = try AgentRuntime(store: store, monitor: monitor, art: artDirectory, control: AgentControl(),
                                   environment: machine.environment(aquaLog: aquaLog))
    }
    var log: String { String(decoding: (try? ReadOnlyFile.data(try store.url("agent.log").path)) ?? Data(), as: UTF8.self) }
    func lines(_ prefix: String) -> [String] {
        log.split(separator: "\n").map { String($0.drop { $0 != " " }.dropFirst()) }.filter { $0.hasPrefix(prefix) }
    }
    var state: AgentState { get throws { try store.readJSON(AgentState.self, from: "state.json") } }
    var status: AgentStatus { get throws { try store.readJSON(AgentStatus.self, from: "status.json") } }
    func spin(_ seconds: Double = 0.05) async { try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000)) }
    /// The limit is a ceiling for a loaded machine (the file watcher's events and the main queue are delivered late when other work runs), not an expected time.
    func spin(until condition: () -> Bool, limit: Double = 30) async {
        let deadline = Date().addingTimeInterval(limit)
        while !condition(), Date() < deadline { await spin(0.02) }
    }
    func write(_ changes: [String: Any]) throws { try writeControlLikeTheCLI(store.root, changes) }

    func event(_ type: NSEvent.EventType, at windowPoint: CGPoint) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: windowPoint, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                        context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
    }
    /// A global point on Clawd's body in the picture on screen.
    func bodyPoint() throws -> CGPoint {
        let frame = try #require(stage.lastFrame, "nothing is on screen")
        let panel = frame.panelFrame
        var y = panel.minY + 0.5
        while y < panel.maxY {
            var x = panel.minX + 0.5
            while x < panel.maxX {
                let p = CGPoint(x: x, y: y)
                if frame.hit.containsBody(p) { return p }
                x += 1
            }
            y += 1
        }
        throw RuntimeRigError.noPointOutsideTheBodyWindow
    }
    func window(_ global: CGPoint) -> CGPoint { CGPoint(x: global.x - runtime.panels.body.frame.minX, y: global.y - runtime.panels.body.frame.minY) }
    func press(at global: CGPoint) throws { machine.pointer = global; view.mouseDown(with: try event(.leftMouseDown, at: window(global))) }
    func drag(to global: CGPoint, from start: CGPoint) throws { machine.pointer = global; view.mouseDragged(with: try event(.leftMouseDragged, at: window(start))) }
    func release(at global: CGPoint, window start: CGPoint) throws { machine.pointer = global; view.mouseUp(with: try event(.leftMouseUp, at: window(start))) }
}

@Suite("Sprint 11 Space", .serialized)
@MainActor
struct Sprint11Space {
    @Test func Space_aPetStartedInAFullScreenSpaceIsSentAwayAndDoesNotAnimateUnseen() async throws {
        let rig = try HardenRig(spaceAnswer: false)
        await rig.spin(until: { rig.stage.lastFrame == nil })
        #expect(rig.machine.spaceAsked >= 1, "the Space was asked about at the start")
        #expect(rig.lines("QUIET on reason=not-on-active-space").count == 1, "\(rig.log)")
        #expect(rig.stage.lastFrame == nil); #expect(rig.stage.wake.armedTimers == 0, "no render and no animation timer for a pet nobody can see")
        #expect(rig.stage.scheduler.quietReason == .notOnActiveSpace)
    }

    @Test func Space_aPetOnTheActiveSpaceOrOffScreenIsNeverSentAway() async throws {
        for answer: Bool? in [true, nil] {
            let rig = try HardenRig(spaceAnswer: answer)
            await rig.spin(0.3)
            #expect(rig.machine.spaceAsked >= 1)
            #expect(rig.lines("QUIET on").isEmpty, "answer \(String(describing: answer)): \(rig.log)")
            #expect(rig.stage.lastFrame != nil); #expect(rig.stage.wake.armedTimers == 1)
        }
    }

    @Test func Space_hideThenMoveToAFullScreenSpaceThenShowDoesNotAnimateUnseen() async throws {
        let rig = try HardenRig(control: ["scale": 1, "generation": 0])
        await rig.spin(until: { (try? rig.status.appliedGeneration) == 0 })
        await rig.spin(0.2)
        #expect(rig.stage.lastFrame != nil); #expect(rig.lines("QUIET on").isEmpty)
        try rig.write(["hiddenUntil": -1])                                   // clawd-pet hide
        await rig.spin(until: { (try? rig.status.appliedGeneration) == 1 })
        #expect(rig.stage.lastFrame == nil, "hidden")
        rig.machine.spaceAnswer = false                                      // the user moves to a full-screen Space: nobody hears it while the window is out
        let asked = rig.machine.spaceAsked
        try rig.write(["hiddenUntil": 0])                                    // clawd-pet show
        await rig.spin(until: { (try? rig.status.appliedGeneration) == 2 })
        await rig.spin(until: { rig.lines("QUIET on reason=not-on-active-space").count == 1 })
        #expect(rig.machine.spaceAsked > asked, "showing the pet again asks about the Space")
        #expect(rig.lines("QUIET on reason=not-on-active-space").count == 1, "\(rig.log)")
        #expect(rig.stage.lastFrame == nil); #expect(rig.stage.wake.armedTimers == 0)
    }

    @Test func Space_aLockThatEndsInAFullScreenSpaceSendsThePetAwayAndLeavingItBringsTheOtherBack() async throws {
        let rig = try HardenRig()
        await rig.spin(0.2)
        let sink = try #require(rig.machine.sink)
        sink.setQuiet(.screenLocked, active: true)
        #expect(rig.stage.lastFrame == nil)
        rig.machine.spaceAnswer = false
        sink.setQuiet(.screenLocked, active: false)                          // unlock into a full-screen Space
        await rig.spin(until: { rig.stage.scheduler.quietReason == .notOnActiveSpace })
        #expect(rig.stage.scheduler.quietReason == .notOnActiveSpace); #expect(rig.stage.lastFrame == nil); #expect(rig.stage.wake.armedTimers == 0)
        rig.machine.spaceAnswer = true                                       // back on a normal Space: the observer lifts the reason
        sink.setQuiet(.notOnActiveSpace, active: false)
        await rig.spin(0.2)
        #expect(rig.stage.lastFrame != nil); #expect(rig.stage.scheduler.quietReason == nil); #expect(rig.stage.wake.armedTimers == 1)
    }
}
