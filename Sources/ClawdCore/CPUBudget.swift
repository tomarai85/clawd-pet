import Foundation

/// The CPU budgets of the done-bar (spec 7, item 3; 7b "CPU"). `nil` budget in the measuring tool means v1's budget over the window given.
public enum CPUBudget: String, CaseIterable {
    case b1 = "B1", b2 = "B2", b3 = "B3", b4 = "B4", b5 = "B5"

    /// The shortest window that counts as this budget's evidence.
    public var minimumWindow: TimeInterval { self == .b2 ? 3600 : 600 }
    public var cpuLimit: Double {
        switch self {
        case .b1, .b5: return 0.3
        case .b2: return 1.8
        case .b3: return 0.05
        case .b4: return 1.5
        }
    }
    /// B2 and B4 are "at most"; the others are "under".
    public var cpuInclusive: Bool { self == .b2 || self == .b4 }
    /// Idle wakeups must stay under this; nil: the budget names none.
    public var wakeupsLimit: UInt64? {
        switch self {
        case .b1, .b5: return 600
        case .b2: return 3600
        case .b3, .b4: return nil
        }
    }
    /// v1's budget when no budget is named.
    public static let v1CPU = 0.3
    public static let v1Wakeups: UInt64 = 600

    public struct Measurement {
        public var cpuSeconds: Double
        public var wakeups: UInt64
        /// Lines of a dictation scene or an Aqua event in the window (STATE scene=, EVENT).
        public var dictationLines: Int
        public var renderDelta: Int?
        public var idleMotions: Int
        public var walks: Int
        public var lookChanges: Int
        /// Armed timers: the most any one-second sample showed, and over the process's life; nil when the gauge was missing.
        public var timersSampled: Int?
        public var timersLifetime: Int?
        public var quietReason: String?
        public init(cpuSeconds: Double, wakeups: UInt64, dictationLines: Int, renderDelta: Int?, idleMotions: Int, walks: Int,
                    lookChanges: Int, timersSampled: Int? = nil, timersLifetime: Int? = nil, quietReason: String? = nil) {
            self.cpuSeconds = cpuSeconds; self.wakeups = wakeups; self.dictationLines = dictationLines; self.renderDelta = renderDelta
            self.idleMotions = idleMotions; self.walks = walks; self.lookChanges = lookChanges
            self.timersSampled = timersSampled; self.timersLifetime = timersLifetime; self.quietReason = quietReason
        }
    }
    public enum Verdict: String { case pass = "PASS", fail = "FAIL", notRun = "NOT RUN" }

    public func judge(_ m: Measurement) -> Verdict {
        let cpuOK = cpuInclusive ? m.cpuSeconds <= cpuLimit : m.cpuSeconds < cpuLimit
        let wakeupsOK = wakeupsLimit.map { m.wakeups < $0 } ?? true
        let quiet = m.dictationLines == 0
        let rendered = m.renderDelta.map { $0 > 0 } ?? true
        let base = quiet && cpuOK && wakeupsOK
        switch self {
        case .b1: return base && rendered ? .pass : .fail
        case .b2: return base && rendered && m.idleMotions >= 10 && m.walks >= 1 && m.lookChanges >= 1 ? .pass : .fail
        case .b3:
            return base && m.renderDelta == 0 && (m.timersSampled ?? 2) <= 1 && (m.timersLifetime ?? 2) <= 1 && m.quietReason != nil ? .pass : .fail
        case .b4: return base && rendered && m.idleMotions >= 5 ? .pass : .fail
        case .b5:
            // A window with a dictation, or with no idle life in it, measured something else: rerun it.
            if !quiet || m.idleMotions + m.walks == 0 { return .notRun }
            return base ? .pass : .fail
        }
    }

    /// v1's verdict (no budget named): the render mode must have rendered, and the log shows no dictation.
    public static func judgeV1(_ m: Measurement) -> Verdict {
        m.dictationLines == 0 && m.cpuSeconds < v1CPU && m.wakeups < v1Wakeups && (m.renderDelta.map { $0 > 0 } ?? true) ? .pass : .fail
    }
}
