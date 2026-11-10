import Testing
import Foundation
import AppKit
import ClawdCore
import ClawdRendering
import ClawdDesktop

// Test support for the Settings window (Stage SA, Sprint SA2): a folder picker that only records, and the real runtime with a fake bridge, a fake
// status bar, an exit that only records, and the Settings seams that record instead of showing anything. No window is ever put on screen or made key.

/// A folder picker that is up only in the test: its window is a plain window that is never shown, and `choose` delivers the completion.
final class FakeFolderPicker: SettingsFolderPicking {
    final class Handle: ChatAttachHandle {
        let owner: FakeFolderPicker
        init(_ owner: FakeFolderPicker) { self.owner = owner }
        var window: NSWindow? { owner.pickerWindow }
        func cancel() { owner.cancels += 1; owner.order("picker-cancel") }
    }
    let pickerWindow = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 200, height: 100), styleMask: [.titled], backing: .buffered, defer: true)
    var startedAt: [String?] = []
    var cancels = 0
    private var completion: ((String?) -> Void)?
    var order: (String) -> Void
    init(order: @escaping (String) -> Void) { self.order = order; pickerWindow.isReleasedWhenClosed = false }
    var isUp: Bool { completion != nil }
    func present(startingAt: String?, _ completion: @escaping (String?) -> Void) -> ChatAttachHandle {
        startedAt.append(startingAt)
        self.completion = completion
        order("picker-present")
        return Handle(self)
    }
    /// The user's answer: a folder, or nil for cancel.
    func choose(_ path: String?) { let done = completion; completion = nil; done?(path) }
}

/// The real runtime with a fake bridge, a fake status bar and a virtual clock; every Settings seam records.
@MainActor
final class SettingsRig {
    final class Box {
        var surfaces: [FakeStatusSurface] = []
        var exits: [(code: Int32, stops: [ChatStopReason])] = []
        /// The seams in the order they were called: present, makeKey, dismiss, picker-present, picker-cancel, handback, deactivate.
        var order: [String] = []
        var presented: [NSWindow] = []
        var dismissed: [NSWindow] = []
        var keyed: [SettingsWindow] = []
        var pickers: [FakeFolderPicker] = []
        /// Called inside the open's make-key call (a test posts the key notification there).
        var onKey: ((SettingsWindow) -> Void)?
        /// Called inside the window's dismiss call, with the window as it is at that moment.
        var onDismiss: ((NSWindow) -> Void)?
    }
    let box = Box()
    let rig: RuntimeRig
    let session = FakeChatSession()
    let focus = FakeChatFocus()
    let stub: MenuStubHome
    var machine: RuntimeMachine { rig.machine }
    var runtime: AgentRuntime { rig.runtime }
    var settings: SettingsController { rig.runtime.settingsController }
    var surface: FakeStatusSurface { box.surfaces[0] }
    var picker: FakeFolderPicker { box.pickers[box.pickers.count - 1] }

    init(control: [String: Any]? = nil, examAtBoot: Bool = false, chat: Bool = true, claudeSearch: [String] = [],
         request: SettingsRequestVerdict = .none, requestSeams: SettingsRequestSeams = .inert,
         aquaInstalled: Bool = true, aquaVersion: String? = nil) throws {
        let box = self.box, session = self.session, focus = self.focus
        let stub = try MenuStubHome()
        self.stub = stub
        rig = try RuntimeRig(control: control, virtual: true, settingsRequest: request, prepare: { machine in
            machine.examRunning = examAtBoot
            machine.settingsRequestSeams = requestSeams
            machine.aquaInstalled = aquaInstalled
            machine.aquaVersion = aquaVersion
            if chat { machine.chatSession = { _ in session } }
            machine.chatFocus = focus.seams
            machine.home = stub.root
            machine.statusBar = { let made = FakeStatusSurface(); box.surfaces.append(made); return made }
            machine.exitProcess = { box.exits.append(($0, session.stops)) }
            machine.settingsPresent = { box.presented.append($0); box.order.append("present") }
            machine.settingsDismiss = { box.dismissed.append($0); box.order.append("dismiss"); box.onDismiss?($0) }
            machine.claudeSearch = claudeSearch
            machine.settingsMakeKey = { box.keyed.append($0); box.order.append("makeKey"); box.onKey?($0) }
            machine.settingsFolderPicker = {
                let made = FakeFolderPicker(order: { box.order.append($0) })
                box.pickers.append(made)
                return made
            }
        })
        focus.now = { [unowned rig] in rig.virtualClock?.now ?? 0 }
        focus.onHandBack = { box.order.append("handback") }
        focus.onDeactivate = { box.order.append("deactivate") }
        machine.chatEvent = nil
    }
    func lines(_ prefix: String) -> [String] { rig.lines(prefix) }
    func post(_ name: Notification.Name, _ object: Any?) { rig.center.post(name: name, object: object) }
    var violations: Int { rig.monitor.status.focusViolations }

    /// The icon's Settings… pick, as AppKit makes it.
    func openFromMenuBar() throws {
        surface.open()
        try surface.pick("Settings\u{2026}")
    }
    func window() throws -> SettingsWindow { try #require(settings.window, "Settings is not open") }

    /// Clawd's activation as the system delivers it: will, then did.
    func clawdBecomesActive() {
        focus.active = true
        post(NSApplication.willBecomeActiveNotification, nil)
        post(NSApplication.didBecomeActiveNotification, nil)
    }
    func resign() {
        focus.active = false
        post(NSApplication.didResignActiveNotification, nil)
    }
    /// A mouse-down of any button in a window, as the application's current event.
    func mouseDown(in window: NSWindow?, _ button: ChatPressButton = .left) {
        machine.chatEvent = ChatCurrentEvent(isMouseDown: button == .left, window: window, mouseDownButton: button)
    }
    func keyEvent(in window: NSWindow? = nil) {
        machine.chatEvent = ChatCurrentEvent(isMouseDown: false, window: window, isMouse: false, timestamp: 1)
    }
    /// The arguments of every run of the stub CLI, as `[hide] [60]`.
    var cliRuns: [String] {
        stub.calls.filter { $0.hasPrefix("START") }.map { line in line.components(separatedBy: " ARGS").dropFirst().joined().trimmingCharacters(in: .whitespaces) }
    }
}
