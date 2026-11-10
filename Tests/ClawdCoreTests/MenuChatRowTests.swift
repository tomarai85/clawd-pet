import Testing
import Foundation
import AppKit
import ClawdCore
import ClawdRendering
import ClawdDesktop

// The chat entry of the right-click menu: the first row, shown only while chat is on, and what choosing it does. Choosing it opens or closes
// the chat panel by the same path as the double-click, after the menu has closed.

@Suite("MenuChatRow", .serialized)
@MainActor
struct MenuChatRowSuite {
    private static let looks = ["plain", "helmet", "sunglasses"]
    /// The chat item, or a recorded failure (a missing row must fail the test, not end the process).
    private static func chatItem(_ layout: MenuLayout) throws -> MenuItem {
        try #require(layout.items.first { $0.key == "chat" && $0.value == "toggle" }, "the layout has a chat row")
    }
    private static func layout(_ chat: MenuChatRow) -> MenuLayout { MenuLayout(looks: looks, drawnStyles: [1, 6, 10], chat: chat) }

    @Test func MenuChatRow_isTheFirstRowWithItsLabelInBothStates() throws {
        for (state, label) in [(MenuChatRow.closed, "Chat with Claude Code"), (.open, "Close chat")] {
            let layout = Self.layout(state)
            #expect(layout.rows.first?.key == "chat", "the first row")
            let item = try Self.chatItem(layout)
            #expect(item.label == label && item.kind == .action && item.clickable && item.row == 0)
            try #require(layout.rows.count > 1, "layout.rows needs 2 elements: \(layout.rows.count)")
            #expect(item.rect.minY == layout.rows[0].rect.minY && layout.rows[0].rect.minY < layout.rows[1].rect.minY)
            #expect(layout.item(at: CGPoint(x: item.rect.midX, y: item.rect.midY)) == item)
        }
    }

    @Test func MenuChatRow_withChatOffThereIsNoRowAndTheRestOfTheMenuMovesByOneRowHeightOnly() {
        let off = Self.layout(.absent), on = Self.layout(.closed)
        #expect(!off.rows.contains { $0.key == "chat" } && !off.items.contains { $0.key == "chat" })
        #expect(abs(on.size.height - off.size.height - MenuMetrics.rowMinHeight) < 1e-9)
        #expect(on.rows.dropFirst().map(\.rect) == off.rows.map { $0.rect.offsetBy(dx: 0, dy: MenuMetrics.rowMinHeight) })
        #expect(on.items.filter { $0.key != "chat" }.map(\.rect) == off.items.map { $0.rect.offsetBy(dx: 0, dy: MenuMetrics.rowMinHeight) })
    }

    @Test func MenuChatRow_aPickRunsNoCLIVerb() throws {
        let layout = Self.layout(.closed)
        #expect(MenuSelection().action(for: try Self.chatItem(layout)) == nil, "it is not a settings write")
    }

    // MARK: the controller

    @Test func MenuChatRow_aPickTogglesTheChatOnlyAfterTheMenuHasClosed() throws {
        let rig = try MenuRig()
        let item = try Self.chatItem(Self.layout(.closed))
        rig.open()
        try rig.click(item, time: 7.5)
        #expect(rig.lines("MENU pick") == ["MENU pick id=1 et=7.500000 key=chat value=toggle gen=1"])
        try #require(rig.host.surfaces.count > 0, "rig.host.surfaces needs 1 elements: \(rig.host.surfaces.count)")
        #expect(rig.host.surfaces[0].flashes == [item])
        rig.advance(0.139)
        #expect(rig.host.chatToggles.isEmpty && rig.controller.isOpen, "nothing happens while the pick flashes")
        rig.advance(0.002)
        #expect(!rig.controller.isOpen && rig.host.chatToggles == [7.5])
        let order = rig.lines.filter { $0.hasPrefix("(host) hide") || $0.hasPrefix("(host) chat") }
        #expect(order == ["(host) hide render=true", "(host) chat toggle"], "the menu is closed before the panel may take focus: \(order)")
        #expect(rig.lines("MENU write").isEmpty && rig.lines("MENU cli").isEmpty, "the settings writer is not involved")
    }

    @Test func MenuChatRow_aSecondPickInAnotherOpeningTogglesAgain() throws {
        let rig = try MenuRig()
        let item = try Self.chatItem(Self.layout(.closed))
        for n in 1...2 {
            rig.open(at: Double(n) * 10)
            try rig.click(item, time: Double(n) * 10 + 1)
            rig.advance(0.2)
        }
        #expect(rig.host.chatToggles == [11, 21])
    }

    @Test func MenuChatRow_aPendingPickIsDroppedUnlessTheMenuClosesWithPick() throws {
        let rig = try MenuRig()
        let item = try Self.chatItem(Self.layout(.closed))
        // Another reason ends the menu while the pick flashes: nothing toggles, and the drop is logged.
        rig.open(at: 10)
        try rig.click(item, time: 11)
        rig.controller.close(.hidden, render: false)
        #expect(rig.host.chatToggles.isEmpty && rig.lines("MENU chat-dropped reason=hidden gen=1").count == 1, "\(rig.lines("MENU"))")
        rig.open(at: 20)
        try rig.click(item, time: 21)
        rig.controller.close(.chat)
        #expect(rig.host.chatToggles.isEmpty && rig.lines("MENU chat-dropped reason=chat gen=2").count == 1, "\(rig.lines("MENU"))")
        // The close the pick itself ends: one toggle, after the menu window is gone, and no `chat-dropped`.
        rig.open(at: 30)
        try rig.click(item, time: 31)
        rig.controller.close(.pick)
        #expect(rig.host.chatToggles == [31] && rig.lines("MENU chat-dropped").count == 2)
    }

    // MARK: the runtime

    private func rig() throws -> (rig: ChatRuntimeRig, timer: MenuFakeTimer) {
        var timer: MenuFakeTimer!
        let stub = try MenuStubHome()
        let r = try ChatRuntimeRig(virtual: true, prepare: { machine in
            timer = MenuFakeTimer(clock: machine.clock!)
            machine.menuTimer = timer; machine.menuSource = MenuFakeSource(); machine.home = stub.root
        })
        _ = stub
        r.machine.onChatKey = { [unowned r] panel in r.post(NSWindow.didBecomeKeyNotification, panel) }
        return (r, timer)
    }

    private func rightClick(_ r: ChatRuntimeRig) throws {
        let point = try r.rig.points().body
        r.rig.machine.pointer = point
        let event = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: r.rig.window(point), modifierFlags: [], timestamp: 4.5, windowNumber: 0,
                                                    context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        r.rig.view.rightMouseDown(with: event)
    }

    private func pick(_ r: ChatRuntimeRig, timer: MenuFakeTimer) throws {
        let view = try #require(r.runtime.panels.menu?.menuView)
        let item = try Self.chatItem(view.layout)
        let point = CGPoint(x: item.rect.midX, y: view.bounds.height - item.rect.midY)
        view.mouseDown(with: try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: point, modifierFlags: [], timestamp: 5.5, windowNumber: 0,
                                                              context: nil, eventNumber: 0, clickCount: 1, pressure: 1)))
        r.rig.virtualClock?.advance(MenuMetrics.flashSeconds + 0.01)
        timer.onFire?()
    }

    @Test func MenuChatRow_inTheRealRuntimeTheMenuShowsTheRowAndPickingItOpensThePanelLikeADoubleClick() throws {
        let (r, timer) = try rig()
        try rightClick(r)
        let view = try #require(r.runtime.panels.menu?.menuView)
        let chatRow = try Self.chatItem(view.layout)
        #expect(view.layout.rows.first?.key == "chat" && chatRow.label == "Chat with Claude Code")
        try pick(r, timer: timer)
        #expect(r.runtime.panels.menu == nil && r.panel != nil && r.runtime.chatPanelIsOpen, "\(r.lines("MENU")) \(r.lines("CHAT"))")
        #expect(r.lines("CHAT open").count == 1 && r.lines("CHAT key gen=1").count == 1 && r.lines("CHAT key-uncaused").isEmpty)
        let log = r.rig.log.split(separator: "\n").map(String.init)
        let close = try #require(log.firstIndex { $0.contains("MENU close reason=pick") }), open = try #require(log.firstIndex { $0.contains("CHAT open") })
        #expect(close < open, "the menu closes first")
        #expect(r.rig.monitor.status.focusViolations == 0)
        let panel = try #require(r.panel)
        #expect(panel.firstResponder === panel.chatView.inputView, "the input has the keyboard once the menu has closed")
        // The same path closes it: the toggle a double-click makes.
        r.runtime.menuToggleChat(eventTime: 9)
        #expect(r.panel == nil && r.lines("CHAT close").first?.hasPrefix("CHAT close reason=toggle") == true, "\(r.lines("CHAT close"))")
    }

    @Test func MenuChatRow_inTheRealRuntimeChatOffMeansNoRow() throws {
        let off = try ChatRuntimeRig(control: ["chat": false])
        try rightClick(off)
        let view = try #require(off.runtime.panels.menu?.menuView)
        #expect(!view.layout.rows.contains { $0.key == "chat" })
        let none = try ChatRuntimeRig(withChat: false)
        try rightClick(none)
        #expect(!(try #require(none.runtime.panels.menu?.menuView)).layout.rows.contains { $0.key == "chat" }, "no chat bridge, no row")
    }
}
