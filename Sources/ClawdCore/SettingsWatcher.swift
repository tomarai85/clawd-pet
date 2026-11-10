import Foundation
import Darwin

/// Everything `control.json` says, read key by key (spec 5.1 "Reading"): the v1 keys (`AgentControl`) and the v2 keys the scheduler
/// reads (`SchedulerSettings`), the chat's `chat*` keys (`ChatSettings`), plus the generation the last writer stamped.
public struct AppliedSettings: Equatable {
    public var control: AgentControl
    public var scheduler: SchedulerSettings
    public var chat: ChatSettings
    public var generation: Int { scheduler.generation }
    public init(control: AgentControl = AgentControl(), scheduler: SchedulerSettings = SchedulerSettings(), chat: ChatSettings = ChatSettings()) {
        self.control = control; self.scheduler = scheduler; self.chat = chat
    }

    /// The scheduler's settings with the v1 `helmet` key folded in (spec 5.1): `helmet on` pins the helmet look unless a look is pinned
    /// explicitly. `helmetOff` is the one-shot "back to plain" after `helmet off`, until Clawd wears plain again.
    public func effectiveScheduler(helmetOffPending: Bool) -> SchedulerSettings {
        var settings = scheduler
        if settings.lookPin == nil {
            if control.helmet { settings.lookPin = "helmet" }
            else if helmetOffPending { settings.lookPin = PetCatalog.plainLook }
        }
        return settings
    }

    /// Parses `control.json` text. nil only when it is not a JSON object (the caller then keeps what it has applied).
    public static func parse(_ data: Data) -> AppliedSettings? {
        guard (try? JSONSerialization.jsonObject(with: data)) is [String: Any],
              let control = try? JSONDecoder().decode(AgentControl.self, from: data) else { return nil }
        return AppliedSettings(control: control, scheduler: SchedulerSettings(data: data), chat: ChatSettings(data: data))
    }
}

/// The v1 `helmet on|off` alias (spec 5.1): `on` pins the helmet look; `off` goes back to plain at the next allowed moment and then
/// rotation resumes. The "back to plain" is a one-shot pin on `plain` that ends when Clawd wears plain.
public struct HelmetAlias: Equatable {
    public private(set) var offPending = false
    private var lastHelmet: Bool
    /// `offPending` is the one-shot restored from a restart (state.json): it only means something while the helmet is off.
    public init(helmet: Bool, offPending: Bool = false) { lastHelmet = helmet; self.offPending = offPending && !helmet }
    /// A new `helmet` value was applied while Clawd wears `currentLook`.
    public mutating func settingsChanged(helmet: Bool, currentLook: String) {
        if helmet { offPending = false }
        else if lastHelmet, currentLook != PetCatalog.plainLook { offPending = true }
        lastHelmet = helmet
    }
    /// Clawd changed its look. True when that ends the one-shot (the pin must be dropped so rotation resumes).
    public mutating func lookChanged(to look: String) -> Bool {
        guard offPending, look == PetCatalog.plainLook else { return false }
        offPending = false
        return true
    }
}

/// What the watcher tells its host after it has applied a generation. Both hosts (the desktop runtime and the headless settings
/// mode) write `appliedGeneration` to status.json here; the watcher itself touches no other file.
public protocol SettingsApplySink: AnyObject {
    /// Applies `settings` live. Called on the watcher's queue.
    func apply(_ settings: AppliedSettings)
    /// Called after `apply`, once the settings are in effect.
    func applied(generation: Int, settings: AppliedSettings)
}

/// The one component that reads `control.json` (spec 5.1 "One applier"). It is event-driven: a vnode source on the state directory
/// reports every change of an entry (the CLI replaces control.json with a rename), the watcher compares control.json's identity and
/// modification time with what it applied, and reads and applies only when they differ. No timer, no polling.
public final class SettingsWatcher {
    public static let fileName = "control.json"
    private let directory: URL
    private let queue: DispatchQueue
    private weak var sink: SettingsApplySink?
    private var source: DispatchSourceFileSystemObject?
    private var lastSignature: String?
    public private(set) var current: AppliedSettings
    public private(set) var appliedGeneration: Int?
    public private(set) var applyCount = 0

    /// `defaults` is what the host uses while control.json is missing or unreadable.
    public init(store: OwnState, defaults: AppliedSettings = AppliedSettings(), queue: DispatchQueue = .main) {
        directory = store.root; self.queue = queue; current = defaults
    }
    deinit { source?.cancel() }

    private var path: String { directory.appendingPathComponent(Self.fileName).path }

    /// The initial read, without applying: a host needs the values to build its panel before it can apply anything.
    public func load() -> AppliedSettings {
        if let read = readFile(), let data = read.data, let parsed = AppliedSettings.parse(data) {
            current = parsed; lastSignature = read.signature
        }
        return current
    }

    /// Applies the loaded settings once (so `appliedGeneration` is written for a CLI that saved while the agent was down), then
    /// watches the directory.
    public func start(sink: SettingsApplySink) {
        self.sink = sink
        arm()
        sink.apply(current); applyCount += 1
        appliedGeneration = current.generation
        sink.applied(generation: current.generation, settings: current)
        // A change that landed between load() and the watch being armed is picked up here.
        check()
    }
    public func stop() { source?.cancel(); source = nil }

    private func arm() {
        guard let file = try? ReadOnlyFile(directory.path, flags: O_EVTONLY) else { return }
        let created = DispatchSource.makeFileSystemObjectSource(fileDescriptor: file.descriptor,
            eventMask: [.write, .extend, .rename, .delete, .attrib], queue: queue)
        created.setEventHandler { [weak self] in self?.check() }
        created.setCancelHandler { _ = file.descriptor }       // keeps the descriptor alive until the cancel is delivered
        created.resume()
        source = created
    }

    /// `st_dev:st_ino:mtime:size`.
    private static func signature(of info: stat) -> String {
        "\(info.st_dev):\(info.st_ino):\(info.st_mtimespec.tv_sec).\(info.st_mtimespec.tv_nsec):\(info.st_size)"
    }

    /// The signature of the file now at the path (nil when it does not exist): only a cheap question "may it have changed?", never
    /// the signature of what was read (see `readFile`).
    private func signature() -> String? {
        var info = stat()
        guard stat(path, &info) == 0 else { return nil }
        return Self.signature(of: info)
    }

    /// Test seam: runs after the file has been opened and before it is measured and read, so a test can replace the file at the one
    /// moment in which reading the content and taking the signature from the path used to disagree.
    public var afterOpen: (() -> Void)?

    /// The content and the signature of ONE open file. The CLI replaces control.json with a rename, so the path can name a newer
    /// file at any moment; the signature of what was read is the one of the descriptor that was read (fstat before the read: a file
    /// written in place after it only makes the next check read again). Taking the signature from the path afterwards would label
    /// generation N with the signature of N+1, and N+1 would never be read. `data` is nil for a file that is too big or cannot be
    /// read; nil result: the file cannot be opened.
    private func readFile() -> (data: Data?, signature: String)? {
        guard let file = try? ReadOnlyFile(path) else { return nil }
        afterOpen?()
        guard let info = try? file.metadata() else { return nil }
        let signature = Self.signature(of: info)
        let limit = 1024 * 1024
        guard info.st_size >= 0, info.st_size <= limit, let data = try? file.read(offset: 0, count: limit + 1), data.count <= limit else {
            return (nil, signature)
        }
        return (data, signature)
    }

    /// Reads and applies control.json when it changed. Safe to call at any time (tests call it directly).
    public func check() {
        guard let now = signature(), now != lastSignature else { return }
        guard let read = readFile() else { return }       // gone again between the question and the open: the next event asks again
        lastSignature = read.signature
        // A file that cannot be read as an object is left alone; the next replacement is read again.
        guard let data = read.data, let parsed = AppliedSettings.parse(data) else { return }
        guard parsed != current || parsed.generation != appliedGeneration else { return }
        current = parsed
        sink?.apply(parsed); applyCount += 1
        appliedGeneration = parsed.generation
        sink?.applied(generation: parsed.generation, settings: parsed)
    }
}
