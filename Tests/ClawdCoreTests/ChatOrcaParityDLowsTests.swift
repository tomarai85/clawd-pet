import Testing
import Foundation
import Darwin
import ClawdCore
import ClawdDesktop

// Orca parity round D, deferred Lows (s4 L4, s5 L4, s7b NEW-1..3). Fake screens and a temporary state root only: nothing reads or writes the real
// chat-panel.json, no window is shown or made key, and no application is activated.

private func bytes(_ store: OwnState, _ relative: String) -> Data? { try? Data(contentsOf: store.url(relative)) }
private func exists(_ store: OwnState, _ relative: String) -> Bool { FileManager.default.fileExists(atPath: (try? store.url(relative).path) ?? "") }
private func names(_ store: OwnState, in directory: String = "") -> [String] {
    let path = directory.isEmpty ? store.root.path : store.root.appendingPathComponent(directory).path
    return ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).sorted()
}

@Suite("Chat orca parity D, deferred Lows: the panel file", .serialized)
struct ChatOrcaParityDLowsGeometrySuite {
    private static let when = Date(timeIntervalSince1970: 1_793_000_000)
    /// Holds x and y, so the user's position is in it, but `maximized` is not a Bool: it does not decode.
    private static let undecodable = Data("{\"x\": 1, \"y\": 2, \"width\": 420, \"height\": 280, \"maximized\": \"yes\"}".utf8)
    private static let privateV2 = Data("""
        {"version": 2, "display": null, "anchorX": "left", "anchorY": "top", "offsetX": 10, "offsetY": 20, "width": 520, "height": 340}
        """.utf8)

    private func rootBackups(_ store: OwnState) -> [String] { names(store).filter { $0.hasPrefix("chat-panel.json.bak.") } }

    // NEW-3

    @Test func ChatOrcaDLows_aRootThatHoldsAPositionButDoesNotDecodeIsCopiedBeforeItIsRemoved() throws {
        let store = try artifactStore()
        try store.write(Self.undecodable, to: FileChatGeometry.fileName)
        try store.privateDirectory("chat-private")
        try store.write(Self.privateV2, to: FileChatGeometry.privateFileName)
        #expect(FileChatGeometry(store: store, now: { Self.when }).saveMaximized(true))
        let kept = rootBackups(store)
        #expect(kept.count == 1 && bytes(store, kept[0]) == Self.undecodable, "a root .bak holds the root's exact bytes: \(kept)")
        #expect(!exists(store, FileChatGeometry.fileName), "the root is gone")
    }

    @Test func ChatOrcaDLows_aRootWhoseCopyCannotBeMadeStaysAndAMissingRootIsNoFailure() throws {
        let store = try artifactStore()
        try store.write(Self.undecodable, to: FileChatGeometry.fileName)
        try store.privateDirectory("chat-private")
        try store.write(Self.privateV2, to: FileChatGeometry.privateFileName)
        // Every name the copy may take is held by a file with other bytes, so the copy cannot be made although the root could be unlinked.
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = "chat-panel.json.bak." + formatter.string(from: Self.when)
        for name in [stamp] + (1..<10).map({ "\(stamp)-\($0)" }) { try store.write(Data("held".utf8), to: name) }
        let file = FileChatGeometry(store: store, now: { Self.when })
        _ = file.saveMaximized(true)
        #expect(bytes(store, FileChatGeometry.fileName) == Self.undecodable && rootBackups(store).count == 10, "the root stays: \(names(store))")
        // No root at all: the write goes through and nothing is made.
        let bare = try artifactStore()
        try bare.privateDirectory("chat-private")
        try bare.write(Self.privateV2, to: FileChatGeometry.privateFileName)
        #expect(FileChatGeometry(store: bare, now: { Self.when }).saveMaximized(true) && rootBackups(bare).isEmpty)
    }

    // NEW-1

    @Test func ChatOrcaDLows_aBackupTempLeftByAKillIsSweptAtOpenAndOtherNamesAreNot() throws {
        let store = try artifactStore()
        try store.privateDirectory("chat-private")
        try store.write(Self.privateV2, to: FileChatGeometry.privateFileName)
        let leftover = ".chat-panel.json.bak.20261101-020000.Ab12Cd.tmp"
        let other = [".chat-state.json.Ab12Cd.tmp", "chat-panel.json.bak.20261101-020000", ".chat-panel.json.bak.20261101-020000"]
        for name in [leftover] + other { try store.write(Data("x".utf8), to: name) }
        try store.write(Data("x".utf8), to: "chat-private/" + leftover)
        #expect(FileChatGeometry(store: store, now: { Self.when }).loadAnchor() != nil)
        #expect(!exists(store, leftover) && !exists(store, "chat-private/" + leftover), "the leftover is gone: \(names(store)) \(names(store, in: "chat-private"))")
        #expect(other.allSatisfy { exists(store, $0) }, "the other names are untouched: \(names(store))")
    }
}
