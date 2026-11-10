import Testing
import Foundation
import AppKit
import ClawdCore
import ClawdDesktop

/// The web chat's composer starts at one line: one row inside the box (plus, input, send on the row's bottom edge), the input grows to eight lines,
/// and the status is one line above the box that takes no height while empty. Every size is Orca's at the chat's 0.75 text scale, on whole points
/// (Tom, 2026-11-09: the chat's text was too big).
@MainActor
struct ChatComposerLineTests {
    private let line: CGFloat = 15, inset: CGFloat = 6, controls: CGFloat = 24   // 10.5 pt font on a 15 pt line; py-1 (3 pt) on both sides; size-8 at 0.75

    private func composer(width: CGFloat = 520) -> ChatComposerView {
        let view = ChatComposerView(frame: CGRect(x: 0, y: 0, width: width, height: 200))
        view.layoutComposer()
        return view
    }

    private func lines(_ n: Int) -> String { (1...n).map { "line \($0)" }.joined(separator: "\n") }

    private func input(_ view: ChatComposerView) -> NSScrollView { view.inputView.enclosingScrollView! }

    @Test func ChatComposerLine_theEmptyComposerIsFiftyFourPointsAndTheInputIsOneLine() {
        let view = composer()
        // topPad 6 + (border 2 + boxPad 10 + the 24 pt controls) + bottomPad 12.
        #expect(view.preferredHeight() == 54, "empty composer: \(view.preferredHeight())")
        let scroll = input(view)
        #expect(scroll.frame.height == line + inset, "the input is one line tall: \(scroll.frame.height)")
        #expect(view.plusButton.frame.minY == scroll.frame.minY && view.sendButton.frame.minY == scroll.frame.minY,
                "plus \(view.plusButton.frame) send \(view.sendButton.frame) input \(scroll.frame)")
        #expect(view.plusButton.frame.maxX <= scroll.frame.minX && scroll.frame.maxX <= view.sendButton.frame.minX, "the input sits between the controls")
    }

    @Test func ChatComposerLine_eachLineGrowsTheComposerByOneLineUpToEightAndTheNinthScrolls() {
        let view = composer()
        var previous = view.preferredHeight()
        for n in 1...9 {
            view.setText(lines(n))
            view.layoutComposer()
            let height = view.preferredHeight(), shown = input(view).frame.height
            if n == 1 {
                #expect(height == previous, "one line does not grow the empty composer: \(height)")
            } else if n <= 8 {
                // The row is 24 pt while the input is one line (21 pt), so the second line grows it by 12 and every later line by 15.
                #expect(height - previous == (n == 2 ? line * 2 + inset - controls : line), "line \(n) grows by one line: \(height - previous)")
                #expect(shown == line * CGFloat(n) + inset, "the input shows \(n) lines: \(shown)")
            } else {
                #expect(height == previous, "the ninth line does not grow the composer: \(height - previous)")
                #expect(shown == line * 8 + inset, "the input stays at eight lines: \(shown)")
                #expect(view.inputView.frame.height > shown, "the text is taller than the input, so it scrolls: \(view.inputView.frame.height) vs \(shown)")
            }
            previous = height
        }
        #expect(previous == 6 + (2 + 10 + (line * 8 + inset)) + 12, "eight lines: \(previous)")
    }

    @Test func ChatComposerLine_aGrownInputKeepsTheControlsOnItsBottomEdge() {
        let view = composer()
        view.setText(lines(4))
        view.layoutComposer()
        let scroll = input(view)
        #expect(view.plusButton.frame.minY == scroll.frame.minY && view.sendButton.frame.minY == scroll.frame.minY, "controls on the bottom edge")
        #expect(scroll.frame.height == line * 4 + inset)
    }

    @Test func ChatComposerLine_theStatusTakesNoHeightWhileEmptyAndIsOneLineAboveTheBox() {
        let view = composer()
        let empty = view.preferredHeight()
        view.layoutComposer()
        let boxBottom = input(view).frame.minY
        #expect(view.subviews.contains { $0 is NSTextField && $0.isHidden }, "the empty status is hidden")
        view.setStatus("Attaching a file")
        view.layoutComposer()
        #expect(view.preferredHeight() == empty + 12, "one status line: \(view.preferredHeight() - empty)")
        let status = view.subviews.compactMap { $0 as? NSTextField }.first!
        let box = view.subviews.first { !($0 is NSTextField) }!
        #expect(!status.isHidden && status.frame.minY == box.frame.maxY && status.frame.height == 12, "status \(status.frame) box \(box.frame)")
        #expect(box.frame.minY == 12 && input(view).frame.minY == boxBottom, "the box keeps its place from the bottom: \(box.frame)")
        view.setStatus("")
        #expect(view.preferredHeight() == empty, "empty again: \(view.preferredHeight())")
    }

    @Test func ChatPlus_theAttachControlHasATwelvePointImageInsideTheBoxOnTheRow() {
        let view = composer()
        let plus = view.plusButton
        let image = plus.image
        #expect(image != nil, "the plus control has an image")
        #expect(plus.title.isEmpty && plus.toolTip == "Attach file")
        if let size = image?.size { #expect(size.width >= 8 && size.width <= 15 && size.height >= 8 && size.height <= 15, "about 12 pt: \(size)") }
        let box = view.subviews.first { !($0 is NSTextField) }!
        #expect(box.bounds.contains(plus.frame) && plus.superview === box, "plus \(plus.frame) box \(box.bounds)")
        #expect(plus.frame.minY == input(view).frame.minY, "on the one row")
    }
}
