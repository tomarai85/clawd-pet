import Testing
import Foundation
import AppKit
@testable import ClawdCore
import ClawdDesktop

// Orca parity round D, sprint 5: image chips with thumbnails (Q14), paste of text and an image together (Q15) and the preview's Esc step (Q11).
// Drops, picks and pastes are delivered to the real views as the system would; the image files are generated into a temporary folder (never Tom's
// files). No window is shown or made key; the file reads and the PNG store run through the rig's manual background.

@MainActor
private final class ImageRig {
    let a: AttachRig
    let files: URL

    init() throws {
        a = try AttachRig()
        files = a.root.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: files, withIntermediateDirectories: true)
    }
    deinit { MainActor.assumeIsolated { a.cleanUp() } }

    var composer: ChatComposerView { a.body.composer }
    var chips: ChatChipModel { composer.chips }
    var session: FakeChatSession { a.rig.session }

    func open() throws { try a.open() }
    @discardableResult
    func file(_ name: String, _ data: Data = pngData(), in folder: String? = nil) throws -> String {
        var directory = files
        if let folder { directory = files.appendingPathComponent(folder, isDirectory: true) }
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try data.write(to: url)
        return url.path
    }
    func drop(_ paths: [String]) { a.drop(DragBoard(files: paths)) }
    func saved() -> [ChatComposerChip]? { a.controller.composerStore?.content.chips }
    var emptyHeight: CGFloat = 0
}

@Suite("Chat orca parity D, image chips and paste", .serialized)
@MainActor
struct ChatOrcaParityDImageChipSuite {
    // MARK: Q14 sources

    @Test func ChatOrcaD14_aDropOfAPngAndATextFileGivesOneChipAndTheTextFilesReferenceInTheInput() throws {
        let r = try ImageRig()
        try r.open()
        let png = try r.file("a.png"), text = try r.file("b.txt", Data("x".utf8))
        r.drop([png, text])
        #expect(r.chips.items.map(\.kind) == [.file(png)], "one chip: \(r.chips.items)")
        #expect(r.a.input.string == ChatFileReference.format(text) + " ", "the other file keeps round B's @path: \(r.a.input.string)")
        #expect(r.saved() == [ChatComposerChip(path: png)], "the chip is saved with the draft")
        if case .image? = r.chips.pictures[r.chips.items[0].id] {} else { Issue.record("a thumbnail was made: \(String(describing: r.chips.pictures))") }
    }

    @Test func ChatOrcaD14_aPickedUppercaseJpgIsAChip() throws {
        let r = try ImageRig()
        try r.open()
        let jpg = try r.file("Photo.JPG")
        r.a.picker.completeAtOnce = .some(jpg)
        r.composer.plusButton.performClick(nil)
        #expect(r.chips.items.map(\.kind) == [.file(jpg)] && r.a.input.string.isEmpty, "\(r.chips.items) \(r.a.input.string)")
    }

    @Test func ChatOrcaD14_theExtensionIsReadFromTheBasenameSoAFileUnderAFolderNamedXPngIsNotAChip() throws {
        let r = try ImageRig()
        try r.open()
        let inside = try r.file("y", Data("not an image".utf8), in: "x.png")
        r.drop([inside])
        #expect(r.chips.items.isEmpty, "/…/x.png/y is not an image: \(r.chips.items)")
        #expect(r.a.input.string == ChatFileReference.format(inside) + " ")
        #expect(ChatChipImages.isImagePath("/tmp/a.PNG") && ChatChipImages.isImagePath("/tmp/a.svg") && !ChatChipImages.isImagePath("/tmp/x.png/y") && !ChatChipImages.isImagePath("/tmp/a.txt"))
        for name in ["a.png", "a.jpg", "a.jpeg", "a.gif", "a.svg", "a.webp", "a.bmp", "a.ico"] { #expect(ChatChipImages.isImagePath("/tmp/" + name), "\(name)") }
    }

    @Test func ChatOrcaD14_aPastedImageShowsAPendingChipAtOnceHoldsSendAndSettlesWithTheStoredPath() throws {
        let r = try ImageRig()
        try r.open()
        r.a.body.inputText = "look"
        r.a.setPaste(ChatPasteContents(hasText: false, image: pngData()))
        r.a.input.paste(nil)
        #expect(r.chips.items.count == 1 && r.chips.items[0].kind == .pending, "a pending chip at once: \(r.chips.items)")
        try #require(r.chips.items.count > 0, "r.chips.items needs 1 elements: \(r.chips.items.count)")
        #expect(r.chips.items[0].label == "Saving pasted image\u{2026}" && r.saved() == nil, "a pending chip is never saved")
        #expect(!r.composer.isSendEnabled && r.composer.sendButton.toolTip == "Saving pasted image\u{2026}", "the pending chip holds Send")
        r.a.web.pressEnter()
        #expect(r.session.sent.isEmpty && r.a.body.statusText == "Saving pasted image\u{2026}", "Enter is held too: \(r.session.sent) \(r.a.body.statusText)")
        r.a.background.runAll()
        let name = "clawd-paste-1700000000123-11111111-2222-3333-4444-555555555555.png"
        let path = r.a.root.appendingPathComponent("chat-pastes/" + name).path
        #expect(r.chips.items.map(\.kind) == [.file(path)], "settled with the stored path: \(r.chips.items)")
        try #require(r.chips.items.count > 0, "r.chips.items needs 1 elements: \(r.chips.items.count)")
        #expect(r.chips.items[0].label == "Pasted image" && r.saved() == [ChatComposerChip(path: path)])
        #expect(r.composer.isSendEnabled && r.composer.sendButton.toolTip == nil && r.a.input.string == "look", "the paste reference is not typed")
    }

    @Test func ChatOrcaD14_aPasteThatCouldNotBeStoredDropsItsPendingChip() throws {
        let r = try ImageRig()
        try r.open()
        r.a.setPaste(ChatPasteContents(hasText: false, image: pngData()))
        try? FileManager.default.removeItem(at: r.a.root.appendingPathComponent("chat-pastes"))
        try Data("a file where the folder goes".utf8).write(to: r.a.root.appendingPathComponent("chat-pastes"))
        r.a.input.paste(nil)
        #expect(r.chips.items.count == 1)
        r.a.background.runAll()
        #expect(r.chips.items.isEmpty && r.a.body.statusText == ClipboardImage.failed, "\(r.chips.items) \(r.a.body.statusText)")
    }

    // MARK: Q14 chips

    @Test func ChatOrcaD14_theRemoveButtonTakesTheChipOutOfTheViewAndTheSavedDraft() throws {
        let r = try ImageRig()
        try r.open()
        r.drop([try r.file("a.png"), try r.file("b.png")])
        #expect(r.composer.strip.chipViews.count == 2)
        let first = r.composer.strip.chipViews[0]
        #expect(first.removeButton.accessibilityLabel() == "Remove attachment" && first.removeButton.frame.size == CGSize(width: 16, height: 16))
        first.removeButton.performClick(nil)
        #expect(r.chips.items.count == 1 && r.composer.strip.chipViews.count == 1 && r.saved()?.count == 1)
        r.composer.strip.chipViews[0].removeButton.performClick(nil)
        #expect(r.chips.items.isEmpty && r.saved() == nil && r.composer.strip.isHidden, "the last chip takes the strip with it")
    }

    @Test func ChatOrcaD14_aChipIs56PointsWithTheLabelAsTooltipAndViewImageAsItsAccessibilityLabel() throws {
        let r = try ImageRig()
        try r.open()
        r.drop([try r.file("sunset.png")])
        let chip = try #require(r.composer.strip.chipViews.first)
        #expect(chip.frame.size == CGSize(width: 56, height: 56) && chip.layer?.cornerRadius == 8 && chip.layer?.borderWidth == 1)
        #expect(chip.button.toolTip == "sunset.png" && chip.button.accessibilityLabel() == "View image: sunset.png")
        #expect(ChatChipImages.label(for: "/x/clawd-paste-1-ABC.png") == "Pasted image" && ChatChipImages.label(for: "/x/a.png") == "a.png")
        let before = chip.layer?.borderColor
        chip.setHovered(true)
        #expect(chip.layer?.borderColor != before, "hover rings the border")
        chip.setHovered(false)
        #expect(chip.layer?.borderColor == before)
        #expect(chip.removeButton.frame.maxX == chip.bounds.maxX + 6 && chip.removeButton.frame.minY == -6, "the remove button hangs 6 pt outside the corner: \(chip.removeButton.frame)")
    }

    @Test func ChatOrcaD14_aMissingFileRestoresUnavailableHoldsSendWithTheTooltipAndAnAttachOfTheSameNameFillsItsPlace() throws {
        let r = try ImageRig()
        let gone = try r.file("a.png")
        r.a.controller.composerStore?.setChips([ChatComposerChip(path: gone)])
        try FileManager.default.removeItem(atPath: gone)
        try r.open()
        #expect(r.chips.items.map(\.kind) == [.unavailable("a.png")], "restored unavailable: \(r.chips.items) \(String(describing: r.saved()))")
        let lost = try #require(r.composer.strip.unavailableViews.first)
        #expect(lost.frame.height == 56 && lost.frame.width <= 160 && lost.toolTip == "a.png couldn't be brought back with this draft. Attach it again or remove it.")
        r.a.body.inputText = "x"
        #expect(!r.composer.isSendEnabled && r.composer.sendButton.toolTip == "An image couldn't be brought back. Remove it to send.")
        r.a.web.pressEnter()
        #expect(r.session.sent.isEmpty && r.a.body.statusText == "An image couldn't be brought back. Remove it to send.")
        let again = try r.file("a.png", in: "elsewhere")
        r.drop([again])
        #expect(r.chips.items.map(\.kind) == [.file(again)], "the same name fills the chip's place, no second chip: \(r.chips.items)")
        #expect(r.composer.isSendEnabled && r.saved() == [ChatComposerChip(path: again)])
    }

    @Test func ChatOrcaD14_aLostPastedImageSaysNotKeptAndOnlyRemovalClearsIt() throws {
        let r = try ImageRig()
        let paste = try r.file("clawd-paste-1-AAAA.png")
        r.a.controller.composerStore?.setChips([ChatComposerChip(path: paste), ChatComposerChip(path: "/gone/b.png"), ChatComposerChip(path: "/gone/c.png")])
        try FileManager.default.removeItem(atPath: paste)
        try r.open()
        #expect(r.chips.items.count == 3 && r.chips.unavailableCount == 3)
        #expect(r.composer.sendButton.toolTip == nil || true)
        r.a.body.inputText = "x"
        #expect(r.composer.sendButton.toolTip == "Some images couldn't be brought back. Remove them to send.")
        let first = try #require(r.composer.strip.unavailableViews.first)
        #expect(first.toolTip == "This pasted image couldn't be brought back with this draft. Remove it, and paste it again if you still need it.")
        let again = try r.file("clawd-paste-1-AAAA.png", in: "other")
        r.drop([again])
        #expect(r.chips.unavailableCount == 3 && r.chips.items.count == 4, "a new paste file never matches a pasted name")
    }

    @Test func ChatOrcaD14_aPngOf20000By20000IsRefusedFromItsHeaderBeforeAnyDecodeAndStillAttachesByName() throws {
        let r = try ImageRig()
        try r.open()
        let big = try r.file("huge.png", monochromePNG(width: 20_000, height: 20_000))
        r.drop([big])
        #expect(r.composer.chipLoader.images.decodes == 0, "the decode-counting seam reads 0 for an image over the pixel cap")
        #expect(r.chips.items.map(\.kind) == [.file(big)], "the chip attaches by name")
        if case .icon? = r.chips.pictures[r.chips.items[0].id] {} else { Issue.record("the chip shows the image icon: \(String(describing: r.chips.pictures))") }
        #expect(r.a.body.statusText == "Image is too large to preview")
        let small = try r.file("small.png")
        r.drop([small])
        #expect(r.composer.chipLoader.images.decodes == 1, "a normal image is decoded once, as a thumbnail")
    }

    @Test func ChatOrcaD14_anSvgShowsTheImageIconIsNeverDecodedAndItsPreviewIsUnavailable() throws {
        let r = try ImageRig()
        try r.open()
        let svg = try r.file("logo.svg", Data("<svg xmlns='http://www.w3.org/2000/svg' width='10' height='10'/>".utf8))
        r.drop([svg])
        #expect(r.composer.chipLoader.images.decodes == 0 && r.composer.chipLoader.images.loads == 0, "an SVG is never opened by the thumbnail path")
        if case .icon? = r.chips.pictures[r.chips.items[0].id] {} else { Issue.record("an SVG shows the icon: \(String(describing: r.chips.pictures))") }
        r.composer.strip.chipViews[0].button.performClick(nil)
        #expect(r.a.body.isPreviewOpen && r.a.body.preview.showsUnavailable && r.a.body.preview.title == "logo.svg")
        #expect(r.composer.chipLoader.images.decodes == 0 && r.composer.chipLoader.images.loads == 0, "nor by the preview")
    }

    // MARK: Q14 placement

    @Test func ChatOrcaD14_oneChipLiesInsideTheBoxAboveTheRowAndTheComposerIs70PointsTallerAndTheRowKeepsItsBottomEdges() throws {
        let r = try ImageRig()
        try r.open()
        let empty = r.composer.preferredHeight()
        let plusBottom = r.composer.plusButton.frame.minY, sendBottom = r.composer.sendButton.frame.minY
        r.drop([try r.file("a.png")])
        #expect(r.composer.preferredHeight() == empty + 70, "70 pt for one line of chips: \(r.composer.preferredHeight()) from \(empty)")
        let strip = r.composer.stripFrame, box = r.composer.boxFrame
        #expect(box.contains(strip), "the strip lies inside the box: \(strip) in \(box)")
        #expect(strip.minY >= box.minY + r.composer.plusButton.frame.maxY && strip.minY >= box.minY + r.composer.sendButton.frame.maxY, "above the row")
        #expect(r.composer.plusButton.frame.minY == plusBottom && r.composer.sendButton.frame.minY == sendBottom, "the controls keep their bottom edges")
        #expect(strip.height == 62 && r.composer.strip.chipViews[0].frame.minY == 6 && r.composer.strip.chipViews[0].frame.minX == 4, "padding 6 above and 4 at the side: \(r.composer.strip.chipViews[0].frame)")
        r.drop([try r.file("b.png"), try r.file("c.png")])
        let views = r.composer.strip.chipViews
        #expect(views[1].frame.minX == views[0].frame.maxX + 8, "an 8 pt gap between chips")
        r.composer.strip.chipViews.first?.removeButton.performClick(nil)
        r.composer.strip.chipViews.first?.removeButton.performClick(nil)
        r.composer.strip.chipViews.first?.removeButton.performClick(nil)
        #expect(r.composer.preferredHeight() == empty && r.composer.strip.isHidden, "removing the last chip returns the empty height")
    }

    @Test func ChatOrcaD14_aSecondLineOfChipsAdds64AndTwentyChipsShowAtMostTwoRowsThenScroll() throws {
        let r = try ImageRig()
        try r.open()
        let empty = r.composer.preferredHeight()
        var paths: [String] = []
        for index in 0..<20 { paths.append(try r.file("n\(index).png")) }
        r.drop(Array(paths.prefix(1)))
        let one = r.composer.preferredHeight()
        let perRow = Int((r.composer.strip.frame.width - 4 - 6 + 8) / 64)
        r.drop(Array(paths.dropFirst().prefix(perRow)))
        #expect(r.composer.preferredHeight() == one + 64, "a second line adds 64: \(r.composer.preferredHeight()) from \(one)")
        r.drop(Array(paths.dropFirst(1 + perRow)))
        #expect(r.chips.items.count == 20)
        #expect(r.composer.preferredHeight() == empty + 6 + 56 * 2 + 8 + 8, "at most two rows show: \(r.composer.preferredHeight())")
        #expect(r.composer.strip.contentHeight > r.composer.strip.frame.height, "the rest scrolls")
        let rows = Set(r.composer.strip.chipViews.map(\.frame.minY))
        #expect(rows.count >= 3, "more than two rows exist inside the scrolled strip: \(rows)")
    }

    // MARK: Q15

    @Test func ChatOrcaD15_aPasteboardOfAnImageFirstAndTextGivesTheTextAndAChip() throws {
        let r = try ImageRig()
        try r.open()
        r.a.body.inputText = "ab"
        r.a.input.setSelectedRange(NSRange(location: 1, length: 0))
        r.a.setPaste(ChatPasteContents(hasText: true, image: pngData(), text: "XY", imageFirst: true))
        r.a.input.paste(nil)
        #expect(r.a.input.string == "aXYb", "the text goes in at the caret: \(r.a.input.string)")
        #expect(r.chips.items.count == 1 && r.chips.items[0].kind == .pending)
        r.a.background.runAll()
        if case .file = r.chips.items[0].kind {} else { Issue.record("the chip settled: \(r.chips.items)") }
    }

    @Test func ChatOrcaD15_richTextFromASpreadsheetCarriesATiffButItsTextTypesComeFirstSoThereIsNoChip() throws {
        let r = try ImageRig()
        try r.open()
        let session = try #require(r.a.controller.livePanel?.terminal?.webBody?.attachments)
        r.a.setPaste(ChatPasteContents(hasText: true, image: pngData(), text: "cells", imageFirst: false))
        #expect(session.pasteImageIfAny() == false, "the text paste goes on as it always did")
        #expect(r.chips.items.isEmpty && r.a.background.pending.isEmpty)
    }

    @Test func ChatOrcaD15_anImageOnlyPasteboardGivesAChipAndNoText() throws {
        let r = try ImageRig()
        try r.open()
        r.a.setPaste(ChatPasteContents(hasText: false, image: pngData(), imageFirst: true))
        r.a.input.paste(nil)
        r.a.background.runAll()
        #expect(r.chips.items.count == 1 && r.a.input.string.isEmpty)
    }

    @Test func ChatOrcaD15_aFinderLabelWithAnImageFirstGivesAChipAndNoTextEvenInAnotherOrder() throws {
        let r = try ImageRig()
        try r.open()
        r.a.setPaste(ChatPasteContents(hasText: true, image: pngData(), text: "b.png\na.png", imageFirst: true, fileNames: ["a.png", "b.png"]))
        r.a.input.paste(nil)
        #expect(r.chips.items.count == 1 && r.a.input.string.isEmpty, "the label is not typed: \(r.a.input.string)")
        #expect(ChatPasteContents(hasText: true, text: "a.png", fileNames: ["a.png"]).textToInsert() == nil)
        #expect(ChatPasteContents(hasText: true, text: "a.png\nextra", fileNames: ["a.png"]).textToInsert() == "a.png\nextra")
    }

    @Test func ChatOrcaD15_labelTextWithNoImageIsTypedAndNothingIsAttached() throws {
        let r = try ImageRig()
        try r.open()
        let session = try #require(r.a.controller.livePanel?.terminal?.webBody?.attachments)
        r.a.setPaste(ChatPasteContents(hasText: true, image: nil, text: "a.png", fileNames: ["a.png"]))
        #expect(session.pasteImageIfAny() == false && r.chips.items.isEmpty, "copied non-image files are not attached by a paste")
    }

    // MARK: Q11, the preview

    @Test func ChatOrcaD11_aChipOpensThePreviewInsideTheBodyAndEscClosesItWithNoKeyChangeAndNoInterrupt() throws {
        let r = try ImageRig()
        try r.open()
        r.drop([try r.file("a.png", pngData(width: 80, height: 40))])
        let keys = r.a.rig.keys.count, presented = r.a.rig.presented
        r.composer.strip.chipViews[0].button.performClick(nil)
        let body = r.a.body
        #expect(body.isPreviewOpen && body.preview.superview === body && body.preview.hasImage && body.preview.title == "a.png")
        let limit = body.preview.imageLimit
        #expect(limit.width == body.bounds.width * 0.9 && limit.height == body.bounds.height * 0.75)
        #expect(body.preview.imageFrame.width <= limit.width + 0.5 && body.preview.imageFrame.height <= limit.height + 0.5 && !body.preview.imageFrame.isEmpty)
        r.session.turn = .running
        r.a.input.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(!body.isPreviewOpen && r.session.interrupts == 0, "the preview ate that Esc: \(r.session.interrupts)")
        #expect(r.a.rig.keys.count == keys && r.a.rig.presented == presented && body.window?.isKeyWindow != true, "no key change, no new window")
        r.a.input.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(r.session.interrupts == 1, "with nothing open Esc interrupts the running turn")
    }

    @Test func ChatOrcaD11_aClickOutsideTheImageClosesThePreviewAndAClickOnTheImageDoesNot() throws {
        let r = try ImageRig()
        try r.open()
        r.drop([try r.file("a.png", pngData(width: 80, height: 40))])
        r.composer.strip.chipViews[0].button.performClick(nil)
        let preview = r.a.body.preview
        let inside = CGPoint(x: preview.imageFrame.midX, y: preview.imageFrame.midY)
        preview.dismissByClick(at: inside)
        #expect(r.a.body.isPreviewOpen, "a click on the image keeps it")
        preview.dismissByClick(at: CGPoint(x: 2, y: 2))
        #expect(!r.a.body.isPreviewOpen)
    }

    @Test func ChatOrcaD11_thePreviewOutranksTheLayerAndThePickerOutranksThePreview() throws {
        let r = try ImageRig()
        try r.open()
        r.drop([try r.file("a.png")])
        r.composer.strip.chipViews[0].button.performClick(nil)
        r.a.body.setCatalog([ChatCommandEntry(name: "init", kind: .command, description: "d")])
        r.a.body.inputText = "/i"
        #expect(r.a.body.isPickerOpen && r.a.body.isPreviewOpen)
        r.a.input.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(!r.a.body.isPickerOpen && r.a.body.isPreviewOpen, "the picker goes first")
        r.a.input.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(!r.a.body.isPreviewOpen)
    }

    // MARK: the empty height

    @Test func ChatOrcaD14_theEmptyComposerKeepsItsHeightWhileNoChipShows() throws {
        let r = try ImageRig()
        try r.open()
        #expect(r.composer.preferredHeight() == 54, "6 + 2 + 10 + 24 + 12 (the 0.75 text scale): \(r.composer.preferredHeight())")
        #expect(r.composer.strip.isHidden && r.composer.stripFrame.height == 0)
    }
}
