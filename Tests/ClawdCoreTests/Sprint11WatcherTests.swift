import Testing
import Foundation
import CoreGraphics
import ClawdCore
import ClawdRendering
import ClawdDesktop

// Sprint 11 (spec 9b item 16, item 2 of the brief): the settings watcher takes the content and the signature of control.json from ONE open
// file, so a generation the CLI saves while a read is going on is read by the next check instead of being labelled as already seen.

/// The way the CLI writes control.json (bin/clawd-pet write_control): read, change one key, bump `generation`, write a partial file and
/// rename it over control.json.
func writeControlLikeTheCLI(_ root: URL, _ changes: [String: Any], bump: Bool = true) throws {
    let target = root.appendingPathComponent("control.json"), partial = root.appendingPathComponent("control.json.partial")
    var object = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: target))) as? [String: Any]) ?? [:]
    for (key, value) in changes { object[key] = value }
    if bump { object["generation"] = ((object["generation"] as? Int) ?? 0) + 1 }
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: partial)
    guard rename(partial.path, target.path) == 0 else { throw FileFailure.system(errno) }
}

private final class SinkRecorder: SettingsApplySink {
    var applied: [Int] = []
    var confirmed: [Int] = []
    func apply(_ settings: AppliedSettings) { applied.append(settings.generation) }
    func applied(generation: Int, settings: AppliedSettings) { confirmed.append(generation) }
}

@Suite("Sprint 11 settings watcher", .serialized)
struct Sprint11WatcherTests {
    @Test func Watcher_aGenerationSavedWhileTheStartReadsTheFileIsReadAtOnceAndNeverLost() throws {
        let store = try artifactStore()
        try writeControlLikeTheCLI(store.root, ["walk": true], bump: false)                                   // generation 0
        let watcher = SettingsWatcher(store: store, queue: DispatchQueue(label: "sprint11.watcher.load"))
        var opened = 0
        // The CLI saves generation 1 at the one moment that matters: the file is open, its content is not taken yet.
        watcher.afterOpen = { opened += 1; if opened == 1 { try? writeControlLikeTheCLI(store.root, ["walk": false]) } }
        let loaded = watcher.load()
        #expect(loaded.generation == 0 && loaded.scheduler.walk, "the load took the content of the file it had open: generation 0")
        let sink = SinkRecorder()
        watcher.start(sink: sink)
        #expect(sink.confirmed == [0, 1], "generation 1 is applied by the start's own check, not skipped: \(sink.confirmed)")
        #expect(watcher.current.generation == 1 && !watcher.current.scheduler.walk)
        #expect(watcher.appliedGeneration == 1)
        watcher.stop()
    }

    @Test func Watcher_aGenerationSavedWhileACheckReadsTheFileIsReadByTheNextCheck() throws {
        let store = try artifactStore()
        try writeControlLikeTheCLI(store.root, ["walk": true], bump: false)                                   // generation 0
        let watcher = SettingsWatcher(store: store, queue: DispatchQueue(label: "sprint11.watcher.check"))
        _ = watcher.load()
        try writeControlLikeTheCLI(store.root, ["walk": false])                                               // generation 1 is on disk
        var raced = false
        watcher.afterOpen = { if !raced { raced = true; try? writeControlLikeTheCLI(store.root, ["motion": "off"]) } }       // generation 2 lands during the read
        watcher.check()
        #expect(watcher.current.generation == 1 && !watcher.current.scheduler.walk, "the check applied what it had open: generation 1")
        #expect(watcher.current.scheduler.motion != .off)
        watcher.check()
        #expect(watcher.current.generation == 2 && watcher.current.scheduler.motion == .off, "the next check reads generation 2: it was labelled with the file that was read, not the one at the path")
        #expect(watcher.appliedGeneration == 2)
    }

    @Test func Watcher_aFileThatCannotBeReadAsAnObjectIsLeftAloneAndTheNextReplacementIsRead() throws {
        let store = try artifactStore()
        try writeControlLikeTheCLI(store.root, ["walk": true], bump: false)
        let watcher = SettingsWatcher(store: store, queue: DispatchQueue(label: "sprint11.watcher.bad"))
        _ = watcher.load()
        try Data("{{{ not json".utf8).write(to: store.root.appendingPathComponent("control.json"))
        watcher.check()
        #expect(watcher.current.generation == 0 && watcher.applyCount == 0)
        var reads = 0
        watcher.afterOpen = { reads += 1 }
        watcher.check()
        #expect(reads == 0, "the damaged file is not read again until it is replaced")
        try writeControlLikeTheCLI(store.root, ["walk": false], bump: false)
        watcher.check()
        #expect(reads == 1 && !watcher.current.scheduler.walk)
    }
}
