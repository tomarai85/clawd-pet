import Testing
import Foundation
import AppKit
import WebKit
@testable import ClawdCore
import ClawdDesktop

// Orca parity round D, sprint 5: sending images (Q16) and sent images in the transcript (Q17). The reads and the encoding are tested on their own,
// in the session against a stand-in child that echoes the frame as the measured CLI does (d-image-replay: the replay carries the data), and in the
// controller with the file work stepped by hand. The image files are generated into temporary folders.

private func tempFolder() throws -> URL {
    let url = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("clawd-s5-" + UUID().uuidString, isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

private func write(_ folder: URL, _ name: String, _ data: Data) throws -> String {
    let url = folder.appendingPathComponent(name)
    try data.write(to: url)
    return url.path
}

private func parsed(_ payload: ChatImagePayload) throws -> [[String: Any]] {
    try #require(try JSONSerialization.jsonObject(with: payload.contentJSON) as? [[String: Any]])
}

@Suite("Chat orca parity D, sending images", .serialized)
@MainActor
struct ChatOrcaParityDImageSendSuite {
    // MARK: Q16, the content

    @Test func ChatOrcaD16_twoPngChipsAndHiGiveImageImageTextWithBase64EqualToTheFiles() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = pngData(width: 3, height: 3), b = pngData(width: 5, height: 2)
        let pa = try write(folder, "a.png", a), pb = try write(folder, "b.PNG", b)
        let payload = try ChatImageSend.prepare(paths: [pa, pb], text: "hi").get()
        let content = try parsed(payload)
        #expect(content.map { $0["type"] as? String } == ["image", "image", "text"], "images in chip order, then the text: \(content.map { $0["type"] ?? "" })")
        let sources = content.prefix(2).compactMap { $0["source"] as? [String: Any] }
        #expect(sources.map { $0["data"] as? String } == [a.base64EncodedString(), b.base64EncodedString()])
        #expect(sources.allSatisfy { $0["type"] as? String == "base64" && $0["media_type"] as? String == "image/png" })
        #expect(content[2]["text"] as? String == "hi" && payload.count == 2 && payload.rawBytes == a.count + b.count)
        let other = try ChatImageSend.prepare(paths: [try write(folder, "c.JPG", a), try write(folder, "d.webp", a), try write(folder, "e.gif", a), try write(folder, "f.jpeg", a)], text: "").get()
        #expect(try parsed(other).compactMap { ($0["source"] as? [String: Any])?["media_type"] as? String } == ["image/jpeg", "image/webp", "image/gif", "image/jpeg"])
    }

    @Test func ChatOrcaD16_imagesOnlyAreSentAsImageBlocksWithNoTextBlock() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let payload = try ChatImageSend.prepare(paths: [try write(folder, "a.png", pngData())], text: "").get()
        #expect(try parsed(payload).map { $0["type"] as? String } == ["image"])
    }

    @Test func ChatOrcaD16_anSvgChipRefusesWithThePngJpegGifWebpWords() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let svg = try write(folder, "v.svg", Data("<svg/>".utf8))
        guard case .failure(let refusal) = ChatImageSend.prepare(paths: [svg], text: "x") else { Issue.record("an SVG must be refused"); return }
        #expect(refusal == .type && refusal.words == "Claude accepts only PNG, JPEG, GIF, and WebP images, so this message was not sent.")
    }

    @Test func ChatOrcaD16_aFileOverFiveMiBAndATwentyFirstChipRefuse() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let edge = try write(folder, "edge.png", Data(count: 5 * 1024 * 1024))
        let over = try write(folder, "over.png", Data(count: 5 * 1024 * 1024 + 1))
        #expect((try? ChatImageSend.prepare(paths: [edge], text: "").get()) != nil, "exactly 5 MiB is taken")
        guard case .failure(let big) = ChatImageSend.prepare(paths: [over], text: "") else { Issue.record("5 MiB + 1 must refuse"); return }
        #expect(big == .tooBig && big.words == "An image on this message is larger than 5 MB, so the message was not sent.")
        let small = try write(folder, "s.png", pngData())
        #expect((try? ChatImageSend.prepare(paths: Array(repeating: small, count: 20), text: "").get()) != nil, "twenty are taken")
        guard case .failure(let many) = ChatImageSend.prepare(paths: Array(repeating: small, count: 21), text: "") else { Issue.record("the 21st must refuse"); return }
        #expect(many == .tooMany && many.words == "Claude accepts at most 20 images in one message, so this message was not sent.")
    }

    @Test func ChatOrcaD16_threeFourMiBFilesAddUpTo12MiBAndRefuseWithTheElevenMegabyteWords() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let four = Data(count: 4 * 1024 * 1024)
        let paths = try (0..<3).map { try write(folder, "p\($0).png", four) }
        guard case .failure(let refusal) = ChatImageSend.prepare(paths: paths, text: "") else { Issue.record("12 MiB must refuse"); return }
        #expect(refusal == .total && refusal.words == "The images on this message add up to more than 11 MB, so the message was not sent.")
        let under = try write(folder, "q.png", Data(count: 3 * 1024 * 1024 + 512 * 1024))
        #expect((try? ChatImageSend.prepare(paths: Array(paths.prefix(2)) + [under], text: "").get()) == nil, "4 + 4 + 3.5 MiB is 11.5 MiB")
        #expect((try? ChatImageSend.prepare(paths: Array(paths.prefix(2)), text: "").get()) != nil, "8 MiB is taken")
    }

    @Test func ChatOrcaD16_theCapIsCheckedOnTheWholeEncodedFrameSoADraftFullOfQuotesCannotPushTheReplayPastTheLineCap() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let five = Data(count: 5 * 1024 * 1024)
        let paths = [try write(folder, "a.png", five), try write(folder, "b.png", five), try write(folder, "c.png", Data(count: 1024 * 1024))]
        let atCap = try ChatImageSend.prepare(paths: paths, text: "").get()
        #expect(atCap.rawBytes == ChatImageSend.maxTotalBytes, "exactly 11 MiB raw is taken")
        #expect(atCap.contentJSON.count + ChatImageSend.framingBytes <= ChatImageSend.lineCapBytes, "and its frame fits the line cap")
        guard case .failure(let refusal) = ChatImageSend.prepare(paths: paths, text: String(repeating: "\"", count: 1_000_000)) else {
            Issue.record("a quote-heavy draft with 11 MiB of images must refuse"); return
        }
        #expect(refusal == .total)
    }

    @Test func ChatOrcaD16_aFileThatGrowsDuringTheReadRefusesWithTheUnreadableWordsAndEmptyAndNonFilesRefuse() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let grows = try write(folder, "g.png", pngData())
        guard case .failure(let refusal) = ChatImageSend.prepare(paths: [grows], text: "", afterRead: {
            if let handle = FileHandle(forWritingAtPath: grows) { handle.seekToEndOfFile(); handle.write(Data(count: 10)); try? handle.close() }
        }) else { Issue.record("a file that changed while it was read must refuse"); return }
        #expect(refusal == .unreadable && refusal.words == "An attachment on this message couldn't be read, so the message was not sent.")
        guard case .failure(let empty) = ChatImageSend.prepare(paths: [try write(folder, "e.png", Data())], text: "") else { Issue.record("empty"); return }
        #expect(empty == .empty && empty.words == "An image on this message is empty, so the message was not sent.")
        let directory = folder.appendingPathComponent("d.png", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        guard case .failure(let notFile) = ChatImageSend.prepare(paths: [directory.path], text: "") else { Issue.record("a folder"); return }
        #expect(notFile == .notFile && notFile.words == "An image on this message isn't a file, so the message was not sent.")
        guard case .failure(let gone) = ChatImageSend.prepare(paths: [folder.appendingPathComponent("nope.png").path], text: "") else { Issue.record("missing"); return }
        #expect(gone == .unreadable)
    }

    @Test func ChatOrcaD16_aNamedPipeIsNotAFileAndTheReadDoesNotWaitForAWriter() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let fifo = folder.appendingPathComponent("pipe.png").path
        #expect(mkfifo(fifo, 0o600) == 0)
        guard case .failure(let refusal) = ChatImageSend.prepare(paths: [fifo], text: "") else { Issue.record("a pipe must refuse"); return }
        #expect(refusal == .notFile)
    }

    // MARK: Q16, the frame and the child

    @Test func ChatOrcaD16_theUserFrameCarriesTheBlocksAsTheContentAndATextSendKeepsItsStringContent() throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let png = pngData()
        let payload = try ChatImageSend.prepare(paths: [try write(folder, "a.png", png)], text: "say \"hi\"\n").get()
        var request = ChatSendRequest(text: "say \"hi\"\n", chips: [ChatComposerChip(path: "/x/a.png")], uuid: "u-1")
        request.payload = payload
        let bytes = Data(try #require(ChatSession.userFrame(request, conversationId: "conv-1")).joined())
        #expect(bytes.last == 0x0A, "the frame ends with its newline")
        let line = String(decoding: bytes.dropLast(), as: UTF8.self)
        let frame = try #require(try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any])
        #expect(frame["type"] as? String == "user" && frame["uuid"] as? String == "u-1" && frame["session_id"] as? String == "conv-1" && frame["parent_tool_use_id"] is NSNull)
        let content = try #require((frame["message"] as? [String: Any])?["content"] as? [[String: Any]])
        #expect(content.map { $0["type"] as? String } == ["image", "text"] && content[1]["text"] as? String == "say \"hi\"\n")
        #expect(!line.contains("\n"), "one line")
        let plain = try #require(ChatSession.userFrame(ChatSendRequest(text: "hello", uuid: "u-2"), conversationId: "c"))
        let plainFrame = try #require(try JSONSerialization.jsonObject(with: Data(plain.joined())) as? [String: Any])
        #expect((plainFrame["message"] as? [String: Any])?["content"] as? String == "hello")
    }

    @Test func ChatOrcaD16_aSessionWritesTheBlocksToTheChildKeepsTheImagePathsInTheEntryAndLogsOnlyCounts() async throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let a = pngData(width: 4, height: 4), b = pngData(width: 6, height: 6)
        let pa = try write(folder, "a.png", a), pb = try write(folder, "clawd-paste-1-ABC.png", b)
        let rig = try ChatRig(stub: "image-echo.py")
        let payload = try ChatImageSend.prepare(paths: [pa, pb], text: "what is this").get()
        var request = ChatSendRequest(text: "what is this", chips: [ChatComposerChip(path: pa), ChatComposerChip(path: pb)])
        request.payload = payload
        #expect(rig.session.send(request))
        #expect(await rig.wait { rig.outcomes.count == 1 })
        guard case .success? = rig.outcomes.first else { Issue.record("the turn ended: \(rig.outcomes) \(rig.log)"); return }
        let received = try String(contentsOfFile: rig.folder + "/received.jsonl", encoding: .utf8)
        let frame = try #require(try JSONSerialization.jsonObject(with: Data(received.utf8)) as? [String: Any])
        let content = try #require((frame["message"] as? [String: Any])?["content"] as? [[String: Any]])
        #expect(content.map { $0["type"] as? String } == ["image", "image", "text"])
        try #require(content.count > 1, "content needs 2 elements: \(content.count)")
        #expect((content[0]["source"] as? [String: Any])?["data"] as? String == a.base64EncodedString())
        #expect((content[1]["source"] as? [String: Any])?["data"] as? String == b.base64EncodedString())
        let user = try #require(rig.session.transcript.entries.first { $0.kind == .user })
        #expect(user.text == "what is this" && user.images == [pa, pb], "the user entry keeps the text and the image paths: \(user)")
        #expect(rig.session.hasUnsettledSend == false, "the replay (which carries the data) settled the send")
        let sendLine = try #require(rig.log.first { $0.hasPrefix("CHAT send ") })
        #expect(sendLine == "CHAT send turn=1 chars=12 images=2 bytes=\(a.count + b.count)", "\(sendLine)")
        #expect(rig.log.allSatisfy { !$0.contains("what is this") && !$0.contains(folder.path) && !$0.contains("clawd-paste") }, "the log rule: counts only")
        rig.session.stop(.userStop)
    }

    @Test func ChatOrcaD16_anElevenMiBSendsOwnReplayFitsTheLineCapAndIsNotSkipped() async throws {
        let folder = try tempFolder()
        defer { try? FileManager.default.removeItem(at: folder) }
        let five = Data(count: 5 * 1024 * 1024)
        let paths = [try write(folder, "a.png", five), try write(folder, "b.png", five), try write(folder, "c.png", Data(count: 1024 * 1024))]
        let rig = try ChatRig(stub: "image-echo.py")
        let payload = try ChatImageSend.prepare(paths: paths, text: "big").get()
        var request = ChatSendRequest(text: "big", chips: paths.map { ChatComposerChip(path: $0) })
        request.payload = payload
        #expect(rig.session.send(request))
        #expect(await rig.wait { rig.outcomes.count == 1 })
        guard case .success? = rig.outcomes.first else { Issue.record("the turn ended: \(rig.outcomes) \(rig.log.suffix(5))"); return }
        #expect(rig.session.hasUnsettledSend == false, "the 15 MB replay line was read whole and settled the send: \(rig.log.suffix(5))")
        #expect(rig.session.transcript.entries.allSatisfy { $0.kind != .notice || !$0.text.lowercased().contains("long") }, "no very-long-line notice")
        #expect(rig.log.contains("CHAT send turn=1 chars=3 images=3 bytes=\(ChatImageSend.maxTotalBytes)"), "\(rig.log.suffix(5))")
        rig.session.stop(.userStop)
    }

    // MARK: Q16, the controller

    private func rig() throws -> AttachRig { try AttachRig() }

    private func chip(_ r: AttachRig, _ name: String, _ data: Data = pngData()) throws -> String {
        let folder = r.root.appendingPathComponent("files", isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let url = folder.appendingPathComponent(name)
        try data.write(to: url)
        r.drop(DragBoard(files: [url.path]))
        return url.path
    }

    @Test func ChatOrcaD16_enterWithAChipReadsOffTheMainThreadThenSendsTheImageAndClearsTheDraftAndTheChip() throws {
        let r = try rig()
        defer { r.cleanUp() }
        try r.open()
        let path = try chip(r, "a.png")
        r.body.inputText = "hi"
        r.web.pressEnter()
        #expect(r.rig.session.sent.isEmpty && r.body.composer.isLocked, "the read is off the main thread and the input is locked meanwhile")
        #expect(r.controller.composerStore?.content.chips == [ChatComposerChip(path: path)] && r.body.inputText == "hi", "the draft and the chip stay until the send is accepted")
        r.background.runAll()
        let request = try #require(r.rig.session.requests.last)
        #expect(request.text == "hi" && request.payload?.paths == [path] && request.chips == [ChatComposerChip(path: path)] && !request.steer)
        #expect(r.body.inputText.isEmpty && r.body.composer.chips.items.isEmpty && r.controller.composerStore?.content.chips == nil && !r.body.composer.isLocked)
        #expect(r.rig.session.transcript.entries.last?.images == [path])
    }

    @Test func ChatOrcaD16_aDraftWithOnlyChipsCanBeSent() throws {
        let r = try rig()
        defer { r.cleanUp() }
        try r.open()
        _ = try chip(r, "a.png")
        #expect(r.body.composer.isSendEnabled, "a draft with only chips can be sent")
        r.web.pressEnter()
        r.background.runAll()
        #expect(r.rig.session.requests.count == 1 && r.rig.session.requests[0].text.isEmpty && r.rig.session.requests[0].payload?.count == 1)
    }

    @Test func ChatOrcaD16_aRefusalSendsNothingKeepsTheDraftAndTheChipsAndSaysOrcasWordsInTheStatusLine() throws {
        let r = try rig()
        defer { r.cleanUp() }
        try r.open()
        let svg = try chip(r, "v.svg", Data("<svg/>".utf8))
        r.body.inputText = "look"
        r.web.pressEnter()
        r.background.runAll()
        #expect(r.rig.session.sent.isEmpty && r.body.inputText == "look" && r.body.composer.chips.persisted == [ChatComposerChip(path: svg)])
        #expect(r.body.statusText == ChatImageRefusal.type.words && !r.body.composer.isLocked, "\(r.body.statusText)")
        #expect(r.controller.composerStore?.content.chips == [ChatComposerChip(path: svg)] && r.controller.composerStore?.draft == "look")
    }

    @Test func ChatOrcaD16_aCloseDuringTheReadDropsOnlyTheWriteAndLosesNothing() throws {
        let r = try rig()
        defer { r.cleanUp() }
        try r.open()
        let path = try chip(r, "a.png")
        r.body.inputText = "keep me"
        r.web.pressEnter()
        r.controller.close(.button)
        r.background.runAll()
        #expect(r.rig.session.sent.isEmpty, "no write after a close")
        #expect(r.controller.composerStore?.content.chips == [ChatComposerChip(path: path)] && r.controller.composerStore?.draft == "keep me", "the draft and the chip are still saved")
    }

    @Test func ChatOrcaD16_aTurnThatStartsDuringTheReadMakesTheSendASteerAndAStoppingTurnWaits() throws {
        let r = try rig()
        defer { r.cleanUp() }
        try r.open()
        _ = try chip(r, "a.png")
        r.body.inputText = "late"
        r.web.pressEnter()
        r.rig.session.turn = .running
        r.background.runAll()
        #expect(r.rig.session.requests.last?.steer == true && r.rig.session.sent == ["late"], "a turn that started meanwhile: the image goes into it as a steer")
        let s = try rig()
        defer { s.cleanUp() }
        try s.open()
        _ = try chip(s, "a.png")
        s.body.inputText = "x"
        s.web.pressEnter()
        s.rig.session.turn = .stopping
        s.background.runAll()
        #expect(s.rig.session.sent.isEmpty && s.body.statusText == "Wait for the current turn to stop." && s.body.inputText == "x")
    }

    @Test func ChatOrcaD16_aSecondEnterWhileTheFilesAreBeingReadDoesNothing() throws {
        let r = try rig()
        defer { r.cleanUp() }
        try r.open()
        _ = try chip(r, "a.png")
        r.web.pressEnter()
        r.web.pressEnter()
        r.background.runAll()
        #expect(r.rig.session.requests.count == 1, "one read, one send: \(r.rig.session.requests.count)")
    }

    @Test func ChatOrcaD16_aChipFileThatTheSweepsRemovedBeforeTheSendBecomesUnavailableAndHoldsTheSend() throws {
        let r = try rig()
        defer { r.cleanUp() }
        try r.open()
        let path = try chip(r, "a.png")
        r.body.inputText = "x"
        try FileManager.default.removeItem(atPath: path)
        r.web.pressEnter()
        r.background.runAll()
        #expect(r.rig.session.sent.isEmpty && r.body.composer.chips.unavailableCount == 1, "the file is looked at again at the send: \(r.body.composer.chips.items)")
        #expect(r.body.statusText == "An image couldn't be brought back. Remove it to send.")
    }

    @Test func ChatOrcaD16_aSendWithoutChipsLeavesTheChipsThatArrivedMeanwhileInTheDraft() throws {
        let r = try rig()
        defer { r.cleanUp() }
        try r.open()
        let first = try chip(r, "a.png")
        r.body.inputText = "go"
        r.web.pressEnter()
        // While the first chip's file is read, another image is stored into the draft (a pasted image finishes saving).
        let second = r.root.appendingPathComponent("files/late.png").path
        try pngData().write(to: URL(fileURLWithPath: second))
        r.body.composer.attachImages(paths: [second])
        r.background.runAll()
        #expect(r.rig.session.requests.last?.chips == [ChatComposerChip(path: first)])
        #expect(r.controller.composerStore?.content.chips == [ChatComposerChip(path: second)], "only the chip that was sent leaves the draft: \(String(describing: r.controller.composerStore?.content.chips))")
    }

    @Test func ChatOrcaD16_aTextOnlyDraftSendLeavesTheChipsTheDraftFileHolds() throws {
        let r = try rig()
        defer { r.cleanUp() }
        try r.open()
        let held = ChatComposerChip(path: r.root.appendingPathComponent("files/held.png").path)
        r.controller.composerStore?.update(durable: true) { $0.chips = [held] }
        r.body.inputText = "hello"
        r.web.pressEnter()
        r.background.runAll()
        #expect(r.rig.session.requests.last?.chips.isEmpty == true && r.rig.session.requests.last?.text == "hello", "a text-only send: \(String(describing: r.rig.session.requests.last))")
        #expect(r.controller.composerStore?.content.chips == [held], "the send takes out only the chips it carried: \(String(describing: r.controller.composerStore?.content.chips))")
    }

    // MARK: N2, the default click-count closures

    @Test func ChatOrcaD12_N2_theDefaultClickCountClosuresOfTheSendControlAndTheCardButtonsReadTheEventSource() throws {
        let key = NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, characters: "a",
                                   charactersIgnoringModifiers: "a", isARepeat: false, keyCode: 0)!
        func click(_ count: Int) -> NSEvent {
            NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: count, pressure: 1)!
        }
        let saved = ChatClickCount.source
        defer { ChatClickCount.source = saved }
        let r = try rig()
        defer { r.cleanUp() }
        try r.open()
        r.body.inputText = "first"
        ChatClickCount.source = { click(2) }
        r.body.composer.sendButton.performClick(nil)
        #expect(r.rig.session.sent.isEmpty, "the send control's default ignores the second click of a double-click")
        ChatClickCount.source = { key }
        r.body.composer.sendButton.performClick(nil)
        #expect(r.rig.session.sent == ["first"], "a press that is not a mouse click counts as one and sends")
        r.web.type("second"); r.web.pressEnter()
        #expect(r.body.queueList.rows.count == 1, "a card")
        ChatClickCount.source = { click(2) }
        r.body.queueList.rows[0].steerButton.performClick(nil)
        #expect(r.rig.session.sent == ["first"] && r.body.queueList.rows.count == 1, "the card button's default ignores the second click")
        ChatClickCount.source = { key }
        r.body.queueList.rows[0].steerButton.performClick(nil)
        #expect(r.rig.session.sent == ["first", "second"], "and a key press steers")
        #expect(ChatClickCount.current(of: key) == 1 && ChatClickCount.current(of: click(3)) == 3 && ChatClickCount.current(of: nil) == 1)
    }

    // MARK: Q14, cards that carry chips

    @Test func ChatOrcaD14_aDoubtCardThatCarriedImagesShowsThemAsChipsOnTheCard() throws {
        let r = try rig()
        defer { r.cleanUp() }
        try r.open()
        let card = ChatComposerFile.Card(id: "c1", text: "with images", state: "waiting", hold: "paused", paused: "doubt",
                                         chips: [ChatComposerChip(path: "/x/clawd-paste-1-A.png"), ChatComposerChip(path: "/x/b.png"), ChatComposerChip(unavailable: "gone.png")])
        let row = ChatQueueRow(card: card, hold: .paused("doubt"))
        #expect(row.chipLabels == ["Pasted image", "b.png", "gone.png"])
        r.body.setQueue([row], pauseText: nil)
        let view = try #require(r.body.queueList.rows.first)
        #expect(view.chipRow?.labels == ["Pasted image", "b.png", "gone.png"], "the card shows its images as chips")
        #expect(ChatQueueRowView.height(for: row) == ChatQueueRowView.height(for: ChatQueueRow(card: ChatComposerFile.Card(id: "c2", text: "t", state: "waiting", hold: "paused", paused: "doubt"), hold: .paused("doubt"))) + ChatQueueRowView.chipLine)
        let plain = ChatQueueRow(card: ChatComposerFile.Card(id: "c3", text: "t", state: "waiting", hold: "turn"), hold: .turn)
        r.body.setQueue([plain], pauseText: nil)
        #expect(r.body.queueList.rows.first?.chipRow == nil)
    }

    // MARK: Q17

    @Test func ChatOrcaD17_aUserEntryWithImagesCarriesTheirPathsToThePageAndNoOtherEntryDoes() throws {
        var transcript = ChatTranscript()
        transcript.appendUser("see", uuid: "u", images: ["/x/a.png", "/x/clawd-paste-9-Z.png"])
        transcript.appendUser("plain", uuid: "v")
        let first = ChatWebPayload.entry(transcript.entries[0]), second = ChatWebPayload.entry(transcript.entries[1])
        #expect(first["images"] as? [String] == ["/x/a.png", "/x/clawd-paste-9-Z.png"] && second["images"] == nil)
        var long = ChatTranscript()
        long.appendUser("x", uuid: "w", images: [String(repeating: "p", count: 1025), "/ok.png"] + (0..<30).map { "/\($0).png" })
        try #require(long.entries.count > 0, "long.entries needs 1 elements: \(long.entries.count)")
        #expect(long.entries[0].images.count == 20 && long.entries[0].images[0] == "/ok.png" && long.entries[0].images.allSatisfy { $0.utf8.count <= 1024 }, "at most 20 paths, each at most 1 KiB")
    }

    @Test func ChatOrcaD17_thePageShowsOneNameChipPerImageAboveTheTextWithTheFullPathAsTitleAndLoadsNoImage() async throws {
        let r = WebPageRig()
        #expect(await r.loadAndWaitReady())
        try await applyEntries(r.page.view!, [["id": 1, "kind": "user", "text": "look at these", "images": ["/Users/example/a.png", "/private/x/clawd-paste-1-AB.png"]],
                                             ["id": 2, "kind": "user", "text": "no pictures"]])
        let found = try await pageObject(r.page.view!, """
        const rows = Array.from(document.querySelectorAll('#column > .row[data-id]'));
        function chips(row) {
          return Array.from(row.querySelectorAll('.msg-image')).map(function (chip) {
            const name = chip.querySelector('.msg-image-name');
            return {name: name ? name.textContent : '', title: chip.title, icon: chip.querySelector('svg') !== null,
                    border: getComputedStyle(chip).borderTopWidth, radius: getComputedStyle(chip).borderTopLeftRadius, font: getComputedStyle(chip).fontSize,
                    padding: getComputedStyle(chip).paddingLeft + '/' + getComputedStyle(chip).paddingTop};
          });
        }
        const bubble = rows[0].querySelector('.user-bubble');
        const imagesEl = rows[0].querySelector('.msg-images');
        return JSON.stringify({first: chips(rows[0]), second: chips(rows[1]), above: imagesEl !== null && imagesEl.nextElementSibling !== null && imagesEl.nextElementSibling.classList.contains('native-chat-markdown'),
                               hiddenWhenNone: rows[1].querySelector('.msg-images') === null,
                               imgs: document.querySelectorAll('img').length});
        """)
        let first = try #require(found["first"] as? [[String: Any]])
        #expect(first.map { $0["name"] as? String } == ["a.png", "Pasted image"], "\(first)")
        #expect(first.map { $0["title"] as? String } == ["/Users/example/a.png", "/private/x/clawd-paste-1-AB.png"], "the full path is the tooltip")
        #expect(first.allSatisfy { $0["icon"] as? Bool == true && $0["border"] as? String == "1px" && $0["font"] as? String == "12px" && $0["padding"] as? String == "8px/4px" }, "\(first)")
        #expect((found["second"] as? [[String: Any]])?.isEmpty == true && found["above"] as? Bool == true && found["hiddenWhenNone"] as? Bool == true && found["imgs"] as? Int == 0)
    }

    @Test func ChatOrcaD17_theContentSecurityPolicyStillRefusesEveryImage() throws {
        let html = try String(contentsOf: URL(fileURLWithPath: chatPageDirectory.path + "/index.html"), encoding: .utf8)
        #expect(html.contains("img-src 'none'"), "index.html's CSP stays")
    }
}
