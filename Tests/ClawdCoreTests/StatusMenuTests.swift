import Testing
import Foundation
import AppKit
import ClawdCore
import ClawdRendering
import ClawdDesktop

// The menu bar icon (Stage SA, Sprint SA1): one status item made through the runtime's `statusBar` seam, its rows, its picks and its removal for
// an exam stand-down. The seam is inert by default and no test names the system's status bar: every item here is a fake that records calls.

/// A status item that only records what the controller does to it.
final class FakeStatusSurface: StatusItemSurface {
    var autosaveName: String?
    var menu: NSMenu?
    /// The window of the item's button: a test supplies one (a plain window, never shown).
    var buttonWindow: NSWindow?
    private(set) var images: [(image: NSImage, label: String)] = []
    private(set) var opacities: [Double] = []
    private(set) var calls: [String] = []
    private(set) var menuOpen = false
    /// Whether the menu was still open at the moment the item was removed.
    private(set) var openAtRemoval: Bool?
    var removed: Bool { calls.contains("remove") }

    func setImage(_ image: NSImage, label: String) { images.append((image, label)) }
    func setOpacity(_ alpha: Double) { opacities.append(alpha) }
    func cancelMenuTracking() { calls.append("cancel"); menuOpen = false }
    /// What AppKit does when the menu closes: its delegate is told.
    func close() {
        guard let menu else { return }
        menu.delegate?.menuDidClose?(menu)
        menuOpen = false
    }
    func remove() { calls.append("remove"); openAtRemoval = menuOpen }

    /// What AppKit does when the user opens the item's menu: the delegate builds the rows, then the menu is open.
    func open() {
        guard let menu else { return }
        menu.delegate?.menuNeedsUpdate?(menu)
        menu.delegate?.menuWillOpen?(menu)
        menuOpen = true
    }
    var items: [NSMenuItem] { menu?.items ?? [] }
    var titles: [String] { items.map { $0.isSeparatorItem ? "-" : $0.title } }
    func item(_ title: String) throws -> NSMenuItem { try #require(items.first { $0.title == title }, "no row titled \(title): \(titles)") }
    /// A pick as AppKit makes it: the item's own action on its own target.
    func pick(_ title: String) throws {
        let row = try item(title)
        #expect(row.isEnabled, "\(title) is enabled")
        let action = try #require(row.action)
        _ = row.target?.perform(action, with: row)
    }
}

/// The real runtime with a fake bridge, a fake status bar and an exit that only records.
@MainActor
final class StatusRig {
    final class Box {
        var surfaces: [FakeStatusSurface] = []
        var exits: [(code: Int32, stops: [ChatStopReason])] = []
    }
    let box = Box()
    let rig: RuntimeRig
    let session = FakeChatSession()
    let focus = FakeChatFocus()
    let stub: MenuStubHome
    var machine: RuntimeMachine { rig.machine }
    var runtime: AgentRuntime { rig.runtime }
    var surfaces: [FakeStatusSurface] { box.surfaces }
    var surface: FakeStatusSurface { box.surfaces[0] }

    init(control: [String: Any]? = nil, examAtBoot: Bool = false, seam: Bool = true, chat: Bool = true) throws {
        let box = self.box, session = self.session, focus = self.focus
        let stub = try MenuStubHome()
        self.stub = stub
        rig = try RuntimeRig(control: control, virtual: true, prepare: { machine in
            machine.examRunning = examAtBoot
            if chat { machine.chatSession = { _ in session } }
            machine.chatFocus = focus.seams
            machine.home = stub.root
            if seam { machine.statusBar = { let made = FakeStatusSurface(); box.surfaces.append(made); return made } }
            machine.exitProcess = { box.exits.append(($0, session.stops)) }
        })
        focus.now = { [unowned rig] in rig.virtualClock?.now ?? 0 }
    }
    func lines(_ prefix: String) -> [String] { rig.lines(prefix) }

    /// Hides Clawd the way `clawd-pet hide` leaves the settings, or shows it again.
    func setHidden(_ hidden: Bool) {
        var settings = rig.stage.settings
        settings.hiddenUntil = hidden ? -1 : 0
        rig.stage.apply(settings: settings)
    }
    /// A batch that changes nothing.
    func batch() { rig.stage.apply(settings: rig.stage.settings) }
    func examLaunch() {
        machine.examRunning = true
        runtime.workspaceApplication(launched: true, bundleIdentifier: "com.Respondus.LockDownBrowser", name: "LockDown Browser", pid: 77)
    }
    func examQuit() {
        machine.examRunning = false
        runtime.workspaceApplication(launched: false, bundleIdentifier: "com.Respondus.LockDownBrowser", name: "LockDown Browser", pid: 77)
        rig.advance(200)
    }
    /// The arguments of every run of the stub CLI, as `[hide] [60]`.
    var cliRuns: [String] {
        stub.calls.filter { $0.hasPrefix("START") }.map { line in line.components(separatedBy: " ARGS").dropFirst().joined() .trimmingCharacters(in: .whitespaces) }
    }
}

@Suite("StatusMenu", .serialized)
@MainActor
struct StatusMenuSuite {
    // MARK: the rows

    @Test func StatusMenu_rowsForEachState() throws {
        func shape(_ state: StatusMenuState) -> [String] {
            StatusMenu.entries(for: state).map { "\($0.kind?.rawValue ?? "-"):\($0.title):\($0.enabled ? "on" : "off")" }
        }
        #expect(shape(StatusMenuState()) == ["settings:Settings\u{2026}:on", "openChat:Open Chat:on", "hide:Hide Clawd for 1 Hour:on", "-::off", "quit:Quit Clawd:on"], "shown")
        #expect(shape(StatusMenuState(hiddenByUser: true)) == ["settings:Settings\u{2026}:on", "openChat:Open Chat:off", "show:Show Clawd:on", "-::off", "quit:Quit Clawd:on"], "hidden by the user")
        #expect(shape(StatusMenuState(quiet: true)) == ["settings:Settings\u{2026}:on", "openChat:Open Chat:off", "hide:Hide Clawd for 1 Hour:on", "-::off", "quit:Quit Clawd:on"], "quiet")
        #expect(shape(StatusMenuState(chatAvailable: false)) == ["settings:Settings\u{2026}:on", "openChat:Open Chat:off", "hide:Hide Clawd for 1 Hour:on", "-::off", "quit:Quit Clawd:on"], "chat off")
        #expect(shape(StatusMenuState(chatOpen: true)) == ["settings:Settings\u{2026}:on", "closeChat:Close Chat:on", "hide:Hide Clawd for 1 Hour:on", "-::off", "quit:Quit Clawd:on"], "chat open")

        // The same rows in the menu the runtime builds at each opening.
        let r = try StatusRig()
        #expect(r.surfaces.count == 1)
        r.surface.open()
        #expect(r.surface.titles == ["Settings\u{2026}", "Open Chat", "Hide Clawd for 1 Hour", "-", "Quit Clawd"], "\(r.surface.titles)")
        #expect(try r.surface.item("Open Chat").isEnabled)
        r.setHidden(true)
        r.surface.open()
        #expect(r.surface.titles == ["Settings\u{2026}", "Open Chat", "Show Clawd", "-", "Quit Clawd"], "\(r.surface.titles)")
        #expect(try !r.surface.item("Open Chat").isEnabled && r.surface.item("Show Clawd").isEnabled)
        r.setHidden(false)
        r.machine.sink?.setQuiet(.displayAsleep, active: true)
        r.surface.open()
        #expect(try !r.surface.item("Open Chat").isEnabled && r.surface.item("Hide Clawd for 1 Hour").isEnabled, "quiet: \(r.surface.titles)")
        r.machine.sink?.setQuiet(.displayAsleep, active: false)
        r.surface.open()
        #expect(try r.surface.item("Open Chat").isEnabled)
        r.runtime.chatController.toggle(eventTime: 1)
        #expect(r.runtime.chatPanelIsOpen)
        r.surface.open()
        #expect(try r.surface.item("Close Chat").isEnabled, "chat open: \(r.surface.titles)")

        let off = try StatusRig(control: ["chat": false])
        off.surface.open()
        #expect(try !off.surface.item("Open Chat").isEnabled, "control.json chat false")
        let none = try StatusRig(chat: false)
        none.surface.open()
        #expect(try !none.surface.item("Open Chat").isEnabled, "no chat in the environment")
        let standDown = try StatusRig(examAtBoot: true)
        #expect(standDown.surfaces.isEmpty, "a stand-down has no item")
    }

    @Test func StatusMenu_aStandDownRemovesTheItemAndItsEndBringsItBack() throws {
        let r = try StatusRig()
        #expect(r.surfaces.count == 1 && !r.surface.removed)
        r.examLaunch()
        #expect(r.surface.removed, "the item is taken away for the stand-down")
        #expect(r.lines("STATUS item removed reason=exam").count == 1, "\(r.lines("STATUS"))")
        r.rig.advance(30)
        #expect(r.surfaces.count == 1, "no batch of the stand-down makes a new item")
        r.examQuit()
        #expect(r.surfaces.count == 2 && !r.surfaces[1].removed, "the end of the stand-down brings the item back: \(r.surfaces.count)")
        #expect(r.lines("STATUS item created").count == 2)
        r.rig.advance(30)
        #expect(r.surfaces.count == 2)
        // D10, second run (SA6): the same stand-down with `aquaReact` off; the workspace observer stays, so an exam still removes the item.
        let off = try StatusRig(control: ["aquaReact": false, "generation": 0])
        #expect(off.surfaces.count == 1 && !off.surface.removed && !off.runtime.aquaLogIsRead)
        off.examLaunch()
        #expect(off.surface.removed && off.lines("STATUS item removed reason=exam").count == 1, "react off: \(off.lines("STATUS"))")
        off.rig.advance(30)
        #expect(off.surfaces.count == 1, "react off: no batch of the stand-down makes a new item")
        off.examQuit()
        #expect(off.surfaces.count == 2 && !off.surfaces[1].removed, "react off: the end of the stand-down brings the item back: \(off.surfaces.count)")
    }

    @Test func StatusMenu_aStandDownCancelsAnOpenMenuBeforeRemoving() throws {
        let r = try StatusRig()
        r.surface.open()
        #expect(r.surface.menuOpen)
        r.examLaunch()
        #expect(r.surface.calls == ["cancel", "remove"], "\(r.surface.calls)")
        #expect(r.surface.openAtRemoval == false, "the menu was down when the item went")
        // D10, second run (SA6): with `aquaReact` off.
        let off = try StatusRig(control: ["aquaReact": false, "generation": 0])
        off.surface.open()
        #expect(off.surface.menuOpen)
        off.examLaunch()
        #expect(off.surface.calls == ["cancel", "remove"] && off.surface.openAtRemoval == false, "react off: \(off.surface.calls)")
    }

    @Test func StatusMenu_aStandDownAtBootBuildsNoItem() throws {
        let r = try StatusRig(examAtBoot: true)
        #expect(r.surfaces.isEmpty && r.lines("STATUS item created").isEmpty, "\(r.lines("STATUS"))")
        r.rig.advance(60)
        #expect(r.surfaces.isEmpty, "no batch of the stand-down makes one")
        // D10, second run (SA6): with `aquaReact` off.
        let off = try StatusRig(control: ["aquaReact": false, "generation": 0], examAtBoot: true)
        #expect(off.surfaces.isEmpty && off.lines("STATUS item created").isEmpty, "react off: \(off.lines("STATUS"))")
        off.rig.advance(60)
        #expect(off.surfaces.isEmpty, "react off: no batch of the stand-down makes one")
    }

    // MARK: the item

    @Test func StatusMenu_autosaveNameIsFixedAtCreationAndRecreation() throws {
        #expect(StatusMenu.autosaveName == "ClawdStatusItem")
        let r = try StatusRig()
        #expect(r.surface.autosaveName == "ClawdStatusItem")
        r.examLaunch()
        r.examQuit()
        #expect(r.surfaces.count == 2)
        try #require(r.surfaces.count > 1, "r.surfaces needs 2 elements: \(r.surfaces.count)")
        #expect(r.surfaces[1].autosaveName == "ClawdStatusItem", "a re-created item has the same name")
    }

    @Test func StatusMenu_noTimerNoObserverAndRowsBuiltOnlyWhenTheMenuOpens() throws {
        let r = try StatusRig()
        #expect(r.surface.items.isEmpty, "the menu is empty at creation")
        #expect(r.surface.menu?.autoenablesItems == false)
        let armed = r.rig.stage.wake.armedTimers
        for _ in 0..<5 { r.batch() }
        r.setHidden(true)
        #expect(r.surface.items.isEmpty, "no batch builds rows")
        r.surface.open()
        #expect(r.surface.titles.contains("Show Clawd"), "the rows are built at the opening and show the state of that moment")
        r.setHidden(false)
        #expect(r.surface.titles.contains("Show Clawd"), "an open menu's rows are not rebuilt by a batch")
        r.surface.open()
        #expect(r.surface.titles.contains("Hide Clawd for 1 Hour") && !r.surface.titles.contains("Show Clawd"), "and the next opening builds them again")
        #expect(r.rig.stage.wake.armedTimers <= max(armed, 1), "the icon arms no timer of its own")
        // The file holds no timer, observer or event monitor to find: the only things that could wake it while the menu is closed.
        let source = String(decoding: try ReadOnlyFile.data(repository.appendingPathComponent("Sources/ClawdDesktop/StatusMenu.swift").path), as: UTF8.self)
        for banned in ["Timer", "addObserver", "NotificationCenter", "DispatchSource", "asyncAfter", "NSEvent.add", "NSTrackingArea"] {
            #expect(!source.contains(banned), "StatusMenu.swift names \(banned)")
        }
    }

    @Test func StatusMenu_opacityIsSetOnlyWhenTheHiddenStateChanges() throws {
        let r = try StatusRig()
        #expect(r.surface.opacities == [1], "drawn once at creation: \(r.surface.opacities)")
        for _ in 0..<4 { r.batch() }
        r.rig.advance(20)
        #expect(r.surface.opacities == [1], "batches that change nothing set nothing: \(r.surface.opacities)")
        r.setHidden(true)
        #expect(r.surface.opacities == [1, 0.5])
        for _ in 0..<4 { r.batch() }
        #expect(r.surface.opacities == [1, 0.5], "\(r.surface.opacities)")
        r.setHidden(false)
        #expect(r.surface.opacities == [1, 0.5, 1])
    }

    @Test func StatusMenu_aRigWithoutTheSeamBuildsNoItemAndThePetBuildsOne() throws {
        let bare = try RuntimeRig()
        #expect(bare.machine.statusBar == nil)
        bare.stage.apply(settings: bare.stage.settings)
        #expect(bare.lines("STATUS item created").isEmpty, "a default rig has no status bar and makes no item")

        let r = try StatusRig()
        #expect(r.surfaces.count == 1, "exactly one item after boot")
        for _ in 0..<4 { r.batch() }
        r.setHidden(true); r.setHidden(false)
        r.rig.advance(30)
        #expect(r.surfaces.count == 1, "and still one after several batches: \(r.surfaces.count)")
    }

    @Test func StatusMenu_theImageIsATemplateOfTheIdleFrameNamedClawd() throws {
        let r = try StatusRig()
        let drawn = try #require(r.surface.images.first)
        #expect(r.surface.images.count == 1 && drawn.label == "Clawd")
        #expect(drawn.image.isTemplate, "a template image: the menu bar tints it")
        #expect(drawn.image.accessibilityDescription == "Clawd")
        let idle = try MenuThumbnails.thumbnail(look: PetCatalog.plainLook, art: r.rig.stage.renderer.art)
        let template = StatusMenu.templateRaster(from: idle)
        #expect(drawn.image.size == NSSize(width: 26, height: 26) && template.width == 26 && template.height == 26, "24 x 16 cells of Clawd + 2: \(drawn.image.size)")
        var opaque = 0
        for y in 0..<template.height { for x in 0..<template.width where template[x, y].a != 0 { opaque += 1 } }
        #expect(opaque > 20, "the template has Clawd in it")
        let cg = try #require(drawn.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let bitmap = NSBitmapImageRep(cgImage: cg)
        #expect(bitmap.pixelsWide == template.width * 2 && bitmap.pixelsHigh == template.height * 2)
        for y in 0..<bitmap.pixelsHigh { for x in 0..<bitmap.pixelsWide {
            let alpha = bitmap.colorAt(x: x, y: y)?.alphaComponent ?? -1
            #expect((alpha > 0.5) == (template[x / 2, y / 2].a != 0), "the image is the template at \(x),\(y)")
        } }
    }

    @Test func StatusMenu_theIconIsClawdCroppedAndCenteredWithHollowEyes() throws {
        let r = try StatusRig()
        let drawn = try #require(r.surface.images.first)
        let idle = try MenuThumbnails.thumbnail(look: PetCatalog.plainLook, art: r.rig.stage.renderer.art)
        var minX = idle.width, minY = idle.height, maxX = -1, maxY = -1
        for y in 0..<idle.height { for x in 0..<idle.width where idle[x, y].a != 0 {
            minX = min(minX, x); maxX = max(maxX, x); minY = min(minY, y); maxY = max(maxY, y)
        } }
        let w = maxX - minX + 1, h = maxY - minY + 1, side = max(w, h) + 2
        #expect(drawn.image.size == NSSize(width: side, height: side), "side = the longer side of Clawd's bounds + 2 cells: \(drawn.image.size)")
        let cg = try #require(drawn.image.cgImage(forProposedRect: nil, context: nil, hints: nil))
        let bitmap = NSBitmapImageRep(cgImage: cg)
        #expect(bitmap.pixelsWide == side * 2 && bitmap.pixelsHigh == side * 2)

        // Margins, in cells, from the drawn image's own pixels.
        var left = side, right = side, top = side, bottom = side
        for y in 0..<side { for x in 0..<side where (bitmap.colorAt(x: x * 2, y: y * 2)?.alphaComponent ?? 0) > 0.5 {
            left = min(left, x); right = min(right, side - 1 - x); top = min(top, y); bottom = min(bottom, side - 1 - y)
        } }
        #expect(abs(left - right) <= 1 && abs(top - bottom) <= 1, "centered within one cell: l\(left) r\(right) t\(top) b\(bottom)")
        #expect(left >= 1 && top >= 1, "a cell of air on every side: l\(left) t\(top)")

        var eyes = 0
        for y in 0..<h { for x in 0..<w {
            let p = idle[minX + x, minY + y]
            guard p.a != 0 else { continue }
            let luma = (299 * Int(p.r) + 587 * Int(p.g) + 114 * Int(p.b)) / 1000
            let isEye = luma < StatusMenu.eyeLumaBelow
            if isEye { eyes += 1 }
            // The odd leftover cell goes right or bottom: the origin is the floor.
            let ix = (side - w) / 2 + x, iy = (side - h) / 2 + y
            for (dx, dy) in [(0, 0), (1, 0), (0, 1), (1, 1)] {
                let c = try #require(bitmap.colorAt(x: ix * 2 + dx, y: iy * 2 + dy))
                if isEye {
                    #expect(c.alphaComponent == 0, "an eye pixel is hollow at \(ix),\(iy)")
                } else {
                    #expect(abs(c.alphaComponent - Double(p.a) / 255) < 0.01 && c.redComponent == 0 && c.greenComponent == 0 && c.blueComponent == 0,
                            "every other pixel of Clawd is black with its own alpha at \(ix),\(iy)")
                }
            }
        } }
        // The colour record of the idle frame (2026-11-03): two 2x2 eyes at 20,20,19 and 248 body pixels at 215,119,87.
        #expect(eyes == 8, "only the eyes are hollow: \(eyes) eye pixels")
    }

    // MARK: the picks

    @Test func StatusMenu_openChatIsTheRightClickChatEntryWithThePicksEventTime() throws {
        let r = try StatusRig()
        r.machine.chatEvent = ChatCurrentEvent(isMouseDown: false, window: nil, isMouse: true, timestamp: 42.5)
        #expect(r.lines("CHAT").isEmpty)
        r.surface.open()
        try r.surface.pick("Open Chat")
        #expect(r.runtime.chatPanelIsOpen, "\(r.lines("CHAT"))")
        #expect(r.lines("CHAT open").first == "CHAT open et=42.500000 gen=1", "the pick's own event time: \(r.lines("CHAT"))")
        r.machine.chatEvent = ChatCurrentEvent(isMouseDown: false, window: nil, isMouse: true, timestamp: 50)
        r.surface.open()
        #expect(r.surface.titles.dropFirst().first == "Close Chat", "Q2: while the chat is open the row closes it")
        try r.surface.pick("Close Chat")
        #expect(!r.runtime.chatPanelIsOpen && r.lines("CHAT close").first?.hasPrefix("CHAT close reason=toggle gen=1") == true, "\(r.lines("CHAT"))")
    }

    @Test func StatusMenu_hideRowRunsHideSixtyLabelledForOneHour() async throws {
        let r = try StatusRig()
        r.surface.open()
        #expect(r.surface.titles.contains("Hide Clawd for 1 Hour"), "\(r.surface.titles)")
        #expect(StatusMenu.hideMinutes == 60 && StatusMenu.hideAction.arguments == ["hide", "60"])
        try r.surface.pick("Hide Clawd for 1 Hour")
        await r.rig.spin(until: { r.cliRuns.count >= 1 })
        #expect(r.cliRuns == ["[hide] [60]"], "the stub CLI saw `hide 60`: \(r.stub.calls)")
        await r.rig.spin(until: { !r.lines("MENU write").isEmpty })
        #expect(r.lines("MENU write").first?.contains("key=hide verb=hide+60 exit=0 gen=0") == true, "\(r.lines("MENU"))")
    }

    @Test func StatusMenu_hideAndShowRunTheCLIAndActivateNothing() async throws {
        let r = try StatusRig()
        // Show alone runs `show`.
        r.setHidden(true)
        r.surface.open()
        try r.surface.pick("Show Clawd")
        // The waits end on the CLI run's completion (its `MENU write` line), however long a loaded machine takes to start it.
        await r.rig.spin(until: { r.lines("MENU write").count >= 1 }, limit: 120)
        #expect(r.lines("MENU write").count == 1, "the first run did not complete: \(r.lines("MENU"))")
        #expect(r.cliRuns == ["[show]"], "\(r.stub.calls)")
        // Both rows share the queue key `hide`: while a hide runs, a waiting show is replaced by the newer hide.
        try r.stub.set("stub-delay", "1")
        r.setHidden(false)
        r.surface.open()
        try r.surface.pick("Hide Clawd for 1 Hour")
        r.setHidden(true)
        r.surface.open()
        try r.surface.pick("Show Clawd")
        r.setHidden(false)
        r.surface.open()
        try r.surface.pick("Hide Clawd for 1 Hour")
        #expect(r.lines("MENU drop").count == 1, "the waiting show is dropped by the newer pick of the same queue key: \(r.lines("MENU"))")
        await r.rig.spin(until: { r.lines("MENU write").count >= 3 }, limit: 120)
        #expect(r.lines("MENU write").count == 3, "the runs did not complete: \(r.lines("MENU"))")
        #expect(r.cliRuns == ["[show]", "[hide] [60]", "[hide] [60]"], "\(r.cliRuns)")
        #expect(r.lines("MENU write").allSatisfy { $0.contains("key=hide ") && $0.hasSuffix("gen=0") }, "\(r.lines("MENU write"))")
        #expect(r.focus.activationRequests == 0 && r.machine.chatKeys.isEmpty, "no activation was asked and no window was made key")
        #expect(r.lines("CHAT").isEmpty)
    }

    @Test func StatusMenu_quitStopsTheChatChildThenExitsZero() throws {
        let r = try StatusRig()
        r.runtime.chatController.toggle(eventTime: 1)
        #expect(r.runtime.chatPanelIsOpen)
        // A hide runs and a show waits behind it: the exit drops the waiting one, and the line says how many were queued.
        try r.stub.set("stub-delay", "1")
        r.surface.open()
        try r.surface.pick("Hide Clawd for 1 Hour")
        r.setHidden(true)
        r.surface.open()
        try r.surface.pick("Show Clawd")
        r.surface.open()
        try r.surface.pick("Quit Clawd")
        #expect(r.box.exits.count == 1 && r.box.exits[0].code == 0, "\(r.box.exits)")
        #expect(r.box.exits.first?.stops == [.agentQuit], "the chat child was stopped before the process was asked to exit: \(r.box.exits)")
        #expect(!r.runtime.chatPanelIsOpen)
        #expect(r.lines("STATUS quit").first == "STATUS quit queued=1", "the exit leaves a line with the writes it dropped: \(r.lines("STATUS"))")
    }

    @Test func StatusMenu_aStaleChatRowDoesNothing() throws {
        // Open Chat, picked after the chat has opened another way: it does not close the chat.
        let open = try StatusRig()
        open.surface.open()
        let stale = try open.surface.item("Open Chat")
        open.runtime.chatController.toggle(eventTime: 1)
        #expect(open.runtime.chatPanelIsOpen)
        let before = open.lines("CHAT")
        _ = stale.target?.perform(try #require(stale.action), with: stale)
        #expect(open.runtime.chatPanelIsOpen, "a stale Open Chat leaves the open chat open")
        #expect(open.lines("CHAT") == before && open.lines("STATUS pick").last == "STATUS pick row=openChat stale", "\(open.lines("STATUS"))")

        // Close Chat, picked after the chat has closed another way: it does not open it.
        let close = try StatusRig()
        close.runtime.chatController.toggle(eventTime: 1)
        close.surface.open()
        let staleClose = try close.surface.item("Close Chat")
        close.runtime.chatController.toggle(eventTime: 2)
        #expect(!close.runtime.chatPanelIsOpen)
        let opens = close.lines("CHAT open").count
        _ = staleClose.target?.perform(try #require(staleClose.action), with: staleClose)
        #expect(!close.runtime.chatPanelIsOpen && close.lines("CHAT open").count == opens, "a stale Close Chat opens nothing: \(close.lines("CHAT"))")
        #expect(close.lines("STATUS pick").last == "STATUS pick row=closeChat stale", "\(close.lines("STATUS"))")
    }

    @Test func StatusMenu_actionsSetTheStatusMenuContext() async throws {
        let r = try StatusRig()
        for (title, hidden) in [("Open Chat", false), ("Hide Clawd for 1 Hour", false), ("Show Clawd", true), ("Quit Clawd", false)] {
            r.setHidden(hidden)
            r.surface.open()
            r.rig.monitor.context = "click"
            try r.surface.pick(title)
            #expect(r.rig.monitor.context == "status-menu", "\(title) sets the context")
        }
        await r.rig.spin(until: { r.lines("MENU write").count >= 2 })
    }
}
