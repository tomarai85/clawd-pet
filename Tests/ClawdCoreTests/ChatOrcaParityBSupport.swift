import Testing
import Foundation
import AppKit
import ClawdCore
import ClawdDesktop

// Doubles for Orca parity round B (drops, the picker, pastes, menus, the copy button, Clawd's body as a drop target, the recall of a click-closed
// chat). A drag is delivered by calling the destination view's own methods with a fake `NSDraggingInfo`: no window is shown, no window is made key
// and no application is activated.

/// A private named pasteboard that holds what a drag would carry, and gives itself up when the test ends.
final class DragBoard {
    let board: ChatDragPasteboard
    init(files: [String] = [], promise: Bool = false, string: String? = nil, url: String? = nil) {
        board = ChatDragPasteboard(name: ChatDragPasteboard.Name("clawd-test-drag-" + UUID().uuidString))
        board.clearContents()
        if !files.isEmpty { board.writeObjects(files.map { URL(fileURLWithPath: $0) as NSURL }) }
        if promise, let type = ChatDropContent.promiseTypes.first { board.addTypes([type], owner: nil); board.setData(Data("x".utf8), forType: type) }
        if let string { board.addTypes([.string], owner: nil); board.setString(string, forType: .string) }
        if let url { board.addTypes([.URL], owner: nil); board.setString(url, forType: .URL) }
    }
    deinit { board.releaseGlobally() }
}

final class FakeDrag: NSObject, NSDraggingInfo {
    let source: DragBoard
    var location: NSPoint = .zero
    init(_ source: DragBoard, at location: NSPoint = .zero) { self.source = source; self.location = location }
    var draggingDestinationWindow: NSWindow? { nil }
    var draggingSourceOperationMask: NSDragOperation { .every }
    var draggingLocation: NSPoint { location }
    var draggedImageLocation: NSPoint { location }
    var draggedImage: NSImage? { nil }
    var draggingPasteboard: ChatDragPasteboard { source.board }
    var draggingSource: Any? { nil }
    var draggingSequenceNumber: Int { 1 }
    var draggingFormation: NSDraggingFormation = .default
    var animatesToDestination = false
    var numberOfValidItemsForDrop = 1
    var springLoadingHighlight: NSSpringLoadingHighlight { .none }
    func slideDraggedImage(to screenPoint: NSPoint) {}
    func enumerateDraggingItems(options enumOpts: NSDraggingItemEnumerationOptions, for view: NSView?, classes classArray: [AnyClass],
                                searchOptions: [ChatDragPasteboard.ReadingOptionKey: Any], using block: @escaping (NSDraggingItem, Int, UnsafeMutablePointer<ObjCBool>) -> Void) {}
    func resetSpringLoading() {}
}

/// What AppKit does with a drag: the deepest view registered for `type` among the subviews whose frame holds the point, found by walking the
/// subviews from the top down (`point` is in the coordinates of `root`'s superview, as AppKit gives it to the content view).
func dragDestination(in root: NSView, at point: CGPoint, type: ChatDragPasteboard.PasteboardType = .fileURL) -> NSView? {
    guard !root.isHidden, root.frame.contains(point) else { return nil }
    let local = root.convert(point, from: root.superview)
    for sub in root.subviews.reversed() {
        if let found = dragDestination(in: sub, at: local, type: type) { return found }
    }
    return root.registeredDraggedTypes.contains(type) ? root : nil
}

extension NSView {
    /// The view's drag-destination calls, which the compiler does not show on NSView itself.
    var destination: NSDraggingDestination { self as NSDraggingDestination }
}

/// The background runner of the attach environment: each piece of work waits until the test steps it, and its main-queue half waits behind it.
final class ManualBackground {
    private(set) var pending: [(work: () -> Void, done: () -> Void)] = []
    func run(_ work: @escaping () -> Void, _ done: @escaping () -> Void) { pending.append((work, done)) }
    /// Runs the work of the oldest piece (the background thread's half).
    func runWork() { guard !pending.isEmpty else { return }; pending[0].work() }
    /// Runs its main-queue half and removes it.
    func runDone() { guard !pending.isEmpty else { return }; let entry = pending.removeFirst(); entry.done() }
    func runAll() { while !pending.isEmpty { runWork(); runDone() } }
}

final class FakePickerHandle: ChatAttachHandle {
    var window: NSWindow?
    var cancelled = false
    private let finish: (String?) -> Void
    init(window: NSWindow?, finish: @escaping (String?) -> Void) { self.window = window; self.finish = finish }
    func cancel() { cancelled = true; finish(nil) }
}

final class FakePicker: ChatAttachPicking {
    private(set) var handles: [FakePickerHandle] = []
    private var completions: [(String?) -> Void] = []
    /// A window the handle reports (the picker's own); a test sets it before pressing the "+".
    var window: NSWindow? = NSWindow(contentRect: .zero, styleMask: [.borderless], backing: .buffered, defer: true)
    var completeAtOnce: String??
    /// Runs inside `present`, before it returns (what AppKit does when `begin` makes the open panel key at once).
    var duringPresent: ((NSWindow?) -> Void)?
    func present(_ completion: @escaping (String?) -> Void) -> ChatAttachHandle {
        let handle = FakePickerHandle(window: window, finish: completion)
        duringPresent?(window)
        handles.append(handle); completions.append(completion)
        if let path = completeAtOnce { completion(path) }
        return handle
    }
    var presented: Int { handles.count }
    func choose(_ path: String?) { completions.last?(path) }
}

/// A fresh state directory for a test (the agent's own store).
func makeState() throws -> (OwnState, URL) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("clawd-b-" + UUID().uuidString, isDirectory: true)
    return (try OwnState(root: root), root)
}

/// A chat rig with the web kind, a manual background, a fake picker and a fake pasteboard for paste, over a fresh state directory.
@MainActor
final class AttachRig {
    let web: WebKindRig
    let background = ManualBackground()
    let picker = FakePicker()
    let state: OwnState
    let root: URL
    let temp: URL

    init(fileCap: Int64? = nil, encoder: ((Data) -> Data?)? = nil, withState: Bool = true) throws {
        let (store, root) = try makeState()
        state = store; self.root = root
        temp = root.appendingPathComponent("tmp", isDirectory: true)
        try FileManager.default.createDirectory(at: temp, withIntermediateDirectories: true)
        let background = self.background, picker = self.picker
        var env = ChatAttachEnvironment()
        env.state = withState ? store : nil
        env.temporaryDirectory = temp.path
        if let fileCap { env.fileCap = fileCap }
        env.background = { background.run($0, $1) }
        env.picker = { picker }
        if let encoder { env.encodePNG = encoder }
        env.wallMilliseconds = { 1_700_000_000_123 }
        env.uuid = { UUID(uuidString: "11111111-2222-3333-4444-555555555555")! }
        let holder = PasteHolder()
        env.pasteContents = { holder.contents }
        self.holder = holder
        env.wall = { [unowned holder] in holder.now }
        web = WebKindRig(attach: env)
    }
    private let holder: PasteHolder
    final class PasteHolder { var contents = ChatPasteContents(hasText: true); var now = Date() }
    func setPaste(_ contents: ChatPasteContents) { holder.contents = contents }
    func setNow(_ date: Date) { holder.now = date }

    var rig: ControllerRig { web.rig }
    var controller: ChatController { web.controller }
    var body: ChatWebBody { web.body! }
    var input: ChatInputTextView { web.body!.inputView }  // only after a successful open()
    /// Opens the chat; the sweeps an open starts run at once (they are off the main thread in production and have nothing to say here).
    func open() throws {
        rig.open()
        background.runAll()
        try #require(rig.controller.isOpen, "the chat opened: \(rig.logs)")
    }

    /// A drag of files delivered to the body (or to the composer's input, which forwards): entered, then performed.
    @discardableResult
    func drop(_ board: DragBoard, onInput: Bool = false) -> Bool {
        let target: NSView = onInput ? input : body
        let drag = FakeDrag(board)
        _ = target.destination.draggingEntered?(drag)
        let performed = target.destination.performDragOperation?(drag) ?? false
        target.destination.concludeDragOperation?(drag)
        return performed
    }

    /// A file in the fake per-user temp directory, where a drag provider would put it: `TemporaryItems/NSIRD_x/<name>`.
    func providerFile(_ name: String, contents: Data = Data("hello".utf8)) throws -> String {
        let dir = temp.appendingPathComponent("TemporaryItems/NSIRD_abc123", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let path = dir.appendingPathComponent(name)
        try contents.write(to: path)
        return path.path
    }

    func cleanUp() { try? FileManager.default.removeItem(at: root) }
}

/// A real PNG of the given size, as small as it can be: one bit per pixel, all the same, so it compresses to a few KB. (ImageIO gives no size for a
/// header-only or truncated PNG once the image is more than about 100,000 pixels, so the fixture has to be a whole file.)
func monochromePNG(width: Int, height: Int) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 1, samplesPerPixel: 1, hasAlpha: false,
                               isPlanar: false, colorSpaceName: .deviceWhite, bytesPerRow: 0, bitsPerPixel: 1)!
    return rep.representation(using: .png, properties: [:])!
}

/// A real PNG of the given size.
func pngData(width: Int = 4, height: Int = 4) -> Data {
    let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: width, pixelsHigh: height, bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true,
                               isPlanar: false, colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0)!
    return rep.representation(using: .png, properties: [:])!
}

func mouseEvent(_ type: NSEvent.EventType, at point: CGPoint = .zero, time: TimeInterval = 0, window: NSWindow? = nil) -> NSEvent {
    NSEvent.mouseEvent(with: type, location: point, modifierFlags: [], timestamp: time, windowNumber: window?.windowNumber ?? 0, context: nil,
                       eventNumber: 0, clickCount: 1, pressure: 1)!
}
