import Testing
import Foundation
import AppKit
import ClawdCore
import ClawdDesktop

// The chat panel opens beside Clawd and goes smaller (design-clawd-chat-near-pet r2): every open that is not a recall lands where
// ChatPanelPlacement.rect puts it for Clawd's canvas and display, at the saved size; the saved position, corner and display are never used for an
// open. Two fake displays (A is Clawd's, B is where the saved file points), literal sizes, a temporary in-memory geometry store: no window is shown
// or made key, nothing reads or writes the real chat-panel.json, and no application is activated.

private let screenA = ChatScreen(id: "UUID-A", frame: CGRect(x: 0, y: 0, width: 1440, height: 900), visible: CGRect(x: 0, y: 25, width: 1440, height: 875))
private let screenB = ChatScreen(id: "UUID-B", frame: CGRect(x: 1440, y: 0, width: 1000, height: 800), visible: CGRect(x: 1440, y: 0, width: 1000, height: 780))
private let canvasOne = CGRect(x: 600, y: 100, width: 60, height: 48)
private let canvasTwo = CGRect(x: 200, y: 300, width: 60, height: 48)

/// Clawd's canvas, which a test moves.
private final class PetBox { var canvas = canvasOne }

/// A corner anchor on B (30 from the right, 40 from the bottom) at `size`.
private func anchorOnB(_ width: CGFloat, _ height: CGFloat) -> ChatAnchor {
    ChatAnchor(display: "UUID-B", anchorX: .right, anchorY: .bottom, offsetX: 30, offsetY: 40, width: width, height: height)
}

/// What the host answers for a size: the real rule, for Clawd's canvas and display A (nil size: the default).
private func placement(_ canvas: CGRect, _ size: CGSize?, visible: CGRect = screenA.visible) -> CGRect {
    ChatPanelPlacement.rect(canvas: canvas, bubbleSide: .above, visible: visible,
                            width: size?.width ?? ChatPanelPlacement.terminalWidth, maxHeight: size?.height ?? ChatPanelPlacement.terminalMaxHeight)
}

@Suite("ChatNearPet", .serialized)
@MainActor
struct ChatNearPetSuite {
    private func wire(_ host: FakeChatHost, _ pet: PetBox, screens: [ChatScreen] = [screenA, screenB]) {
        host.visible = screenA.visible
        host.screens = screens
        host.terminalPlacement = { [pet] size in placement(pet.canvas, size) }
    }

    private func webRig(_ geometry: ChatGeometryStoring?, _ pet: PetBox, screens: [ChatScreen] = [screenA, screenB]) -> WebKindRig {
        let r = WebKindRig(geometry: geometry)
        wire(r.rig.host, pet, screens: screens)
        return r
    }

    private func frameOf(_ r: WebKindRig) -> CGRect { r.panel?.frame ?? .null }

    private func drag(_ r: WebKindRig, dx: CGFloat, dy: CGFloat) throws {
        let bar = try #require(r.panel?.terminal).titleBarView
        bar.beginDrag(at: CGPoint(x: 400, y: 300))
        bar.drag(to: CGPoint(x: 400 + dx, y: 300 + dy))
        bar.endDrag()
    }

    private func clickClose(_ r: WebKindRig) {
        r.rig.focus.surfaceOwner = { _ in "com.apple.Safari" }
        r.rig.focus.outsidePress(ChatOutsidePress(time: 5, location: CGPoint(x: 50, y: 50), button: .left, ownerPid: 321))
        r.rig.focus.followUp(.up, CGPoint(x: 50, y: 50))
    }

    private func fileDrag(_ r: WebKindRig, at point: CGPoint, time: TimeInterval) {
        r.rig.focus.dragBoard = ChatDragPasteboardState(changeCount: 1, hasFileURLs: true)
        r.rig.focus.dragEvent(.dragged, time: time, at: point)
    }

    // MARK: T1

    @Test func ChatNearPet_anOpenAfterAnAnchorSavedOnBLandsBesideClawdOnAAtTheSavedSize() throws {
        let pet = PetBox()
        let expected = placement(pet.canvas, CGSize(width: 500, height: 320))
        #expect(expected.size == CGSize(width: 500, height: 320) && screenA.visible.contains(expected))
        // The web kind, a version 2 file on B.
        let web = webRig(MemoryChatGeometry(anchor: anchorOnB(500, 320)), pet)
        web.rig.open()
        #expect(frameOf(web) == expected, "\(frameOf(web))")
        // A version 1 file on B: its size is used, and its migration still happens.
        let geometry = MemoryChatGeometry(CGRect(x: 1600, y: 100, width: 500, height: 320))
        let old = webRig(geometry, pet)
        old.rig.open()
        #expect(frameOf(old) == expected && geometry.migrations == 1, "\(frameOf(old)) migrations=\(geometry.migrations)")
        // The terminal kind, both file versions.
        let r = try TermControllerRig(geometry: MemoryChatGeometry(anchor: anchorOnB(500, 320)))
        wire(r.host, pet)
        r.open()
        #expect(r.controller.livePanel?.frame == expected, "\(String(describing: r.controller.livePanel?.frame))")
        r.controller.close(.toggle)
        let termGeometry = MemoryChatGeometry(CGRect(x: 1600, y: 100, width: 500, height: 320))
        let termOld = try TermControllerRig(geometry: termGeometry)
        wire(termOld.host, pet)
        termOld.open()
        #expect(termOld.controller.livePanel?.frame == expected && termGeometry.migrations == 1, "\(String(describing: termOld.controller.livePanel?.frame))")
        termOld.controller.close(.toggle)
    }

    // MARK: T2

    @Test func ChatNearPet_aSavedSizeWiderThanItsShrunkDisplayOpensFullSizeOnClawdsLargerDisplay() throws {
        let narrow = ChatScreen(id: "UUID-B", frame: CGRect(x: 1440, y: 0, width: 700, height: 800), visible: CGRect(x: 1440, y: 0, width: 700, height: 780))
        let pet = PetBox()
        let r = webRig(MemoryChatGeometry(anchor: anchorOnB(900, 500)), pet, screens: [screenA, narrow])
        r.rig.open()
        #expect(frameOf(r).size == CGSize(width: 900, height: 500), "\(frameOf(r))")
        #expect(frameOf(r) == placement(pet.canvas, CGSize(width: 900, height: 500)))
    }

    // MARK: T3

    @Test func ChatNearPet_aWalkEndReplacesANonCustomPanelBesideClawdAtItsPlacedSize() throws {
        let pet = PetBox()
        let r = webRig(MemoryChatGeometry(anchor: anchorOnB(500, 320)), pet)
        r.rig.open()
        let first = frameOf(r)
        pet.canvas = canvasTwo
        r.controller.replace()
        let moved = placement(canvasTwo, CGSize(width: 500, height: 320))
        #expect(moved != first, "premise: the canvases give different places")
        #expect(frameOf(r) == moved && frameOf(r).size == CGSize(width: 500, height: 320), "\(frameOf(r))")
    }

    @Test func ChatNearPet_theTerminalKindKeepsItsPlacedSizeOnAWalkEnd() throws {
        let pet = PetBox()
        let r = try TermControllerRig(geometry: MemoryChatGeometry(anchor: anchorOnB(400, 260)))
        wire(r.host, pet)
        r.open()
        #expect(r.controller.livePanel?.frame == placement(pet.canvas, CGSize(width: 400, height: 260)), "\(String(describing: r.controller.livePanel?.frame))")
        pet.canvas = canvasTwo
        r.controller.replace()
        #expect(r.controller.livePanel?.frame == placement(canvasTwo, CGSize(width: 400, height: 260)), "\(String(describing: r.controller.livePanel?.frame))")
        r.controller.close(.toggle)
    }

    // MARK: the real host

    @Test func ChatNearPet_theRuntimePlacesTheTerminalPanelAtTheAskedSizeAndAtTheDefaultForNil() throws {
        let r = try ChatRuntimeRig()
        try r.doubleClick()
        let stage = r.rig.stage
        let frame = try #require(stage.lastFrame)
        let visible = stage.scheduler.geometry.visibleFrame
        #expect(visible.width >= 336 && visible.height >= 256, "premise: the rig's display holds 320 x 210 and 360 x 240 with margins: \(visible)")
        let asked = try #require(r.runtime.chatTerminalPlacement(size: CGSize(width: 320, height: 210)))
        #expect(asked.size == CGSize(width: 320, height: 210), "\(asked)")
        #expect(asked == ChatPanelPlacement.rect(canvas: frame.canvas, bubbleSide: stage.settings.bubbleSide, visible: visible, width: 320, maxHeight: 210))
        let standard = try #require(r.runtime.chatTerminalPlacement(size: nil))
        #expect(standard.size == CGSize(width: 360, height: 240), "\(standard)")
    }

    // MARK: T4

    @Test func ChatNearPet_aResizeReaches300By200AndNotBelowAndTheNextOpenUsesIt() throws {
        #expect(ChatPanelGeometry.defaultSize == CGSize(width: 360, height: 240))
        #expect(ChatPanelGeometry.minSize == CGSize(width: 300, height: 200))
        let pet = PetBox()
        let geometry = MemoryChatGeometry()
        let r = webRig(geometry, pet)
        r.rig.open()
        #expect(frameOf(r).size == CGSize(width: 360, height: 240), "\(frameOf(r))")
        let handle = try #require(r.panel?.terminal).handle(.sw)
        handle.beginDrag(at: CGPoint(x: 400, y: 300))
        handle.drag(to: CGPoint(x: 3000, y: 2000))
        handle.endDrag()
        #expect(frameOf(r).size == CGSize(width: 300, height: 200), "\(frameOf(r))")
        #expect(geometry.anchor?.width == 300 && geometry.anchor?.height == 200, "\(String(describing: geometry.anchor))")
        r.controller.close(.toggle)
        r.rig.clock.advance(5)
        r.rig.open(at: 10)
        #expect(frameOf(r) == placement(pet.canvas, CGSize(width: 300, height: 200)), "\(frameOf(r))")
    }

    // MARK: T5

    @Test func ChatNearPet_aPersistedMaximizeFillsClawdsDisplayAndRestoreLandsWhereClawdIsNow() throws {
        let pet = PetBox()
        let r = webRig(MemoryChatGeometry(maximized: true, anchor: anchorOnB(500, 320)), pet)
        r.rig.open()
        #expect(frameOf(r) == ChatPanelGeometry.maximized(in: screenA.visible), "\(frameOf(r))")
        pet.canvas = canvasTwo
        try #require(r.panel?.terminal).maximizeButton.performClick(nil)
        #expect(frameOf(r) == placement(canvasTwo, CGSize(width: 500, height: 320)), "\(frameOf(r))")
        // And it follows Clawd after the Restore.
        pet.canvas = canvasOne
        r.controller.replace()
        #expect(frameOf(r) == placement(canvasOne, CGSize(width: 500, height: 320)), "\(frameOf(r))")
    }

    // MARK: T6

    @Test func ChatNearPet_theMaximizeControlOnANonCustomPanelRestoresWhereClawdIsNow() throws {
        let pet = PetBox()
        let r = webRig(MemoryChatGeometry(), pet)
        r.rig.open()
        let button = try #require(r.panel?.terminal).maximizeButton
        button.performClick(nil)
        #expect(frameOf(r) == ChatPanelGeometry.maximized(in: screenA.visible))
        pet.canvas = canvasTwo
        button.performClick(nil)
        #expect(frameOf(r) == placement(canvasTwo, nil) && frameOf(r).size == CGSize(width: 360, height: 240), "\(frameOf(r))")
        // A dragged (custom) panel goes back to its committed anchor, as before.
        let custom = webRig(MemoryChatGeometry(), PetBox())
        custom.rig.open()
        try drag(custom, dx: 300, dy: 200)
        let dragged = frameOf(custom)
        let control = try #require(custom.panel?.terminal).maximizeButton
        control.performClick(nil)
        control.performClick(nil)
        #expect(frameOf(custom) == dragged, "\(frameOf(custom)) vs \(dragged)")
    }

    // MARK: T7

    @Test func ChatNearPet_aRecalledNonCustomPanelKeepsItsPlacedSize() throws {
        let pet = PetBox()
        let r = webRig(MemoryChatGeometry(anchor: anchorOnB(500, 320)), pet)
        r.rig.open()
        let closedOn = frameOf(r)
        clickClose(r)
        #expect(!r.controller.isOpen, "premise: the click closed it: \(r.rig.lines("CHAT"))")
        fileDrag(r, at: CGPoint(x: closedOn.midX, y: closedOn.midY), time: 2)
        #expect(r.rig.lines("CHAT recall gen=2").count == 1, "\(r.rig.lines("CHAT"))")
        pet.canvas = canvasTwo
        r.controller.replace()
        #expect(frameOf(r) == placement(canvasTwo, CGSize(width: 500, height: 320)), "\(frameOf(r))")
        // A recall while maximized, then Restore.
        let pet2 = PetBox()
        let m = webRig(MemoryChatGeometry(anchor: anchorOnB(500, 320)), pet2)
        m.rig.open()
        let button = try #require(m.panel?.terminal).maximizeButton
        button.performClick(nil)
        let filled = frameOf(m)
        clickClose(m)
        fileDrag(m, at: CGPoint(x: filled.midX, y: filled.maxY - 2), time: 2)
        #expect(m.rig.lines("CHAT recall gen=2").count == 1, "\(m.rig.lines("CHAT"))")
        pet2.canvas = canvasTwo
        try #require(m.panel?.terminal).maximizeButton.performClick(nil)
        #expect(frameOf(m) == placement(canvasTwo, CGSize(width: 500, height: 320)), "\(frameOf(m))")
    }

    // MARK: T8

    @Test func ChatNearPet_aMoveInsideOneOpeningStaysUntilCloseAndTheNextOpenIsBesideClawd() throws {
        let pet = PetBox()
        let r = webRig(MemoryChatGeometry(anchor: anchorOnB(500, 320)), pet)
        r.rig.open()
        try drag(r, dx: 300, dy: 150)
        let dragged = frameOf(r)
        #expect(dragged != placement(pet.canvas, CGSize(width: 500, height: 320)), "premise: the drag moved it")
        pet.canvas = canvasTwo
        r.controller.replace()
        #expect(frameOf(r) == dragged, "a re-measure leaves a dragged panel alone: \(frameOf(r))")
        r.controller.close(.toggle)
        r.rig.clock.advance(5)
        r.rig.open(at: 10)
        #expect(frameOf(r) == placement(canvasTwo, CGSize(width: 500, height: 320)), "\(frameOf(r))")
    }
}
