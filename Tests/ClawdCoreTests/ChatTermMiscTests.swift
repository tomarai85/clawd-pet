import Testing
import Foundation
import AppKit
import ClawdCore
import ClawdDesktop
import SwiftTerm

@MainActor
struct ChatTermMiscTests {
    /// Orca's rule in Orca's order (src/shared/agent-title-status.ts:245-259): a title that starts with "✳" is idle, checked first; otherwise a
    /// spinner glyph anywhere (braille U+2800-U+28FF, quarter circles U+25D0-U+25D3) is work; anything else is unknown.
    @Test func ChatTermTitle_aSparklePrefixIsIdleBeforeAnySpinnerGlyphIsWork() {
        let table: [(String, ChatTermTitle)] = [
            ("\u{2733} Claude Code", .idle),
            ("\u{2733} Fix the \u{25d0} bug", .idle),          // the sparkle is checked first
            ("\u{2733}\u{280b}", .idle),
            ("\u{25d0} Claude Code", .working), ("\u{25d1} Ok reply", .working), ("\u{25d2} x", .working), ("\u{25d3} x", .working),
            ("\u{280b} Thinking", .working), ("\u{28ff}", .working), ("Fix \u{2819} the bug", .working), ("Task \u{25d1}", .working),
            ("Claude Code", .unknown), ("", .unknown), ("\u{25d4} out of range", .unknown), ("\u{27ff}", .unknown), ("\u{2900}", .unknown),
            (" \u{2733} leading space is not a prefix", .unknown),
        ]
        for (title, expected) in table { #expect(ChatTermTitle.state(of: title) == expected, "\(title.unicodeScalars.map { String($0.value, radix: 16) }): expected \(expected)") }
    }

    /// R9.12 item 6 and item 4's exit-key matcher: the draft rule, row by row. Every row also runs with each text typed one key at a time.
    @Test func ChatTermDraft_aBackslashReturnAndAPossibleSuggestionReturnKeepTheDraft() {
        typealias Send = (bytes: [UInt8], paste: Bool)
        func text(_ value: String) -> Send { (Array(value.utf8), false) }
        func paste(_ value: [UInt8]) -> Send { (value, true) }
        func csi(_ body: String) -> Send { ([0x1B, 0x5B] + Array(body.utf8) + [0x75], false) }
        let cr: Send = ([0x0D], false), backspace: Send = ([0x7F], false), ctrlC: Send = ([0x03], false), escCR: Send = ([0x1B, 0x0D], false)
        let table: [(String, [Send], Bool)] = [
            ("abc CR clears", [text("abc"), cr], false),
            ("abc\\ CR keeps", [text("abc\\"), cr], true),
            ("abc\\ CR def CR clears", [text("abc\\"), cr, text("def"), cr], false),
            ("abc\\ Backspace CR clears", [text("abc\\"), backspace, cr], false),
            ("a paste of abc\\ then CR keeps", [paste(Array("abc\\".utf8)), cr], true),
            ("a bracketed paste of abc\\ then CR keeps", [paste([0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E] + Array("abc\\".utf8) + [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]), cr], true),
            ("a bracketed paste of abc then CR clears", [paste([0x1B, 0x5B, 0x32, 0x30, 0x30, 0x7E] + Array("abc".utf8) + [0x1B, 0x5B, 0x32, 0x30, 0x31, 0x7E]), cr], false),
            ("see @src CR keeps", [text("see @src"), cr], true),
            ("see @src CR CR clears", [text("see @src"), cr, cr], false),
            ("see @src CR x CR clears", [text("see @src"), cr, text("x"), cr], false),
            ("see @src, a space, CR clears", [text("see @src "), cr], false),
            ("me@x.com CR clears", [text("me@x.com"), cr], false),
            ("an @ at the very start keeps", [text("@src"), cr], true),
            ("0x03 clears", [text("abc"), ctrlC], false),
            ("CSI 99;5u clears", [text("abc"), csi("99;5")], false),
            ("CSI 27u leaves it", [text("abc"), csi("27")], true),
            ("CSI 12381::99;5u clears", [text("abc"), csi("12381::99;5")], false),
            ("CSI 99:67;6u clears", [text("abc"), csi("99:67;6")], false),
            ("CSI 99;5:3u (a release) leaves it", [text("abc"), csi("99;5:3")], true),
            ("CSI 100;5u (Ctrl+D) leaves it", [text("abc"), csi("100;5")], true),
            ("see ESC CR @src CR keeps", [text("see"), escCR, text("@src"), cr], true),
        ]
        func keyByKey(_ sends: [Send]) -> [Send] {
            sends.flatMap { send -> [Send] in
                guard !send.paste, send.bytes.first != 0x1B, send.bytes.count > 1, send.bytes != [0x0D] else { return [send] }
                return send.bytes.map { ([$0], false) as Send }
            }
        }
        for (name, sends, expected) in table {
            for (variant, run) in [("as written", sends), ("key by key", keyByKey(sends))] {
                var draft = ChatTermDraft()
                for send in run { draft.sent(send.bytes, fromPaste: send.paste) }
                #expect(draft.pending == expected, "\(name), \(variant): pending is \(draft.pending)")
            }
        }

        // The matcher itself: exactly one CSI u key event whose key field is C or D, with Control and a press.
        let exitKeys: [([UInt8], ChatTermExitKey?)] = [
            ([0x03], .ctrlC), ([0x04], .ctrlD),
            (csi("99;5").bytes, .ctrlC), (csi("100;5").bytes, .ctrlD), (csi("99:67;6").bytes, .ctrlC), (csi("12381::99;5").bytes, .ctrlC),
            (csi("99;5:1").bytes, .ctrlC), (csi("99;5:3").bytes, nil), (csi("99;1").bytes, nil), (csi("99").bytes, nil), (csi("97;5").bytes, nil),
            (csi("27").bytes, nil), ([0x1B, 0x5B, 0x39, 0x39, 0x3B, 0x35, 0x75, 0x61], nil), ([0x03, 0x03], nil), ([0x1B], nil), ([], nil),
        ]
        for (bytes, expected) in exitKeys { #expect(ChatTermExitKey.match(bytes) == expected, "\(bytes): expected \(String(describing: expected))") }
    }

    @Test func ChatSettings_chatViewDefaultsToChatAndTerminalAndStreamStayWhenNamed() {
        #expect(ChatSettings(home: "/Users/example").view == .chat)
        #expect(ChatSettings(object: [:], home: "/Users/example").view == .chat)
        #expect(ChatSettings(object: ["chatView": "chat"], home: "/Users/example").view == .chat)
        #expect(ChatSettings(object: ["chatView": "stream"], home: "/Users/example").view == .stream)
        #expect(ChatSettings(object: ["chatView": "terminal"], home: "/Users/example").view == .terminal)
        for bad in ["Stream", "", "old", "streams", " stream", "Chat"] as [Any] + [1, true, ["stream"]] as [Any] {
            #expect(ChatSettings(object: ["chatView": bad], home: "/Users/example").view == .chat, "\(bad) reads as the default")
        }
        #expect(ChatSettings(data: Data(#"{"chatView":"stream","chatModel":"opus"}"#.utf8), home: "/Users/example").view == .stream)
    }

    @Test func ChatTermAudit_theAuditRefusesAWrongTerminalPanel() async throws {
        let r = try TermControllerRig()
        r.open()
        let panel = r.panel
        panel.disallowKey()      // the audit runs before the open's key right exists
        #expect(r.controller.isOpen && ChatPanelAudit.violations(of: panel).isEmpty, "a conforming terminal panel passes: \(ChatPanelAudit.violations(of: panel))")
        let container = try #require(panel.terminal)
        func refused(_ what: String, _ mutate: () -> Void, _ undo: () -> Void) {
            mutate()
            #expect(!ChatPanelAudit.violations(of: panel).isEmpty, "\(what) is refused")
            undo()
        }
        refused("a non-activating style", { panel.styleMask.insert(.nonactivatingPanel) }, { panel.styleMask.remove(.nonactivatingPanel) })
        let delegate = r.path.delegate
        let stranger = NSObject()
        _ = stranger
        refused("a delegate that is not Clawd's", { container.terminalView!.terminalDelegate = ForeignDelegate() }, { container.terminalView!.terminalDelegate = delegate })
        refused("a menu on the view", { container.terminalView!.menu = NSMenu() }, { container.terminalView!.menu = nil })
        refused("a second terminal view in the container", { container.addSubview(ChatTerminalView(frame: .zero)) }, { container.subviews.last?.removeFromSuperview() })
        refused("a close control that does not take the first mouse", { container.closeButton.takesFirstMouse = false }, { container.closeButton.takesFirstMouse = true })
        let content = panel.contentView
        refused("a hosting view", { panel.contentView = FakeHostingView() }, { panel.contentView = content })
        #expect(ChatPanelAudit.violations(of: panel).isEmpty, "undone, the panel conforms again")
        await r.finish()
    }
}

final class FakeHostingView: NSView {}

/// A terminal delegate that is not Clawd's.
@MainActor
final class ForeignDelegate: TerminalViewDelegate {
    func sizeChanged(source: TerminalView, newCols: Int, newRows: Int) {}
    func setTerminalTitle(source: TerminalView, title: String) {}
    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}
    func send(source: TerminalView, data: ArraySlice<UInt8>) {}
    func scrolled(source: TerminalView, position: Double) {}
    func rangeChanged(source: TerminalView, startY: Int, endY: Int) {}
}
