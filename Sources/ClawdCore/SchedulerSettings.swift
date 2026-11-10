import Foundation

/// `motion off|quiet|normal|lively` (spec 5.1). The interval is the time between idle motions, uniform random.
public enum MotionLevel: String, CaseIterable {
    case off, quiet, normal, lively
    public var interval: ClosedRange<TimeInterval>? {
        switch self {
        case .off: return nil
        case .quiet: return 120...300
        case .normal: return 45...100
        case .lively: return 6...15
        }
    }
}

/// `bubble side below|above|left|right`: where the bubble sits relative to Clawd. The values are absolute screen directions; left and right never
/// mirror with the half of the display Clawd stands in.
public enum BubbleSide: String, CaseIterable {
    case below, above, left, right
}

/// The `control.json` keys the scheduler reads (Interface Contract). Every key is read on its own:
/// a missing key, an out-of-range value and a value of the wrong type each give that key's default and touch no other key
/// (spec 5.1 "Reading"; v1's whole-file fallback is exactly what this avoids).
public struct SchedulerSettings: Equatable {
    public static let allowedLookHours = [2, 3, 4]
    public static let bubbleStyles = Array(1...15)

    public var walk = true
    public var motion: MotionLevel = .quiet
    public var lookEveryHours = 4
    /// A look id, or nil for rotation.
    public var lookPin: String?
    /// Board ids (A12, C10, D16, B7), item ids or item names, lowercased.
    public var excluded: Set<String> = []
    public var bubble = true
    public var bubbleExcluded: Set<Int> = []
    /// Where the bubble sits (key `bubbleSide`). The scheduler and the style choice never see it: it is a placement-time input only.
    public var bubbleSide: BubbleSide = .below
    /// Epoch seconds. 0 = shown, -1 = hidden until `show`, otherwise hidden until that instant.
    public var hiddenUntil: Double = 0
    public var generation = 0

    public init() {}

    public init(data: Data) {
        self.init(object: (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] ?? [:])
    }

    public init(object: [String: Any]) {
        if let value = Self.bool(object["walk"]) { walk = value }
        if let text = object["motion"] as? String, let level = MotionLevel(rawValue: text) { motion = level }
        if let hours = Self.integer(object["lookEveryHours"]), Self.allowedLookHours.contains(hours) { lookEveryHours = hours }
        if let pin = object["lookPin"] as? String {
            let trimmed = pin.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty, trimmed.count <= 64, trimmed.lowercased() != "random" { lookPin = trimmed }
        }
        if let list = object["excluded"] as? [Any] {
            let names = list.compactMap { ($0 as? String)?.trimmingCharacters(in: .whitespaces).lowercased() }
            if names.count == list.count, names.allSatisfy({ !$0.isEmpty && $0.count <= 64 }) { excluded = Set(names) }
        }
        if let value = Self.bool(object["bubble"]) { bubble = value }
        if let text = object["bubbleSide"] as? String, let side = BubbleSide(rawValue: text) { bubbleSide = side }
        for (key, allowed) in [("bubbleExcluded", 1...12), ("bubbleExcludedNew", 13...15)] {
            guard let list = object[key] as? [Any] else { continue }
            let numbers = list.compactMap { Self.integer($0) }
            let styles = Set(numbers)
            // One bad element resets only its key. Keep the old key readable by builds with twelve styles.
            if numbers.count == list.count, styles.isSubset(of: allowed), key != "bubbleExcluded" || styles.count < 12 {
                bubbleExcluded.formUnion(styles)
            }
        }
        if let value = Self.number(object["hiddenUntil"]), value == 0 || value == -1 || value > 0 { hiddenUntil = value }
        if let value = Self.integer(object["generation"]), value >= 0 { generation = value }
    }

    private static func bool(_ value: Any?) -> Bool? {
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { return nil }
        return n.boolValue
    }
    private static func number(_ value: Any?) -> Double? {
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite else { return nil }
        return n.doubleValue
    }
    private static func integer(_ value: Any?) -> Int? {
        guard let d = number(value), d == d.rounded(), abs(d) < 1e12 else { return nil }
        return Int(d)
    }

    /// Whether an item is switched off. Matches the item id, its board id and its name, ignoring case.
    public func excludes(id: String, board: String, name: String) -> Bool {
        excluded.contains(id.lowercased()) || (!board.isEmpty && excluded.contains(board.lowercased()))
            || (!name.isEmpty && excluded.contains(name.lowercased()))
    }
    public func excludes(_ motion: CatalogMotion) -> Bool { excludes(id: motion.id, board: motion.board, name: motion.name) }
    public func excludes(_ look: CatalogLook) -> Bool { excludes(id: look.id, board: look.board, name: look.name) }

    public var enabledBubbleStyles: [Int] { Self.bubbleStyles.filter { !bubbleExcluded.contains($0) } }

    /// `wall` is epoch seconds.
    public func hidden(atWall wall: Double) -> Bool {
        hiddenUntil == -1 || (hiddenUntil > 0 && wall < hiddenUntil)
    }
}
