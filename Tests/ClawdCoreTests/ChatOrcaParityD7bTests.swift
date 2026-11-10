import Testing
import Foundation
import AppKit
import ClawdCore
import ClawdDesktop

// Orca parity round D, sprint 7b: more than one display (Q20) and the panel's place kept as a corner anchor of its display (Q26), with the move of the
// file Tom already has. Fake screens and a temporary state root only: nothing reads or writes the real chat-panel.json, no window is shown or made
// key, and no application is activated.

private let screenA = ChatScreen(id: "UUID-A", frame: CGRect(x: 0, y: 0, width: 1512, height: 982), visible: CGRect(x: 0, y: 38, width: 1512, height: 944))
private let screenB = ChatScreen(id: "UUID-B", frame: CGRect(x: 1512, y: 0, width: 1920, height: 1080), visible: CGRect(x: 1512, y: 0, width: 1920, height: 1055))
private let screenC = ChatScreen(id: "UUID-C", frame: CGRect(x: 3432, y: 0, width: 1000, height: 800), visible: CGRect(x: 3432, y: 0, width: 1000, height: 780))

/// 30 pt from the right and 40 pt from the bottom of a display, at the default size.
private func cornerAnchor(on id: String?) -> ChatAnchor {
    ChatAnchor(display: id, anchorX: .right, anchorY: .bottom, offsetX: 30, offsetY: 40, width: 520, height: 340)
}

@Suite("Chat orca parity D, sprint 7b", .serialized)
@MainActor
struct ChatOrcaParityD7bSuite {
    /// A web-kind rig whose host knows `screens`; Clawd is on the first of them.
    private func rig(_ geometry: ChatGeometryStoring?, screens: [ChatScreen] = [screenA, screenB]) -> WebKindRig {
        let r = WebKindRig(geometry: geometry)
        r.rig.host.visible = screens.first?.visible
        r.rig.host.screens = screens
        r.rig.host.rect = CGRect(x: 300, y: 100, width: 520, height: 340)
        return r
    }

    private func setScreens(_ r: WebKindRig, _ screens: [ChatScreen]) {
        r.rig.host.screens = screens
        r.rig.host.visible = screens.first?.visible
        r.controller.replace()
    }

    private func drag(_ r: WebKindRig, dx: CGFloat, dy: CGFloat, finish: Bool = true) throws {
        let bar = try #require(r.panel?.terminal).titleBarView
        bar.beginDrag(at: CGPoint(x: 400, y: 300))
        bar.drag(to: CGPoint(x: 400 + dx, y: 300 + dy))
        if finish { bar.endDrag() }
    }

    private func frameOf(_ r: WebKindRig) -> CGRect { r.panel?.frame ?? .null }

    private func corner(_ frame: CGRect, in visible: CGRect) -> (right: CGFloat, bottom: CGFloat) { (visible.maxX - frame.maxX, frame.minY - visible.minY) }

    // MARK: Q26: the anchor

    @Test func ChatOrcaD7b_aGestureSavesTheNearestCornerAndItsDistances() throws {
        let geometry = MemoryChatGeometry()
        let r = rig(geometry)
        r.rig.open()
        // The default panel is at (300, 100): left of centre and below it.
        try drag(r, dx: 662, dy: -22)
        let frame = frameOf(r)
        #expect(frame.maxX == screenA.visible.maxX - 30 && frame.minY == screenA.visible.minY + 40, "\(frame)")
        #expect(geometry.anchor == cornerAnchor(on: "UUID-A"), "\(String(describing: geometry.anchor))")
        #expect(r.rig.lines("CHAT gesture move-end").last?.hasSuffix(" anchor=rb") == true, "\(r.rig.lines("CHAT gesture"))")
        // Left of the centre of the display, above it: left, top.
        try drag(r, dx: -700, dy: 400)
        let moved = frameOf(r)
        let anchor = try #require(geometry.anchor)
        #expect(anchor.anchorX == .left && anchor.anchorY == .top && anchor.offsetX == moved.minX - screenA.visible.minX
                && anchor.offsetY == screenA.visible.maxY - moved.maxY, "\(anchor) \(moved)")
        #expect(r.rig.lines("CHAT gesture move-end").last?.hasSuffix(" anchor=lt") == true)
    }

    @Test func ChatOrcaD7b_theDisplayShrinksUnderAnOpenPanelAndItKeepsItsCornerDistances() throws {
        let r = rig(MemoryChatGeometry(anchor: cornerAnchor(on: "UUID-A")), screens: [screenA])
        r.rig.open()
        // The open is beside Clawd (the file supplies only the size); a drag to the corner makes the opening the user's, whose anchor is re-resolved.
        try drag(r, dx: 662, dy: -22)
        #expect(frameOf(r).maxX == screenA.visible.maxX - 30)
        let smaller = ChatScreen(id: "UUID-A", frame: CGRect(x: 0, y: 0, width: 1280, height: 820), visible: CGRect(x: 0, y: 20, width: 1280, height: 800))
        setScreens(r, [smaller])
        let frame = frameOf(r)
        #expect(corner(frame, in: smaller.visible) == (30, 40) && frame.size == CGSize(width: 520, height: 340), "\(frame)")
    }

    @Test func ChatOrcaD7b_aRectSavedOnBOpensBesideClawdOnAWhetherBIsPresentOrAway() throws {
        let onB = rig(MemoryChatGeometry(anchor: cornerAnchor(on: "UUID-B")))
        onB.rig.open()
        #expect(frameOf(onB) == CGRect(x: 300, y: 100, width: 520, height: 340) && screenA.visible.contains(frameOf(onB)))
        let away = rig(MemoryChatGeometry(anchor: cornerAnchor(on: "UUID-B")), screens: [screenA])
        away.rig.open()
        let frame = frameOf(away)
        #expect(frame == CGRect(x: 300, y: 100, width: 520, height: 340), "B absent: beside Clawd on its display: \(frame)")
        // An anchor 1500 pt from B's left edge changes nothing about the open, and the saved offsets are untouched.
        let far = ChatAnchor(display: "UUID-B", anchorX: .left, anchorY: .bottom, offsetX: 1500, offsetY: 40, width: 520, height: 340)
        let geometry = MemoryChatGeometry(anchor: far)
        let wide = rig(geometry, screens: [screenA])
        wide.rig.open()
        #expect(frameOf(wide) == CGRect(x: 300, y: 100, width: 520, height: 340) && geometry.anchor == far)
    }

    @Test func ChatOrcaD7b_aDraggedPanelOnBGoesToAAtItsCornerDistancesComesBackToBAndAddingCMovesNothing() throws {
        let geometry = MemoryChatGeometry(anchor: cornerAnchor(on: "UUID-B"))
        let r = rig(geometry)
        r.rig.open()
        try drag(r, dx: 2582, dy: -60)
        let onB = frameOf(r)
        #expect(screenB.visible.contains(onB) && corner(onB, in: screenB.visible) == (30, 40), "premise: dragged to B's corner: \(onB)")
        // The drag is the only write (R3): re-resolving the committed anchor on a display change saves nothing (Codex ADV-1).
        let saved = geometry.saves
        #expect(saved >= 1, "premise: the drag committed its anchor")
        setScreens(r, [screenA])
        let onA = frameOf(r)
        #expect(corner(onA, in: screenA.visible) == (30, 40), "\(onA)")
        setScreens(r, [screenA, screenB])
        #expect(frameOf(r) == onB, "B is back: \(String(describing: r.panel?.frame))")
        setScreens(r, [screenA, screenB, screenC])
        #expect(frameOf(r) == onB, "adding C moves nothing")
        #expect(geometry.saves == saved, "the display changes write nothing: \(geometry.saves - saved) more saves")
    }

    @Test func ChatOrcaD7b_aPanelOpenedBesideClawdIsNotMovedByBGoingBComingBackOrCArriving() throws {
        let geometry = MemoryChatGeometry(anchor: cornerAnchor(on: "UUID-B"))
        let r = rig(geometry)
        r.rig.open()
        let onB = frameOf(r)
        #expect(onB == CGRect(x: 300, y: 100, width: 520, height: 340) && screenA.visible.contains(onB), "premise: it opened beside Clawd on A: \(onB)")
        setScreens(r, [screenA])
        let onA = frameOf(r)
        #expect(onA == onB, "\(onA)")
        setScreens(r, [screenA, screenB])
        #expect(frameOf(r) == onB, "B is back: \(String(describing: r.panel?.frame))")
        setScreens(r, [screenA, screenB, screenC])
        #expect(frameOf(r) == onB, "adding C moves nothing")
        #expect(geometry.saves == 0, "none of it is written")
    }

    @Test func ChatOrcaD7b_thePetsFramesWithNoDisplayChangeLeaveThePanelWhereItIs() throws {
        let r = rig(MemoryChatGeometry(anchor: ChatAnchor(display: "UUID-A", anchorX: .left, anchorY: .top, offsetX: 123.5, offsetY: 77.25, width: 531, height: 347)))
        r.rig.open()
        // The open is beside Clawd; a drag makes the opening the user's, and it is the committed anchor that every pet frame re-resolves (R3).
        try drag(r, dx: 0.5, dy: -0.25)
        let first = frameOf(r)
        for step in 0..<50 {
            r.rig.host.rect = CGRect(x: CGFloat(step * 7), y: 100, width: 520, height: 340)
            r.controller.replace()
        }
        #expect(frameOf(r) == first, "no drift: \(String(describing: r.panel?.frame))")
    }

    @Test func ChatOrcaD7b_aCommitOnADisplayTooSmallToAnchorSavesNothingAndTheNextReplaceKeepsTheDraggedFrame() throws {
        let geometry = MemoryChatGeometry()
        // 315 pt wide: one point short of holding the minimum panel (300) and both margins. (A 400 x 300 display pins the panel in both axes, so no gesture
        // could change its frame and the commit would never be reached.)
        let tiny = ChatScreen(id: "UUID-T", frame: CGRect(x: 0, y: 0, width: 315, height: 600), visible: CGRect(x: 0, y: 0, width: 315, height: 600))
        // The opening is the user's first (a drag on Clawd's roomy display commits an anchor), then the display shrinks under it.
        let r = rig(geometry, screens: [screenA])
        r.rig.open()
        try drag(r, dx: 0, dy: 60)
        let stale = try #require(geometry.anchor, "premise: the first drag committed an anchor")
        setScreens(r, [tiny])
        let before = frameOf(r)
        try drag(r, dx: 0, dy: 60)
        let dragged = frameOf(r)
        #expect(dragged != before, "premise: the gesture moved the panel: \(before) \(dragged)")
        #expect(geometry.saves == 1 && geometry.anchor == stale, "the file is unchanged by the commit that could not anchor")
        r.controller.replace()
        #expect(frameOf(r) == dragged, "a stale anchor does not pull it back: \(String(describing: r.panel?.frame))")
        #expect(r.rig.lines("CHAT gesture move-end").last?.contains("anchor=") == false)
    }

    @Test func ChatOrcaD7b_aMoveWhoseScreenGoesBeforeTheEndSavesAClampedFrame() throws {
        let geometry = MemoryChatGeometry()
        let r = rig(geometry)
        r.rig.open()
        let bar = try #require(r.panel?.terminal).titleBarView
        bar.beginDrag(at: CGPoint(x: 400, y: 300))
        bar.drag(to: CGPoint(x: 400 + 1800, y: 300))
        #expect(screenB.visible.contains(frameOf(r)), "premise: the panel followed the pointer onto B")
        r.rig.host.screens = [screenA]
        r.controller.replace()
        bar.endDrag()
        let frame = frameOf(r)
        #expect(screenA.visible.contains(frame), "clamped to A before it was saved: \(frame)")
        #expect(geometry.anchor?.display == "UUID-A" && geometry.rect(in: screenA.visible) == frame, "\(String(describing: geometry.anchor))")
    }

    @Test func ChatOrcaD7b_anIdThatIsEmptyOrBuiltFromAnIndexIsSavedAsNullAndNullResolvesOnClawdsDisplay() throws {
        let rect = CGRect(x: 962, y: 78, width: 520, height: 340)
        #expect(ChatPanelGeometry.anchor(of: rect, in: screenA.visible, display: "")?.display == nil)
        #expect(ChatPanelGeometry.anchor(of: rect, in: screenA.visible, display: "display-1")?.display == nil)
        #expect(ChatPanelGeometry.anchor(of: rect, in: screenA.visible, display: "UUID-A")?.display == "UUID-A")
        let indexed = ChatScreen(id: "display-0", frame: screenA.frame, visible: screenA.visible)
        let geometry = MemoryChatGeometry()
        let r = rig(geometry, screens: [indexed, screenB])
        r.rig.open()
        try drag(r, dx: 662, dy: -22)
        #expect(geometry.anchor == cornerAnchor(on: nil), "\(String(describing: geometry.anchor))")
        // A live null anchor resolves at the same corner distances on Clawd's display after the displays change.
        let movedB = ChatScreen(id: "UUID-B", frame: CGRect(x: 4000, y: 0, width: 1000, height: 800), visible: CGRect(x: 4000, y: 0, width: 1000, height: 780))
        setScreens(r, [indexed, movedB])
        #expect(corner(frameOf(r), in: screenA.visible) == (30, 40), "\(frameOf(r))")
        // Null resolves on Clawd's display, whichever it is.
        let other = rig(MemoryChatGeometry(anchor: cornerAnchor(on: nil)), screens: [screenB, screenA])
        other.rig.open()
        #expect(frameOf(other) == CGRect(x: 300, y: 100, width: 520, height: 340), "the open is beside Clawd, whatever display the file names")
    }

    @Test func ChatOrcaD7b_theSmallestDisplayThatHoldsThePanelAndItsMarginsCanBeAnchoredAndOneLessCannot() {
        let rect = CGRect(x: 8, y: 8, width: 300, height: 200)
        #expect(ChatPanelGeometry.anchor(of: rect, in: CGRect(x: 0, y: 0, width: 316, height: 216), display: nil) != nil)
        #expect(ChatPanelGeometry.anchor(of: rect, in: CGRect(x: 0, y: 0, width: 315, height: 216), display: nil) == nil)
        #expect(ChatPanelGeometry.anchor(of: rect, in: CGRect(x: 0, y: 0, width: 316, height: 215), display: nil) == nil)
    }

    // MARK: Q26: the file

    private func fileRig(_ store: OwnState, screens: [ChatScreen] = [screenA], now: Date = Date(timeIntervalSince1970: 1_793_000_000)) -> WebKindRig {
        rig(FileChatGeometry(store: store, now: { now }), screens: screens)
    }

    private func bytes(_ store: OwnState, _ relative: String) -> Data? { try? Data(contentsOf: store.url(relative)) }
    private func exists(_ store: OwnState, _ relative: String) -> Bool { FileManager.default.fileExists(atPath: (try? store.url(relative).path) ?? "") }
    private func backups(_ store: OwnState, in directory: String = "") -> [String] {
        let path = directory.isEmpty ? store.root.path : store.root.appendingPathComponent(directory).path
        return ((try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []).filter { $0.hasPrefix("chat-panel.json.bak.") }.sorted()
    }
    private func mode(_ store: OwnState, _ relative: String) -> Int? {
        (try? FileManager.default.attributesOfItem(atPath: store.url(relative).path)[.posixPermissions] as? NSNumber)?.intValue
    }

    private static let tomsFile = Data("{\"height\":280,\"width\":420,\"x\":134,\"y\":614}".utf8)

    @Test func ChatOrcaD7b_tomsFileIsMovedOnceAtOpenWithABackupAndResolvesToTheSameRect() throws {
        let store = try artifactStore()
        try store.write(Self.tomsFile, to: FileChatGeometry.fileName)
        let r = fileRig(store)
        r.rig.open()
        #expect(frameOf(r) == CGRect(x: 300, y: 100, width: 420, height: 280), "\(String(describing: r.panel?.frame))")
        #expect(r.rig.lines("CHAT panel-geometry migrated=1").count == 1, "\(r.rig.lines("CHAT panel-geometry"))")
        let file = FileChatGeometry(store: store)
        let anchor = try #require(file.loadAnchor())
        #expect(anchor.anchorX == .left && anchor.anchorY == .top && anchor.offsetX == 134 && anchor.offsetY == 88 && anchor.display == "UUID-A", "\(anchor)")
        #expect(file.load() == nil && !exists(store, FileChatGeometry.fileName), "the root file is gone")
        let kept = backups(store)
        #expect(kept.count == 1 && bytes(store, kept[0]) == Self.tomsFile, "the .bak holds the v1 bytes: \(kept)")
        #expect(mode(store, kept[0]) == 0o600 && mode(store, FileChatGeometry.privateFileName) == 0o600)
        let v2 = bytes(store, FileChatGeometry.privateFileName)
        // A second open rewrites neither file.
        r.controller.close(.toggle)
        r.rig.open(at: 2)
        #expect(frameOf(r) == CGRect(x: 300, y: 100, width: 420, height: 280))
        #expect(bytes(store, FileChatGeometry.privateFileName) == v2 && backups(store) == kept && r.rig.lines("CHAT panel-geometry migrated=1").count == 1)
    }

    @Test func ChatOrcaD7b_aV1RectOnNoPresentScreenIsNotMovedAndItsScreenGetsTheMoveAtALaterOpen() throws {
        let store = try artifactStore()
        let v1 = Data("{\"height\":340,\"width\":520,\"x\":3600,\"y\":300}".utf8)
        try store.write(v1, to: FileChatGeometry.fileName)
        let r = fileRig(store)
        r.rig.open()
        #expect(screenA.visible.contains(frameOf(r)), "clamped on Clawd's display: \(String(describing: r.panel?.frame))")
        #expect(r.rig.lines("CHAT panel-geometry migrate=later reason=away").count == 1 && r.rig.lines("CHAT panel-geometry migrated").isEmpty)
        #expect(bytes(store, FileChatGeometry.fileName) == v1 && backups(store).isEmpty && !exists(store, FileChatGeometry.privateFileName))
        r.controller.close(.toggle)
        r.rig.host.screens = [screenA, screenC]
        r.rig.open(at: 2)
        #expect(frameOf(r) == CGRect(x: 300, y: 100, width: 520, height: 340), "\(String(describing: r.panel?.frame))")
        #expect(FileChatGeometry(store: store).loadAnchor()?.display == "UUID-C" && backups(store).count == 1 && !exists(store, FileChatGeometry.fileName))
    }

    @Test func ChatOrcaD7b_aV1RectPartlyOffItsScreenIsMovedWithNonNegativeOffsetsThatResolveInside() throws {
        let store = try artifactStore()
        try store.write(Data("{\"height\":280,\"width\":420,\"x\":1400,\"y\":900}".utf8), to: FileChatGeometry.fileName)
        let r = fileRig(store)
        r.rig.open()
        let anchor = try #require(FileChatGeometry(store: store).loadAnchor())
        #expect(anchor.offsetX >= 0 && anchor.offsetY >= 0, "\(anchor)")
        // The migrated anchor resolves to the v1 rect clamped inside the 8 pt edge margin of A's visible frame (0, 38, 1512 x 944):
        // x 1512 - 8 - 420, y 982 - 8 - 280 (Codex ADV-2: the open no longer shows it, so the anchor itself is checked).
        let back = ChatPanelGeometry.resolve(anchor, in: screenA.visible)
        #expect(screenA.visible.contains(back) && back == CGRect(x: 1084, y: 694, width: 420, height: 280), "\(back)")
        let frame = frameOf(r)
        #expect(screenA.visible.contains(frame) && frame == CGRect(x: 300, y: 100, width: 420, height: 280), "\(frame)")
    }

    @Test func ChatOrcaD7b_aV1FileAtThePrivatePathIsBackedUpBesideItBeforeItBecomesV2() throws {
        let store = try artifactStore()
        let v1 = Data("{\"height\":280,\"width\":420,\"x\":134,\"y\":614}".utf8)
        try store.privateDirectory("chat-private")
        try store.write(v1, to: FileChatGeometry.privateFileName)
        #expect(!exists(store, FileChatGeometry.fileName))
        let r = fileRig(store)
        r.rig.open()
        #expect(r.rig.lines("CHAT panel-geometry migrated=1").count == 1, "\(r.rig.lines("CHAT panel-geometry"))")
        let kept = backups(store, in: "chat-private")
        #expect(kept.count == 1 && bytes(store, "chat-private/" + kept[0]) == v1, "the only copy of the private v1 bytes: \(kept)")
        #expect(mode(store, "chat-private/" + kept[0]) == 0o600 && mode(store, FileChatGeometry.privateFileName) == 0o600)
        let text = String(decoding: try #require(bytes(store, FileChatGeometry.privateFileName)), as: UTF8.self)
        #expect(text.contains("\"version\" : 2") && text.contains("\"anchorX\""), "the private file is v2: \(text)")
        #expect(backups(store).isEmpty, "no root copy: \(backups(store))")
    }

    @Test func ChatOrcaD7b_noScreenKnownYetLeavesTheV1FileAndTheNextOpenMovesIt() throws {
        let store = try artifactStore()
        try store.write(Self.tomsFile, to: FileChatGeometry.fileName)
        let r = WebKindRig(geometry: FileChatGeometry(store: store))
        r.rig.host.rect = CGRect(x: 300, y: 100, width: 520, height: 340)
        r.rig.host.visible = nil
        r.rig.open()
        #expect(r.rig.lines("CHAT panel-geometry migrate=later reason=no-screen").count == 1, "\(r.rig.lines("CHAT"))")
        #expect(bytes(store, FileChatGeometry.fileName) == Self.tomsFile && backups(store).isEmpty)
        r.controller.close(.toggle)
        r.rig.host.visible = screenA.visible
        r.rig.host.screens = [screenA]
        r.rig.open(at: 2)
        #expect(r.rig.lines("CHAT panel-geometry migrated=1").count == 1 && backups(store).count == 1)
    }

    @Test func ChatOrcaD7b_aDisplayTooSmallToAnchorLeavesTheV1File() throws {
        let store = try artifactStore()
        let onTiny = Data("{\"height\":280,\"width\":420,\"x\":134,\"y\":10}".utf8)
        try store.write(onTiny, to: FileChatGeometry.fileName)
        let tiny = ChatScreen(id: "UUID-T", frame: CGRect(x: 0, y: 0, width: 800, height: 600), visible: CGRect(x: 0, y: 0, width: 800, height: 210))
        let r = fileRig(store, screens: [tiny])
        r.rig.open()
        #expect(r.rig.lines("CHAT panel-geometry migrate=later reason=small").count == 1, "\(r.rig.lines("CHAT"))")
        #expect(bytes(store, FileChatGeometry.fileName) == onTiny && backups(store).isEmpty)
    }

    @Test func ChatOrcaD7b_aSecondMoveMakesNoSecondBackupAndAnExistingBackupIsNeverOverwritten() throws {
        let store = try artifactStore()
        // An earlier copy of these very bytes is the copy: no second one, and it is not touched.
        try store.write(Self.tomsFile, to: "chat-panel.json.bak.20260101-000000")
        try store.write(Self.tomsFile, to: FileChatGeometry.fileName)
        let file = FileChatGeometry(store: store, now: { Date(timeIntervalSince1970: 1_793_000_000) })
        #expect(file.migrate(to: cornerAnchor(on: nil)))
        #expect(backups(store) == ["chat-panel.json.bak.20260101-000000"] && bytes(store, "chat-panel.json.bak.20260101-000000") == Self.tomsFile)
        #expect(file.loadAnchor() == cornerAnchor(on: nil) && !exists(store, FileChatGeometry.fileName))
    }

    @Test func ChatOrcaD7b_aBackupWithOtherBytesOrNoBytesIsNotTheCopy() throws {
        for (label, other) in [("empty", Data()), ("other bytes", Data("an earlier copy".utf8)), ("a prefix of the v1 bytes", Self.tomsFile.prefix(20))] {
            let store = try artifactStore()
            try store.write(other, to: "chat-panel.json.bak.20260101-000000")
            try store.write(Self.tomsFile, to: FileChatGeometry.fileName)
            let file = FileChatGeometry(store: store, now: { Date(timeIntervalSince1970: 1_793_000_000) })
            #expect(file.migrate(to: cornerAnchor(on: nil)), "\(label)")
            let kept = backups(store)
            #expect(kept.count == 2 && bytes(store, "chat-panel.json.bak.20260101-000000") == other, "\(label): the earlier file is untouched: \(kept)")
            #expect(kept.contains { bytes(store, $0) == Self.tomsFile }, "\(label): a new .bak holds the v1 bytes: \(kept)")
            #expect(!exists(store, FileChatGeometry.fileName), "\(label)")
        }
    }

    @Test func ChatOrcaD7b_aBackupAppearsWholeUnderItsFinalNameAndLeavesNoTemp() throws {
        let store = try artifactStore()
        try store.write(Self.tomsFile, to: FileChatGeometry.fileName)
        #expect(FileChatGeometry(store: store, now: { Date(timeIntervalSince1970: 1_793_000_000) }).migrate(to: cornerAnchor(on: nil)))
        let names = (try? FileManager.default.contentsOfDirectory(atPath: store.root.path)) ?? []
        #expect(names.filter { $0.hasSuffix(".tmp") }.isEmpty, "\(names)")
        // The name is taken by a file with other bytes: the copy gets the next name, and the taken one is never overwritten.
        let taken = try artifactStore()
        let when = Date(timeIntervalSince1970: 1_793_000_000)
        let stamp = backups(store)[0]
        try taken.write(Data("not it".utf8), to: stamp)
        try taken.write(Self.tomsFile, to: FileChatGeometry.fileName)
        #expect(FileChatGeometry(store: taken, now: { when }).migrate(to: cornerAnchor(on: nil)))
        #expect(bytes(taken, stamp) == Data("not it".utf8) && backups(taken).count == 2 && backups(taken).contains { bytes(taken, $0) == Self.tomsFile })
    }

    // Tom's real file as of 2026-11-01 (spec, chat-panel.json contract): 64 bytes, pretty-printed.
    private static let tomsReal = Data("{\n  \"height\" : 280,\n  \"width\" : 420,\n  \"x\" : 103,\n  \"y\" : 1738\n}".utf8)

    private func awayRig(_ store: OwnState) throws -> WebKindRig {
        try store.write(Self.tomsReal, to: FileChatGeometry.fileName)
        let r = fileRig(store)
        r.rig.open()
        #expect(r.rig.lines("CHAT panel-geometry migrate=later reason=away").count == 1, "premise: the migration is deferred: \(r.rig.lines("CHAT"))")
        #expect(bytes(store, FileChatGeometry.fileName) == Self.tomsReal && backups(store).isEmpty)
        return r
    }

    @Test func ChatOrcaD7b_awayV1ThenOneMaximizeToggleLeavesARootBackupOfTheV1Bytes() throws {
        #expect(Self.tomsReal.count == 64)
        let store = try artifactStore()
        let r = try awayRig(store)
        try #require(r.panel?.terminal).maximizeButton.performClick(nil)
        let kept = backups(store)
        #expect(kept.count == 1 && bytes(store, kept[0]) == Self.tomsReal, "a root .bak holds Tom's bytes: \(kept)")
        #expect(!exists(store, FileChatGeometry.fileName) && FileChatGeometry(store: store).loadMaximized())
    }

    @Test func ChatOrcaD7b_awayV1ThenOneCommitOnAPresentDisplayLeavesARootBackupOfTheV1Bytes() throws {
        let store = try artifactStore()
        let r = try awayRig(store)
        try drag(r, dx: 200, dy: 0)
        let kept = backups(store)
        #expect(kept.count == 1 && bytes(store, kept[0]) == Self.tomsReal, "a root .bak holds Tom's bytes: \(kept)")
        #expect(!exists(store, FileChatGeometry.fileName) && FileChatGeometry(store: store).loadAnchor() != nil)
    }

    @Test func ChatOrcaD7b_aWriteWhoseBackupCannotBeMadeKeepsTheRootV1File() throws {
        let store = try artifactStore()
        try store.write(Self.tomsReal, to: FileChatGeometry.fileName)
        // Every name the copy may take is held by a file with other bytes.
        let when = Date(timeIntervalSince1970: 1_793_000_000)
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "en_US_POSIX"); formatter.dateFormat = "yyyyMMdd-HHmmss"
        let stamp = "chat-panel.json.bak." + formatter.string(from: when)
        for name in [stamp] + (1..<10).map({ "\(stamp)-\($0)" }) { try store.write(Data("held".utf8), to: name) }
        let file = FileChatGeometry(store: store, now: { when })
        file.saveMaximized(true)
        #expect(bytes(store, FileChatGeometry.fileName) == Self.tomsReal, "the root stays when its copy cannot be made")
        #expect(file.saveAnchor(cornerAnchor(on: nil)))
        #expect(bytes(store, FileChatGeometry.fileName) == Self.tomsReal && backups(store).count == 10)
    }

    @Test func ChatOrcaD7b_anIndexBuiltIdDisplayKeepsThePanelWhereItWasCommittedAcrossPetFrames() throws {
        let a = ChatScreen(id: "UUID-A", frame: screenA.frame, visible: screenA.visible)
        let b = ChatScreen(id: "display-1", frame: screenB.frame, visible: screenB.visible)
        let geometry = MemoryChatGeometry()
        let r = rig(geometry, screens: [a, b])
        r.rig.open()
        try drag(r, dx: 1800, dy: 0)
        let onB = frameOf(r)
        #expect(b.visible.contains(onB) && geometry.anchor?.display == nil, "premise: committed on B, stored as null: \(onB)")
        for step in 0..<10 {
            r.rig.host.rect = CGRect(x: CGFloat(step * 11), y: 100, width: 520, height: 340)
            r.controller.replace()
        }
        #expect(frameOf(r) == onB, "a pet frame moves nothing: \(frameOf(r))")
        // After a display change the id no longer names it: Clawd's display (N19).
        let moved = ChatScreen(id: "display-1", frame: CGRect(x: 4000, y: 0, width: 1000, height: 800), visible: CGRect(x: 4000, y: 0, width: 1000, height: 780))
        setScreens(r, [a, moved])
        #expect(a.visible.contains(frameOf(r)), "on Clawd's display: \(frameOf(r))")
    }

    @Test func ChatOrcaD7b_aFailedGeometryWriteIsLoggedOncePerWrite() throws {
        let geometry = MemoryChatGeometry()
        geometry.failWrites = true
        let r = rig(geometry)
        r.rig.open()
        try drag(r, dx: 100, dy: 0)
        #expect(r.rig.lines("CHAT panel-geometry save=failed what=anchor").count == 1, "\(r.rig.lines("CHAT panel-geometry"))")
        try #require(r.panel?.terminal).maximizeButton.performClick(nil)
        #expect(r.rig.lines("CHAT panel-geometry save=failed what=maximized").count == 1 && r.rig.lines("CHAT panel-geometry save=failed").count == 2)
        geometry.failWrites = false
        try drag(r, dx: -50, dy: 0)
        #expect(r.rig.lines("CHAT panel-geometry save=failed").count == 2)
    }

    @Test func ChatOrcaD7b_aVersion2FileWithNoDisplayWritesNullNotAMissingKey() throws {
        let store = try artifactStore()
        let file = FileChatGeometry(store: store)
        #expect(file.saveAnchor(cornerAnchor(on: nil)))
        let text = String(decoding: try #require(bytes(store, FileChatGeometry.privateFileName)), as: UTF8.self)
        #expect(text.contains("\"display\" : null"), "\(text)")
        #expect(file.loadAnchor() == cornerAnchor(on: nil))
        #expect(file.saveAnchor(cornerAnchor(on: "UUID-A")))
        #expect(String(decoding: try #require(bytes(store, FileChatGeometry.privateFileName)), as: UTF8.self).contains("\"display\" : \"UUID-A\""))
    }

    @Test func ChatOrcaD7b_maximizedOnBRemoveBBringBBackIsMaximizedOnBAgain() throws {
        let r = rig(MemoryChatGeometry())
        r.rig.open()
        try drag(r, dx: 1800, dy: 0)
        try #require(r.panel?.terminal).maximizeButton.performClick(nil)
        #expect(frameOf(r) == ChatPanelGeometry.maximized(in: screenB.visible), "premise: maximized on B")
        setScreens(r, [screenA])
        #expect(frameOf(r) == ChatPanelGeometry.maximized(in: screenA.visible))
        setScreens(r, [screenA, screenB])
        #expect(frameOf(r) == ChatPanelGeometry.maximized(in: screenB.visible), "B is back: \(frameOf(r))")
        // B goes again and comes back as the same display (its UUID) at another place and size: found by the UUID, not by the old rect.
        setScreens(r, [screenA])
        let moved = ChatScreen(id: "UUID-B", frame: CGRect(x: 6000, y: 0, width: 1600, height: 900), visible: CGRect(x: 6000, y: 0, width: 1600, height: 875))
        setScreens(r, [screenA, moved])
        #expect(frameOf(r) == ChatPanelGeometry.maximized(in: moved.visible), "B is back elsewhere: \(frameOf(r))")
    }

    @Test func ChatOrcaD7b_aFailedBackupLeavesTheV1FileAsItWas() throws {
        let store = try artifactStore()
        try store.write(Self.tomsFile, to: FileChatGeometry.fileName)
        // A state root nobody can write into, with chat-private/ already there and writable: the backup cannot be made, so nothing is moved even
        // though the private file could be written.
        try store.privateDirectory("chat-private")
        let file = FileChatGeometry(store: store, now: { Date(timeIntervalSince1970: 1_793_000_000) })
        chmod(store.root.path, 0o500)
        defer { chmod(store.root.path, 0o700) }
        #expect(!file.migrate(to: cornerAnchor(on: nil)))
        chmod(store.root.path, 0o700)
        #expect(bytes(store, FileChatGeometry.fileName) == Self.tomsFile && !exists(store, FileChatGeometry.privateFileName) && file.load() != nil)
    }

    @Test func ChatOrcaD7b_theMaximizeToggleOnAV2FileLeavesEveryAnchorFieldEqual() throws {
        let store = try artifactStore()
        let file = FileChatGeometry(store: store)
        file.saveAnchor(cornerAnchor(on: "UUID-A"))
        func fields() throws -> [String: Any] {
            let data = try #require(bytes(store, FileChatGeometry.privateFileName))
            var all = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
            all["maximized"] = nil
            return all
        }
        let before = try fields()
        let r = rig(file, screens: [screenA])
        r.rig.open()
        let container = try #require(r.panel?.terminal)
        container.maximizeButton.performClick(nil)
        #expect(file.loadMaximized())
        let maximized = try fields()
        #expect(NSDictionary(dictionary: maximized).isEqual(to: before) && file.loadAnchor() == cornerAnchor(on: "UUID-A"), "\(maximized)")
        container.maximizeButton.performClick(nil)
        let restored = try fields()
        #expect(!file.loadMaximized() && NSDictionary(dictionary: restored).isEqual(to: before))
    }

    @Test func ChatOrcaD7b_aV1FileThatHoldsOnlyTheFlagStaysV1UntilTheFirstCommitWhichKeepsTheFlag() throws {
        let store = try artifactStore()
        let file = FileChatGeometry(store: store)
        file.saveMaximized(true)
        let flagData = try #require(bytes(store, FileChatGeometry.privateFileName))
        let flagOnly = try #require(JSONSerialization.jsonObject(with: flagData) as? [String: Any])
        #expect(flagOnly["version"] == nil && flagOnly["maximized"] as? Bool == true && file.loadAnchor() == nil && file.load() == nil, "\(flagOnly)")
        file.saveAnchor(cornerAnchor(on: nil))
        let v2Data = try #require(bytes(store, FileChatGeometry.privateFileName))
        let v2 = try #require(JSONSerialization.jsonObject(with: v2Data) as? [String: Any])
        #expect(v2["version"] as? Int == 2 && v2["maximized"] as? Bool == true && v2["x"] == nil && v2["y"] == nil, "\(v2)")
    }

    @Test func ChatOrcaD7b_aMaximizedV2FileNamingBOpensMaximizedOnClawdsDisplayAndBComingMovesNothing() throws {
        let r = rig(MemoryChatGeometry(maximized: true, anchor: cornerAnchor(on: "UUID-B")), screens: [screenA])
        r.rig.open()
        #expect(frameOf(r) == ChatPanelGeometry.maximized(in: screenA.visible), "Clawd's display meanwhile")
        setScreens(r, [screenA, screenB])
        #expect(frameOf(r) == ChatPanelGeometry.maximized(in: screenA.visible), "B coming back no longer moves it: \(String(describing: r.panel?.frame))")
    }

    @Test func ChatOrcaD7b_maximizedOnBThenBGoesRestoreSitsOnAAtTheAnchorsDistancesNeverAtTheStaleRect() throws {
        let r = rig(MemoryChatGeometry(anchor: cornerAnchor(on: "UUID-B")))
        r.rig.open()
        // Beside Clawd on A at open; a drag to B's corner (30, 40) makes it the user's, anchored on B.
        try drag(r, dx: 2582, dy: -60)
        let staleRect = frameOf(r)
        let container = try #require(r.panel?.terminal)
        container.maximizeButton.performClick(nil)
        #expect(frameOf(r) == ChatPanelGeometry.maximized(in: screenB.visible))
        setScreens(r, [screenA])
        #expect(frameOf(r) == ChatPanelGeometry.maximized(in: screenA.visible))
        container.maximizeButton.performClick(nil)
        let frame = frameOf(r)
        #expect(corner(frame, in: screenA.visible) == (30, 40) && frame != staleRect, "\(frame) vs \(staleRect)")
    }

    @Test func ChatOrcaD7b_theFileIsPrivateAndARootFileMovesAndThePrivateOneWinsWhenBothExist() throws {
        let store = try artifactStore()
        let file = FileChatGeometry(store: store)
        file.saveAnchor(cornerAnchor(on: "UUID-A"))
        #expect(mode(store, FileChatGeometry.privateFileName) == 0o600 && mode(store, "chat-private") == 0o700)
        #expect(!exists(store, FileChatGeometry.fileName))
        // A root file alone is read, and moved by the next write.
        let rootOnly = try artifactStore()
        try rootOnly.write(Data("{\"maximized\":true}".utf8), to: FileChatGeometry.fileName)
        let moving = FileChatGeometry(store: rootOnly)
        #expect(moving.loadMaximized())
        moving.saveMaximized(false)
        #expect(!exists(rootOnly, FileChatGeometry.fileName) && exists(rootOnly, FileChatGeometry.privateFileName) && !moving.loadMaximized())
        // Both present (a downgrade wrote a new root v1): the private one wins and the root is removed.
        try store.write(Self.tomsFile, to: FileChatGeometry.fileName)
        #expect(file.loadAnchor() == cornerAnchor(on: "UUID-A") && file.load() == nil)
        #expect(!exists(store, FileChatGeometry.fileName), "the root is removed")
    }

    // MARK: Q20

    private func recallAfterClick(_ r: WebKindRig) {
        r.rig.focus.surfaceOwner = { _ in "com.apple.Safari" }
        r.rig.focus.outsidePress(ChatOutsidePress(time: 5, location: CGPoint(x: 50, y: 50), button: .left, ownerPid: 321))
        r.rig.focus.followUp(.up, CGPoint(x: 50, y: 50))
    }

    private func fileDrag(_ r: WebKindRig, at point: CGPoint, time: TimeInterval) {
        r.rig.focus.dragBoard = ChatDragPasteboardState(changeCount: 1, hasFileURLs: true)
        r.rig.focus.dragEvent(.dragged, time: time, at: point)
    }

    @Test func ChatOrcaD7b_aPanelClosedOnBAndRecalledAfterBWentIsOnAInsideTheMargins() throws {
        let r = rig(MemoryChatGeometry(anchor: cornerAnchor(on: "UUID-B")))
        r.rig.open()
        try drag(r, dx: 2582, dy: -60)
        let closedOn = frameOf(r)
        recallAfterClick(r)
        #expect(!r.controller.isOpen, "premise: the click closed it: \(r.rig.lines("CHAT"))")
        r.rig.host.screens = [screenA]
        r.rig.host.visible = screenA.visible
        fileDrag(r, at: CGPoint(x: closedOn.midX, y: closedOn.midY), time: 2)
        let frame = frameOf(r)
        #expect(r.rig.lines("CHAT recall gen=2").count == 1)
        #expect(screenA.visible.insetBy(dx: 8, dy: 8).contains(frame), "on A inside the margins: \(frame)")
        #expect(corner(frame, in: screenA.visible) == (30, 40), "\(frame)")
    }

    @Test func ChatOrcaD7b_aMaximizedPanelRecalledAfterItsDisplayWentFillsClawdsDisplay() throws {
        let r = rig(MemoryChatGeometry(anchor: cornerAnchor(on: "UUID-B")))
        r.rig.open()
        try drag(r, dx: 2582, dy: -60)
        try #require(r.panel?.terminal).maximizeButton.performClick(nil)
        let filled = ChatPanelGeometry.maximized(in: screenB.visible)
        recallAfterClick(r)
        r.rig.host.screens = [screenA]
        r.rig.host.visible = screenA.visible
        fileDrag(r, at: CGPoint(x: filled.midX, y: filled.maxY - 2), time: 2)
        #expect(r.rig.lines("CHAT recall gen=2").count == 1, "\(r.rig.lines("CHAT"))")
        #expect(frameOf(r) == ChatPanelGeometry.maximized(in: screenA.visible), "\(String(describing: r.panel?.frame))")
    }

    @Test func ChatOrcaD7b_aPanelWithNoAnchorRestoresToItsRectClampedToTheScreensAsTheyAre() throws {
        // A display too small to anchor the minimum panel (310 x 210 is under 316 x 216): the user's drag commits no anchor and clears it, so
        // Restore uses the restore rect, clamped to the screens as they are.
        let tiny = ChatScreen(id: "UUID-T", frame: CGRect(x: 5000, y: 0, width: 310, height: 210), visible: CGRect(x: 5000, y: 0, width: 310, height: 210))
        let r = rig(MemoryChatGeometry(), screens: [tiny])
        r.rig.host.rect = CGRect(x: 5010, y: 10, width: 520, height: 340)
        r.rig.open()
        try drag(r, dx: 3, dy: 3)
        #expect(r.rig.lines("CHAT gesture move-end").last?.contains("anchor=") == false, "premise: no anchor was committed: \(r.rig.lines("CHAT gesture"))")
        let container = try #require(r.panel?.terminal)
        container.maximizeButton.performClick(nil)
        // Clawd went to the remaining display with it: the host's placement is on A now, and Restore lands there.
        r.rig.host.rect = CGRect(x: 300, y: 100, width: 520, height: 340)
        setScreens(r, [screenA])
        container.maximizeButton.performClick(nil)
        let frame = frameOf(r)
        #expect(screenA.visible.contains(frame), "never at the rect of a display that is gone: \(frame)")
    }

    @Test func ChatOrcaD7b_anIndexBuiltIdIsUsedOnlyUntilTheNextDisplayChange() throws {
        let a = ChatScreen(id: "display-0", frame: screenA.frame, visible: screenA.visible)
        let b = ChatScreen(id: "display-1", frame: screenB.frame, visible: screenB.visible)
        let r = rig(MemoryChatGeometry(), screens: [a, b])
        r.rig.open()
        try drag(r, dx: 1800, dy: 0)
        try #require(r.panel?.terminal).maximizeButton.performClick(nil)
        #expect(frameOf(r) == ChatPanelGeometry.maximized(in: b.visible), "premise: maximized on B")
        setScreens(r, [a, b])
        #expect(frameOf(r) == ChatPanelGeometry.maximized(in: b.visible), "no change: the id still names B")
        // B goes and another display takes its index: the id no longer names it.
        let other = ChatScreen(id: "display-1", frame: CGRect(x: 4000, y: 0, width: 1000, height: 800), visible: CGRect(x: 4000, y: 0, width: 1000, height: 780))
        setScreens(r, [a, other])
        #expect(frameOf(r) == ChatPanelGeometry.maximized(in: a.visible), "the restore rect's screen decides, then Clawd's: \(String(describing: r.panel?.frame))")
        // The same for a panel that is not maximized: its committed anchor was taken on the index-built id, which no longer names that display.
        let dragged = rig(MemoryChatGeometry(), screens: [a, b])
        dragged.rig.open()
        try drag(dragged, dx: 1800, dy: 0)
        #expect(b.visible.contains(frameOf(dragged)), "premise: dragged onto B: \(frameOf(dragged))")
        setScreens(dragged, [a, other])
        #expect(a.visible.contains(frameOf(dragged)), "the stale id is not the other display: \(frameOf(dragged))")
    }

    @Test func ChatOrcaD7b_theBackingScaleReachesTheLayersClawdMakesItself() throws {
        let overlay = ChatDropOverlay()
        overlay.backingScaleOverride = 2
        overlay.viewDidChangeBackingProperties()
        #expect(overlay.dashContentsScale == 2)
        overlay.backingScaleOverride = 1
        overlay.viewDidChangeBackingProperties()
        #expect(overlay.dashContentsScale == 1)
        // The chips' own layers: a lost chip's dash and a thumbnail's picture.
        let r = rig(MemoryChatGeometry())
        r.rig.open()
        let body = try #require(r.body)
        body.composer.restoreChips([ChatComposerChip(unavailable: "a.png"), ChatComposerChip(path: "/nonexistent/b.png")])
        let strip = body.composer.strip
        let lost = try #require(strip.unavailableViews.first), thumb = try #require(strip.chipViews.first)
        lost.backingScaleOverride = 2; thumb.backingScaleOverride = 2
        lost.viewDidChangeBackingProperties(); thumb.viewDidChangeBackingProperties()
        #expect(lost.dashContentsScale == 2 && thumb.pictureContentsScale == 2)
    }
}
