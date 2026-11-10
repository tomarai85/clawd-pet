import Foundation
import CoreGraphics

public struct SavedPosition: Codable, Equatable {
    public var displayUUID: String?
    public var xFrac: Double
    public var feetFrac: Double
    public var scale: Double
    public init(displayUUID: String? = nil, xFrac: Double = 0.5, feetFrac: Double = 0, scale: Double = 1) {
        self.displayUUID = displayUUID; self.xFrac = xFrac; self.feetFrac = feetFrac; self.scale = scale
    }
}

/// `aqua follow|ignore|auto` (control.json key `aqua`): whether Clawd stays hidden while Aqua Voice is not running.
public enum AquaSetting: String, CaseIterable, Codable {
    case follow, ignore, auto
}

/// A dictation app Clawd reacts to. Only this file and OwnState may spell the name (lint `aqua-path-literal`).
public struct DictationSource: Equatable {
    public let id: String
    public let displayName: String
    /// The app is found by this bundle identifier (never by a path).
    public let bundleIdentifier: String
    /// The control.json key for "react while I dictate" (restart-only).
    public let reactKey: String
    /// The control.json key for "only show Clawd while it runs" (restart-only).
    public let followKey: String
    /// The version the log keys were last checked against.
    public let testedVersion: String
    public init(id: String, displayName: String, bundleIdentifier: String, reactKey: String, followKey: String, testedVersion: String) {
        self.id = id; self.displayName = displayName; self.bundleIdentifier = bundleIdentifier
        self.reactKey = reactKey; self.followKey = followKey; self.testedVersion = testedVersion
    }
}
public enum DictationSources {
    public static let aqua = DictationSource(id: "aqua", displayName: "Aqua Voice", bundleIdentifier: "com.electron.aqua-voice",
                                             reactKey: "aquaReact", followKey: "aqua", testedVersion: "0.21.4")
}

/// What the agent does with Aqua's liveness after the setting is resolved once at its start.
public enum AquaMode: String {
    case follow, ignore
    /// `auto` follows Aqua only when Aqua Voice is installed; a Mac without it never has a reason to keep Clawd hidden.
    public static func resolve(_ setting: AquaSetting, installed: Bool) -> AquaMode {
        switch setting {
        case .follow: return .follow
        case .ignore: return .ignore
        case .auto: return installed ? .follow : .ignore
        }
    }
}

/// `control.json` in the agent's own state directory. Every key is optional on read,
/// and the source-B flag is off unless the file says otherwise.
public struct AgentControl: Codable, Equatable {
    public static let allowedScales: [Double] = [0.5, 0.75, 1, 1.5, 2, 3, 4]
    public var scale = 1.0
    public var helmet = false
    public var overFullScreen = false
    public var releaseHintsEnabled = false
    /// Dotted path into Aqua's settings.json that names the selected native input UID.
    public var selectedInputKeyPath = AquaInput.defaultInputKeyPath
    public var idleBudgetMode = false
    /// The chat (Clawd v3): off closes the panel and stops the child; a double-click is then what it was in v2. Live, like every key not in restartKeyNames.
    public var chat = true
    public var aqua: AquaSetting = .auto
    /// Whether Clawd reacts to dictation at all: off builds no log reader and resolves the Aqua mode to ignore. A missing key reads true.
    public var aquaReact = true
    public init() {}
    private enum CodingKeys: String, CodingKey {
        case scale, helmet, overFullScreen, releaseHintsEnabled, selectedInputKeyPath, idleBudgetMode, aqua, chat, aquaReact
    }

    /// The keys the agent builds something from once, when it starts: the panel's level (`overFullScreen`), Source B and its device
    /// listener (`releaseHintsEnabled`), the Aqua setting that names the input device (`selectedInputKeyPath`) and the idle-budget
    /// measurement mode (`idleBudgetMode`), the Aqua follow mode (`aqua`) and whether the Aqua log is read at all (`aquaReact`). A new value of one of them changes nothing in a running agent; only a restart applies it.
    /// Every other key (`scale`, `helmet` and the scheduler's) is applied live.
    public static let restartKeyNames = ["overFullScreen", "releaseHintsEnabled", "selectedInputKeyPath", "idleBudgetMode", "aqua", "aquaReact"]

    /// The restart-only keys whose value here differs from the value the process started with, in the order of `restartKeyNames`.
    public func restartKeys(since boot: AgentControl) -> [String] {
        var names: [String] = []
        if overFullScreen != boot.overFullScreen { names.append("overFullScreen") }
        if releaseHintsEnabled != boot.releaseHintsEnabled { names.append("releaseHintsEnabled") }
        if selectedInputKeyPath != boot.selectedInputKeyPath { names.append("selectedInputKeyPath") }
        if idleBudgetMode != boot.idleBudgetMode { names.append("idleBudgetMode") }
        if aqua != boot.aqua { names.append("aqua") }
        if aquaReact != boot.aquaReact { names.append("aquaReact") }
        return names
    }
    /// Every key is read on its own (spec 5.1 "Reading"): a missing key, an out-of-range value and a value of the wrong type each give
    /// that key's default and leave the other keys as written. Only a file that is not a JSON object at all throws.
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        func value<T: Decodable>(_ key: CodingKeys, _ type: T.Type) -> T? { (try? c.decodeIfPresent(type, forKey: key)) ?? nil }
        let requested = value(.scale, Double.self) ?? 1
        scale = Self.allowedScales.contains(requested) ? requested : 1
        helmet = value(.helmet, Bool.self) ?? false
        overFullScreen = value(.overFullScreen, Bool.self) ?? false
        releaseHintsEnabled = value(.releaseHintsEnabled, Bool.self) ?? false
        selectedInputKeyPath = value(.selectedInputKeyPath, String.self) ?? AquaInput.defaultInputKeyPath
        idleBudgetMode = value(.idleBudgetMode, Bool.self) ?? false
        chat = value(.chat, Bool.self) ?? true
        aqua = value(.aqua, String.self).flatMap(AquaSetting.init(rawValue:)) ?? .auto
        aquaReact = value(.aquaReact, Bool.self) ?? true
    }
}

/// The home directory every path derives from. $HOME wins when it names a directory, so sandboxed tests and the
/// CLI test can run the real code against a fake home; launchd always sets it to the real one.
public enum PetHome {
    public static var url: URL {
        if let value = ProcessInfo.processInfo.environment["HOME"], value.hasPrefix("/") {
            var isDirectory: ObjCBool = false
            if FileManager.default.fileExists(atPath: value, isDirectory: &isDirectory), isDirectory.boolValue {
                return URL(fileURLWithPath: value, isDirectory: true)
            }
        }
        return FileManager.default.homeDirectoryForCurrentUser
    }
    public static var stateRoot: URL { url.appendingPathComponent("Library/Application Support/clawd-pet") }
}

/// Read-only view of the two Aqua files the pet may look at. Only the keys listed here are ever extracted.
public enum AquaInput {
    public static let defaultInputKeyPath = "nativeMicrophone.id"
    /// Only these key paths can name the input device; anything else disables source B.
    public static let permittedInputKeyPaths: Set<String> = ["nativeMicrophone.id"]
    public static var home: URL { PetHome.url }
    public static var logPath: String { home.appendingPathComponent("Library/Logs/Aqua Voice/main.log").path }
    public static var configurationPath: String { home.appendingPathComponent("Library/Application Support/Aqua Voice/settings.json").path }
    private static func projection(_ path: String) -> [String: Any]? {
        guard let data = try? ReadOnlyFile.data(path, limit: 1024 * 1024) else { return nil }
        return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
    }
    /// The selected native input UID, used only in memory. Needs `useNativeAudio == true`.
    public static func selectedUID(keyPath: String = defaultInputKeyPath, settingsPath: String = configurationPath) -> String? {
        guard permittedInputKeyPaths.contains(keyPath), let root = projection(settingsPath),
              root["useNativeAudio"] as? Bool == true else { return nil }
        var cursor: Any? = root
        for part in keyPath.split(separator: ".") { cursor = (cursor as? [String: Any])?[String(part)] }
        guard let value = cursor as? String, !value.isEmpty else { return nil }
        return value
    }
    public struct InitialPosition: Equatable {
        public let x: Double; public let feet: Double; public let displayPoint: CGPoint?
    }
    public static func initialPosition(settingsPath: String = configurationPath) -> InitialPosition? {
        guard let value = projection(settingsPath)?["petPosition"] as? [String: Any],
              let x = value["x"] as? Double, let y = value["y"] as? Double, x.isFinite, y.isFinite else { return nil }
        let display = value["display"] as? [String: Double]
        let point = display.flatMap { d -> CGPoint? in
            guard let x = d["x"], let y = d["y"], x.isFinite, y.isFinite else { return nil }
            return CGPoint(x: x, y: y)
        }
        return InitialPosition(x: x, feet: y, displayPoint: point)
    }
}

/// Pure placement math. `x` is the horizontal centre as a fraction of the display width,
/// `feet` is the height of the feet above the display bottom as a fraction of its height.
public enum Placement {
    public static let defaultBodyWidth = 48.0
    /// The size Clawd is drawn at: the size picked, bounded to 0.5...4, on every display. It never depends on the display's backing: cutting it
    /// to whole device pixels per cell drew 0.75 as 0.5 and 1.5 as 1 on a 1x display (Tom, 2026-11-09). Where a cell is not a whole number of
    /// device pixels (0.75 at 1x: 1.5 px), the renderer cuts the cells on the device grid instead (`StageLayout.columnEdges`).
    public static func effectiveScale(_ requested: Double) -> Double {
        requested.isFinite ? min(4, max(0.5, requested)) : 1
    }
    public static func origin(position: SavedPosition, display: CGRect, visible: CGRect, size: CGSize) -> CGPoint {
        clamp(CGPoint(x: display.minX + display.width * position.xFrac - size.width / 2,
                      y: display.minY + display.height * position.feetFrac), visible: visible, size: size)
    }
    /// Where Tom may put Clawd by hand: the whole display width and every height up to the top of the visible frame. The menu bar stays
    /// out; the Dock, wherever it sits, is in. Walks and the bubble, menu and chat panel keep to the visible frame.
    public static func dragArea(display: CGRect, visible: CGRect) -> CGRect {
        CGRect(x: display.minX, y: display.minY, width: display.width, height: max(0, visible.maxY - display.minY))
    }
    public static func clamp(_ point: CGPoint, visible: CGRect, size: CGSize) -> CGPoint {
        CGPoint(x: min(max(visible.minX, point.x), max(visible.minX, visible.maxX - size.width)),
                y: min(max(visible.minY, point.y), max(visible.minY, visible.maxY - size.height)))
    }
    public static func fractions(origin: CGPoint, size: CGSize, display: CGRect, uuid: String?, scale: Double) -> SavedPosition {
        SavedPosition(displayUUID: uuid, xFrac: (origin.x + size.width / 2 - display.minX) / max(1, display.width),
                      feetFrac: (origin.y - display.minY) / max(1, display.height), scale: scale)
    }
    /// A saved display that is no longer present falls back to `fallback` (the runtime passes the primary display, never the focused one).
    public static func resolveDisplay<T>(saved: String?, displays: [(uuid: String?, value: T)], fallback: T) -> T {
        displays.first { $0.uuid != nil && $0.uuid == saved }?.value ?? fallback
    }
    /// Aqua's default spot, moved 120 pt left of centre so the pet does not cover Aqua's floating bar.
    public static func fallbackPosition(display: CGRect, visible: CGRect) -> SavedPosition {
        SavedPosition(xFrac: 0.5 - 120 / max(1, display.width),
                      feetFrac: (visible.minY - display.minY + 15) / max(1, display.height))
    }
}
