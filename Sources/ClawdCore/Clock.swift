import Foundation

public protocol PetClock: AnyObject {
    var now: TimeInterval { get }
    var wallNow: Date { get }
}
public final class SystemPetClock: PetClock {
    public init() {}
    public var now: TimeInterval { ProcessInfo.processInfo.systemUptime }
    public var wallNow: Date { Date() }
}
public final class VirtualClock: PetClock {
    public var now: TimeInterval
    public var wallNow: Date
    public init(now: TimeInterval = 0, wallNow: Date = Date(timeIntervalSince1970: 1_800_000_000)) {
        self.now = now; self.wallNow = wallNow
    }
    public func advance(_ seconds: TimeInterval) { now += seconds; wallNow.addTimeInterval(seconds) }
}
