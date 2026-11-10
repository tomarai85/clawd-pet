import Testing
import Foundation
import AppKit
import WebKit
import ClawdCore
import ClawdDesktop

/// The web chat is drawn at three quarters of Orca's size (Tom, 2026-11-09: "it's TOO BIG make sure the size of text is small"): the page is
/// zoomed to 0.75 and the composer's text is 10.5 pt, so the messages and the input show the same small text; the title bar, the picker, the
/// hint and the queue follow.
@MainActor
struct ChatTextSizeTests {
    @Test func ChatTextSize_thePageIsDrawnAtThreeQuartersOfItsSize() async {
        let rig = WebPageRig()
        #expect(rig.page.view?.pageZoom == 0.75, "page zoom \(String(describing: rig.page.view?.pageZoom))")
        #expect(await rig.loadAndWaitReady(), "the page still loads at that zoom")
        #expect(rig.page.view?.pageZoom == 0.75, "the zoom holds after the load")
    }

    @Test func ChatTextSize_theComposerTextIsTenAndAHalfPoints() {
        let view = ChatComposerView(frame: CGRect(x: 0, y: 0, width: 360, height: 200))
        view.layoutComposer()
        #expect(view.inputView.font?.pointSize == 10.5, "input font \(String(describing: view.inputView.font?.pointSize))")
        #expect(view.plusButton.frame.height == 24 && view.sendButton.frame.height == 24, "controls \(view.plusButton.frame) \(view.sendButton.frame)")
    }

    /// The native pieces around the page follow the same scale (Tom, 2026-11-09: "still the other things are big"): the title bar, the mention
    /// hint and the queue list.
    @Test func ChatTextSize_theTitleBarTheHintAndTheQueueAreAtThreeQuarters() {
        #expect(ChatLook.titleBarHeight == 27 && ChatLook.buttonSize == 18 && ChatLook.tabWidth == 135, "title bar \(ChatLook.titleBarHeight)")
        #expect(ChatLook.titleSize == 9 && ChatLook.titleFont().pointSize == 9, "title \(ChatLook.titleFont().pointSize)")
        #expect(ChatMentionHintView.height == 24, "hint \(ChatMentionHintView.height)")
        #expect(ChatQueueListView.padX == 12 && ChatQueueListView.padY == 3 && ChatQueueRowView.chipLine == 18)
    }
}
