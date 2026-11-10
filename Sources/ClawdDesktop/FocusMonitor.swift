import AppKit
import ClawdCore

public struct AgentStatus: Codable {
    public var focusViolations = 0
    public var wakeCount = 0
    public var displayChangeCount = 0
    public var lastEvent: Date?
    public var scene = "idle"
    public var sourceBEnabled = false
    public var idleBudgetMode = false
    /// nil for the installed agent; "test-idle-no-window" or "test-idle-render-no-window" for the headless idle entries used by the CPU measurement.
    public var mode: String?
    /// The process that wrote this file. `clawd-pet update` tells a restarted agent from the one it replaced by this pid: the file
    /// outlives a process, so the old process's `appliedGeneration` would otherwise confirm a restart that has not happened yet.
    public var pid: Int32?
    /// v2: the last `generation` of control.json the agent has applied (the CLI waits for it), and the settings now in effect.
    public var appliedGeneration: Int?
    public var look: String?
    /// The active scheduler quiet reason, or "none". Absent in status files from older agents.
    public var quiet: String?
    /// Wall epoch seconds of the scheduler's due threshold; absent when there is no automatic change due.
    public var nextLookChange: Double?
    public var walk: Bool?
    public var motion: String?
    public var bubble: Bool?
    /// The restart-only keys (`AgentControl.restartKeyNames`) whose value in control.json differs from the value this process started with,
    /// and the generation that carries them. While there are any, `appliedGeneration` does not advance to that generation: the setting is
    /// saved but not in effect, and `clawd-pet` restarts the agent for it. Both are absent when nothing is pending.
    public var restartRequired: [String]?
    /// The resolved Aqua mode ("follow" or "ignore") this process runs with; absent in an older build's file.
    public var aquaMode: String?
    public var restartGeneration: Int?
    /// v2 (focus-violation ledger): how many violations the agent could not append to `focus-violations.log`. Absent in an older
    /// build's file, which decodes it as nil; an older build ignores the key.
    public var ledgerFailures: Int?
    public init() {}

    /// Records that this process has applied `generation` live. `restartKeys` are the restart-only keys that generation changed: with any,
    /// the generation is NOT confirmed and the keys are recorded instead; with none, it is confirmed and nothing is pending.
    public mutating func settingsApplied(generation: Int, restartKeys: [String]) {
        if restartKeys.isEmpty {
            appliedGeneration = generation; restartRequired = nil; restartGeneration = nil
        } else {
            restartRequired = restartKeys; restartGeneration = generation
        }
    }
}

/// Logs every activation, key and main notification this process ever receives, with the trigger context.
/// It must be created before NSApplication is touched, before finishLaunching and before any panel exists.
public final class FocusMonitor {
    public static let watched: [Notification.Name] = [
        NSApplication.didBecomeActiveNotification, NSWindow.didBecomeKeyNotification, NSWindow.didBecomeMainNotification
    ]
    public var context = "launch"
    public var status: AgentStatus
    public let store: OwnState
    /// Production wiring hands focus back; tests leave it empty.
    public var onViolation: (() -> Void)?
    /// The chat panel's exemption (F1.5), installed by the runtime: asked about every key notification with the window it names. `.exempt`
    /// means the live chat panel became key with the user's cause (logged by the asker, not counted); `.uncaused` means the same panel
    /// became key without one (logged by the asker, counted like any other); nil means it is not the chat panel. With no query installed
    /// nothing is exempt (fail closed).
    public var keyExemption: ((NSWindow?) -> ChatKeyVerdict?)?
    /// The chat panel resigned key; installed by the runtime for its `CHAT resign` line.
    public var keyResigned: ((NSWindow?) -> Void)?
    /// The chat's judgment of an application activation (Sprint 3e): `.exempt` is the open panel's own activation (not recorded);
    /// `.answeredByClose` is one the controller answers by closing the panel (recorded, `onViolation` not called); `.violation` is recorded and
    /// `onViolation` runs. With no query installed every activation is a violation (fail closed).
    public var activationVerdict: (() -> ChatActivationVerdict)?
    /// `willBecomeActive` and `didResignActive`, for the controller's activation bookkeeping; they are never violations.
    public var appWillBecomeActive: (() -> Void)?
    public var appResigned: (() -> Void)?

    // The surfaces that may claim an activation or a key are asked in a fixed order: Settings, then the chat (design 4.5, H1). Nothing closes
    // and nothing is recorded until every surface has answered.
    /// Settings' answer for a key notification: the same verdicts as the chat's, for Settings' own windows only; nil means not Settings'.
    public var settingsKeyExemption: ((NSWindow?) -> ChatKeyVerdict?)?
    /// Claim step, Settings: true is "mine, with a cause". Declining changes nothing in Settings.
    public var settingsActivationClaim: (() -> Bool)?
    /// Another surface claimed the activation: Settings clears its waiting state and resolves its waiting keys as exempt.
    public var settingsActivationClaimedElsewhere: (() -> Void)?
    /// No surface claimed it: Settings judges the keys that waited for it as uncaused.
    public var settingsActivationUnclaimed: (() -> Void)?
    /// Claim step, the chat: the exempt branches of its old verdict. True is "mine".
    public var chatActivationClaim: (() -> Bool)?
    public var chatActivationClaimedElsewhere: (() -> Void)?
    /// Unclaimed step, the chat: its close (`answeredByClose`, recorded, `onViolation` not run) when it is open, else `violation`.
    public var chatUnclaimedActivation: (() -> ChatActivationVerdict)?
    /// Whether Clawd's current activation is claimed: set when the claim step accepts any surface's claim, cleared at `didResignActive`.
    /// Every surface's return test reads it (a key on an already-open window inside a claimed activation is a return).
    public private(set) var activationClaimed = false
    /// Whether an activation step is running now. A waiting key's resolver that a nested event pass inside the step runs early judges nothing:
    /// every exit of the step judges the waiting keys. A count, so a step inside a step ends only its own.
    public var activationStepRunning: Bool { stepDepth > 0 }
    private var stepDepth = 0
    /// The menu bar icon's trace (M17): told of every activation, key and main notification, it writes its own line only inside the menu's interval.
    public var statusTrace: ((Notification.Name, NSWindow?) -> Void)?
    private var observations: [NSObjectProtocol] = []
    private let center: NotificationCenter

    public init(store: OwnState, center: NotificationCenter = .default) {
        self.store = store; self.center = center
        status = (try? store.readJSON(AgentStatus.self, from: "status.json")) ?? AgentStatus()
        // What a previous process reported about itself is not this process's: the counts stay (they run since the install), the
        // pid is this one's, and appliedGeneration stays empty until this process has applied control.json.
        status.pid = ProcessInfo.processInfo.processIdentifier
        status.appliedGeneration = nil
        status.quiet = nil; status.nextLookChange = nil
        status.restartRequired = nil; status.restartGeneration = nil
        for name in Self.watched {
            observations.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let self else { return }
                self.statusTrace?(note.name, note.object as? NSWindow)
                if note.name == NSWindow.didBecomeKeyNotification {
                    let window = note.object as? NSWindow
                    // Settings first, then the chat; each answers only for its own windows. A window no surface owns falls through to a violation.
                    switch self.settingsKeyExemption?(window) {
                    case .exempt?, .deferred?: return
                    case .uncaused?: self.record(note.name); return
                    case nil: break
                    }
                    switch self.keyExemption?(window) {
                    case .exempt?, .deferred?: return
                    case .uncaused?: self.record(note.name, answeredByClose: true); return
                    case nil: break
                    }
                }
                if note.name == NSApplication.didBecomeActiveNotification {
                    switch self.activationStep() {
                    case .claimed: return
                    case .answeredByClose: self.record(note.name, answeredByClose: true); return
                    case .violation: break
                    }
                }
                self.record(note.name)
            })
        }
        observations.append(center.addObserver(forName: NSApplication.willBecomeActiveNotification, object: nil, queue: .main) { [weak self] note in
            self?.statusTrace?(note.name, nil)
            self?.appWillBecomeActive?()
        })
        observations.append(center.addObserver(forName: NSApplication.didResignActiveNotification, object: nil, queue: .main) { [weak self] _ in
            self?.activationClaimed = false
            self?.appResigned?()
        })
        observations.append(center.addObserver(forName: NSWindow.didResignKeyNotification, object: nil, queue: .main) { [weak self] note in
            self?.keyResigned?(note.object as? NSWindow)
        })
    }
    deinit { observations.forEach(center.removeObserver) }

    private enum ActivationStep { case claimed, answeredByClose, violation }

    /// An application activation, in three steps (design 4.5): the claim step asks Settings and then the chat; a claim is recorded and the other
    /// surface is told; when nobody claims, the unclaimed step is the chat's close when it is open (recorded, `onViolation` not run), else a violation.
    private func activationStep() -> ActivationStep {
        stepDepth += 1
        defer { stepDepth -= 1 }
        if settingsActivationClaim?() == true {
            activationClaimed = true
            chatActivationClaimedElsewhere?()
            return .claimed
        }
        if let claim = chatActivationClaim {
            if claim() {
                activationClaimed = true
                settingsActivationClaimedElsewhere?()
                return .claimed
            }
            settingsActivationUnclaimed?()
            return chatUnclaimedActivation?() == .answeredByClose ? .answeredByClose : .violation
        }
        // A rig that installs only the chat's composed verdict: claim and close in one call.
        switch activationVerdict?() ?? .violation {
        case .exempt:
            activationClaimed = true
            settingsActivationClaimedElsewhere?()
            return .claimed
        case .answeredByClose:
            settingsActivationUnclaimed?()
            return .answeredByClose
        case .violation:
            settingsActivationUnclaimed?()
            return .violation
        }
    }

    public static let ledgerFile = "focus-violations.log"

    /// Counts one violation. `answeredByClose`: the chat controller closes the panel for it, so the production hand-back (`onViolation`) is not run.
    public func record(_ name: Notification.Name, answeredByClose: Bool = false) {
        status.focusViolations += 1
        // The ledger line is appended first, before the counter is persisted and before the log line: neither of those writes can
        // be lost without this one already being on the disk.
        var ledgerFailure: Int32?
        do {
            try store.appendLedger("\(Self.stamp()) VIOLATION n=\(status.focusViolations) pid=\(ProcessInfo.processInfo.processIdentifier) trigger=\(Self.field(context)) notification=\(Self.field(name.rawValue))\n", to: Self.ledgerFile)
        } catch {
            ledgerFailure = LedgerFailure.errnoOf(error)
            status.ledgerFailures = (status.ledgerFailures ?? 0) + 1
        }
        log("FOCUS_VIOLATION trigger=\(context) notification=\(name.rawValue)")
        if let code = ledgerFailure { log("FOCUS_VIOLATION_LEDGER_FAILED errno=\(code)") }
        persist()
        if !answeredByClose { onViolation?() }
    }

    /// Appends this process's BOOT line. The agent keeps running whatever happens here, and a failure is never a violation and never
    /// touches `ledgerFailures`. A BOOT whose write failed leaves no BOOT line (the check then reports a running pid without one) and is
    /// logged `LEDGER_BOOT_FAILED`; a BOOT whose bytes were written but whose fsync failed stays readable and is logged
    /// `LEDGER_BOOT_SYNC_FAILED`. True when a complete BOOT line is in the file.
    @discardableResult public func recordBoot() -> Bool {
        do {
            let data = try ReadOnlyFile.data(try store.url(Self.ledgerFile).path, limit: 64 * 1024 * 1024)
            let violations = String(decoding: data, as: UTF8.self).split(separator: "\n").filter { $0.contains(" VIOLATION ") }.count
            let line = "BOOT \(Self.stamp()) pid=\(ProcessInfo.processInfo.processIdentifier) counter=\(status.focusViolations) violations=\(violations)\n"
            try store.appendLedger(line, to: Self.ledgerFile, sealTornTail: true)
            return true
        } catch LedgerFailure.sync(let code) {
            log("LEDGER_BOOT_SYNC_FAILED errno=\(code)")
            return true
        } catch {
            log("LEDGER_BOOT_FAILED errno=\(LedgerFailure.errnoOf(error))")
            return false
        }
    }

    private static func stamp() -> String { String(format: "%.6f", Date().timeIntervalSince1970) }
    /// One word of a ledger line: whitespace and control characters become "_", so a line keeps its shape.
    private static func field(_ text: String) -> String {
        String(text.unicodeScalars.map { $0.value <= 0x20 || $0.value == 0x7F ? "_" : Character($0) })
    }
    public func persist() { try? store.writeJSON(status, to: "status.json") }
    public func log(_ safeMessage: String) {
        let seconds = String(format: "%.6f", Date().timeIntervalSince1970)
        try? store.append("\(seconds) \(safeMessage)\n", to: OwnState.agentLogName)
    }
}
