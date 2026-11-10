import AppKit
import WebKit
import ClawdCore

/// What `/resume` takes from the machine: where Claude Code keeps its conversations and sessions, and how a listing is made. The default lists
/// nothing and touches no folder; the real values (the child's `~/.claude`, a serial utility queue) exist only in `production`.
public struct ChatResumeEnvironment {
    public typealias Lister = (_ folder: String, _ excluding: String?, _ cancelled: @escaping () -> Bool, _ done: @escaping (ChatResume.Listing) -> Void) -> Void
    /// The roots the pick checks a conversation file and the live-session registry against.
    public var roots: ChatResume.Roots
    /// Makes one listing and calls `done` on the main queue.
    public var list: Lister

    public init(roots: ChatResume.Roots = .none,
                list: @escaping Lister = { folder, excluding, cancelled, done in
                    done(ChatResume.list(folder: folder, roots: .none, excluding: excluding, cancelled: cancelled))
                }) {
        self.roots = roots; self.list = list
    }

    private static let queue = DispatchQueue(label: "clawd.chat.resume", qos: .utility)

    /// One listing per call, on one serial utility queue made on first use; the result comes back on the main queue.
    public static func production() -> ChatResumeEnvironment {
        let roots = ChatResume.Roots.production()
        return ChatResumeEnvironment(roots: roots, list: { folder, excluding, cancelled, done in
            queue.async {
                let listing = ChatResume.list(folder: folder, roots: roots, excluding: excluding, cancelled: cancelled)
                DispatchQueue.main.async { done(listing) }
            }
        })
    }
}

/// What the web chat takes from the machine it runs on (Stage 2). Production values are in `RuntimeEnvironment.production`; a rig supplies its
/// own, so no test opens a browser or touches the real pasteboard.
public struct ChatWebEnvironment {
    /// The installed page directory (`~/Library/Application Support/clawd-pet/chat-page/`): the page is loaded from it, and the web view may read
    /// that directory and nothing else.
    public var pageDirectory: URL
    /// The one-shot timers of the bridge (the 2 s limit of a call).
    public var timers: ChatTimers
    /// Opens an http(s) URL in the default browser (a Cmd-click on a link; the URL has already passed `ChatWebLink.openable`).
    public var openLink: (URL) -> Void
    /// Where Cmd+C puts the page's selection.
    public var pasteboard: ChatPasteboardSource
    /// Whether every file of the page is in the page directory (an install that predates the page has none: the chat then uses the stream view).
    public var isInstalled: () -> Bool
    /// The drop, paste and picker collaborators (drop copies, pasted images, the "+" picker); the defaults keep and show nothing.
    public var attach: ChatAttachEnvironment
    /// The one-shot timer of the composer's saved draft (250 ms after the first change not yet saved).
    public var composerTimers: ChatTimers
    /// `/resume`'s roots and lister.
    public var resume: ChatResumeEnvironment

    public init(pageDirectory: URL, timers: ChatTimers = DispatchChatTimers(), openLink: @escaping (URL) -> Void,
                pasteboard: ChatPasteboardSource, isInstalled: (() -> Bool)? = nil, attach: ChatAttachEnvironment = ChatAttachEnvironment(),
                composerTimers: ChatTimers = DispatchChatTimers(), resume: ChatResumeEnvironment = ChatResumeEnvironment()) {
        self.pageDirectory = pageDirectory; self.timers = timers; self.openLink = openLink; self.pasteboard = pasteboard
        self.composerTimers = composerTimers; self.resume = resume
        self.isInstalled = isInstalled ?? { ChatWebPage.installed(in: pageDirectory) }
        self.attach = attach
    }
}

/// Orca's "Copy Session ID" item and the separator before it (NC/use-native-chat-context-menu.tsx:290-299, 326-332): both are absent while the
/// conversation has no id.
public enum ChatSessionIDMenu {
    public static let title = "Copy Session ID"
    public static func items(for sessionID: String?, target: AnyObject, action: Selector) -> [NSMenuItem] {
        guard let sessionID, !sessionID.isEmpty else { return [] }
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = target
        item.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        return [.separator(), item]
    }
}

/// The page's web view: it never takes the keyboard, is never a drag destination, shows Clawd's own menu (Copy, Paste and, once a session exists, Copy Session ID) instead of WebKit's, and has no
/// Look Up or Quick Look.
public final class ChatWebView: WKWebView {
    public override var acceptsFirstResponder: Bool { false }
    /// Whether the page has a selection a Copy could take (the page posts it; see `ChatWebPage.received`).
    public var hasSelection = false
    /// The menu's actions, wired by the web body: Copy reads the page, Paste goes to the composer.
    public var onMenuCopy: (() -> Void)?
    public var onMenuPaste: (() -> Void)?
    /// The conversation id the menu offers to copy (nil: no item), and the item's action (Q19).
    public var sessionID: (() -> String?)?
    public var onMenuCopySessionID: (() -> Void)?

    /// WebKit registers the view for file and URL drags; a registered web view is the destination of a drop over the transcript and navigates to the
    /// file. The view refuses every registration, so the web body (the composer's neighbour) is the one destination.
    public override func registerForDraggedTypes(_ newTypes: [NSPasteboard.PasteboardType]) {}
    public override func viewDidMoveToWindow() { super.viewDidMoveToWindow(); unregisterDraggedTypes() }
    public override func viewDidMoveToSuperview() { super.viewDidMoveToSuperview(); unregisterDraggedTypes() }

    /// WKWebView shows its menu only through `willOpenMenu`: WebKit's items are replaced by Orca's Copy and Paste
    /// (native-chat/use-native-chat-context-menu.tsx:339-356). `menu(for:)` stays nil.
    public override func menu(for event: NSEvent) -> NSMenu? { nil }
    public override func willOpenMenu(_ menu: NSMenu, with event: NSEvent) {
        menu.removeAllItems()
        menu.autoenablesItems = false
        let copy = NSMenuItem(title: "Copy", action: #selector(menuCopy), keyEquivalent: "c")
        copy.target = self
        copy.image = NSImage(systemSymbolName: "doc.on.doc", accessibilityDescription: nil)
        copy.isEnabled = hasSelection
        let paste = NSMenuItem(title: "Paste", action: #selector(menuPaste), keyEquivalent: "")
        paste.target = self
        paste.image = NSImage(systemSymbolName: "doc.on.clipboard", accessibilityDescription: nil)
        menu.addItem(copy); menu.addItem(paste)
        for item in ChatSessionIDMenu.items(for: sessionID?(), target: self, action: #selector(menuCopySessionID)) { menu.addItem(item) }
    }
    @objc public func menuCopy() { onMenuCopy?() }
    @objc public func menuPaste() { onMenuPaste?() }
    @objc public func menuCopySessionID() { onMenuCopySessionID?() }
    public override func quickLook(with event: NSEvent) {}
}

/// The web view's content controller. WebKit has no public call that lists the registered handlers, so this one writes down every name that
/// goes through `add` and `remove*`, and the audit reads that list.
final class ChatWebContent: WKUserContentController {
    private(set) var handlerNames: [String] = []
    override func add(_ scriptMessageHandler: WKScriptMessageHandler, name: String) {
        super.add(scriptMessageHandler, name: name)
        handlerNames.append(name)
    }
    override func removeScriptMessageHandler(forName name: String) {
        super.removeScriptMessageHandler(forName: name)
        handlerNames.removeAll { $0 == name }
    }
    override func removeAllScriptMessageHandlers() {
        super.removeAllScriptMessageHandlers()
        handlerNames.removeAll()
    }
}

/// The script-message handler WebKit keeps: it holds the page weakly, so the web view's configuration never keeps the page, and through it the
/// web view, alive after a close.
final class ChatWebHandlerProxy: NSObject, WKScriptMessageHandler {
    weak var page: ChatWebPage?
    init(page: ChatWebPage) { self.page = page }
    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        page?.received(message.body)
    }
}

/// One opening's chat page: a web view on a non-persistent data store that loads the page file once, answers the page's two messages, and takes
/// the bridge's calls (Stage 2 R1, R2, R5, R6). `teardown()` ends it at close; the object is not used again.
public final class ChatWebPage: NSObject, WKNavigationDelegate, ChatWebTransport {
    public static let handlerName = "clawd"
    public static let pageFile = "index.html"
    /// Every file the page directory holds (the installer's list repeats it; a test keeps the two equal).
    public static let files = ["index.html", "page.css", "page.js", "marked.min.js", "Geist-Variable.woff2",
                               "OFL.txt", "LICENSE-marked.txt", "LICENSE-lucide.txt"]

    public static func installed(in directory: URL) -> Bool {
        files.allSatisfy { FileManager.default.fileExists(atPath: directory.appendingPathComponent($0).path) }
    }

    public private(set) var view: ChatWebView?
    public private(set) var bridge: ChatWebBridge!
    public let directory: URL
    public let pageURL: URL
    /// The message handler names registered on the web view's content controller right now (the audit requires exactly `clawd`).
    public var handlerNames: [String] {
        (view?.configuration.userContentController as? ChatWebContent)?.handlerNames ?? []
    }
    private let openLink: (URL) -> Void
    private let log: (String) -> Void
    private var allowNextLoad = false
    private var reloads = 0
    /// Navigation decisions after the one load: refused ones are counted (the CSP test and the audit read them).
    public private(set) var refusedNavigations = 0
    public private(set) var allowedNavigations = 0
    public private(set) var openedLinks = 0
    public private(set) var refusedLinks = 0
    /// The page's process ended twice in one opening: the controller shows a notice.
    public var onGaveUp: (() -> Void)?
    /// The page reported `ready` (for the tests).
    public var onReady: (() -> Void)?
    /// The copy button of an entry was clicked in the page (`copy`, an entry id); the controller answers it (a recent click, a known id).
    public var onCopyRequest: ((Int) -> Void)?
    /// The page's selection state changed (`selection`, whether a Copy could take text).
    public var onSelectionChanged: ((Bool) -> Void)?
    /// The copy button of a code fence was clicked in the page (`copy-code`, an entry id and the fence's ordinal in that entry).
    public var onCopyCodeRequest: ((Int, Int) -> Void)?
    /// The copy button of the link popover was clicked in the page (`copy-link`, the URL, which has passed `ChatWebLink.openable`).
    public var onCopyLinkRequest: ((String) -> Void)?
    /// The reader's place, as the page's latest `view` message gave it (every field checked for type and range; the controller keeps the latest).
    public var onViewState: ((ChatViewState) -> Void)?
    /// Whether the page's link popover is open, as its latest `layer` message said. Cleared on `ready`, when the content process ends, and at
    /// teardown.
    public private(set) var layerOpen = false
    /// Where the text of a code fence comes from. The default asks the page (`ClawdChat.codeText`, a constant function body); a rig may replace it.
    public var codeTextSource: ((Int, Int, @escaping (String?) -> Void) -> Void)?
    /// Where the answer to "close your link popover" comes from. The default asks the page (`ClawdChat.dismissLayer`); a rig may replace it.
    public var layerDismissSource: ((@escaping (Bool) -> Void) -> Void)?

    public init(environment: ChatWebEnvironment, log: @escaping (String) -> Void = { _ in }) {
        directory = environment.pageDirectory
        pageURL = environment.pageDirectory.appendingPathComponent(Self.pageFile)
        openLink = environment.openLink
        self.log = log
        super.init()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.preferences.javaScriptCanOpenWindowsAutomatically = false
        configuration.mediaTypesRequiringUserActionForPlayback = .all
        let content = ChatWebContent()
        content.add(ChatWebHandlerProxy(page: self), name: Self.handlerName)
        configuration.userContentController = content
        let web = ChatWebView(frame: .zero, configuration: configuration)
        web.unregisterDraggedTypes()
        web.allowsLinkPreview = false
        web.allowsBackForwardNavigationGestures = false
        web.allowsMagnification = false
        web.pageZoom = ChatWebLook.textScale               // the whole page at the chat's size: text, rows and gaps together
        if #available(macOS 13.3, *) { web.isInspectable = false }
        web.navigationDelegate = self
        view = web
        bridge = ChatWebBridge(transport: self, timers: environment.timers, log: log)
    }

    /// Loads the page file: the one navigation the delegate allows, and the web view may read the page directory and nothing else.
    public func load() {
        guard let view else { return }
        allowNextLoad = true
        view.loadFileURL(pageURL, allowingReadAccessTo: directory)
    }

    /// The close: no handler, no load, no view, no timer. Idempotent.
    public func teardown() {
        layerOpen = false
        bridge?.pageLost()
        guard let view else { return }
        view.configuration.userContentController.removeAllScriptMessageHandlers()
        view.stopLoading()
        view.navigationDelegate = nil
        view.removeFromSuperview()
        self.view = nil
    }

    // MARK: the page's messages

    /// Swift checks type and size of every body and ignores any name it does not know.
    public func received(_ body: Any) {
        guard let message = body as? [String: Any], message.count <= 5, let type = message["type"] as? String, type.utf8.count <= 16 else { return }
        // Every type but `copy-code` (3 keys) and `view` (4 or 5) has at most two keys.
        guard message.count <= 2 || (type == "copy-code" && message.count == 3) || type == "view" else { return }
        switch type {
        case "ready":
            guard message.count == 1 else { return }
            layerOpen = false
            bridge.pageReady()
            onReady?()
        case "open":
            guard let text = message["url"] as? String, let url = ChatWebLink.openable(text) else { refusedLinks += 1; return }
            openedLinks += 1
            openLink(url)
        case "selection":
            // Exactly a Bool `has`: never the text itself.
            guard message.count == 2, let has = Self.strictBool(message["has"]) else { return }
            view?.hasSelection = has
            onSelectionChanged?(has)
        case "copy":
            // Exactly an entry id (a whole number); the controller decides whether it is allowed.
            guard message.count == 2, let number = message["id"] as? NSNumber, !Self.isBoolean(number), number.doubleValue == Double(number.intValue) else { return }
            onCopyRequest?(number.intValue)
        case "copy-code":
            // Exactly an entry id and a fence ordinal, both whole numbers of at most 10 million; the controller decides whether it is allowed.
            guard message.count == 3, let id = Self.strictInt(message["id"]), let index = Self.strictInt(message["index"]) else { return }
            onCopyCodeRequest?(id, index)
        case "copy-link":
            guard message.count == 2, let text = message["url"] as? String, ChatWebLink.openable(text) != nil else { return }
            onCopyLinkRequest?(text)
        case "layer":
            guard message.count == 2, let open = Self.strictBool(message["open"]) else { return }
            layerOpen = open
        case "view":
            // Exactly `following`, `anchor` and `offset`, and a four-integer `sel` when there is a selection; anything else is ignored.
            guard message.count == 4 || message.count == 5, let following = Self.strictBool(message["following"]),
                  let anchor = Self.strictInt(message["anchor"]), let offset = Self.strictInt(message["offset"]) else { return }
            var sel: [Int]?
            if message.count == 5 {
                guard let raw = message["sel"] as? [Any], raw.count == 4 else { return }
                let ints = raw.compactMap { Self.strictInt($0) }
                guard ints.count == 4 else { return }
                sel = ints
            }
            guard let state = ChatViewState(following: following, anchor: anchor, offset: offset, sel: sel) else { return }
            onViewState?(state)
        default:
            break
        }
    }

    /// A whole number from 0 to 10,000,000 (a JSON number that is not a Bool).
    private static func strictInt(_ value: Any?) -> Int? {
        guard let number = value as? NSNumber, !isBoolean(number), number.doubleValue == Double(number.intValue),
              (0...10_000_000).contains(number.intValue) else { return nil }
        return number.intValue
    }
    private static func isBoolean(_ number: NSNumber) -> Bool { CFGetTypeID(number) == CFBooleanGetTypeID() }
    private static func strictBool(_ value: Any?) -> Bool? {
        guard let number = value as? NSNumber, isBoolean(number) else { return nil }
        return number.boolValue
    }

    // MARK: transport

    public func send(_ call: ChatWebCall, completion: @escaping (Bool) -> Void) {
        guard let view else { completion(false); return }
        // A constant function body and the payload as an argument: no string-built script.
        let body = call.kind == .reset ? "return window.ClawdChat.reset(message);" : "return window.ClawdChat.apply(message);"
        view.callAsyncJavaScript(body, arguments: ["message": call.arguments], in: nil, in: .page) { result in
            if case .success = result { completion(true) } else { completion(false) }
        }
    }

    /// Cmd+C: the page's selection goes to the pasteboard whole under D5 (nothing when it is empty; `refused` when it is over the limit).
    public func copySelection(to pasteboard: ChatPasteboardSource, refused: @escaping () -> Void) {
        guard let view else { return }
        view.callAsyncJavaScript("return window.getSelection().toString();", arguments: [:], in: nil, in: .page) { result in
            if case .success(let value) = result, let text = value as? String { Self.copyWhole(text, to: pasteboard, refused: refused) }
        }
    }

    /// The menu's Copy: the text the page remembers for the context click (the selection at the right press, else the current one, else the last
    /// one), written whole under D5. Nothing is written when the page has none.
    public func menuCopy(to pasteboard: ChatPasteboardSource, refused: @escaping () -> Void) {
        guard let view else { return }
        view.callAsyncJavaScript("return window.ClawdChat.menuCopyText();", arguments: [:], in: nil, in: .page) { result in
            if case .success(let value) = result, let text = value as? String { Self.copyWhole(text, to: pasteboard, refused: refused) }
        }
    }

    /// D5 for a page copy: an empty text writes nothing, one over the limit calls `refused`, anything else is written whole.
    public static func copyWhole(_ text: String, to pasteboard: ChatPasteboardSource, refused: () -> Void) {
        guard !text.isEmpty else { return }
        guard let whole = clipboardText(text) else { refused(); return }
        pasteboard.setString(whole)
    }

    /// The entries whose copy the page was told succeeded (for the tests).
    public private(set) var copiedIDs: [Int] = []
    /// The copy button of entry `id` worked: the page shows its check and "Copied" for 1500 ms.
    public func copied(_ id: Int) {
        copiedIDs.append(id)
        guard let view else { return }
        view.callAsyncJavaScript("return window.ClawdChat.copied(id);", arguments: ["id": id], in: nil, in: .page) { _ in }
    }

    /// The clipboard rule of D5: text over 16 MiB of UTF-8 is not written.
    public static let copyRefusedStatus = "Copy failed: over 16 MiB"
    public static let clipboardLimit = 16 * 1024 * 1024
    public static func clipboardText(_ text: String) -> String? { text.utf8.count > clipboardLimit ? nil : text }

    /// The text of fence `index` of entry `id`, asked of the page with a constant function body; nil when the page has no such fence.
    public func codeText(id: Int, index: Int, completion: @escaping (String?) -> Void) {
        if let source = codeTextSource { source(id, index, completion); return }
        guard let view else { completion(nil); return }
        view.callAsyncJavaScript("return window.ClawdChat.codeText(id, index);", arguments: ["id": id, "index": index], in: nil, in: .page) { result in
            if case .success(let value) = result, let text = value as? String { completion(text) } else { completion(nil) }
        }
    }

    /// The fences whose copy the page was told succeeded (for the tests).
    public private(set) var copiedCode: [[Int]] = []
    /// The copy button of fence `index` of entry `id` worked: the page shows its check and "Copied" for 1500 ms.
    public func codeCopied(_ id: Int, _ index: Int) {
        copiedCode.append([id, index])
        guard let view else { return }
        view.callAsyncJavaScript("return window.ClawdChat.codeCopied(id, index);", arguments: ["id": id, "index": index], in: nil, in: .page) { _ in }
    }

    /// The popover's copy button worked: the page swaps its icon for a check.
    public private(set) var linkCopiedCount = 0
    public func linkCopied() {
        linkCopiedCount += 1
        guard let view else { return }
        view.callAsyncJavaScript("return window.ClawdChat.linkCopied();", arguments: [:], in: nil, in: .page) { _ in }
    }

    /// Esc, or a press outside the web view: asks the page to close its link popover. The completion says whether it closed one; a page that does not
    /// answer is the caller's to time out.
    public func dismissLayer(completion: @escaping (Bool) -> Void) {
        if let source = layerDismissSource { source(completion); return }
        guard let view else { completion(false); return }
        view.callAsyncJavaScript("return window.ClawdChat.dismissLayer();", arguments: [:], in: nil, in: .page) { result in
            if case .success(let value) = result, let closed = value as? Bool { completion(closed) } else { completion(false) }
        }
    }

    /// Puts the reader's view back (Q18): a constant function body and the state as an argument (null: nothing saved, which only lets the page
    /// start reporting). The completion gets the page's answer, `found`, `next` or `none`, or nil when the call failed.
    public func restoreView(_ state: ChatViewState?, completion: @escaping (String?) -> Void) {
        guard let view else { completion(nil); return }
        let argument: Any = state?.arguments ?? NSNull()
        view.callAsyncJavaScript("return window.ClawdChat.restoreView(state);", arguments: ["state": argument], in: nil, in: .page) { result in
            if case .success(let value) = result, let answer = value as? String { completion(answer) } else { completion(nil) }
        }
    }

    /// The caller found no layer to close (the page said false, or did not answer in time): the flag is stale.
    public func clearLayerFlag() { layerOpen = false }

    // MARK: navigation

    private func isPageURL(_ url: URL?) -> Bool {
        guard let url, url.isFileURL else { return false }
        return url.resolvingSymlinksInPath().path == pageURL.resolvingSymlinksInPath().path
    }

    public func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction,
                        decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if allowNextLoad, navigationAction.targetFrame?.isMainFrame != false, isPageURL(navigationAction.request.url) {
            allowNextLoad = false
            allowedNavigations += 1
            decisionHandler(.allow)
        } else {
            refusedNavigations += 1
            decisionHandler(.cancel)
        }
    }

    public func webViewWebContentProcessDidTerminate(_ webView: WKWebView) {
        log("CHAT web content-process-ended")
        layerOpen = false
        bridge.pageLost()
        if reloads < 1 {
            reloads += 1
            load()
        } else {
            onGaveUp?()
        }
    }

    public func webView(_ webView: WKWebView, didFailProvisionalNavigation navigation: WKNavigation!, withError error: Error) {
        log("CHAT web load-failed")
    }

    public func webView(_ webView: WKWebView, didFail navigation: WKNavigation!, withError error: Error) {
        log("CHAT web load-failed")
    }

    // MARK: audit

    /// What the panel audit checks about the web view (R5): WebKit's own surfaces are off, one handler name (read from the content controller), a non-persistent store, the page
    /// inside the page directory.
    public func auditProblems() -> [String] {
        var found: [String] = []
        guard let view else { return ["the web chat has no web view"] }
        if view.allowsLinkPreview { found.append("the web view allows link previews") }
        if #available(macOS 13.3, *), view.isInspectable { found.append("the web view is inspectable") }
        if view.uiDelegate != nil { found.append("the web view has a UI delegate") }
        if view.acceptsFirstResponder { found.append("the web view takes the keyboard") }
        if !view.registeredDraggedTypes.isEmpty { found.append("the web view is registered for drags") }
        if view.configuration.websiteDataStore.isPersistent { found.append("the web view's data store is persistent") }
        if !(view.configuration.userContentController is ChatWebContent) { found.append("the web view's content controller is not the recording one") }
        if handlerNames != [Self.handlerName] { found.append("the web view's message handlers are not exactly \(Self.handlerName)") }
        if !pageURL.path.hasPrefix(directory.path + "/") || pageURL.lastPathComponent != Self.pageFile { found.append("the page is not inside the page directory") }
        return found
    }
}
