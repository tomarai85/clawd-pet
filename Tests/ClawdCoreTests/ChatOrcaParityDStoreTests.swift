import Testing
import Foundation
import Darwin
@testable import ClawdCore

// Orca parity round D, sprint 2: Q7's history and Q8's private write path, the saved draft, the move of chat-state.json and the private paste
// folder. Every test uses its own temporary state root; the real state directory is never touched.

private func mode(_ path: String) -> Int {
    var info = stat()
    return lstat(path, &info) == 0 ? Int(info.st_mode & 0o7777) : -1
}

private func pathOf(_ state: OwnState, _ relative: String) -> String { state.root.appendingPathComponent(relative).path }

private func readFile(_ state: OwnState, _ relative: String = ChatComposerStore.fileName) throws -> ChatComposerFile {
    try JSONDecoder().decode(ChatComposerFile.self, from: ReadOnlyFile.data(pathOf(state, relative), limit: ChatComposerStore.capBytes))
}

/// What the sync seam was asked, in order.
private final class SyncLog { var full: [Bool] = [] }

private func store(_ state: OwnState, _ timers: ManualChatTimers = ManualChatTimers(), logs: LogBox = LogBox()) -> ChatComposerStore {
    ChatComposerStore(state: state, timers: timers, log: { logs.lines.append($0) })
}

private final class LogBox { var lines: [String] = [] }

@Suite("Chat orca parity D, composer state and private writes", .serialized)
@MainActor
struct ChatOrcaParityDStoreSuite {
    // MARK: Q8 the private write

    @Test func ChatOrcaD8_aPrivateWriteIs0600InA0700DirectoryAndLeavesNoTempFile() throws {
        let state = try artifactStore()
        try state.writePrivate(Data("one".utf8), to: "chat-private/a.json")
        try state.writePrivate(Data("two".utf8), to: "chat-private/a.json", durable: true)
        #expect(mode(pathOf(state, "chat-private")) == 0o700 && mode(pathOf(state, "chat-private/a.json")) == 0o600)
        #expect(String(decoding: try ReadOnlyFile.data(pathOf(state, "chat-private/a.json")), as: UTF8.self) == "two")
        #expect(state.entries(of: "chat-private").map(\.name) == ["a.json"], "the temp file is gone")
    }

    @Test func ChatOrcaD8_aFailedStepLeavesTheTargetAsItWasAndNoTempFile() throws {
        let state = try artifactStore()
        try state.writePrivate(Data("old".utf8), to: "chat-private/a.json")
        state.privateIO = OwnState.PrivateIO(sync: OwnState.PrivateIO.system.sync, rename: { _, _ in errno = EIO; return -1 })
        #expect(throws: (any Error).self) { try state.writePrivate(Data("new".utf8), to: "chat-private/a.json") }
        state.privateIO = OwnState.PrivateIO(sync: { _, _ in errno = EIO; return -1 }, rename: OwnState.PrivateIO.system.rename)
        #expect(throws: (any Error).self) { try state.writePrivate(Data("new".utf8), to: "chat-private/a.json") }
        #expect(String(decoding: try ReadOnlyFile.data(pathOf(state, "chat-private/a.json")), as: UTF8.self) == "old")
        #expect(state.entries(of: "chat-private").map(\.name) == ["a.json"], "a failed step removes its temp file")
    }

    @Test func ChatOrcaD8_aGroupReadableDirectoryRefusesTheWriteAndALinkedOneToo() throws {
        let state = try artifactStore()
        try FileManager.default.createDirectory(atPath: pathOf(state, "chat-private"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        #expect(throws: (any Error).self) { try state.writePrivate(Data("x".utf8), to: "chat-private/a.json") }
        #expect(state.entries(of: "chat-private").isEmpty, "nothing was written")
        let other = try artifactStore()
        let elsewhere = try artifactStore()
        try elsewhere.privateDirectory("real")
        try FileManager.default.createSymbolicLink(atPath: pathOf(other, "chat-private"), withDestinationPath: pathOf(elsewhere, "real"))
        #expect(throws: (any Error).self) { try other.writePrivate(Data("x".utf8), to: "chat-private/a.json") }
        #expect(elsewhere.entries(of: "real").isEmpty, "a link is never followed")
    }

    @Test func ChatOrcaD8_theCardAndSendWriteAsksForTheFullSyncAndTheDraftWriteForPlainFsync() throws {
        let state = try artifactStore()
        let log = SyncLog()
        state.privateIO = OwnState.PrivateIO(sync: { _, full in log.full.append(full); return 0 }, rename: OwnState.PrivateIO.system.rename)
        let timers = ManualChatTimers()
        let composer = store(state, timers)
        composer.setDraft("typing"); composer.flush()
        composer.update(durable: true) { $0.cards = [ChatComposerFile.Card(id: "c1", text: "queued", state: "waiting", hold: "turn")] }
        composer.flush()
        #expect(log.full == [false, true], "a draft-only write is fsync, a write that changes the cards is F_FULLFSYNC: \(log.full)")
        let again = store(state)
        again.setDraft("more"); again.flush()
        #expect(log.full == [false, true, false], "the owed full sync is paid once: \(log.full)")
        // The system implementation really flushes (F_FULLFSYNC where the filesystem has it, else fsync).
        let probe = Darwin.open(pathOf(state, ChatComposerStore.fileName), O_RDONLY)
        defer { close(probe) }
        #expect(OwnState.PrivateIO.system.sync(probe, true) == 0 && OwnState.PrivateIO.system.sync(probe, false) == 0)
    }

    @Test func ChatOrcaD8_aLeftoverTempFileFromACrashIsRemovedAtTheNextStartAndTheOldFileStands() throws {
        let state = try artifactStore()
        let first = store(state)
        first.setDraft("kept"); first.flush()
        let leftover = pathOf(state, "chat-private/.chat-composer.json.AbC123.tmp")
        #expect(Darwin.open(leftover, O_WRONLY | O_CREAT | O_EXCL, 0o600) >= 0, "a crash between create and rename left this")
        let next = store(state)
        #expect(next.draft == "kept" && mode(leftover) == -1, "the old file stands and the temp is removed at start")
    }

    // MARK: Q8 coalescing

    @Test func ChatOrcaD8_aBurstOfTypingIsOneWriteAt250msAndTheLaterChangeArmsTheNextOne() throws {
        let state = try artifactStore()
        let timers = ManualChatTimers()
        let composer = store(state, timers)
        composer.setDraft("a")                         // 0 ms
        composer.setDraft("ab")                        // 200 ms: no second timer
        #expect(timers.live == [ChatComposerStore.debounce], "one timer from the first change: \(timers.live)")
        #expect(mode(pathOf(state, ChatComposerStore.fileName)) == -1, "nothing is written before the 250 ms")
        timers.fire(exactly: ChatComposerStore.debounce)
        #expect(try readFile(state).draft == "ab", "the file holds both characters at 250 ms")
        composer.setDraft("abc")                       // 300 ms: a new timer
        #expect(timers.live == [ChatComposerStore.debounce])
        composer.flush()                               // the quit at 400 ms writes what the timer had not
        #expect(try readFile(state).draft == "abc" && timers.live.isEmpty)
        #expect(ChatComposerStore.debounce == 0.25 && ChatComposerStore.capBytes == 16 * 1024 * 1024)
    }

    @Test func ChatOrcaD8_aChangeThatNeedsNoWriteWritesNothing() throws {
        let state = try artifactStore()
        let timers = ManualChatTimers()
        let composer = store(state, timers)
        composer.setDraft("")
        composer.flush()
        #expect(timers.live.isEmpty && mode(pathOf(state, "chat-private")) == -1, "an empty draft that was empty creates no folder")
        composer.setDraft("x"); composer.flush(); composer.flush()
        let before = mode(pathOf(state, ChatComposerStore.fileName))
        #expect(before == 0o600)
    }

    // MARK: Q8 the failed save, the cap and the bad file

    @Test func ChatOrcaD8_aRefusedWriteKeepsTheDraftInMemoryShowsTheIconAndTheNextChangeRetries() throws {
        let state = try artifactStore()
        let logs = LogBox()
        let composer = store(state, logs: logs)
        var icon: [Bool] = []
        composer.onSaveStateChanged = { icon.append(composer.saveFailed) }
        try FileManager.default.createDirectory(atPath: pathOf(state, "chat-private"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        composer.setDraft("SECRET-DRAFT-TEXT"); composer.flush()
        #expect(composer.saveFailed && icon == [true] && composer.draft == "SECRET-DRAFT-TEXT", "the draft stays in memory with the icon showing")
        #expect(logs.lines.contains { $0.hasPrefix("CHAT composer-state saved=failed bytes=") })
        chmod(pathOf(state, "chat-private"), 0o700)
        composer.setDraft("SECRET-DRAFT-TEXT 2"); composer.flush()
        let saved = try readFile(state).draft
        #expect(!composer.saveFailed && icon == [true, false] && saved == "SECRET-DRAFT-TEXT 2", "the first write that succeeds clears the icon")
        #expect(!logs.lines.joined().contains("SECRET"), "the log rule: counts only, never the text: \(logs.lines)")
    }

    @Test func ChatOrcaD8_aFileOver16MiBIsRenamedBadAndTheNextWriteLeavesIt() throws {
        let state = try artifactStore()
        try state.privateDirectory("chat-private")
        try state.write(Data(count: ChatComposerStore.capBytes + 1), to: ChatComposerStore.fileName)
        let logs = LogBox()
        let composer = store(state, logs: logs)
        #expect(composer.draft.isEmpty && logs.lines == ["CHAT composer-state read=over"], "\(logs.lines)")
        #expect(mode(pathOf(state, ChatComposerStore.fileName + ".bad")) != -1 && mode(pathOf(state, ChatComposerStore.fileName)) == -1)
        composer.setDraft("fresh"); composer.flush()
        #expect(try readFile(state).draft == "fresh" && state.entries(of: "chat-private").map(\.name).contains("chat-composer.json.bad"), "the .bad file is kept")
        // A small file is read as it is.
        let exact = try artifactStore()
        try exact.privateDirectory("chat-private")
        var big = ChatComposerFile(); big.draft = String(repeating: "x", count: 1000)
        try exact.write(try JSONEncoder().encode(big), to: ChatComposerStore.fileName)
        #expect(store(exact).draft.count == 1000)
    }

    @Test func ChatOrcaD8_aFileThatDoesNotParseIsRenamedBadAndANewerBadReplacesTheOlder() throws {
        let state = try artifactStore()
        try state.privateDirectory("chat-private")
        try state.write(Data("{nope".utf8), to: ChatComposerStore.fileName)
        let logs = LogBox()
        _ = store(state, logs: logs)
        #expect(logs.lines == ["CHAT composer-state read=bad"] && mode(pathOf(state, ChatComposerStore.fileName)) == -1)
        try state.write(Data("{second".utf8), to: ChatComposerStore.fileName)
        _ = store(state)
        #expect(String(decoding: try ReadOnlyFile.data(pathOf(state, ChatComposerStore.fileName + ".bad")), as: UTF8.self) == "{second", "one slot")
        let none = LogBox()
        _ = store(try artifactStore(), logs: none)
        #expect(none.lines == ["CHAT composer-state read=none"])
    }

    @Test func ChatOrcaD8_atTheCapADoubtIsKeptAndTheDraftIsLeftOutWithTheIconShowing() throws {
        let state = try artifactStore()
        let composer = store(state)
        let doubt = ChatComposerFile.Send(uuid: "u-1", text: String(repeating: "d", count: 15_900_000))
        composer.update(durable: true) { $0.doubt = [doubt] }
        composer.setDraft(String(repeating: "t", count: 1_048_576))
        composer.flush()
        let file = try readFile(state)
        #expect(file.doubt == [doubt] && file.draft == nil, "the doubt entry stays, the draft goes first")
        #expect(composer.saveFailed && composer.draft.count == 1_048_576, "what was left out stays in memory with the icon showing")
        // A write whose protected entries alone pass the cap is refused whole and the old file stands.
        let refused = try artifactStore()
        let big = store(refused)
        big.setDraft("small"); big.flush()
        big.update(durable: true) { $0.doubt = [ChatComposerFile.Send(uuid: "u-2", text: String(repeating: "d", count: ChatComposerStore.capBytes))] }
        big.flush()
        let kept = try readFile(refused).draft
        #expect(big.saveFailed && kept == "small")
    }

    @Test func ChatOrcaD8_theWaitingCardsGoFromTheNewestAfterTheDraft() throws {
        let state = try artifactStore()
        let composer = store(state)
        let cards = (1...3).map { ChatComposerFile.Card(id: "c\($0)", text: String(repeating: "c", count: 6_000_000), state: "waiting", hold: "turn") }
        composer.update(durable: true) { $0.cards = cards }
        composer.setDraft("draft")
        composer.flush()
        let file = try readFile(state)
        #expect(file.draft == nil && file.cards?.map(\.id) == ["c1", "c2"], "the draft, then the newest card: \(String(describing: file.cards?.map(\.id)))")
        #expect(composer.saveFailed)
    }

    @Test func ChatOrcaD8_aChipWhoseFileWasRemovedRestoresUnavailableAndAPresentOneStays() throws {
        let state = try artifactStore()
        let present = pathOf(state, "keep.png")
        try state.write(Data("png".utf8), to: "keep.png")
        let gone = pathOf(state, "gone.png")
        let composer = store(state)
        composer.setChips([ChatComposerChip(path: present), ChatComposerChip(path: gone)])
        composer.flush()
        let restored = store(state)
        #expect(restored.content.chips == [ChatComposerChip(path: present), ChatComposerChip(unavailable: "gone.png")], "\(String(describing: restored.content.chips))")
        // Looked at again when the files change under a live store (each open and each send).
        try state.removeFile("keep.png")
        restored.recheckChips()
        #expect(restored.content.chips == [ChatComposerChip(unavailable: "keep.png"), ChatComposerChip(unavailable: "gone.png")])
    }

    @Test func ChatOrcaD8_everyFieldIsOptionalUnderVersionOne() throws {
        let state = try artifactStore()
        try state.privateDirectory("chat-private")
        try state.write(Data("{\"version\":1,\"draft\":\"only a draft\"}".utf8), to: ChatComposerStore.fileName)
        let composer = store(state)
        #expect(composer.draft == "only a draft" && composer.content.cards == nil && composer.content.inflight == nil)
        let future = try artifactStore()
        try future.privateDirectory("chat-private")
        try future.write(Data("{}".utf8), to: ChatComposerStore.fileName)
        #expect(store(future).draft.isEmpty)
    }

    // MARK: Q8 chat-state.json moves into chat-private/

    private func legacyJSON(session: String, token: String) -> Data {
        Data("{\"sessionId\":\"\(session)\",\"sessionFolder\":null,\"recentFolders\":[],\"child\":null,\"tokens\":[\"\(token)\"],\"lastStop\":null,\"members\":{}}".utf8)
    }

    @Test func ChatOrcaD8_theRootChatStateIsMovedBeforeTheStartSweepActsOnItsToken() throws {
        let state = try artifactStore()
        try state.write(legacyJSON(session: "sess-1", token: "tok-aaaa"), to: ChatTermState.legacyFileName)
        #expect(mode(pathOf(state, ChatTermState.legacyFileName)) != -1)
        var lines: [String] = []
        TermStartSweep.run(store: state, seconds: 0.2) { lines.append($0) }
        #expect(lines.count == 1 && lines[0].hasPrefix("CHAT sweep n="), "the sweep acted on the recorded token: \(lines)")
        #expect(mode(pathOf(state, ChatTermState.legacyFileName)) == -1, "the root file is gone")
        #expect(mode(pathOf(state, ChatTermState.fileName)) == 0o600 && mode(pathOf(state, "chat-private")) == 0o700)
        let after = try ChatTermState(store: state).read()
        #expect(after.sessionId == "sess-1" && after.tokens.isEmpty, "the new file holds the same sessionId, and the swept token left it")
    }

    @Test func ChatOrcaD8_theFirstReadOfARootOnlyStateMovesItAndRemovesTheRoot() throws {
        let state = try artifactStore()
        try state.write(legacyJSON(session: "sess-2", token: "tok-bbbb"), to: ChatTermState.legacyFileName)
        let read = try ChatTermState(store: state).read()
        #expect(read.sessionId == "sess-2" && read.tokens == ["tok-bbbb"])
        #expect(mode(pathOf(state, ChatTermState.legacyFileName)) == -1, "the root is removed by the move itself")
        #expect(mode(pathOf(state, ChatTermState.fileName)) == 0o600)
    }

    @Test func ChatOrcaD8_withBothFilesPresentTheRootIsRemovedAndTheNewOneIsLeftAsItIs() throws {
        let state = try artifactStore()
        try state.writePrivate(legacyJSON(session: "new", token: "tok-new"), to: ChatTermState.fileName)
        try state.write(legacyJSON(session: "old", token: "tok-old"), to: ChatTermState.legacyFileName)
        let read = try ChatTermState(store: state).read()
        #expect(read.sessionId == "new" && read.tokens == ["tok-new"])
        #expect(mode(pathOf(state, ChatTermState.legacyFileName)) == -1)
        #expect(String(decoding: try ReadOnlyFile.data(pathOf(state, ChatTermState.fileName)), as: UTF8.self).contains("\"new\""), "untouched")
    }

    @Test func ChatOrcaD8_aMalformedRootFileIsNotMovedItIsClosedToOthersAndStillUnreadable() throws {
        let state = try artifactStore()
        try state.write(Data("{not json".utf8), to: ChatTermState.legacyFileName)
        chmod(pathOf(state, ChatTermState.legacyFileName), 0o644)
        #expect(throws: ChatTermState.Failure.unreadable) { try ChatTermState(store: state).read() }
        #expect(mode(pathOf(state, ChatTermState.legacyFileName)) == 0o600, "closed to group and others")
        #expect(String(decoding: try ReadOnlyFile.data(pathOf(state, ChatTermState.legacyFileName)), as: UTF8.self) == "{not json")
        #expect(mode(pathOf(state, ChatTermState.fileName)) == -1, "nothing was moved")
    }

    @Test func ChatOrcaD8_theTerminalPathsWritesGoToThePrivateFile() throws {
        let state = try artifactStore()
        let term = ChatTermState(store: state)
        try term.begin(token: "tok-w")
        #expect(mode(pathOf(state, ChatTermState.fileName)) == 0o600 && mode(pathOf(state, ChatTermState.legacyFileName)) == -1)
        #expect(try term.read().tokens == ["tok-w"])
    }

    // MARK: Q8 review fixes (Sprint 2 code review r1)

    @Test func ChatOrcaD8_L1_aPrivateFileThatDoesNotParseKeepsTheRootAndReadsAsUnreadable() throws {
        let state = try artifactStore()
        try state.writePrivate(Data("{torn".utf8), to: ChatTermState.fileName)
        try state.write(legacyJSON(session: "old", token: "tok-old"), to: ChatTermState.legacyFileName)
        #expect(throws: ChatTermState.Failure.unreadable) { try ChatTermState(store: state).read() }
        #expect(mode(pathOf(state, ChatTermState.legacyFileName)) != -1, "the root, possibly the only good copy, stays")
        #expect(String(decoding: try ReadOnlyFile.data(pathOf(state, ChatTermState.fileName)), as: UTF8.self) == "{torn")
        var lines: [String] = []
        TermStartSweep.run(store: state, seconds: 0.2) { lines.append($0) }
        #expect(lines == ["CHAT notice kind=state-unreadable"], "logged: \(lines)")
    }

    @Test func ChatOrcaD8_L2_aRefusedPrivateFolderStillClosesTheRootTo0600() throws {
        let state = try artifactStore()
        try FileManager.default.createDirectory(atPath: pathOf(state, "chat-private"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try state.write(legacyJSON(session: "sess", token: "tok-x"), to: ChatTermState.legacyFileName)
        chmod(pathOf(state, ChatTermState.legacyFileName), 0o644)
        let read = try ChatTermState(store: state).read()
        #expect(read.sessionId == "sess", "the state is still served from the root")
        #expect(mode(pathOf(state, ChatTermState.legacyFileName)) == 0o600, "closed to group and others although the move was refused")
        #expect(mode(pathOf(state, ChatTermState.fileName)) == -1)
    }

    @Test func ChatOrcaD8_L3_aPrivateFolderThatCannotBeSearchedIsUnreadableNotEmpty() throws {
        let state = try artifactStore()
        try state.privateDirectory("chat-private")
        chmod(pathOf(state, "chat-private"), 0o000)
        defer { chmod(pathOf(state, "chat-private"), 0o700) }
        #expect(throws: ChatTermState.Failure.unreadable) { try ChatTermState(store: state).read() }
        var lines: [String] = []
        TermStartSweep.run(store: state, seconds: 0.2) { lines.append($0) }
        #expect(lines == ["CHAT notice kind=state-unreadable"], "\(lines)")
    }

    @Test func ChatOrcaD8_L9_aMalformedPrivateFileWithNoRootIsUnreadableAndLeftAsItIs() throws {
        let state = try artifactStore()
        try state.writePrivate(Data("{torn".utf8), to: ChatTermState.fileName)
        #expect(throws: ChatTermState.Failure.unreadable) { try ChatTermState(store: state).read() }
        #expect(String(decoding: try ReadOnlyFile.data(pathOf(state, ChatTermState.fileName)), as: UTF8.self) == "{torn")
    }

    @Test func ChatOrcaD8_L4_aPasteTempFileThatDiedMidWriteIsSweptOnceItIsOldAndNothingElseIs() throws {
        let state = try artifactStore()
        try state.privateDirectory(ClipboardImage.folder)
        let dead = ".clawd-paste-1-U.png.AbC123.tmp", fresh = ".clawd-paste-2-U.png.XyZ789.tmp", other = ".notes.tmp"
        for name in [dead, fresh, other] { try state.write(Data("png".utf8), to: ClipboardImage.folder + "/" + name) }
        let old = Date().addingTimeInterval(-2 * 3600)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: pathOf(state, ClipboardImage.folder + "/" + dead))
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: pathOf(state, ClipboardImage.folder + "/" + other))
        ClipboardImage.sweep(in: state)
        let left = state.entries(of: ClipboardImage.folder).map(\.name)
        #expect(left == [fresh, other].sorted(), "the old temp of a paste write is gone, a fresh one (a write in flight) and a foreign dot-file stay: \(left)")
    }

    @Test func ChatOrcaD8_L5_removeStaleTempsMatchesOnlyItsOwnNamePattern() throws {
        let state = try artifactStore()
        try state.privateDirectory("chat-private")
        let own = [".a.json.AbC123.tmp", ".chat-composer.json.zZ09aB.tmp"]
        let foreign = [".x.tmp", ".notes.tmp", ".a.json.AbCd.tmp", ".a.json.AbC12!.tmp", "a.json.AbC123.tmp", ".a.json.AbC123.tmp.bak", "..AbC123.tmp"]
        for name in own + foreign { try state.write(Data("t".utf8), to: "chat-private/" + name) }
        #expect(state.removeStaleTemps(in: "chat-private") == own.count)
        #expect(state.entries(of: "chat-private").map(\.name) == foreign.sorted(), "\(state.entries(of: "chat-private").map(\.name))")
    }

    @Test func ChatOrcaD8_L6_aFailedBadRenameRefusesTheSaveSoTheBadFileIsNeverOverwritten() throws {
        let state = try artifactStore()
        try state.privateDirectory("chat-private")
        try state.write(Data("{nope".utf8), to: ChatComposerStore.fileName)
        // A non-empty folder in the .bad slot: the rename of the unparsable file onto it fails.
        try FileManager.default.createDirectory(atPath: pathOf(state, ChatComposerStore.fileName + ".bad/inside"), withIntermediateDirectories: true)
        let composer = store(state)
        composer.setDraft("typed"); composer.flush()
        #expect(composer.saveFailed && composer.draft == "typed", "the icon is up and the draft stays in memory")
        #expect(String(decoding: try ReadOnlyFile.data(pathOf(state, ChatComposerStore.fileName)), as: UTF8.self) == "{nope", "the unparsable file was not overwritten")
        try FileManager.default.removeItem(atPath: pathOf(state, ChatComposerStore.fileName + ".bad"))
        composer.setDraft("typed more"); composer.flush()
        let after = try readFile(state).draft
        #expect(!composer.saveFailed && after == "typed more", "once the slot is free the file is set aside and the save goes through")
        #expect(String(decoding: try ReadOnlyFile.data(pathOf(state, ChatComposerStore.fileName + ".bad")), as: UTF8.self) == "{nope")
    }

    @Test func ChatOrcaD8_S2N3_aBadFileThatVanishedFromTheBlockedSlotDoesNotKeepTheSaveRefused() throws {
        let state = try artifactStore()
        try state.privateDirectory("chat-private")
        try state.write(Data("{nope".utf8), to: ChatComposerStore.fileName)
        try FileManager.default.createDirectory(atPath: pathOf(state, ChatComposerStore.fileName + ".bad/inside"), withIntermediateDirectories: true)
        let composer = store(state)
        composer.setDraft("typed"); composer.flush()
        #expect(composer.saveFailed, "the .bad slot blocks the rename, so the save is refused")
        try FileManager.default.removeItem(atPath: pathOf(state, ChatComposerStore.fileName))
        composer.setDraft("typed more"); composer.flush()
        try #expect(!composer.saveFailed && (try readFile(state)).draft == "typed more", "the unparsable file is gone, so nothing blocks the write")
    }

    @Test func ChatOrcaD8_S2N2_theStoresHoldOnTheQuitIsReleasedWhenTheWriteIsMadeByTheTimerAndByAFlush() throws {
        let state = try artifactStore()
        let timers = ManualChatTimers()
        let composer = store(state, timers)
        #expect(!composer.holdsQuit)
        composer.setDraft("a")
        #expect(composer.holdsQuit, "a write is owed: a SIGTERM inside the 250 ms goes through the flush")
        timers.fire(exactly: ChatComposerStore.debounce)
        try #expect(!composer.holdsQuit && (try readFile(state)).draft == "a", "the timer's write released it")
        composer.setDraft("ab")
        #expect(composer.holdsQuit)
        composer.flush()
        try #expect(!composer.holdsQuit && (try readFile(state)).draft == "ab", "a flush released it")
        composer.flush()
        #expect(!composer.holdsQuit, "and a second flush has nothing to release")
    }

    @Test func ChatOrcaD8_L9_aRefusedFolderLogsOnceAndTheRecoveryOnce() throws {
        let state = try artifactStore()
        let logs = LogBox()
        let composer = store(state, logs: logs)
        try FileManager.default.createDirectory(atPath: pathOf(state, "chat-private"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        for text in ["a", "ab", "abc"] { composer.setDraft(text); composer.flush() }
        #expect(logs.lines.filter { $0.contains("saved=failed") }.count == 1, "\(logs.lines)")
        chmod(pathOf(state, "chat-private"), 0o700)
        composer.setDraft("abcd"); composer.flush(); composer.setDraft("abcde"); composer.flush()
        #expect(logs.lines.filter { $0.contains("saved=ok") }.count == 1 && logs.lines.filter { $0.contains("saved=") }.count == 2, "\(logs.lines)")
    }

    // MARK: Q8 pasted images

    @Test func ChatOrcaD8_aPastedPngIs0600InA0700FolderAnEarlierDefaultModeFolderIsRepairedAndALinkRefuses() throws {
        let png = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        let state = try artifactStore()
        let path = try ClipboardImage.store(png, in: state, milliseconds: 1, id: UUID())
        #expect(mode(path) == 0o600 && mode(pathOf(state, "chat-pastes")) == 0o700)
        let old = try artifactStore()
        try FileManager.default.createDirectory(atPath: pathOf(old, "chat-pastes"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        let repaired = try ClipboardImage.store(png, in: old, milliseconds: 2, id: UUID())
        #expect(mode(pathOf(old, "chat-pastes")) == 0o700 && mode(repaired) == 0o600, "a real folder of the user's own is narrowed first")
        let linked = try artifactStore()
        let elsewhere = try artifactStore()
        try elsewhere.privateDirectory("target")
        chmod(pathOf(elsewhere, "target"), 0o755)
        try FileManager.default.createSymbolicLink(atPath: pathOf(linked, "chat-pastes"), withDestinationPath: pathOf(elsewhere, "target"))
        #expect(throws: (any Error).self) { try ClipboardImage.store(png, in: linked, milliseconds: 3, id: UUID()) }
        #expect(mode(pathOf(elsewhere, "target")) == 0o755 && elsewhere.entries(of: "target").isEmpty, "a link is neither followed nor repaired")
    }

    @Test func ChatOrcaD8_theSweepNarrowsThePastesAnEarlierBuildLeftAtTheDefaultMode() throws {
        let state = try artifactStore()
        try FileManager.default.createDirectory(atPath: pathOf(state, "chat-pastes"), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o755])
        try state.write(Data("a".utf8), to: "chat-pastes/clawd-paste-1-A.png")
        try state.write(Data("n".utf8), to: "chat-pastes/notes.txt")
        chmod(pathOf(state, "chat-pastes/clawd-paste-1-A.png"), 0o644)
        chmod(pathOf(state, "chat-pastes/notes.txt"), 0o644)
        ClipboardImage.sweep(in: state)
        #expect(mode(pathOf(state, "chat-pastes")) == 0o700 && mode(pathOf(state, "chat-pastes/clawd-paste-1-A.png")) == 0o600)
        #expect(mode(pathOf(state, "chat-pastes/notes.txt")) == 0o644, "only the paste files are narrowed")
    }

    // MARK: Q7 the history

    @Test func ChatOrcaD7_upGoesBackToTheFirstAndStaysThereDownComesBackAndPastTheLastIsEmpty() {
        var history = ChatComposerHistory()
        for text in ["a", "b", "c"] { history.push(text) }
        #expect([history.previous(), history.previous(), history.previous(), history.previous()] == ["c", "b", "a", "a"])
        #expect([history.next(), history.next(), history.next()] == ["b", "c", ""] && history.index == nil)
        #expect(history.next() == nil, "Down while not recalling does nothing")
        var empty = ChatComposerHistory()
        #expect(empty.previous() == nil)
    }

    @Test func ChatOrcaD7_aDuplicateOfTheLastOrWhitespaceIsNotPushedAndAPushResetsTheIndex() {
        var history = ChatComposerHistory()
        history.push("a"); history.push("a"); history.push("  \n"); history.push("")
        #expect(history.entries == ["a"])
        history.push("b")
        _ = history.previous()
        history.push("b")
        #expect(history.entries == ["a", "b"] && history.index == nil, "a push resets the index even when nothing is added")
        history.push("a")
        #expect(history.entries == ["a", "b", "a"], "only the last entry is compared")
        history.edited()
        #expect(history.index == nil)
    }

    @Test func ChatOrcaD7_fiveSendsOfOneMiBKeepTheNewestFourAndFourStayWhole() {
        var history = ChatComposerHistory()
        let mebibyte = 1_048_576
        let texts = (1...5).map { String(UnicodeScalar(UInt8(64 + $0))) + String(repeating: "x", count: mebibyte - 1) }
        for text in texts.prefix(4) { history.push(text) }
        #expect(history.entries == Array(texts.prefix(4)), "4 MiB exactly is kept")
        history.push(texts[4])
        #expect(history.entries == Array(texts.suffix(4)), "the oldest went first")
        #expect(ChatComposerHistory.capBytes == 4 * 1024 * 1024)
    }
}
