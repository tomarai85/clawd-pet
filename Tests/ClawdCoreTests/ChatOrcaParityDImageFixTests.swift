import Testing
import Foundation
import AppKit
import Darwin
@testable import ClawdCore
@testable import ClawdDesktop

// Orca parity round D, sprint 5, code review r1: the image send's races (H1), the deferred send (M1), the chip strip during a read (M2), Edit on
// a card with images (M3), a paste saved after a close (M4), the send's memory (M5), the read's deadline (L7) and the lows. The file work is
// stepped by hand through the rig's manual background; the images are generated into temporary folders.

@MainActor
private final class FixRig {
    let a: AttachRig
    init() throws { a = try AttachRig() }
    /// The page is torn down with the opening, so no load callback reaches the rig after the test.
    func cleanUp() {
        if a.controller.isOpen { a.controller.close(.button) }
        a.cleanUp()
    }

    var session: FakeChatSession { a.rig.session }
    var queue: ChatQueue { a.controller.queue }
    var timers: ManualChatTimers { a.rig.focus.timers }

    func picture(_ name: String) throws -> String {
        let folder = a.root.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try pngData().write(to: url)
        return url.path
    }

    /// A turn that runs, and a steer lost with the child: a doubt card that carried `chips`.
    @discardableResult
    func doubtCard(text: String = "had pictures", chips: [ChatComposerChip]) throws -> ChatSendRequest {
        try a.open()
        a.body.inputText = "first"
        a.web.pressEnter()
        if let first = session.requests.last { session.deliver(first) }
        let lost = ChatSendRequest(text: text, origin: .draft, steer: true, chips: chips)
        session.settle(lost) { .doubt($0, .childEnded) }
        try #require(queue.doubtCards.map(\.id) == [lost.uuid], "the doubt card is there: \(queue.doubtCards)")
        return lost
    }

    func pressCardSend(_ index: Int = 0) { a.body.queueList.rows[index].steerButton.performClick(nil) }
    var imageSends: [ChatSendRequest] { session.requests.filter { $0.payload != nil } }
}

private func mallocFootprint() -> UInt64 {
    var info = task_vm_info_data_t()
    var count = mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size / MemoryLayout<integer_t>.size)
    let result = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) { task_info(mach_task_self_, task_flavor_t(TASK_VM_INFO), $0, &count) }
    }
    return result == KERN_SUCCESS ? info.phys_footprint : 0
}

@Suite("Chat orca parity D, image send fixes", .serialized)
@MainActor
struct ChatOrcaParityDImageFixSuite {
    // MARK: H1

    @Test func ChatOrcaD16_H1_aSecondPressOnACardWhileItsImagesAreReadSendsItOnce() throws {
        let r = try FixRig()
        defer { r.cleanUp() }
        let chip = ChatComposerChip(path: try r.picture("a.png"))
        try r.doubtCard(chips: [chip])
        r.pressCardSend()
        r.pressCardSend()
        #expect(r.a.background.pending.count == 1, "the second press does not start a second read: \(r.a.background.pending.count)")
        r.a.background.runAll()
        #expect(r.imageSends.count == 1, "the card's images and text are written once: \(r.imageSends.count)")
    }

    @Test func ChatOrcaD16_H1_aLateReplayThatSettlesTheCardDuringTheReadStopsTheSend() throws {
        let r = try FixRig()
        defer { r.cleanUp() }
        let chip = ChatComposerChip(path: try r.picture("a.png"))
        let lost = try r.doubtCard(chips: [chip])
        r.pressCardSend()
        r.session.deliver(lost)
        r.a.background.runAll()
        #expect(r.imageSends.isEmpty, "the card is gone: nothing is written for it")
        #expect(r.a.body.statusText == "This message was already sent.", "\(r.a.body.statusText)")
    }

    @Test func ChatOrcaD16_H1_aCardReadEndingFirstDoesNotUnlockTheDraftsRead() throws {
        let r = try FixRig()
        defer { r.cleanUp() }
        let chip = ChatComposerChip(path: try r.picture("a.png"))
        try r.doubtCard(chips: [chip])
        r.a.drop(DragBoard(files: [try r.picture("draft.png")]))
        r.pressCardSend()
        r.a.web.pressEnter()
        #expect(r.a.background.pending.count == 2 && r.a.body.composer.isLocked, "both reads are out")
        r.a.background.runWork(); r.a.background.runDone()
        #expect(r.a.body.composer.isLocked, "the draft's read is still out: the input stays locked")
        r.a.web.pressEnter()
        #expect(r.a.background.pending.count == 1, "a second Enter does not start a second read of the draft: \(r.a.background.pending.count)")
        r.a.background.runAll()
        #expect(r.imageSends.count == 2 && !r.a.body.composer.isLocked)
    }

    // MARK: M1

    @Test func ChatOrcaD16_M1_aDeferredSendOfACardWithImagesWhileTheTurnStopsAndThePanelClosesKeepsTheCardAndWritesNothing() throws {
        let r = try FixRig()
        defer { r.cleanUp() }
        let chip = ChatComposerChip(path: try r.picture("a.png"))
        let lost = try r.doubtCard(chips: [chip])
        let before = r.session.requests.count
        r.session.turn = .stopping
        r.pressCardSend()
        r.a.controller.close(.button)
        r.session.finish(.success(seconds: 1))
        r.a.background.runAll()
        #expect(r.session.requests.count == before, "no text-only send of a card that carried images: \(r.session.requests.dropFirst(before).map(\.text))")
        #expect(r.queue.card(lost.uuid)?.chips == [chip], "the card stays with its images")
    }

    @Test func ChatOrcaD16_M1_aSessionNeverWritesChipsWithoutTheirPayload() throws {
        let rig = try ChatRig(stub: "image-echo.py")
        #expect(!rig.session.send(ChatSendRequest(text: "text", chips: [ChatComposerChip(path: "/x/a.png")])), "chips need their payload")
        #expect(rig.session.turn == .none && rig.session.transcript.entries.isEmpty, "and nothing was started for it")
    }

    // MARK: M2

    @Test func ChatOrcaD16_M2_aChipCannotBeRemovedWhileTheDraftsFilesAreRead() throws {
        let r = try FixRig()
        defer { r.cleanUp() }
        try r.a.open()
        let first = try r.picture("a.png"), second = try r.picture("b.png")
        r.a.drop(DragBoard(files: [first, second]))
        r.a.body.inputText = "two"
        r.a.web.pressEnter()
        try #require(r.a.body.composer.strip.chipViews.dropFirst().first).removeButton.performClick(nil)
        #expect(r.a.body.composer.chips.items.count == 2, "the remove button does nothing while the files are read")
        r.a.background.runAll()
        #expect(r.imageSends.last?.chips.count == 2 && r.a.body.composer.chips.items.isEmpty, "the strip was locked: both went and both left: \(r.imageSends.last?.chips ?? [])")
    }

    @Test func ChatOrcaD16_M2_theRemoveButtonWorksAgainOnceTheReadIsOver() throws {
        let r = try FixRig()
        defer { r.cleanUp() }
        try r.a.open()
        let empty = r.a.root.appendingPathComponent("empty.png")
        try Data().write(to: empty)
        r.a.drop(DragBoard(files: [empty.path]))
        r.a.web.pressEnter()
        r.a.background.runAll()
        #expect(!r.a.body.composer.isLocked && r.a.body.composer.chips.items.count == 1, "the refused send (an empty image) leaves the chip")
        let button = try #require(r.a.body.composer.strip.chipViews.first).removeButton
        button.performClick(nil)
        #expect(r.a.body.composer.chips.items.isEmpty)
    }

    // MARK: M3

    @Test func ChatOrcaD16_M3_editOnACardWithImagesPutsThemBackInTheComposerAndAnImagesOnlyCardIsNotLost() throws {
        let r = try FixRig()
        defer { r.cleanUp() }
        let chips = [ChatComposerChip(path: try r.picture("a.png")), ChatComposerChip(unavailable: "gone.png")]
        let withText = try r.doubtCard(chips: chips)
        r.a.body.queueList.onEdit?(withText.uuid)
        #expect(r.a.body.inputText == "had pictures" && r.a.body.composer.chips.persisted == chips, "text and images are back: \(r.a.body.composer.chips.persisted)")
        #expect(r.a.controller.composerStore?.content.chips == chips && r.queue.card(withText.uuid) == nil)

        let only = ChatSendRequest(text: "", origin: .draft, steer: true, chips: [ChatComposerChip(path: try r.picture("only.png"))])
        r.session.settle(only) { .doubt($0, .childEnded) }
        r.a.body.queueList.onEdit?(only.uuid)
        #expect(r.a.body.composer.chips.persisted.count == 3 && r.queue.card(only.uuid) == nil, "the images-only card's image joined the draft: \(r.a.body.composer.chips.persisted)")
    }

    // MARK: M4

    @Test func ChatOrcaD16_M4_aPasteSavedAfterTheCloseJoinsTheSavedDraftAsAChip() throws {
        let r = try FixRig()
        defer { r.cleanUp() }
        try r.a.open()
        r.a.setPaste(ChatPasteContents(hasText: false, image: pngData()))
        r.a.input.paste(nil)
        r.a.controller.close(.button)
        r.a.background.runAll()
        let saved = r.a.controller.composerStore?.content.chips
        #expect(saved?.count == 1 && saved?.first?.path?.contains("chat-pastes/") == true, "the pasted image is a chip of the stored draft: \(String(describing: saved))")
    }

    // MARK: M5

    @Test func ChatOrcaD16_M5_theMessageOfThreeImagesAtTheCapPeaksUnderTheSpecsFigure() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("clawd-s5-peak-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        var paths: [String] = []
        for (name, size) in [("a.png", 5 * 1024 * 1024), ("b.png", 5 * 1024 * 1024), ("c.png", 1024 * 1024)] {
            var bytes = Data(count: size)
            bytes.withUnsafeMutableBytes { raw in for i in stride(from: 0, to: raw.count, by: 4093) { raw[i] = UInt8(truncatingIfNeeded: i) } }
            let url = folder.appendingPathComponent(name)
            try bytes.write(to: url)
            paths.append(url.path)
        }
        let baseline = mallocFootprint()
        let sampler = PeakSampler()
        sampler.start()
        var request = ChatSendRequest(text: "see", chips: paths.map { ChatComposerChip(path: $0) })
        request.payload = try ChatImageSend.prepare(paths: paths, text: "see").get()
        let frame = try #require(ChatSession.userFrame(request, conversationId: "conv"))
        let frameBytes = frame.reduce(0) { $0 + $1.count }
        request.payload = nil
        let peak = sampler.stop()
        let delta = Int64(peak) - Int64(baseline)
        print("M5 peak growth during prepare + frame: \(delta) bytes for \(ChatImageSend.maxTotalBytes) raw, frame \(frameBytes) bytes")
        #expect(delta < 41_000_000, "the spec's 41 MB figure for 11 MiB: measured \(delta)")
        #expect(frameBytes > ChatImageSend.maxTotalBytes)
    }

    @Test func ChatOrcaD16_M5_theReaderKeepsItsBufferOnlyAfterOrdinaryLines() {
        #expect(ChatSession.keepsReaderBuffer(afterLine: 2_000) && !ChatSession.keepsReaderBuffer(afterLine: 15 * 1024 * 1024))
    }

    // MARK: L7

    @Test func ChatOrcaD16_L7_aDraftReadThatNeverReturnsIsRefusedAfterTheDeadlineMarksTheChipAndKeepsTheDraft() throws {
        let r = try FixRig()
        defer { r.cleanUp() }
        try r.a.open()
        let path = try r.picture("a.png")
        r.a.drop(DragBoard(files: [path]))
        r.a.body.inputText = "stuck"
        r.a.web.pressEnter()
        #expect(r.a.body.composer.isLocked && r.timers.live.contains(ChatController.imageReadSeconds))
        r.timers.fire(exactly: ChatController.imageReadSeconds)
        #expect(!r.a.body.composer.isLocked && r.session.requests.isEmpty, "nothing is sent and the input is free")
        #expect(r.a.body.composer.chips.persisted == [ChatComposerChip(unavailable: "a.png")] && r.a.body.inputText == "stuck", "the chip is marked, the draft stays")
        #expect(r.a.body.statusText == "An image couldn't be brought back. Remove it to send.", "\(r.a.body.statusText)")
        r.a.background.runAll()
        #expect(r.session.requests.isEmpty, "the late result of the stalled read is ignored")
        r.a.body.inputText = "again"
        r.a.web.pressEnter()
        #expect(r.a.background.pending.isEmpty, "the hold of the unavailable chip refuses a new send at once")
    }

    @Test func ChatOrcaD16_L7_aCardReadThatNeverReturnsIsRefusedAndTheCardStaysWithItsChipMarked() throws {
        let r = try FixRig()
        defer { r.cleanUp() }
        let lost = try r.doubtCard(chips: [ChatComposerChip(path: try r.picture("a.png"))])
        let before = r.session.requests.count
        r.pressCardSend()
        r.timers.fire(exactly: ChatController.imageReadSeconds)
        r.a.background.runAll()
        #expect(r.session.requests.count == before)
        #expect(r.queue.card(lost.uuid)?.chips == [ChatComposerChip(unavailable: "a.png")], "the card is kept, its image marked")
        #expect(r.a.body.statusText == "An image couldn't be brought back. Remove it to send.", "\(r.a.body.statusText)")
    }

    // MARK: recheck N1-N3

    @Test func ChatOrcaD16_N1_aCardsTextEditedIntoTheDraftDuringItsImageReadSurvivesTheSendClearingTheInput() throws {
        let r = try FixRig()
        defer { r.cleanUp() }
        let lost = try r.doubtCard(text: "card words", chips: [])
        r.a.drop(DragBoard(files: [try r.picture("a.png")]))
        r.a.body.inputText = "go"
        r.a.web.pressEnter()
        r.a.body.queueList.onEdit?(lost.uuid)
        r.a.background.runAll()
        #expect(r.imageSends.last?.text == "go", "the draft that was sent is the one typed: \(r.imageSends.last?.text ?? "")")
        #expect(r.a.body.inputText == "card words" && r.a.controller.composerStore?.draft == "card words", "the card's text stays: \(r.a.body.inputText)")
    }

    @Test func ChatOrcaD16_N2_anEditWhoseDraftCannotBeSavedLeavesTheCardsImagesOnTheCardOnly() throws {
        let r = try FixRig()
        defer { r.cleanUp() }
        let chip = ChatComposerChip(path: try r.picture("a.png"))
        let lost = try r.doubtCard(chips: [chip])
        let folder = r.a.root.appendingPathComponent("chat-private")
        try FileManager.default.removeItem(at: folder)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        r.a.body.queueList.onEdit?(lost.uuid)
        #expect(r.a.controller.composerStore?.saveFailed == true && r.queue.card(lost.uuid)?.chips == [chip], "the card stays")
        #expect(r.a.body.composer.chips.items.isEmpty, "and its images are not also in the composer: \(r.a.body.composer.chips.items)")
    }

    @Test func ChatOrcaD16_N3_aDeadlineThatFiresAfterACloseAndReopenDoesNotWriteTheOldChipsOverTheNewOpenings() throws {
        let r = try FixRig()
        defer { r.cleanUp() }
        try r.a.open()
        let first = try r.picture("a.png"), second = try r.picture("b.png")
        r.a.drop(DragBoard(files: [first]))
        r.a.web.pressEnter()
        r.a.controller.close(.button)
        r.a.rig.open()
        r.a.drop(DragBoard(files: [second]))
        r.timers.fire(exactly: ChatController.imageReadSeconds)
        #expect(r.a.controller.composerStore?.content.chips == [ChatComposerChip(path: first), ChatComposerChip(path: second)], "\(String(describing: r.a.controller.composerStore?.content.chips))")
    }

    // MARK: lows

    @Test func ChatOrcaD16_L1_aFileCutShortBetweenTheSizeAndTheReadIsRefused() throws {
        let folder = FileManager.default.temporaryDirectory.appendingPathComponent("clawd-s5-l1-" + UUID().uuidString, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: folder) }
        let url = folder.appendingPathComponent("a.png")
        try pngData(width: 40, height: 40).write(to: url)
        let result = ChatImageSend.read(url.path, beforeRead: {
            let handle = try? FileHandle(forWritingTo: url)
            try? handle?.truncate(atOffset: 20)
            try? handle?.close()
        })
        guard case .failure(let refusal) = result else { Issue.record("a file whose size changed between the check and the read must not be taken"); return }
        #expect(refusal == .unreadable)
    }

    @Test func ChatOrcaD16_L2_aPasteWhileTheInputIsLockedForASendIsLeftAloneAndAddsNoChip() throws {
        let r = try FixRig()
        defer { r.cleanUp() }
        try r.a.open()
        r.a.drop(DragBoard(files: [try r.picture("a.png")]))
        r.a.web.pressEnter()
        r.a.setPaste(ChatPasteContents(hasText: true, image: pngData(), text: "words", imageFirst: true))
        let taken = try #require(r.a.body.attachments).pasteImageIfAny()
        #expect(taken && r.a.body.composer.chips.items.count == 1, "no pending chip is added during the read: \(r.a.body.composer.chips.items)")
    }

    @Test func ChatOrcaD16_L3_theTextOfAPasteGoesInEvenWhenItsImageIsRefused() throws {
        let r = try FixRig()
        defer { r.cleanUp() }
        try r.a.open()
        r.a.setPaste(ChatPasteContents(hasText: true, image: Data("not an image".utf8), text: "caption", imageFirst: true))
        _ = try #require(r.a.body.attachments).pasteImageIfAny()
        #expect(r.a.input.string == "caption", "the text is inserted before the image is judged: \(r.a.input.string)")
    }

    @Test func ChatOrcaD16_L5_aCardsVanishedImageIsMarkedOnTheCardAndSaysTheCountedWords() throws {
        let r = try FixRig()
        defer { r.cleanUp() }
        let path = try r.picture("gone.png")
        let lost = try r.doubtCard(chips: [ChatComposerChip(path: path)])
        try FileManager.default.removeItem(atPath: path)
        let before = r.session.requests.count
        r.pressCardSend()
        #expect(r.session.requests.count == before && r.a.background.pending.isEmpty)
        #expect(r.queue.card(lost.uuid)?.chips == [ChatComposerChip(unavailable: "gone.png")], "the card's image is marked")
        #expect(r.a.body.statusText == "An image couldn't be brought back. Remove it to send.", "\(r.a.body.statusText)")
    }

    @Test func ChatOrcaD16_L6_aPendingPasteStopsCmdEnterFromSteeringTheNewestCard() throws {
        let r = try FixRig()
        defer { r.cleanUp() }
        try r.doubtCard(chips: [])
        let before = r.session.requests.count
        r.a.setPaste(ChatPasteContents(hasText: false, image: pngData()))
        r.a.input.paste(nil)
        #expect(r.a.body.composer.chips.hasPending)
        r.a.web.pressEnter(modifiers: .command)
        #expect(r.session.requests.count == before, "the pending paste is a chip: Cmd+Enter is an ordinary Enter, held by the paste")
    }
}

/// Samples the process footprint on a thread while the test builds a message; the maximum is the peak.
private final class PeakSampler: @unchecked Sendable {
    private let lock = NSLock()
    private var running = false
    private var peak: UInt64 = 0
    private var thread: Thread?
    func start() {
        lock.lock(); running = true; peak = mallocFootprint(); lock.unlock()
        let thread = Thread { [self] in
            while true {
                lock.lock(); let on = running; lock.unlock()
                if !on { break }
                let now = mallocFootprint()
                lock.lock(); if now > peak { peak = now }; lock.unlock()
                usleep(200)
            }
        }
        thread.start()
        self.thread = thread
    }
    func stop() -> UInt64 {
        let now = mallocFootprint()
        lock.lock(); running = false; if now > peak { peak = now }; let result = peak; lock.unlock()
        return result
    }
}
