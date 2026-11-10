import Testing
import Foundation
import AppKit
import Darwin
import ClawdCore
import ClawdDesktop
@testable import ClawdCore

/// A pasteboard source of the tests' own: the real pasteboard is never read or written.
final class FakePasteboard: ChatPasteboardSource {
    var text: String?
    var sets: [String] = []
    func string() -> String? { text }
    func setString(_ text: String) { sets.append(text) }
    /// A pasteboard that refuses the write (the copy button shows no check then).
    var refuseWrites = false
    func putString(_ text: String) -> Bool {
        if refuseWrites { return false }
        setString(text)
        return true
    }
}

final class FakeCancellable: ChatTermCancellable {
    var cancelled = false
    func cancel() { cancelled = true }
}

/// A key-down event for a view's own `keyDown`, built by hand. ASCII only: `keyDown` runs `interpretKeyEvents` with the user's current input
/// source, so IME goes through `setMarkedText` and `insertText`.
func keyEvent(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = [], ignoring: String? = nil) -> NSEvent {
    NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: 0, context: nil,
                     characters: characters, charactersIgnoringModifiers: ignoring ?? characters, isARepeat: false, keyCode: code)!
}

/// The controller on the terminal path with the real PTY spawn and the stub as claude, a virtual clock, manual timers and a fake pasteboard. The
/// panel is never ordered on screen, and no window is made key or activated by a test.
@MainActor
final class TermControllerRig {
    let host = FakeChatHost()
    let timers = ManualChatTimers()
    let clock = VirtualClock()
    let pasteboard = FakePasteboard()
    let focus = FakeChatFocus()
    let store: OwnState
    let state: ChatTermState
    let folder: String
    let argsFile: String
    let script: String
    var logs: [String] = []
    var enabled = true
    var currentEvent: ChatCurrentEvent?
    var memoryHandler: (() -> Void)?
    var memorySources: [FakeCancellable] = []
    var presented = 0, dismissed = 0
    var view: ChatView = .terminal
    var permissions: ChatPermissions = .bypass
    var claude: String
    /// When set, no claude path is given and the chat searches only these folders (so a test never finds a real claude).
    var claudeSearch: [String]?
    var folderOverride: String?
    private(set) var controller: ChatController!

    /// `words` are the stub's commands (`title=...`, `bracketed`, `resume-fail` ...). The script it execs through also records the arguments of
    /// every spawn and fails a fresh start while `failfresh` exists in the folder.
    init(words: [String] = [], trackSeconds: TimeInterval = 0, maxPending: Int = ChatTermChild.maxPendingBytes,
         resumeFailSeconds: TimeInterval = ChatTermPath.resumeFailSeconds, geometry: ChatGeometryStoring? = nil) throws {
        store = try artifactStore()
        state = ChatTermState(store: store)
        folder = try FileManager.default.url(for: .itemReplacementDirectory, in: .userDomainMask, appropriateFor: URL(fileURLWithPath: NSTemporaryDirectory()),
                                              create: true).path
        argsFile = folder + "/args.txt"
        script = folder + "/claude-stub.sh"
        let body = """
        #!/bin/sh
        echo "$*" >> '\(argsFile)'
        case "$*" in *--session-id*) if [ -e '\(folder)/failfresh' ]; then echo boom; exit 1; fi ;; esac
        exec '\(TermRig.stub)' tty \(words.map { "'\($0)'" }.joined(separator: " ")) "$@"
        """
        try body.write(toFile: script, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: script)
        claude = script
        focus.now = { [unowned self] in self.clock.now }
        let environment = RuntimeEnvironment(
            displays: { DisplaySet(all: []) }, pointer: { .zero }, aquaLogPath: { "/nonexistent" }, aquaRunning: { false },
            present: { [weak self] _ in self?.presented += 1 }, dismiss: { [weak self] _ in self?.dismissed += 1 },
            chatMakeKey: { _ in }, chatCurrentEvent: { [weak self] in self?.currentEvent }, chatInstallEditMenu: {},
            chatTerm: ChatTermEnvironment(agent: agentExecutable().path, state: state, timers: timers, pasteboard: pasteboard,
                                          memoryPressure: { [weak self] handler in
                                              guard let self else { return nil }
                                              memoryHandler = handler
                                              let source = FakeCancellable(); memorySources.append(source)
                                              return source
                                          },
                                          now: { [weak self] in self?.clock.now ?? 0 }, resumeFailSeconds: resumeFailSeconds, trackSeconds: trackSeconds,
                                          maxPendingBytes: maxPending),
            chatFocus: focus.seams, chatGeometry: geometry, clock: { [unowned self] in self.clock })
        controller = ChatController(host: host, environment: environment, enabled: { [weak self] in self?.enabled ?? false },
                                    settings: { [weak self] in
                                        guard let self else { return ChatSettings() }
                                        var settings = ChatSettings(home: folder)
                                        if let claudeSearch { settings.claudeSearch = claudeSearch } else { settings.claude = claude }
                                        settings.folder = folderOverride ?? folder; settings.permissions = permissions; settings.view = view
                                        return settings
                                    },
                                    log: { [weak self] line in
                                        guard let self else { return }
                                        logs.append(line)
                                        try? store.append("0.0 \(line)\n", to: OwnState.agentLogName)
                                    })
    }

    func lines(_ prefix: String) -> [String] { logs.filter { $0.hasPrefix(prefix) } }
    func open(at time: TimeInterval = 1) { controller.toggle(eventTime: time) }
    var path: ChatTermPath { controller.termPath! }
    var terminalView: ChatTerminalView { path.view! }
    var panel: ChatPanel { controller.livePanel! }
    var screen: String { path.view?.screenText ?? "" }
    var child: ChatTermChild? { path.child }
    var spawns: Int { lines("CHAT term spawn").count }

    func wait(_ seconds: Double = 90, _ condition: () -> Bool) async -> Bool {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return condition()
    }
    /// The screen with every white space removed: a line the panel's 54 columns wrap reads the same as the text, and a title or reply that the
    /// view kept from an earlier child stays visible, so a test that needs a new line waits on a count (`exits`, `spawns`, `argLines`) too.
    var squashed: String { String(screen.filter { !$0.isWhitespace }) }
    func waitScreen(_ text: String, _ seconds: Double = 90) async -> Bool {
        let needle = String(text.filter { !$0.isWhitespace })
        return await wait(seconds) { squashed.contains(needle) }
    }
    var exits: Int { lines("CHAT term exit").count }
    /// Whether the screen already holds `text` (white space ignored).
    func waitedScreen(_ text: String) -> Bool { squashed.contains(String(text.filter { !$0.isWhitespace })) }

    /// The arguments of the spawns so far, one line each.
    var argLines: [String] { fileLines(argsFile) }

    /// A key of the open panel's view, the way AppKit hands it over: the rig's current event is the key's own (its timestamp and flags, not a
    /// mouse event) for its `keyDown` and is cleared afterwards, so no key shares another key's event.
    func press(_ characters: String, code: UInt16, flags: NSEvent.ModifierFlags = [], ignoring: String? = nil) {
        let event = keyEvent(characters, code: code, flags: flags, ignoring: ignoring)
        currentEvent = ChatCurrentEvent(event)
        terminalView.keyDown(with: event)
        currentEvent = nil
    }
    func type(_ text: String) {
        for character in text { press(String(character), code: 0) }
    }
    func pressReturn(flags: NSEvent.ModifierFlags = []) { press("\r", code: 36, flags: flags) }

    /// A remote-control line for the stub (see Tests/ChatStub/main.swift).
    func control(_ line: String) {
        _ = child?.send(Data([0x01]) + Data((line + "\n").utf8))
    }

    func carriers() -> Int { child.map { ChatProc.carriers(of: $0.token, in: ChatProc.table()).count } ?? 0 }

    /// Hard-stops whatever the test left.
    func finish() async {
        host.examActive = false
        controller.close(.quit)
        path.stopHard(reason: "test")
        _ = await wait(15) { path.child?.hasEnded ?? true }
    }
}
