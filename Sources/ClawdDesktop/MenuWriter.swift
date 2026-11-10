import Foundation
import ClawdCore
import ClawdRendering

/// One pick of the menu, as the writer runs it.
public struct MenuPick: Equatable {
    public let id: Int
    /// The key and value as `MENU pick` logs them.
    public let key: String
    public let value: String
    /// The writer keeps only the newest queued pick of a queue key.
    public let queueKey: String
    /// The exact arguments of the installed CLI: `walk on`, `look-every 3h`, `bubble exclude 7`.
    public let arguments: [String]
    /// The opening the pick was made in.
    public let gen: Int
    /// What the log names: the arguments, or the action's own words when they hold a path.
    public let loggedVerb: String?
    public var verb: String { loggedVerb ?? arguments.joined(separator: "+") }
    /// The pick's row restarts the agent (a Settings restart row). The right-click menu never sets it.
    public let restarts: Bool

    public init(id: Int, action: MenuAction, gen: Int, restarts: Bool = false) {
        self.restarts = restarts
        self.id = id; key = action.key; value = action.value; queueKey = action.queueKey; arguments = action.arguments; self.gen = gen
        loggedVerb = action.logVerb
    }
}

/// How a run ended, for a caller that wants to know: the exit code (nil: the CLI could not be run) and the CLI's one line on failure, without
/// its "clawd-pet: " prefix (empty on success).
public struct MenuResult: Equatable {
    public let exit: Int?
    public let text: String
    public init(exit: Int?, text: String) { self.exit = exit; self.text = text }
}

/// Why `submit` did not take a pick: nothing was queued or run, and neither its completion nor its start hook will ever be called.
public struct MenuRefusal: Equatable {
    /// `restarting` (a child that may restart runs) or `restart-queued` (another restart pick waits).
    public let why: String
    /// The pick whose child runs, or whose restart waits.
    public let by: Int
    /// What a user is told.
    public let text: String
    static let restartingText = "Clawd is restarting; pick this again once it is back"
    static let restartQueuedText = "Clawd restarts for another setting first; pick this again once it is back"
}

/// The menu's one writer (spec 5.1: one writer path). Every pick runs the installed CLI as a child process, the same verbs the user types, so
/// the lock, the validation, the generation and the atomic replace stay in one implementation (bin/clawd-pet).
///   - The CLI is `$HOME/bin/clawd-pet` with the agent's HOME, checked before each run to be a regular executable file and not a symlink.
///     Missing or wrong: the pick does nothing and the log says so. There is no fallback writer.
///   - The arguments are an array; the environment is HOME and PATH and nothing else.
///   - Nothing here blocks the main thread: the CLI waits up to 2 s for this very agent to apply the generation, so the run loop must stay
///     free while the child runs. A completion is handled on the main queue.
///   - One child at a time. A pick that arrives while one runs waits; of the waiting picks only the newest of each queue key stays.
///   - Both pipes are drained to their end, so no child can stall on a full pipe.
///   - The agent never signals the child: the CLI's own bounded waits end it. Exit 3 (saved, not confirmed in 2 s) is logged and never retried.
public final class MenuWriter {
    public static let path = "/usr/bin:/bin:/usr/sbin:/sbin"
    /// How long after the child has ended the writer waits for its pipes to reach their end (a grandchild may still hold one open).
    static let drainGrace: TimeInterval = 1

    private let home: URL
    private let log: (String) -> Void
    private let completions: DispatchQueue
    private var running: MenuPick?
    /// The answer of `restartPending` (or the pick's own row) when the running pick started: its child may restart the agent.
    private var runningMayRestart = false
    /// A right-click selection is on its way to `submit` (the menu flashes): a pick that may restart does not start meanwhile.
    private var menuHolds = false
    /// Whether the agent has a restart-only key saved that differs from boot: then any verb's child restarts the agent. Read when a pick is
    /// about to start and when the hold is decided, never earlier.
    private let restartPending: () -> Bool
    private var waiting: [MenuPick] = []
    /// The completion of a pick that has one, by pick number. A pick a newer pick replaces never completes.
    private var pickCompletions: [Int: (MenuResult) -> Void] = [:]
    /// The start hook of a pick that has one, by pick number: it runs on the main queue just before the child is spawned, and false means the
    /// pick must not run (it then ends as a CLI that could not be run). A pick a newer pick replaces never starts.
    private var startHooks: [Int: () -> Bool] = [:]

    public var cliPath: String { home.appendingPathComponent("bin/clawd-pet").path }
    public var isRunning: Bool { running != nil }
    /// The running pick's number while its child may restart the agent, else nil.
    public var restartRunningID: Int? { runningMayRestart ? running?.id : nil }
    public var restartRunning: Bool { restartRunningID != nil }
    public var queuedCount: Int { waiting.count }
    /// Whether the pick is still the one that runs or one that waits: a pick that finished or that a newer pick replaced is not held.
    public func holds(_ id: Int) -> Bool { running?.id == id || waiting.contains { $0.id == id } }

    /// `log` receives every line (without the time stamp); it is called on `completions`' queue or the caller's, never concurrently.
    public init(home: URL, log: @escaping (String) -> Void, completions: DispatchQueue = .main, restartPending: @escaping () -> Bool = { false }) {
        self.home = home; self.log = log; self.completions = completions; self.restartPending = restartPending
    }

    /// A right-click selection is pending: a pick that may restart the agent waits until `releaseRestarts()`.
    public func holdRestarts() { menuHolds = true }
    /// The selection is in the writer (or gone): the held pick may start.
    public func releaseRestarts() {
        menuHolds = false
        pump()
    }

    /// Runs the pick, or queues it behind the one that runs. Call it on the main queue. nil: queued or started. Non-nil: refused, with the log
    /// line written; its completion and start hook are never stored or called.
    @discardableResult
    public func submit(_ pick: MenuPick, onStart: (() -> Bool)? = nil, completion: ((MenuResult) -> Void)? = nil) -> MenuRefusal? {
        if let runner = running, runningMayRestart {
            return refuse(pick, why: "restarting", by: runner.id, text: MenuRefusal.restartingText)
        }
        if pick.restarts, let queued = waiting.first(where: { $0.restarts && $0.queueKey != pick.queueKey }) {
            return refuse(pick, why: "restart-queued", by: queued.id, text: MenuRefusal.restartQueuedText)
        }
        if let completion { pickCompletions[pick.id] = completion }
        if let onStart { startHooks[pick.id] = onStart }
        if let index = waiting.firstIndex(where: { $0.queueKey == pick.queueKey }) {
            let replaced = waiting.remove(at: index)
            pickCompletions.removeValue(forKey: replaced.id)
            startHooks.removeValue(forKey: replaced.id)
            log("MENU drop id=\(replaced.id) by=\(pick.id) gen=\(replaced.gen)")
        }
        if !pick.restarts, let first = waiting.firstIndex(where: { $0.restarts }) { waiting.insert(pick, at: first) } else { waiting.append(pick) }
        pump()
        return nil
    }

    private func refuse(_ pick: MenuPick, why: String, by: Int, text: String) -> MenuRefusal {
        log("MENU refuse id=\(pick.id) why=\(why) by=\(by) gen=\(pick.gen)")
        return MenuRefusal(why: why, by: by, text: text)
    }

    /// Starts the head of the waiting picks when nothing runs, unless the menu holds a selection and the head may restart the agent.
    private func pump() {
        guard running == nil, let head = waiting.first else { return }
        if menuHolds, head.restarts || restartPending() { return }
        start(waiting.removeFirst())
    }

    // MARK: running one

    /// Why the CLI may not be run, nil when it may.
    func refusal() -> String? {
        let path = cliPath
        guard let attributes = try? FileManager.default.attributesOfItem(atPath: path), let type = attributes[.type] as? FileAttributeType else { return "missing" }
        if type == .typeSymbolicLink { return "symlink" }
        if type != .typeRegular { return "not-regular" }
        if !FileManager.default.isExecutableFile(atPath: path) { return "not-executable" }
        return nil
    }

    private func start(_ pick: MenuPick) {
        running = pick
        runningMayRestart = pick.restarts || restartPending()
        if runningMayRestart { refuseWaiting(by: pick) }
        if let why = refusal() {
            log("MENU cli-refused id=\(pick.id) why=\(why) gen=\(pick.gen)")
            finish(pick, exit: nil, output: "")
            return
        }
        if let hook = startHooks[pick.id], !hook() {
            log("MENU cli-refused id=\(pick.id) why=start-hook gen=\(pick.gen)")
            finish(pick, exit: nil, output: "")
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: cliPath)
        process.arguments = pick.arguments
        process.environment = ["HOME": home.path, "PATH": Self.path]
        process.standardInput = FileHandle.nullDevice
        let out = Pipe(), err = Pipe()
        process.standardOutput = out; process.standardError = err
        let collected = Collected()
        // Both readers are counted before the child can exist, so a child that ends at once is still waited for.
        let drained = DispatchGroup()
        drained.enter(); drained.enter()
        let queue = completions
        process.terminationHandler = { [weak self] ended in
            let status = Int(ended.terminationStatus)
            let code = ended.terminationReason == .uncaughtSignal ? 128 + status : status
            DispatchQueue.global().async {
                _ = drained.wait(timeout: .now() + Self.drainGrace)
                let text = collected.text
                queue.async { self?.finish(pick, exit: code, output: text) }
            }
        }
        do { try process.run() } catch {
            drained.leave(); drained.leave()
            log("MENU cli-refused id=\(pick.id) why=spawn-failed gen=\(pick.gen)")
            finish(pick, exit: nil, output: "")
            return
        }
        for pipe in [out, err] {
            DispatchQueue.global().async {
                let handle = pipe.fileHandleForReading
                while true {
                    let data = handle.availableData
                    if data.isEmpty { break }
                    collected.append(data)
                }
                drained.leave()
            }
        }
    }

    /// A child that may restart the agent starts with nothing waiting: every pick still waiting was accepted earlier, so it is refused through
    /// its completion.
    private func refuseWaiting(by starter: MenuPick) {
        let victims = waiting
        waiting = []
        for victim in victims {
            log("MENU refuse id=\(victim.id) why=restarting by=\(starter.id) gen=\(victim.gen)")
            startHooks.removeValue(forKey: victim.id)
            pickCompletions.removeValue(forKey: victim.id)?(MenuResult(exit: nil, text: MenuRefusal.restartingText))
        }
    }

    private func finish(_ pick: MenuPick, exit code: Int?, output: String) {
        running = nil
        runningMayRestart = false
        log("MENU write id=\(pick.id) key=\(pick.key) verb=\(pick.verb) exit=\(code.map(String.init) ?? "none") gen=\(pick.gen)")
        if let code, code != 0, !output.isEmpty { log("MENU write-output id=\(pick.id) gen=\(pick.gen) text=\(Self.oneLine(output))") }
        let done = pickCompletions.removeValue(forKey: pick.id)
        startHooks.removeValue(forKey: pick.id)
        pump()
        if let done {
            var line = Self.oneLine(output)
            if line.hasPrefix("clawd-pet: ") { line = String(line.dropFirst("clawd-pet: ".count)) }
            done(MenuResult(exit: code, text: code == 0 ? "" : line))
        }
    }

    /// The CLI's words for a failure, on one line and short.
    static func oneLine(_ text: String) -> String {
        let flat = text.split(whereSeparator: \.isNewline).joined(separator: " | ")
        return flat.count > 200 ? String(flat.prefix(200)) + "..." : flat
    }
}

/// What a child printed, from two reader threads. Only the first 64 KB are kept; the rest is read and dropped so the pipe never fills.
private final class Collected {
    private let lock = NSLock()
    private var data = Data()
    func append(_ more: Data) {
        lock.lock(); defer { lock.unlock() }
        if data.count < 64 * 1024 { data.append(more.prefix(64 * 1024 - data.count)) }
    }
    var text: String { lock.lock(); defer { lock.unlock() }; return String(decoding: data, as: UTF8.self) }
}
