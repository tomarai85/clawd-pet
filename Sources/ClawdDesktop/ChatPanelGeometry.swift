import CoreGraphics
import Foundation
import ClawdCore

/// The terminal panel's size, bounds and gestures, following Orca's floating terminal (see THIRD-PARTY-NOTICES.md). Pure functions of rectangles in
/// AppKit's global points (y up): no window, view or event is touched here, so every rule is a plain test.
///
/// Orca's numbers, from src/renderer/src/components/floating-terminal/:
/// - floating-terminal-panel-bounds.ts:3-4 MIN_PANEL_WIDTH 420, MIN_PANEL_HEIGHT 280; :5 MAXIMIZED_MARGIN 12; :9 PANEL_EDGE_MARGIN 8.
/// - FloatingTerminalResizeHandles.tsx:9-16: the edge handles are 8 px thick and inset 8 px from the corners (`left-2 right-2 h-2`), the corner
///   handles are 12 px squares (`size-3`).
/// Orca's default is 920 x 560 (:1-2); Clawd's is 360 x 240 and its minimum 300 x 200, because the user found 420 x 280 (and 520 x 340) too large.
public enum ChatPanelGeometry {
    public static let defaultSize = CGSize(width: 360, height: 240)
    public static let minSize = CGSize(width: 300, height: 200)
    public static let edgeMargin: CGFloat = 8
    public static let maximizedMargin: CGFloat = 12
    public static let edgeHandleThickness: CGFloat = 8
    public static let edgeHandleInset: CGFloat = 8
    public static let cornerHandleSize: CGFloat = 12

    public enum Edge: String, CaseIterable { case n, s, e, w, ne, nw, se, sw }

    /// How far `point` is from `rect`: 0 inside it.
    public static func distance(from point: CGPoint, to rect: CGRect) -> CGFloat {
        let dx = max(rect.minX - point.x, 0, point.x - rect.maxX), dy = max(rect.minY - point.y, 0, point.y - rect.maxY)
        return hypot(dx, dy)
    }

    /// How far `point` is from the border of `rect`: outside it the distance to the rect, inside it the distance to the nearest edge. A maximized
    /// panel fills a screen, so "near it" can only mean near its edge region.
    public static func distanceToEdge(from point: CGPoint, to rect: CGRect) -> CGFloat {
        guard rect.contains(point) else { return distance(from: point, to: rect) }
        return min(point.x - rect.minX, rect.maxX - point.x, point.y - rect.minY, rect.maxY - point.y)
    }

    /// `rect` inside `visible`, as `clampFloatingTerminalBounds` does it (:76-96): the size first (at least the minimum, at most what the screen
    /// holds less the margins, the minimum winning on a screen smaller than it), then the position inside the margins. With no `visible` only the
    /// minimum is enforced.
    public static func clamp(_ rect: CGRect, in visible: CGRect?) -> CGRect {
        var width = max(minSize.width, rect.width), height = max(minSize.height, rect.height)
        guard let visible else { return CGRect(x: rect.minX, y: rect.minY, width: width, height: height) }
        width = max(minSize.width, min(rect.width, max(minSize.width, visible.width - edgeMargin * 2)))
        height = max(minSize.height, min(rect.height, max(minSize.height, visible.height - edgeMargin * 2)))
        let maxX = max(visible.minX + edgeMargin, visible.maxX - width - edgeMargin)
        let maxY = max(visible.minY + edgeMargin, visible.maxY - height - edgeMargin)
        let x = min(max(rect.minX, visible.minX + edgeMargin), maxX)
        let y = min(max(rect.minY, visible.minY + edgeMargin), maxY)
        return CGRect(x: x, y: y, width: width, height: height)
    }

    /// The maximized panel (:114-122): the visible frame less 12 px on every side.
    public static func maximized(in visible: CGRect) -> CGRect {
        let inset = visible.insetBy(dx: maximizedMargin, dy: maximizedMargin)
        return CGRect(x: inset.minX, y: inset.minY, width: max(minSize.width, inset.width), height: max(minSize.height, inset.height))
    }

    /// The panel after a drag by the title bar of (`dx`, `dy`) points (y up), kept inside the margins of `visible`.
    public static func moved(_ start: CGRect, dx: CGFloat, dy: CGFloat, in visible: CGRect?) -> CGRect {
        let moved = CGRect(x: start.minX + dx, y: start.minY + dy, width: start.width, height: start.height)
        guard let visible else { return moved }
        return clamp(moved, in: visible)
    }

    /// The panel after a drag of `edge` by (`dx`, `dy`) points (y up), as the handles of FloatingTerminalResizeHandles.tsx:63-86 do it: the
    /// dragged edges move, the opposite ones stay, and a size at the minimum pins the opposite edge. The moving edges also stop at the margins of
    /// `visible`.
    public static func resized(_ start: CGRect, edge: Edge, dx: CGFloat, dy: CGFloat, in visible: CGRect?) -> CGRect {
        var left = start.minX, right = start.maxX, bottom = start.minY, top = start.maxY
        let name = edge.rawValue
        if name.contains("e") { right += dx }
        if name.contains("w") { left += dx }
        if name.contains("n") { top += dy }
        if name.contains("s") { bottom += dy }
        if let visible {
            left = max(left, visible.minX + edgeMargin); right = min(right, visible.maxX - edgeMargin)
            bottom = max(bottom, visible.minY + edgeMargin); top = min(top, visible.maxY - edgeMargin)
        }
        if right - left < minSize.width { if name.contains("w") { left = start.maxX - minSize.width } else { right = left + minSize.width } }
        if top - bottom < minSize.height { if name.contains("s") { bottom = start.maxY - minSize.height } else { top = bottom + minSize.height } }
        return CGRect(x: left, y: bottom, width: right - left, height: top - bottom)
    }

    /// The screen whose visible frame has the largest intersection with `rect` (the first one on a tie); nil when none intersects.
    public static func screen(of rect: CGRect, in screens: [ChatScreen]) -> ChatScreen? {
        var best: (screen: ChatScreen, area: CGFloat)?
        for screen in screens {
            let overlap = screen.visible.intersection(rect)
            guard !overlap.isNull, overlap.width > 0, overlap.height > 0 else { continue }
            let area = overlap.width * overlap.height
            if best == nil || area > best!.area { best = (screen, area) }
        }
        return best?.screen
    }

    /// The screen whose frame holds `point` (nil: none).
    public static func screen(at point: CGPoint, in screens: [ChatScreen]) -> ChatScreen? {
        screens.first { $0.frame.contains(point) }
    }

    /// The handle's frame inside a panel of `size` (y up): edges 8 px thick inset 8 px from the corners, corners 12 px squares.
    public static func handleFrame(_ edge: Edge, in size: CGSize) -> CGRect {
        let t = edgeHandleThickness, i = edgeHandleInset, c = cornerHandleSize
        switch edge {
        case .n: return CGRect(x: i, y: size.height - t, width: max(0, size.width - 2 * i), height: t)
        case .s: return CGRect(x: i, y: 0, width: max(0, size.width - 2 * i), height: t)
        case .w: return CGRect(x: 0, y: i, width: t, height: max(0, size.height - 2 * i))
        case .e: return CGRect(x: size.width - t, y: i, width: t, height: max(0, size.height - 2 * i))
        case .nw: return CGRect(x: 0, y: size.height - c, width: c, height: c)
        case .ne: return CGRect(x: size.width - c, y: size.height - c, width: c, height: c)
        case .sw: return CGRect(x: 0, y: 0, width: c, height: c)
        case .se: return CGRect(x: size.width - c, y: 0, width: c, height: c)
        }
    }
}

/// One display as the panel's geometry sees it: its frame, the visible frame inside the menu bar and the Dock, and a number that stays the same
/// while the display does (its UUID; empty for a host that knows only one).
public struct ChatScreen: Equatable {
    public var id: String
    public var frame: CGRect
    public var visible: CGRect
    public init(id: String = "", frame: CGRect, visible: CGRect) { self.id = id; self.frame = frame; self.visible = visible }
}

/// The panel's position as a corner of its display (Q26), as Orca keeps its floating terminal: the nearest corner by the panel's centre against the
/// display's centre, and the two offsets from that corner's edges (FT/floating-terminal-panel-bounds.ts:153-189), in AppKit's y-up points.
public struct ChatAnchor: Equatable {
    public enum Horizontal: String { case left, right }
    public enum Vertical: String { case top, bottom }
    /// The display's UUID, nil for a host that knows none (an empty id) or an index-built one (`display-<n>`).
    public var display: String?
    public var anchorX: Horizontal, anchorY: Vertical
    public var offsetX: CGFloat, offsetY: CGFloat, width: CGFloat, height: CGFloat
    public init(display: String?, anchorX: Horizontal, anchorY: Vertical, offsetX: CGFloat, offsetY: CGFloat, width: CGFloat, height: CGFloat) {
        self.display = display; self.anchorX = anchorX; self.anchorY = anchorY
        self.offsetX = offsetX; self.offsetY = offsetY; self.width = width; self.height = height
    }
    /// `lt`, `rt`, `lb` or `rb`: the corner, for the log.
    public var corner: String { (anchorX == .left ? "l" : "r") + (anchorY == .top ? "t" : "b") }
}

extension ChatPanelGeometry {
    /// Whether a display id names a display for good: not empty, not built from an index (`display-<n>`, AgentRuntime.chatScreens).
    public static func isStableDisplayID(_ id: String) -> Bool { !id.isEmpty && !id.hasPrefix("display-") }

    /// The anchored form of `rect` on the display whose visible frame is `visible` (Orca :153-189). nil when that frame cannot hold the minimum
    /// panel and both margins (:145-151), as Orca persists nothing it cannot anchor.
    public static func anchor(of rect: CGRect, in visible: CGRect, display: String?) -> ChatAnchor? {
        guard visible.width >= minSize.width + edgeMargin * 2, visible.height >= minSize.height + edgeMargin * 2 else { return nil }
        let anchorX: ChatAnchor.Horizontal = rect.midX <= visible.midX ? .left : .right
        let anchorY: ChatAnchor.Vertical = rect.midY >= visible.midY ? .top : .bottom
        return ChatAnchor(display: display.flatMap { isStableDisplayID($0) ? $0 : nil }, anchorX: anchorX, anchorY: anchorY,
                          offsetX: anchorX == .left ? rect.minX - visible.minX : visible.maxX - rect.maxX,
                          offsetY: anchorY == .top ? visible.maxY - rect.maxY : rect.minY - visible.minY,
                          width: rect.width, height: rect.height)
    }

    /// The anchor turned back into a rect against `visible`, then clamped (:197-205). The offsets are not scaled: a smaller target keeps them
    /// and the clamp holds the panel inside.
    public static func resolve(_ anchor: ChatAnchor, in visible: CGRect) -> CGRect {
        let x = anchor.anchorX == .left ? visible.minX + anchor.offsetX : visible.maxX - anchor.width - anchor.offsetX
        let y = anchor.anchorY == .top ? visible.maxY - anchor.height - anchor.offsetY : visible.minY + anchor.offsetY
        return clamp(CGRect(x: x, y: y, width: anchor.width, height: anchor.height), in: visible)
    }
}

/// Where the panel's size and position are remembered between openings.
public protocol ChatGeometryStoring: AnyObject {
    /// The absolute rect of a version 1 file (nil for a version 2 file, and for a file without one).
    func load() -> CGRect?
    /// The corner anchor of a version 2 file.
    func loadAnchor() -> ChatAnchor?
    /// Writes the anchor as a version 2 file (the `maximized` flag kept). False when the write failed.
    @discardableResult func saveAnchor(_ anchor: ChatAnchor) -> Bool
    /// The one-time move of a version 1 file to the anchored form: the v1 file is copied to `chat-panel.json.bak.<YYYYMMDD-HHMMSS>` first (once),
    /// then the anchor is written. False, with the v1 file untouched, when the copy or the write failed.
    func migrate(to anchor: ChatAnchor) -> Bool
    /// Whether the panel was left maximized. Kept apart from the rect: the toggle writes only this.
    func loadMaximized() -> Bool
    /// False when the write failed.
    @discardableResult func saveMaximized(_ maximized: Bool) -> Bool
}

/// The panel's geometry in the agent's own private state (`chat-private/chat-panel.json`, 0600), never in control.json. One struct holds every
/// version 1 and version 2 key, and every writer reads the whole of it, changes its own fields and writes it back whole, so the maximize toggle
/// never drops the anchor and a version 1 file that holds only `maximized` stays version 1 until the first commit.
public final class FileChatGeometry: ChatGeometryStoring {
    /// The name older builds wrote at the state root. It is read when the private file is absent and removed once the private file is written.
    public static let fileName = "chat-panel.json"
    public static let privateFileName = "chat-private/chat-panel.json"
    static let backupPrefix = "chat-panel.json.bak."
    private struct Saved: Codable {
        var version: Int?, display: String?, anchorX: String?, anchorY: String?
        var offsetX: Double?, offsetY: Double?, width: Double?, height: Double?, x: Double?, y: Double?, maximized: Bool?

        /// A version 2 file always has a `display` key, null when the display has none (the interface contract); the other keys are left out when nil.
        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encodeIfPresent(version, forKey: .version)
            if version == 2 { try container.encode(display, forKey: .display) } else { try container.encodeIfPresent(display, forKey: .display) }
            try container.encodeIfPresent(anchorX, forKey: .anchorX); try container.encodeIfPresent(anchorY, forKey: .anchorY)
            try container.encodeIfPresent(offsetX, forKey: .offsetX); try container.encodeIfPresent(offsetY, forKey: .offsetY)
            try container.encodeIfPresent(width, forKey: .width); try container.encodeIfPresent(height, forKey: .height)
            try container.encodeIfPresent(x, forKey: .x); try container.encodeIfPresent(y, forKey: .y)
            try container.encodeIfPresent(maximized, forKey: .maximized)
        }
    }
    private let store: OwnState
    private let now: () -> Date
    private var sweptBackupTemps = false
    public init(store: OwnState, now: @escaping () -> Date = { Date() }) { self.store = store; self.now = now }

    /// The file's content and where it was read from. The private file wins when both exist (a downgrade wrote a new root version 1: that move is
    /// lost) and the root is removed once the private one has parsed; a private file that does not parse leaves the root as the only good copy.
    private func read() -> (saved: Saved, source: String?) {
        sweepBackupTemps()
        if let saved = try? store.readJSON(Saved.self, from: Self.privateFileName) {
            removeRoot()
            return (saved, Self.privateFileName)
        }
        if let saved = try? store.readJSON(Saved.self, from: Self.fileName) { return (saved, Self.fileName) }
        return (Saved(), nil)
    }

    private func persist(_ saved: Saved) -> Bool {
        let encoder = JSONEncoder(); encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? encoder.encode(saved), (try? store.writePrivate(data, to: Self.privateFileName)) != nil else { return false }
        removeRoot()
        return true
    }

    /// Removes the root file, but only after its bytes are copied to a `.bak`, whatever they decode to (s7b review r1 M2, and a root that holds
    /// x and y but does not decode, deferred Low NEW-3): when the copy cannot be made the root stays, and the private file still wins at the next
    /// read. A root that is not there is no failure.
    private func removeRoot() {
        if let root = try? store.url(Self.fileName), FileManager.default.fileExists(atPath: root.path), !backUp(Self.fileName) { return }
        try? store.removeFile(Self.fileName)
    }

    private static func positive(_ values: Double?...) -> Bool { values.allSatisfy { $0.map { $0.isFinite && $0 > 0 } ?? false } }

    public func load() -> CGRect? {
        let saved = read().saved
        guard saved.version == nil, let x = saved.x, let y = saved.y, x.isFinite, y.isFinite, Self.positive(saved.width, saved.height),
              let width = saved.width, let height = saved.height else { return nil }
        return CGRect(x: x, y: y, width: width, height: height)
    }

    public func loadAnchor() -> ChatAnchor? {
        let saved = read().saved
        guard saved.version == 2, let rawX = saved.anchorX, let rawY = saved.anchorY, let anchorX = ChatAnchor.Horizontal(rawValue: rawX),
              let anchorY = ChatAnchor.Vertical(rawValue: rawY), let offsetX = saved.offsetX, let offsetY = saved.offsetY,
              offsetX.isFinite, offsetY.isFinite, Self.positive(saved.width, saved.height), let width = saved.width, let height = saved.height else { return nil }
        return ChatAnchor(display: saved.display, anchorX: anchorX, anchorY: anchorY, offsetX: offsetX, offsetY: offsetY, width: width, height: height)
    }

    @discardableResult public func saveAnchor(_ anchor: ChatAnchor) -> Bool {
        var saved = read().saved
        saved.version = 2; saved.display = anchor.display
        saved.anchorX = anchor.anchorX.rawValue; saved.anchorY = anchor.anchorY.rawValue
        saved.offsetX = anchor.offsetX; saved.offsetY = anchor.offsetY; saved.width = anchor.width; saved.height = anchor.height
        saved.x = nil; saved.y = nil
        return persist(saved)
    }

    public func migrate(to anchor: ChatAnchor) -> Bool {
        let (_, source) = read()
        guard let source, backUp(source) else { return false }
        return saveAnchor(anchor)
    }

    /// Removes the `.chat-panel.json.bak.<stamp>.<six>.tmp` files a kill inside `writeNew` left at the state root or in `chat-private/`, once per
    /// instance (a leftover can only come from an earlier process), before the first read or copy. Only this writer's names: another writer's
    /// temp, which may be in flight, is not matched (deferred Low NEW-1).
    private func sweepBackupTemps() {
        guard !sweptBackupTemps else { return }
        sweptBackupTemps = true
        store.removeStaleTemps(namePrefix: Self.backupPrefix)
        store.removeStaleTemps(in: "chat-private", namePrefix: Self.backupPrefix)
    }

    /// The v1 file's bytes copied to `chat-panel.json.bak.<YYYYMMDD-HHMMSS>` next to it: 0600, written whole under a temp name and linked in, never
    /// overwritten, and not copied again when a `chat-panel.json.bak.*` there already holds exactly these bytes (a file with other bytes is no copy,
    /// s7b review r1 M1). False when the copy could not be made.
    private func backUp(_ source: String) -> Bool {
        sweepBackupTemps()
        guard let original = try? store.url(source), let bytes = try? ReadOnlyFile.data(original.path) else { return false }
        let directory = original.deletingLastPathComponent()
        if let names = try? FileManager.default.contentsOfDirectory(atPath: directory.path),
           names.contains(where: { $0.hasPrefix(Self.backupPrefix) && (try? ReadOnlyFile.data(directory.appendingPathComponent($0).path)) == bytes }) { return true }
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyyMMdd-HHmmss"
        let folder = source.lastIndex(of: "/").map { String(source[...$0]) } ?? ""
        let stamp = Self.backupPrefix + formatter.string(from: now())
        for attempt in 0..<10 {
            do { try store.writeNew(bytes, to: folder + stamp + (attempt == 0 ? "" : "-\(attempt)")); return true } catch OwnStorageFailure.system(EEXIST) { continue } catch { return false }
        }
        return false
    }

    public func loadMaximized() -> Bool { read().saved.maximized ?? false }

    @discardableResult public func saveMaximized(_ maximized: Bool) -> Bool {
        var saved = read().saved
        saved.maximized = maximized
        return persist(saved)
    }
}
