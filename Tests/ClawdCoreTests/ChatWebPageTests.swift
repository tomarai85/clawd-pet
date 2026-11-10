import Testing
import Foundation
import AppKit
import WebKit
import Darwin
import ClawdCore
import ClawdDesktop

// Stage 2 R3: the chat page's two layers, tested apart. The renderer (marked's output and the allow-list walk) and the page's CSP. The page is the
// real one, loaded from the repo's chat-page/ into a web view in a window that is never ordered front and never key.

let chatPageDirectory = repository.appendingPathComponent("chat-page", isDirectory: true)

/// Waits for `condition`, polling, up to `seconds`.
@MainActor
func webWait(_ seconds: Double = 15, _ condition: () -> Bool) async -> Bool {
    let end = Date().addingTimeInterval(seconds)
    while Date() < end {
        if condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return condition()
}

/// Runs a constant function body in the page world with arguments (the way the bridge does) and returns its value.
@MainActor
func pageJS(_ view: WKWebView, _ body: String, _ arguments: [String: Any] = [:]) async throws -> Any? {
    try await view.callAsyncJavaScript(body, arguments: arguments, in: nil, contentWorld: .page)
}

/// An offscreen host: a window that is never ordered front or made key, holding the web view.
@MainActor
final class OffscreenHost {
    let window: NSWindow
    init(_ view: NSView, size: CGSize = CGSize(width: 520, height: 700)) {
        window = NSWindow(contentRect: CGRect(x: -20000, y: -20000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: true)
        window.isReleasedWhenClosed = false
        let content = NSView(frame: CGRect(origin: .zero, size: size))
        view.frame = content.bounds
        content.addSubview(view)
        window.contentView = content
    }
}

@MainActor
final class WebPageRig {
    final class OpenedBox { var urls: [URL] = [] }
    let pasteboard: FakePasteboard
    let page: ChatWebPage
    let host: OffscreenHost
    private let box: OpenedBox
    var isReady = false
    var openedLinks: [URL] { box.urls }

    init(directory: URL = chatPageDirectory) {
        let opened = OpenedBox(), board = FakePasteboard()
        box = opened; pasteboard = board
        let environment = ChatWebEnvironment(pageDirectory: directory, openLink: { opened.urls.append($0) }, pasteboard: board)
        let web = ChatWebPage(environment: environment)
        page = web
        host = OffscreenHost(web.view!)
    }

    /// Loads the page and waits for its `ready`.
    func loadAndWaitReady() async -> Bool {
        page.onReady = { [unowned self] in isReady = true }
        page.load()
        return await webWait { isReady }
    }
}

enum WebFixtures {
    static let hostile = """
    <script>window.__pwned=1</script>

    <img src=x onerror="window.__pwned=1">

    [click](javascript:window.__pwned=1) <iframe src="https://example.com/frame"></iframe> https://example.com/bare <https://example.com/angle>

    ![pic](https://example.com/p.png)

    <style>a{background:url(https://example.com/css)}</style> <b onclick="window.__pwned=1">b</b>

    <svg onload="window.__pwned=1"><circle/></svg>

    ```js
    let a = "<script>window.__pwned=1</script>";
    ```

    | a | b |
    |---|---|
    | <img src=x onerror=1> | 2 |

    - [ ] task <input type=checkbox>

    x <code> <img/src/onerror=window.__pwned=1>
    """
    static let hostileShort = "<img src=x onerror=\"window.__pwned=1\"><script>window.__pwned=1</script>"
    /// One 256 KiB line.
    static var bigLine: String { String(repeating: "word ", count: 52_000) }
    /// Nested brackets and emphasis: the shape that makes naive inline parsers backtrack.
    static var pathological: String { String(repeating: "[*_", count: 88_000) }
}

@Suite("Chat web page", .serialized)
@MainActor
struct ChatWebPageSuite {
    // MARK: the installer's list and the page directory

    @Test func ChatWebPage_theFileListIsTheInstallersAndTheDirectorys() throws {
        let cli = String(decoding: try ReadOnlyFile.data(repository.appendingPathComponent("bin/clawd-pet").path), as: UTF8.self)
        let line = try #require(cli.split(separator: "\n").first { $0.hasPrefix("CHAT_PAGE_FILES=(") })
        let listed = line.dropFirst("CHAT_PAGE_FILES=(".count).dropLast().split(separator: " ").map(String.init)
        #expect(listed == ChatWebPage.files, "the installer's list and ChatWebPage.files are the same list")
        let present = try FileManager.default.contentsOfDirectory(atPath: chatPageDirectory.path).sorted()
        #expect(present == ChatWebPage.files.sorted(), "the repo's chat-page/ holds exactly the listed files")
        #expect(ChatWebPage.installed(in: chatPageDirectory))
        #expect(!ChatWebPage.installed(in: repository.appendingPathComponent("art")))
    }

    @Test func ChatWebPage_everyFileThePageReferencesIsListedAndExistsInThePageDirectory() throws {
        func text(_ name: String) throws -> String {
            String(decoding: try ReadOnlyFile.data(chatPageDirectory.appendingPathComponent(name).path), as: UTF8.self)
        }
        func references(_ pattern: String, in source: String) throws -> [String] {
            let expression = try NSRegularExpression(pattern: pattern)
            return expression.matches(in: source, range: NSRange(source.startIndex..., in: source)).compactMap { match in
                Range(match.range(at: 1), in: source).map { String(source[$0]) }
            }
        }
        var found: [(String, String)] = []
        for name in ["index.html", "page.css", "page.js"] {
            let source = try text(name)
            let patterns = name == "index.html" ? ["(?:href|src)=\"([^\"]+)\""] : name == "page.css" ? ["url\\(\\s*['\"]?([^'\")\\s]+)"] : []
            for pattern in patterns { for reference in try references(pattern, in: source) { found.append((name, reference)) } }
        }
        #expect(found.contains { $0.1.hasSuffix(".woff2") } && found.contains { $0.1 == "page.js" }, "the scan sees the font and the scripts: \(found)")
        for (file, reference) in found where !reference.hasPrefix("data:") && !reference.hasPrefix("#") {
            #expect(ChatWebPage.files.contains(reference), "\(file) refers to \(reference), which is not in ChatWebPage.files")
            #expect(FileManager.default.fileExists(atPath: chatPageDirectory.appendingPathComponent(reference).path), "\(file) refers to \(reference), which is not in chat-page/")
        }
    }

    // MARK: the live tail

    @Test func ChatWebTail_theWorkingLineAndItsSpinnerExistOnlyWhileATurnRuns() async throws {
        let r = WebPageRig()
        #expect(await r.loadAndWaitReady())
        let probe = """
        const tail = document.querySelector('.tail');
        const spin = document.querySelector('.tail .spin');
        return JSON.stringify({display: getComputedStyle(tail).display, height: tail.offsetHeight, animations: document.getAnimations().length,
                               spinAnimation: getComputedStyle(spin).animationName, text: tail.textContent});
        """
        func state() async throws -> [String: Any] {
            let report = try #require(try await pageJS(r.page.view!, probe) as? String)
            return try #require(try JSONSerialization.jsonObject(with: Data(report.utf8)) as? [String: Any])
        }
        let idle = try await state()
        #expect(idle["display"] as? String == "none" && idle["height"] as? Int == 0 && idle["animations"] as? Int == 0 && idle["spinAnimation"] as? String == "none", "a fresh page: \(idle)")
        _ = try await pageJS(r.page.view!, "return window.ClawdChat.apply({order: [1], upserts: [{id: 1, kind: 'user', text: 'hi'}], turn: 'running'});")
        let running = try await state()
        #expect(running["display"] as? String == "flex" && running["spinAnimation"] as? String == "spin" && (running["text"] as? String)?.contains("Working") == true, "a running turn: \(running)")
        _ = try await pageJS(r.page.view!, "return window.ClawdChat.apply({upserts: [], turn: 'none'});")
        let ended = try await state()
        #expect(ended["display"] as? String == "none" && ended["height"] as? Int == 0 && ended["animations"] as? Int == 0 && ended["spinAnimation"] as? String == "none", "after the turn: \(ended)")
        #expect((ended["text"] as? String)?.contains("Working") == false, "no Working text stays: \(ended)")
        _ = try await pageJS(r.page.view!, "return window.ClawdChat.apply({upserts: [], turn: 'none'});")
        let again = try await state()
        #expect(again["display"] as? String == "none", "none after none: \(again)")
    }

    // MARK: the renderer (layer 1)

    @Test func ChatWebRenderer_textAfterAnInlineRawTagIsStillEscaped() async throws {
        let r = WebPageRig()
        #expect(await r.loadAndWaitReady())
        let inputs = ["x <code> <img/src/onerror=alert(1)>", "a <pre> <svg/onload=alert(1)> b", "<kbd> <img/src/onerror=1>", "<script> <img/src/onerror=1>",
                      "`x` <img src=x onerror=alert(1)>", "y <code>z</code> <img/src/onerror=alert(1)>"]
        for input in inputs {
            let html = try #require(try await pageJS(r.page.view!, "return window.ClawdChat.markdownHtml(text);", ["text": input]) as? String)
            for forbidden in ["<img", "<svg", "<script", "<iframe"] { #expect(!html.contains(forbidden), "\(input) rendered \(html)") }
            #expect(html.contains("&lt;"), "the tag-looking text shows as text: \(input) rendered \(html)")
        }
    }

    @Test func ChatWebRenderer_theAllowListWalkStripsWhatMarkdownCouldNotProduceFromText() async throws {
        // Layer 1's second guard on its own: markup that marked never makes from text (it is handed in as the HTML string) still ends as inert DOM.
        let r = WebPageRig()
        #expect(await r.loadAndWaitReady())
        let report = try #require(try await pageJS(r.page.view!, """
        const target = document.createElement('div');
        window.ClawdChat.renderHtml(target, html);
        return JSON.stringify({
          img: target.querySelectorAll('img').length, svg: target.querySelectorAll('svg').length, script: target.querySelectorAll('script').length,
          iframe: target.querySelectorAll('iframe').length, style: target.querySelectorAll('style').length, href: target.querySelectorAll('[href]').length,
          handlers: Array.from(target.querySelectorAll('*')).filter(function (e) { return Array.from(e.attributes).some(function (a) { return /^on/i.test(a.name); }); }).length,
          classes: target.querySelectorAll('[class], [style], [id]').length, p: target.querySelectorAll('p').length, text: target.textContent
        });
        """, ["html": "<p onclick=\"window.__pwned=1\" class=\"x\" style=\"a:b\">kept</p><img src=x onerror=\"window.__pwned=1\"><svg onload=\"window.__pwned=1\"><circle/></svg><a href=\"javascript:1\" data-href=\"https://e.com\">l</a><iframe src=\"https://example.com\"></iframe><style>a{}</style>"]) as? String)
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(report.utf8)) as? [String: Any])
        for key in ["img", "svg", "script", "iframe", "style", "href", "handlers", "classes"] { #expect(parsed[key] as? Int == 0, "\(key): \(parsed)") }
        #expect(parsed["p"] as? Int == 1 && (parsed["text"] as? String)?.contains("kept") == true, "\(parsed)")
    }

    @Test func ChatWebRenderer_markdownOutputHasNoActiveMarkupFromText() async throws {
        let r = WebPageRig()
        #expect(await r.loadAndWaitReady())
        let html = try #require(try await pageJS(r.page.view!, "return window.ClawdChat.markdownHtml(text);", ["text": WebFixtures.hostile]) as? String)
        for forbidden in ["<script", "<iframe", "<img", "<style", "<svg", "<input", "<b ", " href=", "<form", "<object", "<embed"] {
            #expect(!html.contains(forbidden), "marked's output holds \(forbidden)")
        }
        #expect(html.contains("&lt;script&gt;"), "the raw HTML shows as text")
        #expect(html.contains("<a data-href=\"https://example.com/bare\">"), "a link keeps its target only in data-href")
        #expect(html.contains("pic") && !html.contains("p.png"), "an image becomes its alt text")
    }

    @Test func ChatWebRenderer_theDomOfAHostileConversationHoldsOnlyAllowListedElementsAndAttributes() async throws {
        let r = WebPageRig()
        #expect(await r.loadAndWaitReady())
        let entries: [[String: Any]] = [
            ["id": 1, "kind": "user", "text": WebFixtures.hostile],
            ["id": 2, "kind": "assistant", "text": WebFixtures.hostile],
            ["id": 3, "kind": "assistant", "text": WebFixtures.bigLine],
            ["id": 4, "kind": "tool", "tool": "Read", "status": "done", "text": WebFixtures.hostileShort],
            ["id": 5, "kind": "tool", "tool": WebFixtures.hostileShort, "status": "running", "text": WebFixtures.hostileShort],
            ["id": 6, "kind": "notice", "text": WebFixtures.hostileShort],
            ["id": 7, "kind": "error", "text": WebFixtures.hostileShort],
            ["id": 8, "kind": "footer", "text": WebFixtures.hostileShort, "ms": 1500, "cost": 0.01],
        ]
        _ = try await pageJS(r.page.view!, "return window.ClawdChat.apply({order: ids, upserts: entries, turn: 'running'});", ["ids": entries.map { $0["id"] as! Int }, "entries": entries])
        let report = try #require(try await pageJS(r.page.view!, """
        const allowedTags = new Set(['div','span','p','br','strong','em','del','code','pre','ul','ol','li','blockquote','h1','h2','h3','h4','h5','h6','hr','a','table','thead','tbody','tr','th','td','svg','path','circle','rect','button','time']);
        const allowedAttrs = new Set(['class','data-id','data-href','data-native-chat-turn-status','aria-hidden','aria-live','start','align','viewBox','d','cx','cy','r','x','y','width','height','rx','ry','type','aria-label','title','datetime','tabindex']);
        const bad = [];
        document.querySelectorAll('#column *').forEach(function (e) {
          if (!allowedTags.has(e.localName)) bad.push('tag ' + e.localName);
          for (const a of e.attributes) { if (!allowedAttrs.has(a.name) || /^on/i.test(a.name)) bad.push('attr ' + e.localName + ' ' + a.name); }
          if (e.localName === 'svg' && !e.closest('.glyph, .activity, .copy-btn')) bad.push('svg from text');
          if (e.localName === 'button' && !(e.classList.contains('copy-btn') && e.parentElement && e.parentElement.matches('.agent-controls, .user-meta, .code-head, .code-block'))) bad.push('button from text');
        });
        return JSON.stringify({
          bad: bad,
          forbidden: document.querySelectorAll('#column script, #column iframe, #column img, #column style, #column input, #column a[href]').length,
          buttons: document.querySelectorAll('#column button').length,
          scripts: document.querySelectorAll('script').length,
          pwned: typeof window.__pwned,
          notice: document.querySelector('.notice').textContent,
          rows: document.querySelectorAll('#column > .row').length
        });
        """) as? String)
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(report.utf8)) as? [String: Any])
        #expect((parsed["bad"] as? [String])?.isEmpty == true, "\(parsed["bad"] ?? "")")
        #expect(parsed["forbidden"] as? Int == 0)
        #expect(parsed["buttons"] as? Int == 7, "a copy button for each of the three user and assistant messages (3), the scroll-to-top button of the two assistant ones (2) and the copy button of the js fence in each of the two hostile messages (2), no other button: \(parsed["buttons"] ?? "")")
        #expect(parsed["scripts"] as? Int == 2, "only marked.min.js and page.js")
        #expect(parsed["pwned"] as? String == "undefined", "no script of the text ran")
        #expect(parsed["notice"] as? String == WebFixtures.hostileShort, "the notice shows the text as text")
        #expect(parsed["rows"] as? Int == 8)
        #expect(r.openedLinks.isEmpty)
    }

    @Test func ChatWebRenderer_aPathologicalReplyRendersOnceInUnder300Milliseconds() async throws {
        let r = WebPageRig()
        #expect(await r.loadAndWaitReady())
        let text = WebFixtures.pathological
        #expect(text.utf8.count >= 255 * 1024)
        let started = Date()
        let milliseconds = try #require(try await pageJS(r.page.view!, """
        const t = performance.now();
        window.ClawdChat.apply({order: [1], upserts: [{id: 1, kind: 'assistant', text: text}], turn: 'none'});
        document.body.offsetHeight;
        return performance.now() - t;
        """, ["text": text]) as? Double)
        #expect(milliseconds < 300, "the page rendered it in \(milliseconds) ms (the whole call took \(Date().timeIntervalSince(started)) s)")
    }

    @Test func ChatWebRenderer_aStreamingReplyOver32KiBIsParsedAtMostEvery250MillisecondsAndTheLastTextIsAlwaysShown() async throws {
        let r = WebPageRig()
        #expect(await r.loadAndWaitReady())
        let counted = try #require(try await pageJS(r.page.view!, """
        window.__parses = 0;
        const original = marked.parse;
        marked.parse = function () { window.__parses += 1; return original.apply(this, arguments); };
        window.ClawdChat.apply({order: [1], upserts: [{id: 1, kind: 'assistant', text: 'start'}], turn: 'running'});
        let text = 'x'.repeat(40000);
        const started = performance.now();
        for (let i = 0; i < 100; i++) { text += ' step' + i; window.ClawdChat.apply({upserts: [{id: 1, kind: 'assistant', text: text}]}); }
        const parsedWhileStreaming = window.__parses;
        window.ClawdChat.apply({upserts: [], turn: 'none'});
        return JSON.stringify({parsedWhileStreaming: parsedWhileStreaming, after: window.__parses, shown: document.querySelector('.assistant-row').textContent.trim().endsWith('step99'), tail: document.querySelector('.assistant-row').textContent.slice(-40), turnTail: document.querySelector('.tail').hidden});
        """) as? String)
        let parsed = try #require(try JSONSerialization.jsonObject(with: Data(counted.utf8)) as? [String: Any])
        #expect((parsed["parsedWhileStreaming"] as? Int ?? 99) <= 3, "100 updates in one burst parse \(parsed["parsedWhileStreaming"] ?? "?") times")
        #expect(parsed["shown"] as? Bool == true, "\(parsed) when the turn ends the final text is parsed")
    }

    // MARK: links and Cmd+C

    @Test func ChatWebLinks_aPlainClickOpensThePopoverAndNavigatesNowhereAndACmdClickAsksSwiftToOpenOnlyHttp() async throws {
        let r = WebPageRig()
        #expect(await r.loadAndWaitReady())
        _ = try await pageJS(r.page.view!, "return window.ClawdChat.apply({order: [1], upserts: [{id: 1, kind: 'assistant', text: '[a](https://example.com/x) [b](javascript:alert(1))'}], turn: 'none'});")
        // The page posts through the real handler: a plain click opens the popover and posts no `open`, a Cmd-click posts `open`.
        _ = try await pageJS(r.page.view!, """
        const links = document.querySelectorAll('a[data-href]');
        links.forEach(function (a) { a.dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true})); });
        return links.length;
        """)
        try await Task.sleep(nanoseconds: 300_000_000)
        #expect(r.openedLinks.isEmpty, "a plain click opened nothing")
        let popovers = try await pageJS(r.page.view!, "return document.querySelectorAll('.link-popover').length;") as? Int
        #expect(popovers == 1, "a plain click on the http link opened one popover, and none for the javascript: link")
        _ = try await pageJS(r.page.view!, """
        document.querySelectorAll('a[data-href]').forEach(function (a) { a.dispatchEvent(new MouseEvent('click', {bubbles: true, cancelable: true, metaKey: true})); });
        return 1;
        """)
        #expect(await webWait { r.openedLinks.count == 1 })
        #expect(r.openedLinks.first?.absoluteString == "https://example.com/x", "the javascript: link never reaches the browser: \(r.openedLinks)")
        #expect(r.page.refusedLinks == 1 && r.page.openedLinks == 1)
    }

    @Test func ChatWebLinks_swiftChecksTheTypeAndSizeOfEveryMessageAndIgnoresUnknownNames() {
        let r = WebPageRig()
        func post(_ message: [String: Any]) { r.page.received(message) }
        post(["type": "open", "url": "https://example.com/ok"])
        post(["type": "open", "url": "https://example.com/" + String(repeating: "a", count: 2100)])
        post(["type": "open", "url": 5])
        post(["type": "open", "url": "file:///etc/passwd"])
        post(["type": "open", "url": "https://example.com/x", "extra": 1, "more": 2])
        post(["type": "frobnicate"])
        post(["type": 7])
        r.page.received("open")
        post(["type": "ready", "x": 1])
        #expect(r.openedLinks.map(\.absoluteString) == ["https://example.com/ok"])
        #expect(!r.page.bridge.isReady, "a ready with extra fields is not a ready")
    }

    @Test func ChatWebCopy_theSelectionOfThePageGoesToThePasteboardAndAnEmptyOneChangesNothing() async throws {
        let r = WebPageRig()
        #expect(await r.loadAndWaitReady())
        _ = try await pageJS(r.page.view!, "return window.ClawdChat.apply({order: [1], upserts: [{id: 1, kind: 'assistant', text: 'copy me please'}], turn: 'none'});")
        r.page.copySelection(to: r.pasteboard, refused: {})
        try await Task.sleep(nanoseconds: 200_000_000)
        #expect(r.pasteboard.sets.isEmpty, "nothing selected: the pasteboard is left alone")
        _ = try await pageJS(r.page.view!, "const s = window.getSelection(); s.removeAllRanges(); const r = document.createRange(); r.selectNodeContents(document.querySelector('.assistant-row')); s.addRange(r); return 1;")
        r.page.copySelection(to: r.pasteboard, refused: {})
        #expect(await webWait { !r.pasteboard.sets.isEmpty })
        #expect(r.pasteboard.sets.first?.contains("copy me please") == true)
    }

    // MARK: the web view's own surfaces (R5)

    @Test func ChatWebView_neverTakesTheKeyboardShowsOnlyClawdsTwoItemMenuAndTheAuditIsClean() throws {
        let r = WebPageRig()
        let view = try #require(r.page.view)
        #expect(!view.acceptsFirstResponder && !view.allowsLinkPreview && view.uiDelegate == nil)
        #expect(!view.configuration.websiteDataStore.isPersistent)
        #expect(view.menu(for: NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!) == nil)
        let menu = NSMenu(); menu.addItem(withTitle: "Look Up", action: nil, keyEquivalent: "")
        view.willOpenMenu(menu, with: NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1)!)
        #expect(menu.items.map(\.title) == ["Copy", "Paste"] && menu.items.first?.keyEquivalent == "c", "WebKit's own items are replaced by Orca's two: \(menu.items.map(\.title))")
        #expect(r.page.auditProblems().isEmpty, "\(r.page.auditProblems())")
        #expect(r.page.handlerNames == ["clawd"])
    }

    @Test func ChatWebView_aSecondMessageHandlerOnTheContentControllerFailsTheAudit() throws {
        let r = WebPageRig()
        let view = try #require(r.page.view)
        #expect(r.page.handlerNames == ["clawd"] && r.page.auditProblems().isEmpty)
        view.configuration.userContentController.add(CSPSensors(), name: "debug")
        #expect(r.page.handlerNames == ["clawd", "debug"], "\(r.page.handlerNames)")
        #expect(r.page.auditProblems().contains { $0.contains("message handlers are not exactly") }, "\(r.page.auditProblems())")
        view.configuration.userContentController.removeScriptMessageHandler(forName: "debug")
        #expect(r.page.auditProblems().isEmpty, "the audit reads the registered names: \(r.page.auditProblems())")
    }

    // MARK: the CSP (layer 2)

    @Test func ChatWebCSP_theRawFixtureInsertedByInnerHTMLRunsNothingAndLoadsNothing() async throws {
        let sensors = CSPSensors()
        let listener = try LoopbackListener()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(sensors, forURLScheme: "clawdtest")
        let content = WKUserContentController()
        content.add(sensors, name: "clawd")
        configuration.userContentController = content
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 400), configuration: configuration)
        view.navigationDelegate = sensors
        let host = OffscreenHost(view)
        _ = host
        sensors.allowFirstLoad = true
        view.loadFileURL(chatPageDirectory.appendingPathComponent("index.html"), allowingReadAccessTo: chatPageDirectory)
        #expect(await webWait { sensors.messages.contains("ready") }, "the page is up and its scripts ran under the CSP (script-src 'self' accepts the bundled files)")
        #expect(try await pageJS(view, "return typeof window.ClawdChat;") as? String == "object", "page.js ran")
        let before = sensors.navigationDecisions
        _ = try await pageJS(view, """
        window.__violations = 0;
        document.addEventListener('securitypolicyviolation', function () { window.__violations += 1; });
        document.body.insertAdjacentHTML('beforeend', html);
        const link = document.getElementById('jl'); if (link) link.click();
        const submit = document.getElementById('sb'); if (submit) submit.click();
        return 1;
        """, ["html": CSPFixture.html(port: listener.port)])
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let violations = try await pageJS(view, "return window.__violations;") as? Int ?? 0
        let pwned = try await pageJS(view, "return typeof window.__pwned;") as? String
        let location = try await pageJS(view, "return location.href;") as? String
        #expect(violations >= 1, "the CSP reported violations (the positive control: the sensors can see)")
        #expect(pwned == "undefined", "no inline script, handler or javascript: URL ran")
        #expect(sensors.messages.filter { $0 != "ready" }.isEmpty, "the message handler was called by the fixture: \(sensors.messages)")
        #expect(sensors.schemeRequests.isEmpty, "requests reached the test scheme handler: \(sensors.schemeRequests)")
        #expect(listener.connections == 0, "a connection reached 127.0.0.1")
        #expect(sensors.navigationDecisions == before, "a navigation was decided after the first load")
        #expect(location?.hasSuffix("/chat-page/index.html") == true, "\(location ?? "")")
    }

    @Test func ChatWebCSP_theSensorsSeeARequestWhenThePolicyAllowsIt() async throws {
        // Negative control of the test itself: a page without the CSP does load from the test scheme, so a zero above means the CSP held.
        let sensors = CSPSensors()
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .nonPersistent()
        configuration.setURLSchemeHandler(sensors, forURLScheme: "clawdtest")
        let view = WKWebView(frame: CGRect(x: 0, y: 0, width: 400, height: 400), configuration: configuration)
        view.navigationDelegate = sensors
        let host = OffscreenHost(view)
        _ = host
        sensors.allowFirstLoad = true
        view.loadHTMLString("<html><body></body></html>", baseURL: URL(string: "clawdtest://host/"))
        #expect(await webWait { !view.isLoading })
        _ = try await pageJS(view, "document.body.insertAdjacentHTML('beforeend', '<img src=\"clawdtest://host/seen\">'); return 1;")
        #expect(await webWait { !sensors.schemeRequests.isEmpty }, "an image of the test scheme reaches the handler when nothing forbids it")
    }
}

/// The fixture of the CSP test: everything a hostile reply could try, as raw markup.
enum CSPFixture {
    static func html(port: UInt16) -> String {
        """
        <script>window.__pwned=1; window.webkit.messageHandlers.clawd.postMessage({type:'open',url:'https://example.com'})</script>
        <img src="clawdtest://host/img" onerror="window.__pwned=1; window.webkit.messageHandlers.clawd.postMessage({type:'open',url:'https://example.com'})">
        <img src="http://127.0.0.1:\(port)/img">
        <iframe src="clawdtest://host/frame"></iframe>
        <link rel="stylesheet" href="clawdtest://host/css">
        <style>@import url(clawdtest://host/imported); a { background: url(clawdtest://host/bg) }</style>
        <div style="background:url(clawdtest://host/inline)" onclick="window.__pwned=1">styled</div>
        <a id="jl" href="javascript:window.__pwned=1; window.webkit.messageHandlers.clawd.postMessage({type:'open'})">js link</a>
        <a href="clawdtest://host/link">link</a>
        <form action="clawdtest://host/form" id="fm"><input type="submit" id="sb"></form>
        <svg onload="window.__pwned=1"><script>window.__pwned=1</script></svg>
        <object data="clawdtest://host/object"></object><embed src="clawdtest://host/embed">
        <video src="clawdtest://host/video"></video><audio src="clawdtest://host/audio"></audio>
        <script src="clawdtest://host/script.js"></script>
        """
    }
}

/// The CSP test's sensors: a scheme handler that records every request it gets, a message handler, and a navigation delegate that counts decisions.
final class CSPSensors: NSObject, WKURLSchemeHandler, WKScriptMessageHandler, WKNavigationDelegate {
    var schemeRequests: [String] = []
    var messages: [String] = []
    var navigationDecisions = 0
    var allowFirstLoad = false

    func webView(_ webView: WKWebView, start urlSchemeTask: WKURLSchemeTask) {
        schemeRequests.append(urlSchemeTask.request.url?.absoluteString ?? "?")
        urlSchemeTask.didFailWithError(URLError(.cancelled))
    }
    func webView(_ webView: WKWebView, stop urlSchemeTask: WKURLSchemeTask) {}

    func userContentController(_ controller: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body as? [String: Any]
        messages.append(body?["type"] as? String ?? "?")
    }

    func webView(_ webView: WKWebView, decidePolicyFor navigationAction: WKNavigationAction, decisionHandler: @escaping (WKNavigationActionPolicy) -> Void) {
        if allowFirstLoad { allowFirstLoad = false; decisionHandler(.allow); return }
        navigationDecisions += 1
        decisionHandler(.cancel)
    }
}

/// A 127.0.0.1 listener on an ephemeral port that counts connections (the page must never reach it).
final class LoopbackListener {
    let port: UInt16
    private let descriptor: Int32
    private let source: DispatchSourceRead
    private let lock = NSLock()
    private var count = 0
    var connections: Int { lock.lock(); defer { lock.unlock() }; return count }

    init() throws {
        let fd = socket(AF_INET, SOCK_STREAM, 0)
        guard fd >= 0 else { throw URLError(.cannotConnectToHost) }
        var address = sockaddr_in()
        address.sin_family = sa_family_t(AF_INET)
        address.sin_addr = in_addr(s_addr: UInt32(0x7f000001).bigEndian)
        address.sin_port = 0
        let bound = withUnsafePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { bind(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size)) } }
        guard bound == 0, listen(fd, 8) == 0 else { close(fd); throw URLError(.cannotConnectToHost) }
        var length = socklen_t(MemoryLayout<sockaddr_in>.size)
        _ = withUnsafeMutablePointer(to: &address) { $0.withMemoryRebound(to: sockaddr.self, capacity: 1) { getsockname(fd, $0, &length) } }
        port = UInt16(bigEndian: address.sin_port)
        descriptor = fd
        source = DispatchSource.makeReadSource(fileDescriptor: fd, queue: DispatchQueue(label: "loopback-listener"))
        source.setEventHandler { [weak self] in
            guard let self else { return }
            let client = accept(self.descriptor, nil, nil)
            if client >= 0 { close(client); self.lock.lock(); self.count += 1; self.lock.unlock() }
        }
        source.resume()
    }

    deinit { source.cancel(); close(descriptor) }
}
