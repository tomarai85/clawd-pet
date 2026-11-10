import AppKit
import ClawdCore
import ClawdRendering

public enum MenuCloseReason: String, CaseIterable { case pick, outside, away, dictation, hidden, drag, toggle, geometry, chat }
public enum MenuOpenHow: String { case right, control }
public enum MenuRequestResult: Equatable {
    case opened
    /// The menu was open: this right-click closed it.
    case toggled
    /// A higher state holds (a dictation scene, a drag, hidden, a quiet condition), or nothing is on screen.
    case busy
}

/// The timer the menu uses for its two deadlines (the 140 ms flash, the 8 s away rule): one timer, armed only while the menu is open.
public protocol MenuTimerSource: PetTimerScheduler {
    var onFire: (() -> Void)? { get set }
}
extension DispatchPetTimer: MenuTimerSource {}

/// What the controller needs from the runtime that owns the windows and the scheduler.
public protocol MenuHost: AnyObject {
    /// The values the agent runs with now (the current generation).
    func menuSelection() -> MenuSelection
    /// Where the menu goes now, in global points; nil when Clawd is not on screen.
    func menuPlacement() -> CGRect?
    /// Opens the menu: the scheduler's hold and the menu window in ONE render, so the open picture shows the cut and the menu together and
    /// the GEOM line that render writes is the interval's geometry. `gen` is the number this opening will have. nil: the scheduler refused.
    func menuShow(gen: Int, rect: CGRect) -> MenuSurface?
    /// Closes the menu: the scheduler's hold ends (`menuClosed()` exactly once) and the window is taken away. `render` is false when
    /// the windows are already going (hidden, a quiet condition): nothing is drawn then.
    func menuHide(render: Bool)
    /// The chat entry was picked and the menu has closed (its window is gone and the scheduler's hold has ended): opens or closes the chat
    /// panel by the same path as a double-click. `eventTime` is the pick's own time stamp.
    func menuToggleChat(eventTime: TimeInterval)
    /// The Settings… entry was picked and the menu has closed at its flash: opens the Settings window on Clawd's display.
    func menuOpenSettings(eventTime: TimeInterval)
    /// The Quit Clawd entry was picked and the menu has closed at its flash.
    func menuQuit()
}

/// The right-click menu's rules (spec 5.2, rulings 3 and 5, and the attended check's R-HOLD / R-GEN): when it opens and closes, which opening
/// a click or a late callback belongs to, what a pick does, and what the agent logs about it.
///
/// Every opening has a number, `gen`, that starts at 1 in the process and rises by one for each opening that succeeds (a refused right-click
/// takes none). Every MENU line names it. The outside-click monitor of an opening captures its gen and acts only while that same opening is
/// the live one, so a copy that arrives after its own close, or after a later opening, changes nothing.
public final class MenuController: MenuViewDelegate {
    public private(set) var generation = 0
    public var isOpen: Bool { live != nil }
    public var liveGeneration: Int? { live?.gen }
    public private(set) var picks = 0
    /// The next pick number, for a pick the menu bar icon makes: one numbering for every pick the shared writer runs.
    public func takePickID() -> Int { picks += 1; return picks }

    private struct Opening {
        let gen: Int
        let surface: MenuSurface
        var token: AnyObject?
        var pending: MenuPick?
        /// The chat entry was picked: the event time of the pick. The panel toggles after the menu has closed.
        var pendingChat: TimeInterval?
        /// Settings… and Quit Clawd were picked: they run at the flash's close, like the chat entry.
        var pendingSettings: TimeInterval?
        var pendingQuit: TimeInterval?
        var flashEnd: TimeInterval?
        var awayAt: TimeInterval?
        var hovered: String?
    }
    private var live: Opening?
    private unowned let host: MenuHost
    private let clock: PetClock
    private let timer: MenuTimerSource
    private let source: MenuOutsideClickSource
    private let writer: MenuWriter
    private let log: (String) -> Void

    public init(host: MenuHost, clock: PetClock, timer: MenuTimerSource, source: MenuOutsideClickSource, writer: MenuWriter,
                log: @escaping (String) -> Void) {
        self.host = host; self.clock = clock; self.timer = timer; self.source = source; self.writer = writer; self.log = log
        timer.onFire = { [weak self] in self?.timerFired() }
    }

    private static func stamp(_ time: TimeInterval) -> String { String(format: "%.6f", time) }

    // MARK: opening and closing

    /// A right-click or a control-click on Clawd's body. `eventTime` is the event's own time stamp.
    public func request(how: MenuOpenHow, eventTime: TimeInterval) -> MenuRequestResult {
        if live != nil { close(.toggle, et: eventTime); return .toggled }
        guard let rect = host.menuPlacement() else { return .busy }
        let gen = generation + 1
        guard let surface = host.menuShow(gen: gen, rect: rect) else { return .busy }
        generation = gen
        let token = source.install { [weak self] time in self?.outsideClick(gen: gen, time: time) }
        live = Opening(gen: gen, surface: surface, token: token, pending: nil, pendingChat: nil, pendingSettings: nil, pendingQuit: nil, flashEnd: nil, awayAt: clock.now + MenuMetrics.awaySeconds, hovered: nil)
        surface.armTracking()
        rearm()
        log("MENU open et=\(Self.stamp(eventTime)) how=\(how.rawValue) gen=\(gen)")
        return .opened
    }

    /// Closes the open menu (a no-op when none is open). `et` is the event that closed it, for an outside click and a second right-click.
    public func close(_ reason: MenuCloseReason, et: TimeInterval? = nil, render: Bool = true) {
        guard let opening = live else { return }
        live = nil
        timer.cancel()
        if let token = opening.token { source.remove(token) }
        opening.surface.disarmTracking()
        var stamp = ""
        if let et, reason == .outside || reason == .toggle { stamp = " et=" + Self.stamp(et) }
        log("MENU close reason=\(reason.rawValue)\(stamp) gen=\(opening.gen)")
        host.menuHide(render: render)
        // Settings picked in the menu apply after it has closed: the child starts here, after the close render.
        if let pick = opening.pending {
            writer.submit(pick)
            // The selection is in the writer now: a pick that may restart the agent can start (it waited behind the flash).
            writer.releaseRestarts()
        }
        // The chat entry: the panel opens or closes only now, after the menu window is gone, so it never takes focus under the menu. Only the
        // close that the pick itself ends (the flash) honours it; any other close drops it and says so.
        if let time = opening.pendingChat {
            if reason == .pick { host.menuToggleChat(eventTime: time) } else { log("MENU chat-dropped reason=\(reason.rawValue) gen=\(opening.gen)") }
        }
        if let time = opening.pendingSettings {
            if reason == .pick { host.menuOpenSettings(eventTime: time) } else { log("MENU settings-dropped reason=\(reason.rawValue) gen=\(opening.gen)") }
        }
        if opening.pendingQuit != nil {
            if reason == .pick { host.menuQuit() } else { log("MENU quit-dropped reason=\(reason.rawValue) gen=\(opening.gen)") }
        }
    }

    /// Closes the open menu only when it is the opening numbered `gen` (a press that began under that opening ends: amendment R-BODY).
    /// False, and nothing logged, when no menu is open or the live one is another opening.
    @discardableResult
    public func closeIfLive(gen: Int, _ reason: MenuCloseReason, et: TimeInterval?) -> Bool {
        guard let opening = live, opening.gen == gen else { return false }
        close(reason, et: et)
        return true
    }

    /// A dictation started: the host calls this inside the batch that starts the scene, before its change is drawn.
    public func closeForDictation() { close(.dictation) }
    /// A drag started (inside the batch that starts it).
    public func closeForDrag() { close(.drag) }
    /// The windows are going (hidden, a quiet condition): nothing is drawn by this close.
    public func closeForHidden() { close(.hidden, render: false) }

    /// The settings changed while the menu is open (a generation applied): the menu shows the truth.
    public func settingsApplied() {
        guard let live else { return }
        live.surface.update(selection: host.menuSelection())
    }

    // MARK: the outside-click monitor of one opening

    func outsideClick(gen: Int, time: TimeInterval) {
        guard let opening = live, opening.gen == gen else {
            log("MENU stale kind=outside et=\(Self.stamp(time)) gen=\(gen) live=\(live.map { String($0.gen) } ?? "none")")
            return
        }
        close(.outside, et: time)
    }

    // MARK: deadlines

    private func rearm() {
        timer.cancel()
        guard let live, let next = [live.flashEnd, live.awayAt].compactMap({ $0 }).min() else { return }
        timer.arm(after: max(0.001, next - clock.now), leeway: 0.005)
    }

    /// The menu's one timer fired.
    public func timerFired() {
        guard let opening = live else { return }
        let now = clock.now
        if let end = opening.flashEnd, end <= now { close(.pick); return }
        if let away = opening.awayAt, away <= now { close(.away); return }
        rearm()
    }

    // MARK: what the menu's window tells

    public func menuView(gen g: Int, mouseDown event: NSEvent, kind: String, hit: MenuHit) {
        let et = Self.stamp(event.timestamp)
        func ignored(_ why: String) {
            log("MOUSE-IGNORED kind=\(kind) \(InputProvenance.fields(of: event)) why=menu-\(why) et=\(et) gen=\(g)")
        }
        // A click that reached a window of an opening that is no longer the live one is never a pick.
        guard let opening = live, opening.gen == g else { ignored("stale"); return }
        if opening.flashEnd != nil { ignored("flash"); return }
        switch hit {
        case .item(let item) where kind == "mouseDown": pick(item, event: event, opening: opening)
        case .muted: ignored("muted")
        case .separator: ignored("separator")
        case .item, .gap: ignored("gap")
        }
    }

    private func pick(_ item: MenuItem, event: NSEvent, opening: Opening) {
        if item.key == "chat", item.clickable {
            picks += 1
            log("MENU pick id=\(picks) et=\(Self.stamp(event.timestamp)) key=\(item.key) value=\(item.value) gen=\(opening.gen)")
            live?.pendingChat = event.timestamp
            live?.flashEnd = clock.now + MenuMetrics.flashSeconds
            opening.surface.flash(item)
            rearm()
            return
        }
        if (item.key == "settings" || item.key == "quit"), item.clickable {
            picks += 1
            log("MENU pick id=\(picks) et=\(Self.stamp(event.timestamp)) key=\(item.key) value=\(item.value) gen=\(opening.gen)")
            if item.key == "settings" { live?.pendingSettings = event.timestamp } else { live?.pendingQuit = event.timestamp }
            live?.flashEnd = clock.now + MenuMetrics.flashSeconds
            opening.surface.flash(item)
            rearm()
            return
        }
        guard let action = host.menuSelection().action(for: item) else { return }
        picks += 1
        let made = MenuPick(id: picks, action: action, gen: opening.gen)
        log("MENU pick id=\(made.id) et=\(Self.stamp(event.timestamp)) key=\(made.key) value=\(made.value) gen=\(made.gen)")
        // A child that may restart the agent runs: this selection cannot run before it, and would die with it. Refused at once; the menu still
        // flashes and closes as after any pick, and nothing is held or submitted.
        if let by = writer.restartRunningID {
            log("MENU refuse id=\(made.id) why=restarting by=\(by) gen=\(made.gen)")
            live?.flashEnd = clock.now + MenuMetrics.flashSeconds
            opening.surface.flash(item)
            rearm()
            return
        }
        live?.pending = made
        writer.holdRestarts()
        live?.flashEnd = clock.now + MenuMetrics.flashSeconds
        opening.surface.flash(item)
        rearm()
    }

    public func menuView(gen g: Int, hover item: MenuItem?) {
        guard let opening = live, opening.gen == g else { return }
        guard let item else { live?.hovered = nil; return }
        let name = item.key + "/" + item.value
        guard opening.hovered != name else { return }
        live?.hovered = name
        log("MENU hover key=\(item.key) value=\(item.value) gen=\(g)")
    }

    public func menuView(gen g: Int, pointerInside inside: Bool) {
        guard let opening = live, opening.gen == g else { return }
        let wanted: TimeInterval? = inside ? nil : (opening.awayAt ?? clock.now + MenuMetrics.awaySeconds)
        guard live?.awayAt != wanted else { return }
        live?.awayAt = wanted
        rearm()
    }
}
