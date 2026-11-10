import Testing
import Foundation
import AppKit
import ClawdCore
import ClawdDesktop

// Restart-only rows and Settings' reopen (Stage SA, Sprint SA5). The `open-settings` request is judged against stubbed clocks and a stubbed process
// table; the reopen goes through the inert `settingsPresent` seam and never makes a window key; the CLI is the stub. Nothing here shows a window,
// touches the real state folder or reads the real kern.boottime.

@Suite("SettingsRestart", .serialized)
@MainActor
struct SettingsRestartSuite {
    static let boot = SettingsRequest.Boot(seconds: 1_790_000_000, microseconds: 123_456)
    static let second: UInt64 = 1_000_000_000
    /// The writer's CLOCK_MONOTONIC reading in the table, in nanoseconds.
    static let written: UInt64 = 500 * second
    static let words = "Clawd restarts for 2 s; this window closes and opens again"

    /// A rig whose clocks and process table are fixed: the pet's own pid is 4242, the monotonic clock reads 777 s, and every pid runs as the pet.
    static let rigSeams = SettingsRequestSeams(ownPid: { 4242 }, monotonicNanoseconds: { 777 * 1_000_000_000 }, boot: { SettingsRestartSuite.boot }, runsAsPet: { _ in true })

    static func restart(_ section: String? = "look") -> SettingsRequestVerdict { .pass(origin: SettingsRequest.originSettingsRestart, section: section) }

    private func line(origin: String = "settings-restart", pid: Int32 = 4242, mono: UInt64 = SettingsRestartSuite.written,
                      boot: SettingsRequest.Boot = SettingsRestartSuite.boot, section: String? = "look") -> String {
        SettingsRequest(origin: origin, pid: pid, mono: mono, boot: boot, section: section).line
    }

    /// Writes `data` as the request file, takes it with the stubbed clocks and says whether the file is gone afterwards.
    private func take(_ data: Data, now: UInt64 = SettingsRestartSuite.written + 5 * SettingsRestartSuite.second,
                      boot: SettingsRequest.Boot? = SettingsRestartSuite.boot, pet: Set<Int32> = []) throws -> (SettingsRequestVerdict, gone: Bool, asked: [Int32]) {
        let store = try artifactStore()
        try store.write(data, to: SettingsRequest.fileName)
        var asked: [Int32] = []
        let seams = SettingsRequestSeams(ownPid: { 1 }, monotonicNanoseconds: { now }, boot: { boot }, runsAsPet: { asked.append($0); return pet.contains($0) })
        let verdict = SettingsRequestFile.take(store: store, seams: seams)
        var info = stat()
        return (verdict, lstat(try store.url(SettingsRequest.fileName).path, &info) != 0, asked)
    }
    private func take(_ text: String, now: UInt64 = SettingsRestartSuite.written + 5 * SettingsRestartSuite.second,
                      boot: SettingsRequest.Boot? = SettingsRestartSuite.boot, pet: Set<Int32> = []) throws -> (SettingsRequestVerdict, gone: Bool, asked: [Int32]) {
        try take(Data(text.utf8), now: now, boot: boot, pet: pet)
    }

    // MARK: the request, judged

    @Test func SettingsRestart_requestTable() throws {
        let second = Self.second, written = Self.written
        // A request that passes: this boot, an age from 0 up to but not including 30 s, a writer that is not the pet. It is read once.
        let good = try take(line())
        #expect(good.0 == .pass(origin: "settings-restart", section: "look") && good.gone, "\(good)")
        #expect(good.asked == [4242], "the process table is asked about the writer's pid and nobody else's: \(good.asked)")
        let bare = try take(line(section: nil))
        #expect(bare.0 == .pass(origin: "settings-restart", section: nil) && bare.gone)
        // An unknown origin, another boot (seconds, microseconds, unreadable), an age under 0 and an age of 30 s or more are dropped with no window.
        typealias Taken = (SettingsRequestVerdict, gone: Bool, asked: [Int32])
        var dropped: [(name: String, taken: Taken, reason: String)] = []
        dropped.append(("an unknown origin", try take(line(origin: "bogus")), "origin"))
        dropped.append(("another boot (seconds)", try take(line(), boot: SettingsRequest.Boot(seconds: Self.boot.seconds + 1, microseconds: Self.boot.microseconds)), "boot"))
        dropped.append(("another boot (microseconds)", try take(line(), boot: SettingsRequest.Boot(seconds: Self.boot.seconds, microseconds: Self.boot.microseconds + 1)), "boot"))
        dropped.append(("an unreadable boot time", try take(line(), boot: nil), "boot"))
        dropped.append(("an age under 0", try take(line(), now: written - 1), "future"))
        dropped.append(("an age of exactly 30 s", try take(line(), now: written + 30 * second), "old"))
        dropped.append(("an age over 30 s", try take(line(), now: written + 31 * second), "old"))
        dropped.append(("a settings-restart whose writer still runs as the pet", try take(line(), pet: [4242]), "writer"))
        for entry in dropped {
            #expect(entry.taken.0 == .dropped(reason: entry.reason), "\(entry.name): \(entry.taken.0)")
            #expect(entry.taken.gone, "\(entry.name): the request is read once, passing or not")
        }
        // The edges that pass: an age of 0 and an age just under 30 s; a pet running under another pid is not the writer.
        let edgeNow = try take(line(), now: written), edgeLate = try take(line(), now: written + 30 * second - 1), otherPids = try take(line(), pet: [1, 2, 3])
        for edge in [edgeNow, edgeLate, otherPids] { #expect(edge.0 == .pass(origin: "settings-restart", section: "look"), "\(edge)") }
        // The writer rule is for settings-restart only: the front door's writer is the pet that is not running any more or never was.
        let frontdoor = try take(line(origin: "frontdoor"), pet: [4242])
        #expect(frontdoor.0 == .pass(origin: "frontdoor", section: "look"), "\(frontdoor)")
        // The wall clock is not a seam of the judgment: the monotonic readings here are a few hundred seconds, so an age read from the wall clock
        // (about 1.8e18 ns) could never fall under 30 s, and the passing cases above would not pass.
        // A line of any other form is dropped, and removed.
        let junk: [(String, Data)] = [
            ("empty", Data()),
            ("binary", Data([0xff, 0xfe, 0x00, 0x01])),
            ("two lines", Data((line() + line()).utf8)),
            ("a version other than 1", Data(line().replacingOccurrences(of: "v=1", with: "v=2").utf8)),
            ("fields in another order", Data("v=1 pid=4242 origin=settings-restart mono=\(written) boot=\(Self.boot.text)\n".utf8)),
            ("two spaces", Data(line().replacingOccurrences(of: "origin", with: " origin").utf8)),
            ("pid 0", Data(line(pid: 1).replacingOccurrences(of: "pid=1", with: "pid=0").utf8)),
            ("a pid with a leading zero", Data(line().replacingOccurrences(of: "pid=4242", with: "pid=04242").utf8)),
            ("a signed mono", Data(line().replacingOccurrences(of: "mono=", with: "mono=+").utf8)),
            ("a boot with five digits of microseconds", Data("v=1 origin=settings-restart pid=4242 mono=\(written) boot=1790000000.12345\n".utf8)),
            ("an unknown section", Data(line(section: "bogus").utf8)),
            ("a trailing field", Data((String(line().dropLast()) + " extra=1\n").utf8)),
            ("more than 256 bytes", Data((String(line().dropLast()) + String(repeating: "x", count: 300) + "\n").utf8)),
        ]
        for (name, data) in junk {
            let result = try take(data)
            #expect(result.0 == .dropped(reason: "form") && result.gone, "\(name): \(result)")
        }
        // No file, no verdict. A link in its place is dropped unread and removed itself, and what it points at is left alone.
        let store = try artifactStore()
        #expect(SettingsRequestFile.take(store: store, seams: Self.rigSeams) == .none)
        let target = try artifactStore().root.appendingPathComponent("target")
        try Data(line().utf8).write(to: target)
        try FileManager.default.createSymbolicLink(atPath: store.root.appendingPathComponent(SettingsRequest.fileName).path, withDestinationPath: target.path)
        let linked = SettingsRequestFile.take(store: store, seams: SettingsRequestSeams(ownPid: { 1 }, monotonicNanoseconds: { written }, boot: { Self.boot }, runsAsPet: { _ in false }))
        #expect(linked == .dropped(reason: "form"), "a link in the file's place is never followed: \(linked)")
        #expect(FileManager.default.fileExists(atPath: target.path), "what the link points at is left alone")
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: store.root.appendingPathComponent(SettingsRequest.fileName).path)) == nil,
                "the link itself is gone after the take")
        #expect(String(decoding: try ReadOnlyFile.data(target.path), as: UTF8.self) == line(), "the target is untouched")
    }

    // MARK: the reopen

    @Test func SettingsRestart_aReopenIsShownWithoutKeyAndArmsNoCause() async throws {
        let r = try SettingsRig(request: Self.restart("look"))
        #expect(r.settings.isOpen && r.settings.section == .look, "the window is open at the request's section")
        #expect(r.box.presented.count == 1 && r.box.presented.first === r.settings.window, "it is shown through settingsPresent: \(r.box.order)")
        #expect(r.box.keyed.isEmpty && !r.box.order.contains("makeKey"), "no settingsMakeKey: \(r.box.order)")
        #expect(!r.settings.causeIsArmed && r.focus.activationRequests == 0, "no cause is armed and no activation is asked for")
        #expect(r.lines("SETTINGS request") == ["SETTINGS request kept"], "\(r.lines("SETTINGS"))")
        let opens = r.lines("SETTINGS open")
        #expect(opens.count == 1 && opens[0].contains("cause=request") && opens[0].hasSuffix("section=look"), "\(opens)")
        // With nothing asked for, nothing is refused when the time passes.
        r.rig.advance(3)
        #expect(r.lines("SETTINGS activate-refused").isEmpty && r.violations == 0, "\(r.lines("SETTINGS"))")
        // The window can take key (on a click): a click on it is its activation's cause.
        let window = try r.window()
        #expect(window.isKeyAllowed)
        r.mouseDown(in: window)
        r.clawdBecomesActive()
        #expect(r.lines("SETTINGS active cause=click").count == 1 && r.violations == 0, "\(r.lines("SETTINGS"))")
        #expect(r.box.keyed.isEmpty, "the click is not a make-key call of the runtime's")
        // A request without a section opens at General.
        let plain = try SettingsRig(request: Self.restart(nil))
        #expect(plain.settings.section == .general && plain.box.keyed.isEmpty)
    }

    // MARK: the writer

    @Test func SettingsRestart_aWriterStillRunningWhenTheCLIReturnsRemovesItsRequest() async throws {
        for (exitCode, closeFirst) in [("0", false), ("3", false), ("1", false), ("2", false), ("0", true)] {
            let r = try SettingsRig(requestSeams: Self.rigSeams)
            try r.openFromMenuBar()
            let content = try #require(r.settings.content)
            let gate = r.stub.root.appendingPathComponent("release")
            try r.stub.set("stub-release", gate.path)
            try r.stub.set("stub-exit", exitCode)
            let file = try r.rig.store.url(SettingsRequest.fileName)
            #expect(!FileManager.default.fileExists(atPath: file.path), "no request before a restart-only row writes")
            press(try #require(content.button(for: .fullScreen(true))))
            // The request is written first, then the verb runs: by the time the CLI has started the request is there, as this process wrote it.
            await r.rig.spin(until: { r.stub.calls.contains { $0.hasPrefix("START") } }, limit: 20)
            #expect(r.stub.started.last == ["full-screen", "on"], "\(exitCode): \(r.stub.started)")
            let data = try #require(FileManager.default.contents(atPath: file.path), "\(exitCode): the request exists while the CLI runs")
            #expect(SettingsRequest.parse(data) == SettingsRequest(origin: "settings-restart", pid: 4242, mono: 777 * Self.second, boot: Self.boot, section: "general"),
                    "\(exitCode): \(String(decoding: data, as: UTF8.self))")
            if closeFirst { r.settings.close(.button) }
            // The CLI returns to this process: the restart did not happen, whatever the exit code, so the request is gone at once.
            try r.stub.set("release", "")
            await r.rig.spin(until: { !FileManager.default.fileExists(atPath: file.path) }, limit: 30)
            #expect(!FileManager.default.fileExists(atPath: file.path), "exit \(exitCode) closeFirst=\(closeFirst): the request is removed: \(r.stub.calls)")
        }
    }

    // MARK: the other side of the request

    @Test func SettingsRestart_aStandDownDropsTheRequest() throws {
        let r = try SettingsRig(examAtBoot: true, request: Self.restart("motion"))
        #expect(!r.settings.isOpen && r.box.presented.isEmpty && r.box.keyed.isEmpty, "no window in a stand-down")
        #expect(r.lines("SETTINGS request") == ["SETTINGS request dropped reason=exam"], "\(r.lines("SETTINGS"))")
        #expect(r.lines("SETTINGS open").isEmpty && r.lines("SETTINGS refuse").isEmpty, "the request is dropped before Settings is asked to open: \(r.lines("SETTINGS"))")
        // A request the judgment dropped opens nothing either, and says why.
        for reason in ["boot", "old", "future", "writer", "form", "origin"] {
            let q = try SettingsRig(request: .dropped(reason: reason))
            #expect(!q.settings.isOpen && q.box.presented.isEmpty && q.lines("SETTINGS request") == ["SETTINGS request dropped reason=\(reason)"], "\(reason): \(q.lines("SETTINGS"))")
        }
        let none = try SettingsRig()
        #expect(none.lines("SETTINGS request").isEmpty && !none.settings.isOpen, "no request, no line")
    }

    @Test func SettingsRestart_aFrontdoorRequestIsDroppedInThisStage() throws {
        let r = try SettingsRig(request: .pass(origin: SettingsRequest.originFrontdoor, section: "about"))
        #expect(!r.settings.isOpen && r.box.presented.isEmpty && r.box.keyed.isEmpty && !r.settings.causeIsArmed, "nothing opens for a front-door request")
        #expect(r.lines("SETTINGS request") == ["SETTINGS request dropped reason=origin"], "\(r.lines("SETTINGS"))")
        #expect(r.lines("SETTINGS open").isEmpty)
    }

    // MARK: the words

    @Test func SettingsRestart_rowsSayTheyRestartBeforeTheyWrite() async throws {
        let r = try SettingsRig(requestSeams: Self.rigSeams)
        try r.openFromMenuBar()
        let content = try #require(r.settings.content)
        let labels = allLabels(in: content.root)
        #expect(labels.contains("Show Clawd over full-screen apps"), "General names the row: \(labels)")
        #expect(labels.filter { $0 == Self.words }.count == 1, "the words are under the row: \(labels)")
        let caption = try #require(allTextFields(in: content.root).first { $0.stringValue == Self.words })
        #expect(!caption.isHidden && !caption.isEditable && !caption.isSelectable)
        #expect(r.cliRuns.isEmpty && r.lines("MENU").isEmpty, "the words are there before anything is written")
        // The words belong to the restart-only row alone.
        for section in SettingsSection.listed where section != .general {
            content.show(section)
            #expect(!allLabels(in: content.root).contains(Self.words), "\(section) has no restart-only row")
        }
        content.show(.general)
        // The row starts at what control.json holds (off), and a press runs `full-screen on` and shows On at once.
        let on = try #require(content.button(for: .fullScreen(true))), off = try #require(content.button(for: .fullScreen(false)))
        #expect(off.state == .on && on.state == .off)
        press(on)
        #expect(on.state == .on && off.state == .off && content.isPending(.fullScreen))
        await r.rig.spin(until: { finishedWrites(r) >= 1 }, limit: 30)
        #expect(r.stub.started.last == ["full-screen", "on"], "\(r.stub.started)")
    }

    // MARK: the request's lifetime

    private func startedCount(_ r: SettingsRig) -> Int { r.stub.started.count }
    /// A stand-in CLI that holds each verb at a gate of its own (`gate-<arguments joined with ->`) and then exits with `code`: two picks can then be
    /// held and released one by one without a swap of a shared gate file that a starting child might read late.
    private func installGatedCLI(_ r: SettingsRig, exit code: Int) throws {
        let script = """
        #!/bin/bash
        log="$HOME/calls.log"
        { printf 'START 0 ARGS'; for a in "$@"; do printf ' [%s]' "$a"; done; printf '\\n'; } >> "$log"
        gate="$HOME/gate-$(IFS=-; echo "$*")"
        while [ ! -e "$gate" ]; do /bin/sleep 0.05; done
        exit \(code)
        """
        try r.stub.store.write(Data(script.utf8), to: "bin/clawd-pet")
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: r.stub.cli.path)
    }
    private func release(_ r: SettingsRig, _ gate: String) { FileManager.default.createFile(atPath: r.stub.root.appendingPathComponent("gate-" + gate).path, contents: Data()) }
    private func requestData(_ r: SettingsRig) throws -> Data? { FileManager.default.contents(atPath: try r.rig.store.url(SettingsRequest.fileName).path) }

    @Test func SettingsRestart_anEarlierPicksCompletionKeepsALaterPicksRequest() async throws {
        // SA5-1b: a second restart pick can no longer wait behind the first (it is refused), so the guard is tested against any other writer of
        // the request file: the pick's completion removes the request only while the file still holds the line the pick wrote.
        let r = try SettingsRig(requestSeams: Self.rigSeams)
        try r.openFromMenuBar()
        let content = try #require(r.settings.content)
        try installGatedCLI(r, exit: 3)
        press(try #require(content.button(for: .fullScreen(true))))
        await r.rig.spin(until: { startedCount(r) >= 1 }, limit: 20)
        let own = try requestData(r)
        #expect(try #require(own, "the pick wrote its request").isEmpty == false)
        // Another writer leaves a different valid request line in the file's place while the pick runs.
        let other = SettingsRequest(origin: "settings-restart", pid: 4242, mono: 888 * Self.second, boot: Self.boot, section: "look").line
        try r.rig.store.write(Data(other.utf8), to: SettingsRequest.fileName)
        #expect(try requestData(r) == Data(other.utf8) && Data(other.utf8) != own)
        release(r, "full-screen-on")
        await r.rig.spin(until: { finishedWrites(r) >= 1 }, limit: 30)
        #expect(r.stub.started == [["full-screen", "on"]] && finishedWrites(r) == 1, "\(r.stub.started) \(r.lines("MENU"))")
        let after = try requestData(r)
        #expect(after == Data(other.utf8), "the completion kept a request that is not its own: \(String(describing: after.map { String(decoding: $0, as: UTF8.self) }))")
    }

    @Test func SettingsRestart_aRequestIsWrittenWhenItsPickStartsToRun() async throws {
        final class Clock { var now: UInt64 = 100 * SettingsRestartSuite.second }
        let clock = Clock()
        let seams = SettingsRequestSeams(ownPid: { 4242 }, monotonicNanoseconds: { clock.now }, boot: { SettingsRestartSuite.boot }, runsAsPet: { _ in true })
        let r = try SettingsRig(requestSeams: seams)
        try r.openFromMenuBar()
        let content = try #require(r.settings.content)
        try installGatedCLI(r, exit: 0)
        press(content.hideButton)
        await r.rig.spin(until: { startedCount(r) >= 1 }, limit: 20)
        press(try #require(content.button(for: .fullScreen(true))))
        let early = try requestData(r)
        #expect(early == nil, "nothing is written while the pick waits")
        clock.now = 140 * Self.second
        release(r, "hide-60")
        await r.rig.spin(until: { startedCount(r) >= 2 }, limit: 30)
        let written = try requestData(r)
        let data = try #require(written, "the request is written when the restart pick starts")
        #expect(SettingsRequest.parse(data)?.mono == 140 * Self.second, "its mono is read at the start, not at the press: \(String(decoding: data, as: UTF8.self))")
        release(r, "full-screen-on")
        await r.rig.spin(until: { finishedWrites(r) >= 2 }, limit: 30)
    }

    // MARK: the restart close

    @Test func SettingsRestart_anUnrelatedApplyAfterAFailedRestartDoesNotClose() async throws {
        let r = try SettingsRig(requestSeams: Self.rigSeams)
        try r.openFromMenuBar()
        let gate = r.stub.root.appendingPathComponent("release")
        try r.stub.set("stub-release", gate.path); try r.stub.set("stub-exit", "3")
        let opened = try #require(r.settings.content)
        press(try #require(opened.button(for: .fullScreen(true))))
        await r.rig.spin(until: { startedCount(r) >= 1 }, limit: 20)
        // The CLI writes the key while this window's own restart-only pick runs: the window closes.
        try writeControlLikeTheCLI(r.rig.store.root, ["overFullScreen": true])
        await r.rig.spin(until: { !r.settings.isOpen }, limit: 20)
        #expect(!r.settings.isOpen && r.lines("SETTINGS close reason=restart").count == 1, "\(r.lines("SETTINGS"))")
        // The restart fails (the CLI returns): the key stays pending. Tom opens Settings again and changes an unrelated row.
        FileManager.default.createFile(atPath: gate.path, contents: Data())
        await r.rig.spin(until: { finishedWrites(r) >= 1 }, limit: 30)
        r.settings.begin(cause: .statusMenu)
        let content = try #require(r.settings.content)
        content.show(.motion)
        try writeControlLikeTheCLI(r.rig.store.root, ["motion": "lively"])
        await r.rig.spin(until: { r.runtime.menuSelection().motion == .lively }, limit: 20)
        await r.rig.spin(until: { content.button(for: .motion(.lively))?.state == .on }, limit: 20)
        #expect(r.settings.isOpen && content.button(for: .motion(.lively))?.state == .on, "the apply refreshed the rows: \(r.lines("SETTINGS"))")
        #expect(r.lines("SETTINGS close reason=restart").count == 1, "an unrelated apply does not close: \(r.lines("SETTINGS"))")
    }

    // MARK: what the row shows

    @Test func SettingsRestart_theRowShowsWhatThisProcessBootedWith() async throws {
        let r = try SettingsRig()
        // A value saved after the boot (a restart that did not happen) is not in effect.
        try writeControlLikeTheCLI(r.rig.store.root, ["overFullScreen": true])
        await r.rig.spin(until: { !r.lines("SETTINGS restart-required").isEmpty }, limit: 20)
        #expect(!r.lines("SETTINGS restart-required").isEmpty, "the write landed: \(r.lines("SETTINGS"))")
        try r.openFromMenuBar()
        let content = try #require(r.settings.content)
        #expect(r.runtime.settingsValues().overFullScreen == false, "the values are the boot's")
        #expect(content.button(for: .fullScreen(false))?.state == .on && content.button(for: .fullScreen(true))?.state == .off,
                "an open shows Off, the boot value, not the saved On")
    }

    // MARK: a request that cannot be written

    @Test func SettingsRestart_aRequestThatCannotBeWrittenRunsNoVerb() async throws {
        let unreadableBoot = SettingsRequestSeams(ownPid: { 4242 }, monotonicNanoseconds: { 777 * 1_000_000_000 }, boot: { nil }, runsAsPet: { _ in true })
        let r = try SettingsRig(requestSeams: unreadableBoot)
        try r.openFromMenuBar()
        let content = try #require(r.settings.content)
        press(try #require(content.button(for: .fullScreen(true))))
        await r.rig.spin(until: { !content.isPending(.fullScreen) }, limit: 30)
        #expect(r.cliRuns.isEmpty && r.stub.started.isEmpty, "the verb does not run: \(r.stub.calls)")
        #expect(content.button(for: .fullScreen(false))?.state == .on && content.button(for: .fullScreen(true))?.state == .off, "the row goes back to what is in effect")
        #expect(content.message(for: .fullScreen) == "Clawd could not save that", "\(content.message(for: .fullScreen))")
        let none = try requestData(r)
        #expect(none == nil)
        // A pick that follows is not held up by it.
        press(content.hideButton)
        await r.rig.spin(until: { finishedWrites(r) >= 2 }, limit: 30)
        #expect(r.stub.started.count == 1 && r.stub.started[0].first == "hide", "\(r.stub.started)")
    }

    // MARK: a link at open-settings

    @Test func SettingsRestart_aLinkAtOpenSettingsIsRemovedNotFollowed() throws {
        let store = try artifactStore()
        let outside = try artifactStore().root.appendingPathComponent("outside")
        try Data("keep".utf8).write(to: outside)
        let path = store.root.appendingPathComponent(SettingsRequest.fileName).path
        try FileManager.default.createSymbolicLink(atPath: path, withDestinationPath: outside.path)
        try store.removeFile(SettingsRequest.fileName)
        #expect((try? FileManager.default.destinationOfSymbolicLink(atPath: path)) == nil && !FileManager.default.fileExists(atPath: path), "the link is gone")
        #expect(String(decoding: try ReadOnlyFile.data(outside.path), as: UTF8.self) == "keep", "its target is untouched")
        // A link in a directory above the file is still refused.
        let real = try artifactStore().root.appendingPathComponent("real")
        try FileManager.default.createDirectory(at: real, withIntermediateDirectories: true)
        try Data("x".utf8).write(to: real.appendingPathComponent("file"))
        try FileManager.default.createSymbolicLink(atPath: store.root.appendingPathComponent("dir").path, withDestinationPath: real.path)
        #expect(throws: (any Error).self) { try store.removeFile("dir/file") }
        #expect(FileManager.default.fileExists(atPath: real.appendingPathComponent("file").path), "nothing was removed through the link")
    }

    // MARK: SA5-1b: a pick made while a restart runs

    private static let restartingText = "Clawd is restarting; pick this again once it is back"

    @Test func SettingsRestart_aRowPickedWhileARestartRunsSaysSoAndRevertsAndWritesNoRequest() async throws {
        let r = try SettingsRig(requestSeams: Self.rigSeams)
        try r.openFromMenuBar()
        let content = try #require(r.settings.content)
        try installGatedCLI(r, exit: 0)
        press(try #require(content.button(for: .fullScreen(true))))
        await r.rig.spin(until: { startedCount(r) >= 1 }, limit: 20)
        let before = try requestData(r)
        #expect(before != nil)
        content.show(.motion)
        let old = r.runtime.menuSelection().motion
        let wanted: MotionLevel = old == .lively ? .quiet : .lively
        press(try #require(content.button(for: .motion(wanted))))
        #expect(content.button(for: .motion(old))?.state == .on && content.button(for: .motion(wanted))?.state == .off, "the row shows its old value")
        #expect(content.message(for: .motion) == Self.restartingText && !content.isPending(.motion), "\(String(describing: content.message(for: .motion)))")
        #expect(try requestData(r) == before && startedCount(r) == 1, "no request written, no second child")
        release(r, "full-screen-on")
        await r.rig.spin(until: { finishedWrites(r) >= 1 }, limit: 30)
        #expect(startedCount(r) == 1 && finishedWrites(r) == 1, "the refused pick never ran: \(r.stub.started)")
    }

    @Test func SettingsRestart_theSameRowPickedAgainWhileItsRestartRunsKeepsTheRunningPicksState() async throws {
        let r = try SettingsRig(requestSeams: Self.rigSeams)
        try r.openFromMenuBar()
        let content = try #require(r.settings.content)
        try installGatedCLI(r, exit: 3)
        press(try #require(content.button(for: .fullScreen(true))))
        await r.rig.spin(until: { startedCount(r) >= 1 }, limit: 20)
        let own = try requestData(r)
        #expect(own != nil)
        press(try #require(content.button(for: .fullScreen(false))))
        #expect(content.button(for: .fullScreen(true))?.state == .on && content.button(for: .fullScreen(false))?.state == .off, "the row keeps the running pick's state")
        #expect(content.message(for: .fullScreen) == Self.restartingText && !content.isPending(.fullScreen))
        #expect(try requestData(r) == own, "after the refusal the file still holds the running pick's line")
        release(r, "full-screen-on")
        await r.rig.spin(until: { finishedWrites(r) >= 1 && content.message(for: .fullScreen) == "saved, pending" }, limit: 30)
        #expect(content.button(for: .fullScreen(true))?.state == .on && content.message(for: .fullScreen) == "saved, pending", "\(String(describing: content.message(for: .fullScreen)))")
        #expect(try requestData(r) == nil, "after the pick returns (exit 3) the request is gone")
        #expect(r.stub.started == [["full-screen", "on"]], "\(r.stub.started)")
    }

    @Test func SettingsRestart_restartPendingReadsTheControlFileOnDisk() throws {
        let r = try SettingsRig()
        #expect(r.runtime.restartPending() == false, "no file and the defaults are the boot")
        try writeControlLikeTheCLI(r.rig.store.root, ["overFullScreen": true])
        #expect(r.runtime.restartPending() == true, "a full-screen value that differs from boot, not applied yet")
        try writeControlLikeTheCLI(r.rig.store.root, ["overFullScreen": false])
        #expect(r.runtime.restartPending() == false, "put back to the boot values")
        try Data("this is not json".utf8).write(to: r.rig.store.root.appendingPathComponent("control.json"))
        #expect(r.runtime.restartPending() == true, "a file that is not JSON counts as pending")
    }

    @Test func Writer_restartPendingReadsAMissingFileAsTheAgentsDefaults() throws {
        // (a) no file, and the defaults equal boot
        let a = try SettingsRig()
        #expect(!FileManager.default.fileExists(atPath: a.rig.store.root.appendingPathComponent("control.json").path))
        #expect(a.runtime.restartPending() == false)
        // (b) the agent booted from a file with a restart key set; the file is gone, so the defaults (full screen off) differ from boot
        let b = try SettingsRig(control: ["overFullScreen": true])
        let file = b.rig.store.root.appendingPathComponent("control.json")
        #expect(b.runtime.restartPending() == false, "the file equals boot")
        try FileManager.default.removeItem(at: file)
        #expect(b.runtime.restartPending() == true)
        // (c) a file that exists but does not parse
        try Data("{".utf8).write(to: file)
        #expect(b.runtime.restartPending() == true)
        let c = try SettingsRig()
        try Data("[]".utf8).write(to: c.rig.store.root.appendingPathComponent("control.json"))
        #expect(c.runtime.restartPending() == true)
    }

    // MARK: no timer, no watcher

    @Test func SettingsRestart_noTimerOrWatcher() throws {
        // The request is read once, at boot, by a plain read: its file names no timer, no file-system source, no poll and no deadline.
        let text = String(decoding: try ReadOnlyFile.data(repository.appendingPathComponent("Sources/ClawdCore/SettingsRequest.swift").path), as: UTF8.self)
        for word in ["DispatchSource", "Timer", "FSEvent", "kqueue", "NSFilePresenter", "asyncAfter", "DispatchQueue", "RunLoop", "LogTailer", "SettingsWatcher",
                     "deadlines", "schedule", "poll("] {
            #expect(!text.contains(word), "SettingsRequest.swift names \(word)")
        }
        // And a reopen arms nothing: the scheduler's timers are what they are without a request, and no deadline of Settings' is armed.
        let plain = try SettingsRig()
        let reopened = try SettingsRig(request: Self.restart("general"))
        #expect(reopened.settings.isOpen)
        #expect(reopened.rig.stage.wake.armedTimers == plain.rig.stage.wake.armedTimers, "the reopen armed a timer")
        #expect(!reopened.settings.causeIsArmed && reopened.focus.activationRequests == 0)
    }
}
