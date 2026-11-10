import AppKit

/// Settings' working-folder picker: one directory, shown with `begin`, never modal and never a sheet, above the Settings window. The completion
/// gets the chosen folder's path, or nil when the picker was cancelled or closed. The handle is the chat picker's (its window, for the focus
/// rule, and the way to take it down).
public protocol SettingsFolderPicking: AnyObject {
    /// `startingAt` is the folder the picker opens in (the one now in use).
    func present(startingAt: String?, _ completion: @escaping (String?) -> Void) -> ChatAttachHandle
}

/// What a rig without a picker has: nothing shows and nothing completes.
public final class InertFolderPicker: SettingsFolderPicking {
    private final class Handle: ChatAttachHandle {
        var window: NSWindow? { nil }
        func cancel() {}
    }
    public init() {}
    public func present(startingAt: String?, _ completion: @escaping (String?) -> Void) -> ChatAttachHandle { Handle() }
}

/// The only file besides the chat's attach picker that names the system's open panel (lint `open-panel`). Shown with `begin(completionHandler:)`
/// at `.modalPanel`, above the Settings window, so it never opens behind it.
public final class SettingsFolderPicker: SettingsFolderPicking {
    public init() {}

    /// The panel as it is shown, built but not shown (the tests read it).
    public static func makePanel(startingAt: String?) -> NSOpenPanel {
        let panel = NSOpenPanel()
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.prompt = "Choose"
        panel.level = .modalPanel
        if let startingAt, startingAt.hasPrefix("/") { panel.directoryURL = URL(fileURLWithPath: startingAt, isDirectory: true) }
        return panel
    }

    private final class Handle: ChatAttachHandle {
        let panel: NSOpenPanel
        init(_ panel: NSOpenPanel) { self.panel = panel }
        var window: NSWindow? { panel }
        func cancel() { panel.cancel(nil) }
    }

    public func present(startingAt: String?, _ completion: @escaping (String?) -> Void) -> ChatAttachHandle {
        let panel = Self.makePanel(startingAt: startingAt)
        panel.begin { response in completion(response == .OK ? panel.url?.path : nil) }
        return Handle(panel)
    }
}
