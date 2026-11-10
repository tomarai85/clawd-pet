import Foundation

public struct ReleaseHintTracker {
    public private(set) var selectedUID: String?
    public private(set) var previous = false
    public private(set) var eligible = false
    public private(set) var emitted = false
    public init() {}
    public mutating func begin(uid: String?, running: Bool?) {
        selectedUID = uid; previous = running == true
        eligible = uid != nil && running == true; emitted = false
    }
    public mutating func invalidate() { eligible = false }
    public mutating func observe(uid: String?, running: Bool?) -> Bool {
        guard uid == selectedUID, let running else { invalidate(); return false }
        defer { previous = running }
        guard eligible, !emitted, previous, !running else { return false }
        emitted = true; return true
    }
}

public struct ProbeLease: Codable {
    public var transitions: Int
    public var gap: Double?
    public var openedRunning: Bool
    public init(transitions: Int, gap: Double?, openedRunning: Bool) {
        self.transitions = transitions; self.gap = gap; self.openedRunning = openedRunning
    }
    public var passes: Bool { openedRunning && transitions == 1 && gap.map { (0.2...2).contains($0) } == true }
}
public struct ProbeReport: Codable {
    public var schema = 1
    public var registrationSucceeded: Bool
    public var callbackCount: Int
    public var baselineSucceeded: Bool
    public var enumerationsSucceeded: Bool
    public var promptWindowDetected: Bool
    public var freshIdentityAttested: Bool
    public var leases: [ProbeLease]
    public var recordedAt: Date
    public init(registrationSucceeded: Bool, callbackCount: Int, baselineSucceeded: Bool,
                enumerationsSucceeded: Bool, promptWindowDetected: Bool, freshIdentityAttested: Bool,
                leases: [ProbeLease], recordedAt: Date = Date()) {
        self.registrationSucceeded = registrationSucceeded; self.callbackCount = callbackCount
        self.baselineSucceeded = baselineSucceeded; self.enumerationsSucceeded = enumerationsSucceeded
        self.promptWindowDetected = promptWindowDetected; self.freshIdentityAttested = freshIdentityAttested
        self.leases = leases; self.recordedAt = recordedAt
    }
    public var enablesSourceB: Bool {
        schema == 1 && registrationSucceeded && callbackCount > 0 && baselineSucceeded && enumerationsSucceeded &&
        !promptWindowDetected && freshIdentityAttested && leases.count >= 3 && leases.allSatisfy(\.passes)
    }
}

public enum SourceBPolicy {
    /// Source B runs only when `control.json` asks for it AND a probe report proved every assertion.
    public static func enabled(control: AgentControl, report: ProbeReport?) -> Bool {
        control.releaseHintsEnabled && report?.enablesSourceB == true
    }
}
