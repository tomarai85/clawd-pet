import Testing
import Foundation
import AppKit
import ClawdCore
import ClawdRendering
import ClawdDesktop

// The chat panel as a place to type: the input has the keyboard whenever the panel is key, it is plainly visible with a placeholder, and the
// "new output" marker stays away until there is output out of sight.

@Suite("ChatInput", .serialized)
@MainActor
struct ChatInputSuite {
    @Test func ChatInput_theInputHasTheKeyboardAfterOpenAndAfterEveryKey() throws {
        let r = ControllerRig()
        r.open()
        let panel = try #require(r.controller.livePanel)
        #expect(panel.firstResponder === r.view.inputView, "after open: \(String(describing: panel.firstResponder))")
        // The keyboard goes elsewhere (a click on the transcript), the panel resigns and becomes key again: the key notification, with
        // a mouse-down in the panel as the current event, reaches the controller exactly as the focus monitor's observer calls it.
        #expect(panel.makeFirstResponder(r.view.transcriptView) && panel.firstResponder === r.view.transcriptView)
        r.currentEvent = ChatCurrentEvent(isMouseDown: true, window: panel)
        #expect(r.controller.keyVerdict(for: panel) == .exempt)
        #expect(panel.firstResponder === r.view.inputView, "after key again: \(String(describing: panel.firstResponder))")
    }

    @Test func ChatInput_aDictationPasteIntoTheKeyWindowLandsInTheInput() throws {
        let r = ControllerRig()
        r.open()
        let panel = try #require(r.controller.livePanel)
        let target = try #require(panel.firstResponder as? NSTextView)
        target.insertText("こんにちは", replacementRange: NSRange(location: NSNotFound, length: 0))
        #expect(r.view.inputText == "こんにちは" && r.view.transcriptView.string.isEmpty)
    }

    @Test func ChatInput_thePlaceholderShowsWhileEmptyAndHidesOnceThereIsText() {
        let r = ControllerRig()
        r.open()
        #expect(ChatInputTextView.placeholder == "Message Claude Code (Enter to send)")
        #expect(r.view.inputView.isPlaceholderShown)
        r.type("a")
        #expect(!r.view.inputView.isPlaceholderShown)
        r.view.inputText = ""
        #expect(r.view.inputView.isPlaceholderShown, "empty again")
    }

    @Test func ChatInput_theBoxIsPlainlyVisibleAndAtLeastTwoLinesHigh() throws {
        let r = ControllerRig()
        r.open()
        r.view.updateLayer()
        r.view.layoutSubtreeIfNeeded()
        #expect(r.view.inputBorderWidth >= 1)
        let panel = try #require(r.view.panelBackgroundColor), fill = try #require(r.view.inputBackgroundColor), border = try #require(r.view.inputBorderColor)
        #expect(fill != panel, "the fill contrasts with the panel")
        #expect(border != panel && border != fill)
        #expect(r.view.inputHeightNow >= 34, "two lines: \(r.view.inputHeightNow)")
    }

    @Test func ChatInput_theNewOutputMarkerIsHiddenOnOpenWithAnEmptyAndWithAOneEntryTranscript() {
        let empty = ControllerRig()
        empty.open()
        #expect(!empty.view.isNewOutputShown, "empty transcript")
        let one = ControllerRig()
        one.session.transcript.appendUser("hello")
        one.open()
        #expect(one.view.transcriptView.string.contains("hello") && !one.view.isNewOutputShown, "one entry")
    }
}
