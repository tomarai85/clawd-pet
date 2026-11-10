import AppKit

/// A picker that is up: its window, for the focus rule, and the way to take it down.
public protocol ChatAttachHandle: AnyObject {
    var window: NSWindow? { get }
    func cancel()
}

/// The "+" control's file picker (Orca main/ipc/shell.ts:235-243, `showOpenDialog({ properties: ['openFile'] })`): one file, no folders. The
/// completion gets the chosen file's path, or nil when the picker was cancelled or closed.
public protocol ChatAttachPicking: AnyObject {
    func present(_ completion: @escaping (String?) -> Void) -> ChatAttachHandle
}

/// What a rig without a picker has: nothing shows and nothing completes.
final class InertAttachPicker: ChatAttachPicking {
    private final class Handle: ChatAttachHandle {
        var window: NSWindow? { nil }
        func cancel() {}
    }
    func present(_ completion: @escaping (String?) -> Void) -> ChatAttachHandle { Handle() }
}

/// The only file that names the system's open panel (lint `open-panel`). It is shown with `begin(completionHandler:)`: never modal, never a
/// sheet, and above the chat panel (`.modalPanel` over the chat's `.floating`), so it never opens behind the chat.
public final class ChatAttachPicker: ChatAttachPicking {
    public init() {}

    /// The panel as it is shown, built but not shown (the tests read it).
    public static func makePanel() -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.level = .modalPanel
        return panel
    }

    private final class Handle: ChatAttachHandle {
        let panel: NSOpenPanel
        init(_ panel: NSOpenPanel) { self.panel = panel }
        var window: NSWindow? { panel }
        func cancel() { panel.cancel(nil) }
    }

    public func present(_ completion: @escaping (String?) -> Void) -> ChatAttachHandle {
        let panel = Self.makePanel()
        panel.begin { response in completion(response == .OK ? panel.url?.path : nil) }
        return Handle(panel)
    }
}
