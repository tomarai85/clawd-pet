import Testing
import Foundation
import AppKit
import ClawdCore
import ClawdProcess
import ClawdDesktop
import ClawdRendering
import CoreGraphics
import Darwin

// None of these tests orders a window front, makes anything key, runs NSApplication or activates it.
// Panels are created and inspected but never shown; the window-server list is only read.

@Suite("Focus layer", .serialized)
@MainActor
struct FocusLayerSuite {
    private func monitor(center: NotificationCenter) throws -> FocusMonitor {
        FocusMonitor(store: try artifactStore(), center: center)
    }

    @Test func FocusLayer_panelContractHasNoViolations() {
        let panel = PetPanel(overFullScreen: false)
        #expect(FocusAudit.violations(of: panel) == [])
        #expect(panel.styleMask.contains(.nonactivatingPanel)); #expect(panel.styleMask.contains(.borderless))
        #expect(!panel.canBecomeKey); #expect(!panel.canBecomeMain)
        #expect(panel.becomesKeyOnlyIfNeeded); #expect(!panel.hidesOnDeactivate)
        #expect(panel.isFloatingPanel); #expect(panel.level == PanelContract.level)
        #expect(panel.collectionBehavior.isSuperset(of: [.canJoinAllSpaces, .stationary, .ignoresCycle]))
        #expect(!panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(!panel.isOpaque); #expect(!panel.hasShadow); #expect(panel.animationBehavior == .none)
        #expect(panel.isExcludedFromWindowsMenu)
    }
    @Test func FocusLayer_negativeControl_plainPanelIsFlagged() {
        let plain = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.titled, .closable],
                            backing: .buffered, defer: true)
        let found = FocusAudit.violations(of: plain)
        #expect(found.contains("styleMask lacks nonactivatingPanel"))
        #expect(found.contains("canBecomeKey is true"))
        negativeControl("plain-nspanel-focus-audit", expectationHolds: found.isEmpty)
    }
    @Test func FocusLayer_negativeControl_missingNonactivatingFlagIsFlagged() {
        let almost = NSPanel(contentRect: NSRect(x: 0, y: 0, width: 10, height: 10), styleMask: [.borderless],
                             backing: .buffered, defer: true)
        almost.isFloatingPanel = true; almost.level = PanelContract.level; almost.hidesOnDeactivate = false
        almost.becomesKeyOnlyIfNeeded = true
        almost.collectionBehavior = PanelContract.behavior
        almost.isOpaque = false; almost.animationBehavior = .none
        let found = FocusAudit.violations(of: almost)
        #expect(found.contains("styleMask lacks nonactivatingPanel"))
        negativeControl("panel-without-nonactivating-style", expectationHolds: found.isEmpty)
    }
    /// Tom, 2026-11-09: an Orca session pane at `.floating`, raised after Clawd, went over him. His windows sit above every level other
    /// apps' floating, modal and utility windows use and above the Dock, and below the menu bar, pop-up menus and the screen saver.
    @Test func FocusLayer_everyPetWindowSitsAboveOtherAppsFloatingWindowsAndBelowTheMenuBar() {
        let level = PanelContract.level.rawValue
        let under = [NSWindow.Level.normal, .floating, .modalPanel,
                     NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.utilityWindow))), NSWindow.Level(rawValue: Int(CGWindowLevelForKey(.dockWindow)))]
        for other in under { #expect(level > other.rawValue, "\(level) is not above \(other.rawValue)") }
        for other in [NSWindow.Level.mainMenu, .statusBar, .popUpMenu, .screenSaver] { #expect(level < other.rawValue, "\(level) is not below \(other.rawValue)") }
        let menu = MenuPanel(overFullScreen: false, gen: 1, view: MenuView(layout: MenuLayout(looks: [], drawnStyles: []), gen: 1))
        for panel in [PetPanel(overFullScreen: false), StagePanel(overFullScreen: false), menu] {
            #expect(panel.level == PanelContract.level && FocusAudit.violations(of: panel) == [], "\(type(of: panel))")
        }
    }
    @Test func FocusLayer_negativeControl_aPetWindowBackAtFloatingIsFlagged() {
        let panel = PetPanel(overFullScreen: false)
        panel.level = .floating
        let found = FocusAudit.violations(of: panel)
        #expect(found == ["level is not the pet's (the Dock's plus one)"], "\(found)")
        negativeControl("pet-window-back-at-floating", expectationHolds: found.isEmpty)
    }
    @Test func FocusLayer_overFullScreenIsAnOptInFlag() {
        let panel = PetPanel(overFullScreen: true)
        #expect(panel.collectionBehavior.contains(.fullScreenAuxiliary))
        #expect(FocusAudit.violations(of: panel, overFullScreenAllowed: true) == [])
        #expect(FocusAudit.violations(of: panel) == ["fullScreenAuxiliary set"])
    }
    @Test func FocusLayer_constructingAndInspectingThePanelPutsNoWindowOnScreen() {
        // Relative to the count before: AppKit keeps one text-input helper window per process after any NSTextView has been edited (the chat
        // tests do), and that window is not the panel's.
        let before = windowCount(ownedBy: getpid())
        let panel = PetPanel(overFullScreen: false)
        #expect(!panel.isVisible)
        #expect(windowCount(ownedBy: getpid()) == before)
    }
    @Test func FocusLayer_viewTakesFirstMouseButNeverMovesTheWindowItself() {
        let view = PetView(frame: NSRect(x: 0, y: 0, width: 48, height: 48))
        #expect(view.acceptsFirstMouse(for: nil)); #expect(!view.mouseDownCanMoveWindow); #expect(!view.acceptsFirstResponder)
    }
    @Test func FocusLayer_syntheticMouseDownDragUpMovesThroughTheViewAndRestoresTheScene() throws {
        let rig = Rig(); rig.start()
        let view = PetView(frame: NSRect(x: 0, y: 0, width: 48, height: 48))
        view.opaqueBody = { _ in true }
        var receipts: [String] = []
        view.input = { kind, _ in
            receipts.append(kind)
            switch kind {
            case "mouseDown": rig.controller.mouseDown()
            case "mouseDragged": rig.controller.mouseDragged()
            case "mouseUp": rig.controller.mouseUp()
            default: break
            }
        }
        func mouse(_ type: NSEvent.EventType, count: Int = 1) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: 12, y: 12), modifierFlags: [], timestamp: 0,
                                            windowNumber: 0, context: nil, eventNumber: 0, clickCount: count, pressure: 1))
        }
        view.mouseDown(with: try mouse(.leftMouseDown)); view.mouseDragged(with: try mouse(.leftMouseDragged))
        #expect(rig.scene == .drag)
        view.mouseUp(with: try mouse(.leftMouseUp)); #expect(rig.scene == .listening)
        #expect(receipts == ["mouseDown", "mouseDragged", "mouseUp"])
        #expect(!NSRunningApplication.current.isActive)
    }
    @Test func FocusLayer_doubleClickRightClickScrollAndTransparentPixelsDoNothing() throws {
        let view = PetView(frame: NSRect(x: 0, y: 0, width: 48, height: 48))
        var receipts: [String] = []
        view.input = { kind, _ in receipts.append(kind) }
        func mouse(_ type: NSEvent.EventType, count: Int) throws -> NSEvent {
            try #require(NSEvent.mouseEvent(with: type, location: NSPoint(x: 12, y: 12), modifierFlags: [], timestamp: 0,
                                            windowNumber: 0, context: nil, eventNumber: 0, clickCount: count, pressure: 1))
        }
        view.opaqueBody = { _ in true }
        view.mouseDown(with: try mouse(.leftMouseDown, count: 2)); view.mouseUp(with: try mouse(.leftMouseUp, count: 2))
        view.rightMouseDown(with: try mouse(.rightMouseDown, count: 1)); view.scrollWheel(with: try mouse(.leftMouseDown, count: 1))
        view.opaqueBody = { _ in false }
        view.mouseDown(with: try mouse(.leftMouseDown, count: 1)); view.mouseDragged(with: try mouse(.leftMouseDragged, count: 1))
        #expect(receipts.isEmpty)
    }
    @Test func FocusLayer_monitorCountsActivationKeyAndMainWithTheirTriggerContext() throws {
        let center = NotificationCenter()
        let focus = try monitor(center: center)
        var handed = 0
        focus.onViolation = { handed += 1 }
        center.post(name: NSApplication.didBecomeActiveNotification, object: nil)
        focus.context = "click"
        center.post(name: NSWindow.didBecomeKeyNotification, object: nil)
        focus.context = "wake"
        center.post(name: NSWindow.didBecomeMainNotification, object: nil)
        center.post(name: NSWindow.didResignKeyNotification, object: nil)      // not a violation
        #expect(focus.status.focusViolations == 3); #expect(handed == 3)
        let log = String(decoding: try ReadOnlyFile.data(try focus.store.url("agent.log").path), as: UTF8.self)
        #expect(log.contains("trigger=launch notification=NSApplicationDidBecomeActiveNotification"))
        #expect(log.contains("trigger=click notification=NSWindowDidBecomeKeyNotification"))
        #expect(log.contains("trigger=wake notification=NSWindowDidBecomeMainNotification"))
        #expect(!log.contains("Resign"))
    }
    @Test func FocusLayer_countSurvivesARestartThroughStatusJSON() throws {
        let store = try artifactStore(), center = NotificationCenter()
        let first = FocusMonitor(store: store, center: center)
        center.post(name: NSWindow.didBecomeKeyNotification, object: nil)
        #expect(first.status.focusViolations == 1)
        let second = FocusMonitor(store: store, center: NotificationCenter())
        #expect(second.status.focusViolations == 1)
        #expect(second.status.wakeCount == 0); #expect(second.status.displayChangeCount == 0)   // "not yet observed"
    }
    @Test func FocusLayer_statusNamesTheProcessThatWroteItAndDropsWhatAnOlderProcessAppliedAndRequired() throws {
        // `clawd-pet update` restarts the agent and waits for a NEW process: status.json outlives the old one, with its pid and its
        // appliedGeneration, so a new process must replace the pid at once and report no applied generation until it has applied one.
        let store = try artifactStore()
        var older = AgentStatus()
        older.focusViolations = 4; older.wakeCount = 2; older.pid = 1; older.appliedGeneration = 9; older.walk = true
        try store.writeJSON(older, to: "status.json")
        let monitor = FocusMonitor(store: store, center: NotificationCenter())
        #expect(monitor.status.pid == getpid(), "the pid is this process's, not the one that wrote the file")
        #expect(monitor.status.appliedGeneration == nil, "an older process's applied generation is not this process's")
        #expect(monitor.status.focusViolations == 4); #expect(monitor.status.wakeCount == 2)   // the counts run since the install
        monitor.persist()
        let written = try store.readJSON(AgentStatus.self, from: "status.json")
        #expect(written.pid == getpid()); #expect(written.appliedGeneration == nil)
        let raw = try #require(try JSONSerialization.jsonObject(with: ReadOnlyFile.data(try store.url("status.json").path)) as? [String: Any])
        #expect(raw["pid"] as? Int == Int(getpid()), "the pid is a plain number in status.json, as the CLI reads it")
        negativeControl("status-keeps-an-older-process-pid-and-generation", expectationHolds: written.pid == 1 || written.appliedGeneration == 9)
    }
    @Test func FocusLayer_sourceCallsOnlyOrderFrontRegardlessAndAccessoryPolicy() throws {
        // The calls are written in two halves so that the Tests scan of FocusLayer_testsNeverMakeAWindowKeyOrActivateAnApp does not match this list.
        let makeKeyCall = "make" + "Key(", orderFrontRegardlessCall = "orderFront" + "Regardless()"
        let sources = try swiftSources()
        let joined = sources.map(\.text).joined(separator: "\n")
        // The chat panel's file and the Settings window's file hold the make-key calls of the tree (spec F1.5; lint row `make-key`): exactly those two
        // files, and every other file is scanned for the call.
        let makeKeyFiles = ["Sources/ClawdDesktop/ChatPanel.swift", "Sources/ClawdDesktop/SettingsWindow.swift"]
        let others = sources.filter { file in !makeKeyFiles.contains { file.path.hasSuffix($0) } }.map(\.text).joined(separator: "\n")
        #expect(Set(sources.filter { $0.text.contains(makeKeyCall) }.map { ($0.path as NSString).lastPathComponent }) == ["ChatPanel.swift", "SettingsWindow.swift"])
        #expect(!others.contains(makeKeyCall))
        #expect(joined.contains("setActivationPolicy(.accessory)"))
        #expect(!joined.contains("setActivationPolicy(.regular"))
        #expect(joined.contains(orderFrontRegardlessCall))
        // Sprint 3e item 8: the chat activation file is the one file of Sources with an activation call; the activation phrases are banned elsewhere.
        let activationFile = "Sources/ClawdDesktop/ChatActivation.swift"
        let apart = sources.filter { !$0.path.hasSuffix(activationFile) }.map(\.text).joined(separator: "\n")
        let callers = sources.filter { $0.text.range(of: #"(?<![A-Za-z0-9_])activ"# + #"ate\("#, options: .regularExpression) != nil }.map(\.path)
        #expect(callers.count == 1 && callers.allSatisfy { $0.hasSuffix(activationFile) }, "the files with an activation call: \(callers)")
        for banned in ["make" + "KeyAndOrderFront", "make" + "Main(", "NSApp." + "activate", "activ" + "ate(ignoringOtherApps", "order" + "Front(", "un" + "hide("] {
            #expect(!apart.contains(banned), "\(banned)")
        }
    }
    /// Part 0 (R7.7, r10): no test makes a window key, brings an application forward, opens anything, posts an event, touches the pasteboard
    /// or is handed the production environment. Every Swift file under Tests/ is scanned line by line (comments included); a hit names the
    /// file and the line. Each pattern has a character class in it, so this list does not match itself, and no line or file is skipped.
    /// A core-graphics event may be built (the provenance tests wrap tagged ones) but never posted: the posting calls are banned below,
    /// and so is the construction of a keyboard event. Only the type name alone (as an optional or in a longer identifier) and the mouse and
    /// wheel constructors pass.
    static let testsScanPatterns: [String] = [
        #"become[K]ey\(\)"#, #"make[K]ey\("#, #"make[K]eyWindow"#, #"make[K]eyAndOrderFront"#, #"order[F]ront\("#, #"order[F]rontRegardless\("#,
        #"(?<![A-Za-z0-9_])[a]ctivate\("#, #"deactiv[a]te\("#, #"yield[A]ctivation"#, #"hide\([n]il\)"#, #"un[h]ide"#,
        #"NSWorkspace[.]shared"#, #"open[A]pplication"#, #""/usr/bin/[o]pen""#, #"LS[O]pen"#,
        #"CG[E]vent(?![A-Za-z0-9_?]|\((?:mouseEventSource|scrollWheelEvent2Source):)"#,
        #"[.]post\(t[a]p:"#, #"post[T]oPid"#, #"NSApple[S]cript"#, #"osa[s]cript"#, #"NSPaste[b]oard"#,
        #"RuntimeEnvironment[.]prod[u]ction"#, #"environment: [.]prod[u]ction"#,
        // The menu bar icon: no test names the system's status bar (the runtime's `statusBar` seam is inert by default).
        #"NSStatus[B]ar"#, #"production[S]urface"#,
        // Part C: every test builds Clawd's subclass of the terminal view (its copy and paste go through the injected pasteboard), never SwiftTerm's.
        #"(?<![A-Za-z0-9_])Terminal[V]iew\("#,
    ]
    @Test func FocusLayer_testsNeverMakeAWindowKeyOrActivateAnApp() throws {
        let patterns = try Self.testsScanPatterns.map { try NSRegularExpression(pattern: $0) }
        let root = repository.appendingPathComponent("Tests")
        let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
        var scanned = 0, hits: [String] = []
        for case let url as URL in enumerator where url.pathExtension == "swift" {
            scanned += 1
            let text = String(decoding: try ReadOnlyFile.data(url.path), as: UTF8.self)
            for (index, line) in text.split(separator: "\n", omittingEmptySubsequences: false).enumerated() {
                let whole = NSRange(line.startIndex..., in: line)
                for (pattern, expression) in zip(Self.testsScanPatterns, patterns) where expression.firstMatch(in: String(line), range: whole) != nil {
                    hits.append("\(url.path.replacingOccurrences(of: repository.path + "/", with: "")):\(index + 1): \(pattern)")
                }
            }
        }
        #expect(scanned > 20, "the scan found only \(scanned) Swift files under Tests/")
        #expect(hits.isEmpty, "a test makes a window key, activates or opens an app, posts an event, touches the pasteboard or uses the production environment: \(hits)")
    }
    /// The generic rotation (agent.log has its own policy, tested in AgentLogTests).
    @Test func FocusLayer_aRotatingLogRotatesAtItsLimitAndKeepsOneOldFile() throws {
        let store = try artifactStore()
        for i in 0..<10 { try store.appendRotating(String(repeating: "x", count: 99) + "\(i)\n", to: "other.log", limit: 300) }
        let live = try ReadOnlyFile.data(try store.url("other.log").path).count
        let old = try ReadOnlyFile.data(try store.url("other.log.1").path).count
        #expect(live > 0 && live <= 400); #expect(old > 0)
    }
}

// MARK: window enumeration failure is its own failing result

@Suite("Window enumeration evidence")
struct WindowEnumerationSuite {
    @Test func WindowEnumeration_aFailingListIsItsOwnFailureNeverNoWindow() throws {
        // The window list cannot be read (-1 every time). The old reading of "no window" looked only at positive counts.
        let blind = try execute(URL(fileURLWithPath: "/usr/bin/true"), [], windowProbe: { _ in -1 })
        #expect(blind.windowPids.isEmpty)                       // nothing was seen, because nothing could be read
        #expect(blind.windowEnumerationFailures >= 1)
        #expect(!blind.provedWindowless, "an unreadable window list must never prove the absence of a window")
    }
    @Test func WindowEnumeration_oneFailedReadAmongGoodOnesStillFailsTheProof() throws {
        var reads = 0
        let flaky = try execute(URL(fileURLWithPath: "/bin/sleep"), ["0.3"], windowProbe: { _ in reads += 1; return reads == 2 ? -1 : 0 })
        #expect(flaky.windowSamples >= 2); #expect(flaky.windowEnumerationFailures == 1)
        #expect(!flaky.provedWindowless)
    }
    @Test func WindowEnumeration_aWindowOfTheChildIsSeenAndAReadableEmptyListProvesAbsence() throws {
        let seen = try execute(URL(fileURLWithPath: "/usr/bin/true"), [], windowProbe: { _ in 1 })
        #expect(seen.windowPids.count == 1); #expect(!seen.provedWindowless)
        let clear = try execute(URL(fileURLWithPath: "/usr/bin/true"), [], windowProbe: { _ in 0 })
        #expect(clear.windowSamples >= 1); #expect(clear.windowEnumerationFailures == 0); #expect(clear.provedWindowless)
        // The real list, for a child that exits at once: read at least once (right after the start), readable, no window.
        let real = try execute(URL(fileURLWithPath: "/usr/bin/true"), [])
        #expect(real.windowSamples >= 1); #expect(real.windowEnumerationFailures == 0); #expect(real.provedWindowless)
    }
}

// MARK: the production input path (AgentRuntime.input) with synthetic NSEvents

/// Everything the real AgentRuntime takes from the machine, replaced by values the test controls. The panel is never ordered
/// on screen: `present` only counts.
private final class FakeMachine {
    var pointer = CGPoint.zero
    var displays: [DisplayInfo]
    var presented = 0
    var dismissed = 0
    init(displays: [DisplayInfo]) { self.displays = displays }
    func environment(aquaLog: String) -> RuntimeEnvironment {
        RuntimeEnvironment(displays: { [unowned self] in DisplaySet(all: self.displays) },
                           pointer: { [unowned self] in self.pointer }, aquaLogPath: { aquaLog }, aquaRunning: { true },
                           present: { [unowned self] _ in self.presented += 1 }, dismiss: { [unowned self] _ in self.dismissed += 1 },
                           inputIdle: { 0 }, observeDesktop: { _, _ in nil })
    }
}
/// The panel's origin goes through fractions of the display on every render, so compare it with a rounding tolerance.
private func near(_ a: CGPoint, _ b: CGPoint) -> Bool { abs(a.x - b.x) < 1e-6 && abs(a.y - b.y) < 1e-6 }
private let laptop = DisplayInfo(uuid: "A", frame: CGRect(x: 0, y: 0, width: 1440, height: 900),
                                 visibleFrame: CGRect(x: 0, y: 0, width: 1440, height: 875), backingScaleFactor: 2)
private let ultrawide = DisplayInfo(uuid: "B", frame: CGRect(x: 1440, y: 0, width: 3440, height: 1440),
                                    visibleFrame: CGRect(x: 1440, y: 40, width: 3440, height: 1400), backingScaleFactor: 1)

@MainActor
private final class InputRig {
    let machine: FakeMachine
    let store: OwnState
    let runtime: AgentRuntime
    let renderer: SceneRenderer
    var view: PetView { runtime.view }
    /// The stage window: the whole picture, at the rectangle the single panel used to have.
    var panel: PetPanel { runtime.panels.stage }
    /// The body window: as small as Clawd's body and costume pixels.
    var bodyPanel: PetPanel { runtime.panels.body }
    /// The middle of the body window, in its own coordinates.
    var bodyCentre: CGPoint { CGPoint(x: bodyPanel.frame.width / 2, y: bodyPanel.frame.height / 2) }

    init(displays: [DisplayInfo] = [laptop, ultrawide], saved: SavedPosition) throws {
        machine = FakeMachine(displays: displays)
        store = try artifactStore()
        try store.writeJSON(saved, to: "state.json")      // present, so the runtime never reads Aqua's settings for a first position
        let monitor = FocusMonitor(store: store, center: NotificationCenter())
        let aquaLog = try artifactStore().url("aqua/main.log").path
        renderer = try SceneRenderer(art: artDirectory)
        runtime = try AgentRuntime(store: store, monitor: monitor, art: artDirectory, control: AgentControl(),
                                   environment: machine.environment(aquaLog: aquaLog))
    }
    func event(_ type: NSEvent.EventType, at windowPoint: CGPoint, clicks: Int = 1) throws -> NSEvent {
        try #require(NSEvent.mouseEvent(with: type, location: windowPoint, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                        context: nil, eventNumber: 0, clickCount: clicks, pressure: 1))
    }
    /// The cursor is at `screenPoint` when the synthetic event is delivered to the real view.
    func down(at screenPoint: CGPoint, window: CGPoint) throws { machine.pointer = screenPoint; view.mouseDown(with: try event(.leftMouseDown, at: window)) }
    func drag(to screenPoint: CGPoint) throws { machine.pointer = screenPoint; view.mouseDragged(with: try event(.leftMouseDragged, at: bodyCentre)) }
    func up(at screenPoint: CGPoint) throws { machine.pointer = screenPoint; view.mouseUp(with: try event(.leftMouseUp, at: bodyCentre)) }
    /// Lets the drop motion that follows a release finish (the longest, A8, lasts 1.92 s; C7 starts away from the rest pose), so the next
    /// press lands on the rest-pose pixel `hitPoints` names.
    func settle() { RunLoop.main.run(until: Date().addingTimeInterval(2.3)) }
    var saved: SavedPosition { get throws { try store.readJSON(SavedPosition.self, from: "state.json") } }
    var log: String { get throws { String(decoding: try ReadOnlyFile.data(try store.url("agent.log").path), as: UTF8.self) } }
    /// An opaque and a fully transparent point of the frame the runtime just drew, in view coordinates (origin bottom-left).
    func hitPoints(backing: Double) throws -> (opaque: CGPoint, clear: CGPoint) {
        let frame = renderer.frame(from: runtime.controller.state(), scale: 1, helmet: false, pixelScale: backing)
        let image = try renderer.render(frame)
        let pixels = try SceneRenderer.pixels(image)
        func point(_ x: Int, _ y: Int) -> CGPoint { CGPoint(x: (Double(x) + 0.5) / backing, y: (Double(image.height - 1 - y) + 0.5) / backing) }
        func alpha(_ x: Int, _ y: Int) -> UInt8 { pixels[(y * image.width + x) * 4 + 3] }
        var opaque: CGPoint?, clear: CGPoint?
        for y in 0..<image.height { for x in 0..<image.width {
            if opaque == nil, alpha(x, y) == 255, abs(Double(x) - Double(image.width) / 2) < 3, abs(Double(y) - Double(image.height) / 2) < 3 { opaque = point(x, y) }
            if clear == nil, alpha(x, y) == 0 { clear = point(x, y) }
        } }
        return (try #require(opaque, "no opaque pixel near the centre"), try #require(clear, "no transparent pixel"))
    }
}

@Suite("Production input path", .serialized)
@MainActor
struct InputPathSuite {
    private let start = SavedPosition(displayUUID: "A", xFrac: 0.25, feetFrac: 0.1, scale: 1)

    @Test func Input_thePanelIsPlacedFromTheSavedFractionsOnItsDisplay() throws {
        let rig = try InputRig(saved: start)
        #expect(rig.panel.frame == CGRect(x: 336, y: 90, width: 48, height: 48))      // 1440 * 0.25 - 24, 900 * 0.1
        #expect(!rig.panel.isVisible); #expect(rig.machine.presented > 0)            // asked to show, never shown
    }
    @Test func Input_aDragMovesThePanelByTheDistanceTheCursorMovedAfterTheThreePointThreshold() throws {
        let rig = try InputRig(saved: start)
        let hit = try rig.hitPoints(backing: 2).opaque
        try rig.down(at: CGPoint(x: 336 + hit.x, y: 90 + hit.y), window: hit)
        #expect(rig.panel.frame.origin == CGPoint(x: 336, y: 90))
        // 2.9 points away: still a click, nothing moves and the scene does not become DRAG.
        try rig.drag(to: CGPoint(x: 336 + hit.x + 2.9, y: 90 + hit.y))
        #expect(rig.panel.frame.origin == CGPoint(x: 336, y: 90)); #expect(rig.runtime.controller.machine.scene != .drag)
        // Exactly 3 points: it is a drag; the panel follows the cursor one to one.
        try rig.drag(to: CGPoint(x: 336 + hit.x + 3, y: 90 + hit.y))
        #expect(rig.panel.frame.origin == CGPoint(x: 339, y: 90)); #expect(rig.runtime.controller.machine.scene == .drag)
        try rig.drag(to: CGPoint(x: 336 + hit.x + 40, y: 90 + hit.y + 70))
        #expect(rig.panel.frame.origin == CGPoint(x: 376, y: 160))
        // The position is saved on mouse-up, not before.
        #expect(try rig.saved == start)
        try rig.up(at: CGPoint(x: 336 + hit.x + 40, y: 90 + hit.y + 70))
        let saved = try rig.saved
        #expect(saved.displayUUID == "A"); #expect(abs(saved.xFrac - (376 + 24) / 1440) < 1e-9); #expect(abs(saved.feetFrac - 160.0 / 900) < 1e-9)
        #expect(rig.runtime.controller.machine.scene != .drag)
        #expect(rig.panel.frame.origin == CGPoint(x: 376, y: 160))
    }
    @Test func Input_aClickUnderThreePointsMovesNothingAndSavesTheSamePosition() throws {
        let rig = try InputRig(saved: start)
        let hit = try rig.hitPoints(backing: 2).opaque
        let at = CGPoint(x: 336 + hit.x, y: 90 + hit.y)
        try rig.down(at: at, window: hit); try rig.drag(to: CGPoint(x: at.x + 2, y: at.y + 2)); try rig.up(at: at)
        #expect(rig.panel.frame.origin == CGPoint(x: 336, y: 90))
        let saved = try rig.saved
        #expect(saved.displayUUID == "A"); #expect(abs(saved.xFrac - 0.25) < 1e-9); #expect(abs(saved.feetFrac - 0.1) < 1e-9)
        #expect(!(try rig.log).contains("scene=drag"))
    }
    @Test func Input_dragToTheOtherDisplayClampsToItsVisibleFrameAndSavesItsUUIDAndFractions() throws {
        let rig = try InputRig(saved: start)
        let hit = try rig.hitPoints(backing: 2).opaque
        // The cursor keeps its offset inside the panel, so the cursor position for a wanted panel origin is origin + hit.
        func cursor(forOrigin origin: CGPoint) -> CGPoint { CGPoint(x: origin.x + hit.x, y: origin.y + hit.y) }
        try rig.down(at: cursor(forOrigin: CGPoint(x: 336, y: 90)), window: hit)
        // Onto the ultrawide (a different display, a different backing scale).
        try rig.drag(to: cursor(forOrigin: CGPoint(x: 1976, y: 676)))
        #expect(near(rig.panel.frame.origin, CGPoint(x: 1976, y: 676)))
        #expect(rig.runtime.currentPosition.displayUUID == "B")
        // Past its top-right corner, with the cursor outside every display: clamped to the visible frame of the display it is on.
        try rig.drag(to: CGPoint(x: 5000, y: 2000))
        #expect(near(rig.panel.frame.origin, CGPoint(x: 1440 + 3440 - 48, y: 1440 - 48)))
        // Below its Dock: the drag area runs down to the display's bottom edge (the visible frame starts 40 points up).
        try rig.drag(to: cursor(forOrigin: CGPoint(x: 1500, y: -5)))
        #expect(near(rig.panel.frame.origin, CGPoint(x: 1500, y: 0)))
        try rig.up(at: cursor(forOrigin: CGPoint(x: 1500, y: 5)))
        let saved = try rig.saved
        #expect(saved.displayUUID == "B")
        #expect(abs(saved.xFrac - (1500 + 24 - 1440) / 3440) < 1e-9); #expect(saved.feetFrac == 0)
        // And back onto the laptop display.
        rig.settle()
        try rig.down(at: cursor(forOrigin: CGPoint(x: 1500, y: 0)), window: hit)
        try rig.drag(to: cursor(forOrigin: CGPoint(x: 700, y: 400))); try rig.up(at: cursor(forOrigin: CGPoint(x: 700, y: 400)))
        #expect(try rig.saved.displayUUID == "A")
        #expect(near(rig.panel.frame.origin, CGPoint(x: 700, y: 400)))
        // Left of the laptop display's edge: clamped to x = 0.
        rig.settle()
        try rig.down(at: cursor(forOrigin: CGPoint(x: 700, y: 400)), window: hit)
        try rig.drag(to: CGPoint(x: -300, y: 300)); try rig.up(at: CGPoint(x: -300, y: 300))
        #expect(near(rig.panel.frame.origin, CGPoint(x: 0, y: (300 - hit.y).rounded())))
    }
    /// The user, 2026-10-21: after Clawd was dragged onto the other display, the right-click menu opened on the display it came from, far from
    /// Clawd, so every click near Clawd closed it as an outside click. The scheduler kept the old display's frames until the next display
    /// change or setting; the drop must make it read the new one.
    @Test func Input_aDropOnTheOtherDisplayMovesTheMenuWithClawd() throws {
        let rig = try InputRig(saved: start)
        let hit = try rig.hitPoints(backing: 2).opaque
        func cursor(forOrigin origin: CGPoint) -> CGPoint { CGPoint(x: origin.x + hit.x, y: origin.y + hit.y) }
        try rig.down(at: cursor(forOrigin: CGPoint(x: 336, y: 90)), window: hit)
        try rig.drag(to: cursor(forOrigin: CGPoint(x: 1976, y: 676)))
        try rig.up(at: cursor(forOrigin: CGPoint(x: 1976, y: 676)))
        let panel = rig.panel.frame
        #expect(ultrawide.frame.contains(panel.origin), "Clawd was dropped on B: \(panel)")
        let menu = try #require(rig.runtime.menuPlacement())
        #expect(ultrawide.visibleFrame.contains(menu), "the menu opens on the display Clawd stands on: \(menu)")
        #expect(menu.minY <= panel.maxY && menu.maxY >= panel.minY, "beside Clawd, not clamped elsewhere: menu \(menu), Clawd \(panel)")
        // B has room on Clawd's right, so the menu opens there with its 8 pt gap (MenuPlacement), not merely somewhere on B.
        #expect(menu.minX >= panel.minX + 40 && menu.minX <= panel.maxX + 20, "on Clawd's right, at the body gap: menu \(menu), Clawd \(panel)")
    }
    @Test func Input_aTransparentPixelIsClickThroughAndRecordsNothing() throws {
        let rig = try InputRig(saved: start)
        let points = try rig.hitPoints(backing: 2)
        try rig.down(at: CGPoint(x: 336 + points.clear.x, y: 90 + points.clear.y), window: points.clear)
        try rig.drag(to: CGPoint(x: 500, y: 500)); try rig.up(at: CGPoint(x: 500, y: 500))
        #expect(rig.panel.frame.origin == CGPoint(x: 336, y: 90)); #expect(rig.runtime.controller.machine.scene != .drag)
        #expect(!(try rig.log).contains("INPUT kind="), "a click on a transparent pixel must not reach the agent's input path")
        try rig.down(at: CGPoint(x: 336 + points.opaque.x, y: 90 + points.opaque.y), window: points.opaque)
        #expect((try rig.log).contains("INPUT kind=mouseDown"))
    }
    @Test func Input_everyDeliveredEventIsLoggedForTheLiveCheckAndNoWindowOrActivationEverHappens() throws {
        let windowsBefore = windowCount(ownedBy: getpid())   // relative: see FocusLayer_constructingAndInspectingThePanelPutsNoWindowOnScreen
        let rig = try InputRig(saved: start)
        let hit = try rig.hitPoints(backing: 2).opaque
        let at = CGPoint(x: 336 + hit.x, y: 90 + hit.y)
        try rig.down(at: at, window: hit)
        try rig.drag(to: CGPoint(x: at.x + 10, y: at.y)); try rig.drag(to: CGPoint(x: at.x + 20, y: at.y))
        try rig.up(at: CGPoint(x: at.x + 20, y: at.y))
        let log = try rig.log
        #expect(log.components(separatedBy: "INPUT kind=mouseDown").count == 2)
        #expect(log.components(separatedBy: "INPUT kind=mouseDragged").count == 3)
        #expect(log.components(separatedBy: "INPUT kind=mouseUp").count == 2)
        #expect(!rig.panel.isVisible); #expect(!rig.panel.isKeyWindow); #expect(!rig.panel.isMainWindow)
        #expect(windowCount(ownedBy: getpid()) == windowsBefore)
        #expect(!NSRunningApplication.current.isActive)
    }
    @Test func Input_aSavedDisplayThatIsGoneFallsBackToThePrimaryOne() throws {
        let rig = try InputRig(saved: SavedPosition(displayUUID: "unplugged", xFrac: 0.5, feetFrac: 0.2, scale: 1))
        #expect(rig.panel.frame == CGRect(x: 696, y: 180, width: 48, height: 48))
        let hit = try rig.hitPoints(backing: 2).opaque
        try rig.down(at: CGPoint(x: 696 + hit.x, y: 180 + hit.y), window: hit)
        try rig.drag(to: CGPoint(x: 800, y: 300)); try rig.up(at: CGPoint(x: 800, y: 300))
        #expect(try rig.saved.displayUUID == "A")
    }
    /// The user, 2026-10-21: with a second monitor the pet moved to whichever screen they clicked. It stood on NSScreen.main (the screen with
    /// keyboard focus) whenever its saved display was not attached. Now it stands on the primary display, the first of the set, whichever
    /// display comes first otherwise, and the saved UUID is kept, so it goes back when its own display returns.
    @Test func Input_aSavedDisplayThatIsGoneUsesThePrimaryAndTheSavedOneWhenItReturns() throws {
        let unknown = try InputRig(displays: [laptop, ultrawide], saved: SavedPosition(displayUUID: "gone", xFrac: 0.5, feetFrac: 0.2, scale: 1))
        #expect(laptop.frame.contains(unknown.panel.frame.origin), "an unknown saved display: on the primary display A: \(unknown.panel.frame)")
        let rig = try InputRig(displays: [laptop, ultrawide], saved: SavedPosition(displayUUID: "B", xFrac: 0.25, feetFrac: 0.1, scale: 1))
        #expect(ultrawide.frame.contains(rig.panel.frame.origin), "on its saved display B: \(rig.panel.frame)")
        rig.machine.displays = [laptop]
        rig.runtime.controller.refresh()
        #expect(laptop.frame.contains(rig.panel.frame.origin), "B unplugged: on the primary display A: \(rig.panel.frame)")
        rig.machine.displays = [laptop, ultrawide]
        rig.runtime.controller.refresh()
        #expect(ultrawide.frame.contains(rig.panel.frame.origin), "B back: on B again: \(rig.panel.frame)")
        #expect(try rig.saved.displayUUID == "B", "the saved display is kept while B is away")
    }
    @Test func Input_noDisplayAttachedHidesThePanelInsteadOfCrashing() throws {
        let rig = try InputRig(saved: start)
        rig.machine.displays = []
        let before = rig.machine.dismissed
        rig.runtime.controller.refresh()
        #expect(rig.machine.dismissed > before)
    }

    // ---- provenance of every mouse event, for the live check (r3) --------------------------------------------------------------
    /// A core-graphics event that is only built and wrapped, never posted: it carries the tag the live check's poster would put on a posted event.
    private func tagged(_ type: CGEventType, button: CGMouseButton = .left, tag: Int64, location: CGPoint = .zero, clickState: Int64 = 1) throws -> NSEvent {
        let cg = try #require(CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: button))
        cg.setIntegerValueField(.eventSourceUserData, value: tag)
        cg.setIntegerValueField(.mouseEventClickState, value: clickState)
        return try #require(NSEvent(cgEvent: cg))
    }
    @Test func Input_theTagIsReadFromTheEventsCGEventAsSixteenHexDigits() throws {
        #expect(InputProvenance.tag(of: try tagged(.rightMouseDown, button: .right, tag: 0x0123_4567_89ab_cdef)) == "0123456789abcdef")
        #expect(InputProvenance.tag(of: try tagged(.rightMouseDown, button: .right, tag: Int64(bitPattern: 0xfedc_ba98_7654_3210))) == "fedcba9876543210")
        #expect(InputProvenance.tag(of: try tagged(.rightMouseDown, button: .right, tag: 0)) == "0000000000000000")
        // NSEvent.mouseEvent(...) has a core-graphics event behind it as well, with no tag. No such event at all can only be modelled with nil.
        let plain = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0,
                                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(InputProvenance.tag(of: plain) == "0000000000000000")
        let nothing: CGEvent? = nil
        #expect(InputProvenance.tag(of: nothing) == "none"); #expect(InputProvenance.sourcePid(of: nothing) == "none")
        #expect(InputProvenance.fields(of: nothing) == "tag=none src=none")
        #expect(InputProvenance.fields(of: try tagged(.rightMouseDown, button: .right, tag: 0xabc)).hasPrefix("tag=0000000000000abc src="))
    }
    @Test func Input_anUntaggedHandledEventLogsAllZeroTag() throws {
        let rig = try InputRig(saved: start)
        let hit = try rig.hitPoints(backing: 2).opaque
        try rig.down(at: CGPoint(x: 336 + hit.x, y: 90 + hit.y), window: hit)
        #expect(try rig.log.contains("INPUT kind=mouseDown tag=0000000000000000 src="))
    }
    @Test func Input_aRightClickAndAScrollWheelAreLoggedAsIgnoredWithTheirOwnTagAndNeverAsInput() throws {
        let rig = try InputRig(saved: start)
        rig.view.rightMouseDown(with: try tagged(.rightMouseDown, button: .right, tag: 0x1111_2222_3333_0007))
        let wheel = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 3, wheel2: 0, wheel3: 0))
        wheel.setIntegerValueField(.eventSourceUserData, value: 0x1111_2222_3333_0008)
        rig.view.scrollWheel(with: try #require(NSEvent(cgEvent: wheel)))
        let log = try rig.log
        #expect(log.contains("MOUSE-IGNORED kind=rightMouseDown tag=1111222233330007 src="))
        #expect(log.contains("MOUSE-IGNORED kind=scrollWheel tag=1111222233330008 src="))
        #expect(!log.contains("INPUT kind="))
    }
    @Test func Input_aClickOnATransparentPixelAndALooseDragAndUpAreEachLoggedAsIgnoredWithAReasonAndADoubleClickOnTheBodyIsAClick() throws {
        let rig = try InputRig(saved: start)
        let points = try rig.hitPoints(backing: 2)
        try rig.down(at: CGPoint(x: 336 + points.clear.x, y: 90 + points.clear.y), window: points.clear)
        try rig.drag(to: CGPoint(x: 500, y: 500)); try rig.up(at: CGPoint(x: 500, y: 500))
        let log = try rig.log
        #expect(log.range(of: #"MOUSE-IGNORED kind=mouseDown tag=0000000000000000 src=[0-9]+ why=transparent et=[0-9]+\.[0-9]{6}\n"#, options: .regularExpression) != nil, "mouseDown/transparent (a mouse-down carries its event time stamp): \(log)")
        #expect(log.range(of: #"MOUSE-IGNORED kind=mouseDragged tag=0000000000000000 src=[0-9]+ why=untracked\n"#, options: .regularExpression) != nil, "mouseDragged/untracked: \(log)")
        #expect(log.range(of: #"MOUSE-IGNORED kind=mouseUp tag=0000000000000000 src=[0-9]+ why=untracked\n"#, options: .regularExpression) != nil, "mouseUp/untracked: \(log)")
        #expect(!log.contains("INPUT kind="), "none of these may reach the agent's input path")
        // v2 (spec 6.4): a second or third click on Clawd's body is a click for the scheduler, so three quick clicks can be counted. It is
        // delivered through `repeatedClick`, never through `input`, so v1's rule that a double click starts no drag still holds.
        rig.machine.pointer = CGPoint(x: 336 + points.opaque.x, y: 90 + points.opaque.y)
        rig.view.mouseDown(with: try rig.event(.leftMouseDown, at: points.opaque, clicks: 2))
        let after = try rig.log
        #expect(after.contains("INPUT kind=mouseDown"), "a double click on the body reaches the input path: \(after)")
        #expect(!after.contains("why=clickcount"))
    }
    @Test func Input_aHandledClickBackedByATaggedCGEventLogsItsTag() throws {
        let rig = try InputRig(saved: start)
        let hit = try rig.hitPoints(backing: 2).opaque
        // NSEvent(cgEvent:) of a window-less event reports the screen point (bottom-left origin), which the view converts like a window point.
        let primary = try #require(NSScreen.screens.first, "no screen attached: cannot place the event")
        let event = try tagged(.leftMouseDown, tag: 0x7a7a_7a7a_7a7a_0002, location: CGPoint(x: hit.x, y: primary.frame.height - hit.y))
        rig.machine.pointer = CGPoint(x: 336 + hit.x, y: 90 + hit.y)
        rig.view.mouseDown(with: event)
        let log = try rig.log
        #expect(log.contains("INPUT kind=mouseDown tag=7a7a7a7a7a7a0002 src="), "the handled path must log the tag of the event: \(log)")
        #expect(!log.contains("MOUSE-IGNORED"))
    }
}

struct SourceFile { let path: String; let text: String }
func swiftSources() throws -> [SourceFile] {
    let root = repository.appendingPathComponent("Sources")
    var found: [SourceFile] = []
    let enumerator = try #require(FileManager.default.enumerator(at: root, includingPropertiesForKeys: nil))
    for case let url as URL in enumerator where ["swift", "c", "h"].contains(url.pathExtension) {
        found.append(SourceFile(path: url.path, text: String(decoding: try ReadOnlyFile.data(url.path), as: UTF8.self)))
    }
    return found
}

// MARK: launchd guard and entry-point order

@Suite("Launchd-only start guard", .serialized)
struct LaunchdGuardSuite {
    private func record(_ pairs: [String: Any]) throws -> Data {
        try PropertyListSerialization.data(fromPropertyList: pairs, format: .xml, options: 0)
    }
    @Test func LaunchdGuard_requiresBothTheServiceNameAndTheMatchingPid() throws {
        let data = try record(["PID": 42])
        #expect(LaunchGuard.accepts(service: LaunchGuard.label, pid: 42, record: data))
        #expect(!LaunchGuard.accepts(service: nil, pid: 42, record: data))
        #expect(!LaunchGuard.accepts(service: "com.apple.something", pid: 42, record: data))
        #expect(!LaunchGuard.accepts(service: LaunchGuard.label, pid: 43, record: data))
        #expect(!LaunchGuard.accepts(service: LaunchGuard.label, pid: 42, record: nil))
    }
    @Test func LaunchdGuard_parsesTheOpenStepFormatLaunchctlPrints() {
        let listing = """
        {
        \t"LimitLoadToSessionType" = "Aqua";
        \t"Label" = "com.tomtim.clawd-pet";
        \t"OnDemand" = false;
        \t"LastExitStatus" = 0;
        \t"PID" = 4242;
        \t"Program" = "/Users/x/Library/Application Support/clawd-pet/bin/clawd-pet-agent";
        };
        """
        #expect(LaunchGuard.accepts(service: LaunchGuard.label, pid: 4242, record: Data(listing.utf8)))
        #expect(!LaunchGuard.accepts(service: LaunchGuard.label, pid: 4243, record: Data(listing.utf8)))
    }
    @Test func LaunchdGuard_aLoadedButNotRunningServiceHasNoPidAndIsRefused() {
        let listing = "{\n\t\"Label\" = \"com.tomtim.clawd-pet\";\n\t\"LastExitStatus\" = 0;\n};"
        #expect(!LaunchGuard.accepts(service: LaunchGuard.label, pid: 1234, record: Data(listing.utf8)))
    }
    @Test func LaunchdGuard_garbageOrEmptyRecordsAreRefused() {
        for garbage in ["", "not a plist", "{ \"PID\" = \"abc\"; }", "{ }", "[1,2,3]"] {
            #expect(!LaunchGuard.accepts(service: LaunchGuard.label, pid: 1, record: Data(garbage.utf8)), "\(garbage)")
        }
    }
    @Test func LaunchdGuard_thisProcessIsNotStartedByLaunchdSoTheGuardRefuses() {
        #expect(ProcessInfo.processInfo.environment["XPC_SERVICE_NAME"] != LaunchGuard.label)
        #expect(!LaunchGuard.allowed())
    }
    /// "Exits at once" without trusting the wall clock on a busy machine. A refused start does no work and ends by itself: its exit status says it
    /// ended by itself (the harness would have stopped it with a signal), and its CPU time says it did no work, on any machine (dyld and the guard
    /// cost tens of milliseconds, and a loaded machine does not turn waiting into CPU time). Its wall time is judged only when the machine is
    /// quiet, which two exits of the same binary on a path that refuses at once (an unknown test mode), made just before and just after the
    /// subject, say: on a loaded machine those take several times longer than usual, the subject also starts a launchctl of its own, and the
    /// seconds it needs say nothing about the guard.
    static let promptExitCPULimit = 0.5, quietReferenceLimit = 0.3
    private func promptExit(_ environment: [String: String] = [:]) throws -> (run: Execution, quiet: Bool, reference: Double) {
        func reference() throws -> Double { try execute(agentExecutable(), ["--test-unknown-mode"]).elapsed }
        let before = try reference()
        let run = try execute(agentExecutable(), [], environment: environment)
        let slowest = max(before, try reference())
        return (run, slowest < Self.quietReferenceLimit, slowest)
    }
    private func expectPromptExit(_ run: Execution, quiet: Bool, reference: Double, within seconds: Double) {
        #expect(run.code == 0, "it ends by itself with status 0 (a signal would mean the harness stopped it)")
        #expect(run.output.isEmpty)
        #expect(run.cpu < Self.promptExitCPULimit, "a refused start does no work: \(run.cpu) s of CPU")
        if quiet { #expect(run.elapsed < seconds, "it exits at once: \(run.elapsed) s") }
        else { emit("NOTE LaunchdGuard: the machine is busy (a reference exit took \(reference) s), so the wall time of the refused start (\(run.elapsed) s) was not judged; its CPU time (\(run.cpu) s) was") }
        #expect(run.provedWindowless)
    }
    @Test func LaunchdGuard_directExecExitsZeroWithinOneSecondAndNeverCreatesAWindow() throws {
        let (run, quiet, reference) = try promptExit()
        expectPromptExit(run, quiet: quiet, reference: reference, within: 1)
    }
    @Test func LaunchdGuard_aWrongServiceNameInTheEnvironmentIsRefusedToo() throws {
        let (run, quiet, reference) = try promptExit(["XPC_SERVICE_NAME": "com.apple.not-us"])
        expectPromptExit(run, quiet: quiet, reference: reference, within: 1)
    }
    @Test func LaunchdGuard_rightNameButNotLaunchdsPidIsRefusedToo() throws {
        // Terminal runs the Mach-O (what `open` does): the name can be forged, launchd's PID record cannot.
        let (run, quiet, reference) = try promptExit(["XPC_SERVICE_NAME": LaunchGuard.label])
        expectPromptExit(run, quiet: quiet, reference: reference, within: 2)
    }
    @Test func LaunchdGuard_aStartThatDoesWorkIsNotMistakenForAnExitAtOnce() throws {
        // The CPU limit is load-bearing: a child that burns CPU for a moment before it ends shows far more than the limit.
        let shell = URL(fileURLWithPath: "/bin/sh")
        let busy = try execute(shell, ["-c", "i=0; while [ $i -lt 40000 ]; do i=$((i+1)); done"])
        #expect(busy.code == 0)
        #expect(busy.cpu >= Self.promptExitCPULimit / 5, "the accounting sees the child's CPU: \(busy.cpu) s")
        let idle = try execute(shell, ["-c", "exit 0"])
        #expect(idle.cpu < busy.cpu, "an idle child costs less than a busy one: \(idle.cpu) against \(busy.cpu)")
    }
    @Test func LaunchdGuard_ownPidsBranchesBeforeTheGuardAndReportsACount() throws {
        let run = try execute(agentExecutable(), ["--own-pids"])
        #expect(run.code == 0)
        let lines = run.output.split(separator: "\n")
        #expect(lines.last?.hasPrefix("OWN-PIDS ") == true)
        #expect(!run.output.contains("enumeration failed"))
        #expect(run.provedWindowless)
    }
    @Test func LaunchdGuard_testModesBranchBeforeTheGuardAndStayHeadless() throws {
        let run = try execute(agentExecutable(), ["--test-entrypoint"])
        #expect(run.code == 0); #expect(run.output.contains("HEADLESS entrypoint")); #expect(run.provedWindowless)
        let unknown = try execute(agentExecutable(), ["--test-unknown-mode"])
        #expect(unknown.code == 2)
    }
    @Test func LaunchdGuard_mainDispatchesInTheRequiredOrder() throws {
        let main = String(decoding: try ReadOnlyFile.data(repository.appendingPathComponent("Sources/ClawdAgent/main.swift").path), as: UTF8.self)
        let order = ["\"--own-pids\"", "hasPrefix(\"--test-\")", "LaunchGuard.allowed()", "state.lock()", "AgentBoot.start"]
        var cursor = main.startIndex
        for token in order {
            let range = try #require(main.range(of: token, range: cursor..<main.endIndex), "missing or out of order: \(token)")
            cursor = range.upperBound
        }
        #expect(!main.contains("NSApplication"))
    }
    @Test func LaunchdGuard_sourceReadsTheXPCServiceNameAndEnumeratesWithProcListpids() throws {
        let joined = try swiftSources().map(\.text).joined(separator: "\n")
        #expect(joined.contains("XPC_SERVICE_NAME")); #expect(joined.contains("proc_listpids")); #expect(joined.contains("proc_pidpath"))
    }
    /// 2026-10-21: one unrelated process of the user's whose executable had been deleted (Stats' widget extension, after the app updated itself)
    /// made every --own-pids fail, so uninstall refused ("files retained") and the cli, update and install-interrupt suites failed. Such a
    /// process can be ours only if its own name is the agent's: other names are skipped; the agent's name still fails closed.
    /// Enumeration is judged the way the CLI judges it (bin/clawd-pet own_pids): five failures in a row fail closed, which makes a refusal
    /// caused by other processes starting and exiting unlikely to decide a check; each fail-closed check is paired with a success once that
    /// copy is stopped, which ties the failure to the copy (the rows in scripts/negative-controls tie it to the code).
    @Test(.timeLimit(.minutes(1)))
    func LaunchdGuard_ownPidsSkipsAnUnrelatedProcessWhoseExecutableIsGoneAndFailsClosedForTheAgentsName() throws {
        let dir = try artifactStore().root
        var held: [Process] = []
        func stop(_ process: Process) { if process.isRunning { process.terminate(); process.waitUntilExit() } }
        defer { held.forEach(stop) }
        func holdThenDelete(_ name: String) throws -> Process {
            let copy = dir.appendingPathComponent("\(name)-dir/\(name)")
            try FileManager.default.createDirectory(at: copy.deletingLastPathComponent(), withIntermediateDirectories: true)
            try FileManager.default.copyItem(at: agentExecutable(), to: copy)
            // The hold outlasts the test's time limit, so the copy cannot expire between the checks.
            let process = Process(); process.executableURL = copy; process.arguments = ["--test-hold", "90"]
            process.environment = ProcessInfo.processInfo.environment.merging(["HOME": dir.path]) { $1 }
            let sink = Pipe(); process.standardOutput = sink; process.standardError = sink
            try process.run()
            held.append(process)
            var announced = Data()
            while !announced.contains(UInt8(ascii: "\n")) {   // blocks until the line is complete; EOF means it never held
                let chunk = sink.fileHandleForReading.availableData
                if chunk.isEmpty { break }
                announced.append(chunk)
            }
            try #require(String(decoding: announced, as: UTF8.self) == "HOLDING \(process.processIdentifier)\n")
            try FileManager.default.removeItem(at: copy)   // its executable is gone, as Stats' was
            try #require(kill(process.processIdentifier, 0) == 0, "\(name) still runs")
            try #require(throws: ProcessFailure.lookup, "\(name) has no executable path") { _ = try ProcessPath.of(pid: process.processIdentifier) }
            return process
        }
        func enumerates(_ path: String) -> Bool {
            (0..<5).contains { _ in (try? OwnPids.enumerate(path: path)) != nil }
        }
        let elsewhere = dir.appendingPathComponent("not-installed/clawd-pet-agent").path
        _ = try holdThenDelete("widget-extension")
        #expect(enumerates(elsewhere), "an unrelated process with no executable is skipped")
        // An install file name longer than the kernel's 32-byte name field: the running copy's name is cut short and must still count.
        let long = "clawd-pet-agent-installed-under-a-long-file-name"
        let longPath = dir.appendingPathComponent("not-installed/\(long)").path
        let longAgent = try holdThenDelete(long)
        #expect(!enumerates(longPath), "a cut-short agent name with no executable keeps it fail-closed")
        stop(longAgent)
        #expect(enumerates(longPath), "and the failure was that copy's")
        let agent = try holdThenDelete("clawd-pet-agent")
        #expect(!enumerates(elsewhere), "a process named like the agent with no executable keeps it fail-closed")
        stop(agent)
        #expect(enumerates(elsewhere), "and the failure was that copy's")
    }
    /// Why the name decides for a pathless process: every agent runs under the install file name. launchd starts only the launcher the
    /// plist names, the launcher execs `<its directory>/AGENT_NAME` (launcher/launcher.c), and the agent refuses any start launchd did
    /// not make (LaunchGuard.allowed). If these three names drift apart, own-pids could skip a running agent whose file is gone.
    @Test func LaunchdGuard_everyAgentRunsUnderTheInstallFileNameTheLauncherExecs() throws {
        func quoted(_ file: String, after prefix: String) throws -> String? {
            let text = try String(contentsOf: repository.appendingPathComponent(file), encoding: .utf8)
            return text.split(separator: "\n").first { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count).prefix { $0 != "\"" }) }
        }
        let execed = try #require(try quoted("launcher/launcher.c", after: "#define AGENT_NAME \""))
        let installed = try #require(try quoted("bin/clawd-pet", after: "AGENT=\"$ROOT/bin/"))
        #expect(!execed.isEmpty)
        #expect(execed == URL(fileURLWithPath: OwnPids.installPath).lastPathComponent)
        #expect(installed == execed)
    }
    /// Codex 20261021-182531-efcb44: the name rule read a name the kernel had cut short as a different name, and skipped a process with
    /// no name at all; both must keep the enumeration fail-closed.
    @Test func LaunchdGuard_aProcessNameIsTheAgentsWhenEqualOrCutShortAndUnknownWhenEmpty() {
        func field(_ text: String, _ capacity: Int) -> [CChar] {
            var bytes = [CChar](repeating: 0, count: capacity)
            for (i, byte) in text.utf8.prefix(capacity).enumerated() { bytes[i] = CChar(bitPattern: byte) }
            return bytes
        }
        func may(name: String, comm: String, _ base: String) -> Int32 {
            clawd_names_may_be(field(name, 32), 32, field(comm, 16), 16, base)
        }
        let long = "clawd-pet-agent-installed-under-a-long-file-name"
        #expect(may(name: "clawd-pet-agent", comm: "clawd-pet-agent", "clawd-pet-agent") == 1)
        #expect(may(name: "WidgetsExtension", comm: "WidgetsExtensio", "clawd-pet-agent") == 0)
        #expect(may(name: "clawd", comm: "clawd", "clawd-pet-agent") == 0, "a name that did not fill its field is a different file")
        #expect(may(name: String(long.prefix(31)), comm: String(long.prefix(15)), long) == 1, "31 bytes and a NUL: cut short")
        #expect(may(name: String(long.prefix(32)), comm: String(long.prefix(16)), long) == 1, "32 bytes with no NUL: cut short")
        #expect(may(name: "", comm: "clawd-pet-agent", "clawd-pet-agent") == 1, "no pbi_name: pbi_comm decides")
        #expect(may(name: "", comm: "WidgetsExtensio", "WidgetsExtension") == 1, "pbi_comm keeps 15 of 16 bytes")
        #expect(may(name: "", comm: "WidgetsExtensio", "clawd-pet-agent") == 0)
        #expect(may(name: "", comm: "", "clawd-pet-agent") == -1, "no name at all is unknown, not a different name")
    }
    @Test func LaunchdGuard_ownPidsFindsAProcessByExactInstallPathAndNothingElse() throws {
        let home = try artifactStore().root
        let installed = home.appendingPathComponent("Library/Application Support/clawd-pet/bin/clawd-pet-agent")
        try FileManager.default.createDirectory(at: installed.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: agentExecutable(), to: installed)
        let holder = Process(); holder.executableURL = installed; holder.arguments = ["--test-hold", "30"]
        holder.environment = ProcessInfo.processInfo.environment.merging(["HOME": home.path]) { $1 }
        let sink = Pipe(); holder.standardOutput = sink; holder.standardError = sink
        try holder.run()
        defer { holder.terminate(); holder.waitUntilExit() }
        let announced = String(decoding: sink.fileHandleForReading.availableData, as: UTF8.self)   // blocks until it prints
        #expect(announced.hasPrefix("HOLDING \(holder.processIdentifier)"))
        let run = try execute(installed, ["--own-pids"], environment: ["HOME": home.path])
        #expect(run.code == 0)
        let lines = run.output.split(separator: "\n").map(String.init)
        #expect(lines.last == "OWN-PIDS 1")
        let fields = lines.first?.split(separator: " ").map(String.init) ?? []
        #expect(fields.count == 4); #expect(fields.first == "PID"); #expect(fields.dropFirst().first == String(holder.processIdentifier))
        // The enumerating process itself is excluded, and a different path matches nothing.
        let other = try execute(agentExecutable(), ["--own-pids"], environment: ["HOME": home.path])
        #expect(other.output.split(separator: "\n").last.map(String.init) == "OWN-PIDS 1")
        let none = try execute(installed, ["--own-pids"], environment: ["HOME": try artifactStore().root.path])
        #expect(none.output.split(separator: "\n").last.map(String.init) == "OWN-PIDS 0")
    }
    /// Stage SA, Sprint SA4 (S1-prep): `--own-pids PATH` lists the processes running the executable at that absolute path; with no path it is the install
    /// path, as `bin/clawd-pet` asks. The copy that is looked for runs headless (`--test-hold`), never a window. It lives in this serialized suite and under
    /// another file name than the agent's: an enumeration that meets an agent-named process with no readable path (one that is starting or ending) fails
    /// closed by design, so no other test of this suite or of this one may start or end such a process while a `--own-pids` runs.
    @Test func LaunchdGuard_ownPidsTakesAnExplicitPath() throws {
        let base = try artifactStore().root
        let elsewhere = base.appendingPathComponent("elsewhere/explicit-path-holder")
        try FileManager.default.createDirectory(at: elsewhere.deletingLastPathComponent(), withIntermediateDirectories: true)
        try FileManager.default.copyItem(at: agentExecutable(), to: elsewhere)
        let holder = Process(); holder.executableURL = elsewhere; holder.arguments = ["--test-hold", "30"]
        let sink = Pipe(); holder.standardOutput = sink; holder.standardError = sink
        try holder.run()
        defer { holder.terminate(); holder.waitUntilExit() }
        let announced = String(decoding: sink.fileHandleForReading.availableData, as: UTF8.self)   // blocks until it prints
        #expect(announced.hasPrefix("HOLDING \(holder.processIdentifier)"))
        // An unrelated HOME: its install path holds nothing, so only the explicit path can find the holder.
        let home = try artifactStore().root.path
        // `--own-pids` fails with exit 2 when the kernel refuses to describe a process that is mid-exec or mid-exit; bin/clawd-pet's own_pids
        // retries that five times, 0.1 s apart, and so does this test (only for that failure, never for a usage error).
        func ownPids(_ arguments: [String], environment: [String: String]) throws -> Execution {
            var run = try execute(agentExecutable(), arguments, environment: environment)
            var tries = 1
            while run.code == 2 && run.output.contains("OWN-PIDS enumeration failed") && tries < 5 {
                Thread.sleep(forTimeInterval: 0.1)
                run = try execute(agentExecutable(), arguments, environment: environment)
                tries += 1
            }
            return run
        }
        let byPath = try ownPids(["--own-pids", elsewhere.path], environment: ["HOME": home])
        #expect(byPath.code == 0 && byPath.provedWindowless)
        let lines = byPath.output.split(separator: "\n").map(String.init)
        #expect(lines.last == "OWN-PIDS 1", "\(byPath.output)")
        let fields = lines.first?.split(separator: " ").map(String.init) ?? []
        #expect(fields.count == 4 && fields.first == "PID" && fields.dropFirst().first == String(holder.processIdentifier), "\(lines)")
        // With no path it is the install path under HOME, which holds nothing.
        let byDefault = try ownPids(["--own-pids"], environment: ["HOME": home])
        #expect(byDefault.code == 0 && byDefault.output.split(separator: "\n").last.map(String.init) == "OWN-PIDS 0", "\(byDefault.output)")
        // A path with nothing at it is a count of 0, not a failure.
        let nothing = try ownPids(["--own-pids", base.appendingPathComponent("no-such-agent").path], environment: ["HOME": home])
        #expect(nothing.code == 0 && nothing.output.split(separator: "\n").last.map(String.init) == "OWN-PIDS 0", "\(nothing.output)")
        // A relative path, an empty one and a second word are usage errors: exit 2, no count, and no path in the line.
        for bad in [["--own-pids", "relative/agent"], ["--own-pids", ""], ["--own-pids", elsewhere.path, "extra"]] {
            let run = try ownPids(bad, environment: ["HOME": home])
            #expect(run.code == 2 && !run.output.contains("OWN-PIDS 0") && !run.output.contains("OWN-PIDS 1"), "\(bad): \(run.code) \(run.output)")
            #expect(!run.output.contains(elsewhere.path) && !run.output.contains("relative"), "the line names no path: \(run.output)")
        }
    }
}

// MARK: observers before the panel

private final class RecordingHost: BootHost {
    var calls: [String] = []
    func registerFocusObservers() throws { calls.append("registerFocusObservers") }
    func setAccessoryPolicy() { calls.append("setAccessoryPolicy") }
    func finishLaunching() { calls.append("finishLaunching") }
    func createPanelAndRuntime() throws { calls.append("createPanelAndRuntime") }
    func run() { calls.append("run") }
}

@Suite("Observers registered before the panel", .serialized)
@MainActor
struct ObserverOrderSuite {
    @Test func ObserverOrder_bootRegistersObserversBeforeLaunchFinishesAndBeforeThePanelExists() throws {
        let host = RecordingHost()
        let steps = try AgentBoot.start(host: host)
        #expect(host.calls == ["registerFocusObservers", "setAccessoryPolicy", "finishLaunching", "createPanelAndRuntime", "run"])
        #expect(steps == [.observersRegistered, .accessoryPolicySet, .finishedLaunching, .panelCreated, .running])
    }
    @Test func ObserverOrder_aFailureWhileRegisteringStopsBeforeAnythingElseHappens() {
        final class Failing: BootHost {
            var calls: [String] = []
            func registerFocusObservers() throws { calls.append("register"); throw FileFailure.unsafePath }
            func setAccessoryPolicy() { calls.append("policy") }
            func finishLaunching() { calls.append("finish") }
            func createPanelAndRuntime() throws { calls.append("panel") }
            func run() { calls.append("run") }
        }
        let host = Failing()
        #expect(throws: (any Error).self) { try AgentBoot.start(host: host) }
        #expect(host.calls == ["register"])
    }
    @Test func ObserverOrder_anActivationFromAPanelCreatedLaterIsStillSeen() throws {
        let center = NotificationCenter()
        let focus = FocusMonitor(store: try artifactStore(), center: center)     // first
        let panel = PetPanel(overFullScreen: false)                              // then the panel
        center.post(name: NSWindow.didBecomeKeyNotification, object: panel)
        #expect(focus.status.focusViolations == 1)
    }
    @Test func ObserverOrder_negativeControl_observersCreatedAfterThePanelMissTheFirstActivation() throws {
        func nothingMissed(observersFirst: Bool) throws -> Bool {
            let center = NotificationCenter(); let store = try artifactStore()
            var focus: FocusMonitor? = observersFirst ? FocusMonitor(store: store, center: center) : nil
            let panel = PetPanel(overFullScreen: false)
            center.post(name: NSWindow.didBecomeKeyNotification, object: panel)      // the activation that must not be missed
            if focus == nil { focus = FocusMonitor(store: store, center: center) }
            return focus!.status.focusViolations == 1
        }
        #expect(try nothingMissed(observersFirst: true))
        negativeControl("observers-after-panel", expectationHolds: try nothingMissed(observersFirst: false))
    }
    @Test func ObserverOrder_allThreeNotificationsAreWatched() {
        #expect(Set(FocusMonitor.watched) == [NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification,
                                              NSWindow.didBecomeMainNotification])
    }
    @Test func ObserverOrder_theMonitorIsBuiltBeforeNSApplicationIsTouchedInTheProductionHost() throws {
        let boot = String(decoding: try ReadOnlyFile.data(repository.appendingPathComponent("Sources/ClawdDesktop/Boot.swift").path), as: UTF8.self)
        let register = try #require(boot.range(of: "func registerFocusObservers() throws { monitor = FocusMonitor"))
        let policy = try #require(boot.range(of: "NSApplication.shared.setActivationPolicy"))
        #expect(register.lowerBound < policy.lowerBound)
        // The first use of NSApplication.shared anywhere in the file is the policy call, after the monitor exists.
        let firstUse = try #require(boot.range(of: "NSApplication.shared"))
        #expect(firstUse.lowerBound > register.lowerBound)
        #expect(firstUse.lowerBound == policy.lowerBound)
    }
    @Test func ObserverOrder_statusCountersStartUnobservedSoTheCliCanSayNotYetObserved() {
        let status = AgentStatus()
        #expect(status.wakeCount == 0); #expect(status.displayChangeCount == 0); #expect(status.focusViolations == 0)
    }
}
