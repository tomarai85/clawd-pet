import Testing
import Foundation
import ClawdCore
import ClawdRendering
import ClawdDesktop

/// The way the CLI writes control.json (bin/clawd-pet write_control): under the lock, read, change one key, bump `generation`, write a
/// partial file and rename it over control.json.
private func writeControl(_ root: URL, _ changes: [String: Any], bump: Bool = true) throws {
    let target = root.appendingPathComponent("control.json"), partial = root.appendingPathComponent("control.json.partial")
    var object = ((try? JSONSerialization.jsonObject(with: Data(contentsOf: target))) as? [String: Any]) ?? [:]
    for (key, value) in changes { object[key] = value }
    if bump { object["generation"] = ((object["generation"] as? Int) ?? 0) + 1 }
    try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]).write(to: partial)
    guard rename(partial.path, target.path) == 0 else { throw FileFailure.system(errno) }
}

private final class RecordingSink: SettingsApplySink {
    var applied: [AppliedSettings] = []
    var confirmed: [Int] = []
    let semaphore = DispatchSemaphore(value: 0)
    func apply(_ settings: AppliedSettings) { applied.append(settings) }
    func applied(generation: Int, settings: AppliedSettings) { confirmed.append(generation); semaphore.signal() }
    func wait(count: Int, timeout: Double = 2) -> Bool {
        while confirmed.count < count { if semaphore.wait(timeout: .now() + timeout) == .timedOut { return false } }
        return true
    }
}

@Suite("Settings reading and the watcher", .serialized)
struct SettingsReadingSuite {
    @Test func Settings_everyKeyIsReadOnItsOwnAndOneBadValueResetsNothingElse() throws {
        let text = #"{"scale":"big","helmet":true,"walk":"yes","motion":"lively","lookEveryHours":3,"bubble":false,"bubbleExcluded":[2,"x"],"hiddenUntil":-1,"generation":9,"excluded":["D16"]}"#
        let settings = try #require(AppliedSettings.parse(Data(text.utf8)))
        #expect(settings.control.scale == 1, "scale of the wrong type: its default")
        #expect(settings.control.helmet, "a good key beside it is kept")
        #expect(settings.scheduler.walk, "walk of the wrong type: its default")
        #expect(settings.scheduler.motion == .lively); #expect(settings.scheduler.lookEveryHours == 3)
        #expect(!settings.scheduler.bubble); #expect(settings.scheduler.bubbleExcluded.isEmpty, "one bad element resets that key only")
        #expect(settings.scheduler.hiddenUntil == -1); #expect(settings.generation == 9); #expect(settings.scheduler.excluded == ["d16"])
        #expect(AppliedSettings.parse(Data("[1,2]".utf8)) == nil); #expect(AppliedSettings.parse(Data("{{{".utf8)) == nil)
        #expect(try JSONDecoder().decode(AgentControl.self, from: Data(#"{"scale":2,"helmet":"x","overFullScreen":true}"#.utf8)).scale == 2)
    }
    /// The two keys cover fifteen styles; a bad element resets only its key, and at least one old style stays enabled.
    @Test func Settings_bubbleExcludedTakesStylesOneToFifteen() throws {
        func read(_ old: String, _ new: String = "[]") throws -> Set<Int> {
            try #require(AppliedSettings.parse(Data(#"{"bubbleExcluded":\#(old),"bubbleExcludedNew":\#(new)}"#.utf8))).scheduler.bubbleExcluded
        }
        #expect(SchedulerSettings.bubbleStyles == Array(1...15))
        #expect(try read("[]", "[13,14,15]") == [13, 14, 15])
        #expect(try read("[3]", "[15]") == [3, 15])
        #expect(try read("[1,2,3,4,5,6,7,8,9,10,11]", "[13,14,15]") == Set(1...15).subtracting([12]), "fourteen exclusions leave one old style")
        #expect(try read("[4,13]", "[14]") == [14], "one bad old element resets only the old key")
        #expect(try read("[4]", "[13,16]") == [4], "one bad new element resets only the new key")
        for bad in [#"["13"]"#, "[true]", "[13.5]", "[12]", "13", "null"] {
            #expect(try read("[4]", bad) == [4])
        }
        for bad in [#"["4"]"#, "[false]", "[4.5]", "[0]", "[4,16]", "{}"] {
            #expect(try read(bad, "[13]") == [13])
        }
        #expect(try read("[4,4.0,4e0]", "[13,13.0]") == [4, 13], "whole numeric values and duplicates are valid")
        #expect(try read("[1,2,3,4,5,6,7,8,9,10,11,11]", "[13,14,15]") == Set(1...15).subtracting([12]), "the previous rule counts distinct styles")
        var settings = SchedulerSettings(); settings.bubbleExcluded = [13, 14]
        #expect(settings.enabledBubbleStyles == [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 15])
    }

    @Test func Settings_bubbleExcludedRejectsAllTwelveLegacyStyles() throws {
        for newer in [[], [13, 14], [13, 14, 15]] {
            let object: [String: Any] = ["bubbleExcluded": Array(1...12), "bubbleExcludedNew": newer, "walk": false, "generation": 9]
            let data = try JSONSerialization.data(withJSONObject: object)
            let settings = try #require(AppliedSettings.parse(data))
            #expect(settings.scheduler.bubbleExcluded == Set(newer), "all twelve void only the old key")
            #expect(settings.scheduler.enabledBubbleStyles.filter { $0 <= 12 } == Array(1...12))
            #expect(!settings.scheduler.walk && settings.generation == 9)
        }
    }

    // MARK: bubbleSide (amendment D-1)

    /// A missing key and every invalid value read as `below`, the one default.
    @Test func Settings_bubbleSideDefaultsToBelow() throws {
        #expect(SchedulerSettings().bubbleSide == .below)
        #expect(try #require(AppliedSettings.parse(Data(#"{"walk":false}"#.utf8))).scheduler.bubbleSide == .below, "a missing key")
        #expect(SchedulerSettings(object: [:]).bubbleSide == .below)
        #expect(BubbleSide.allCases.map(\.rawValue) == ["below", "above", "left", "right"])
    }
    @Test func Settings_bubbleSideRejectsUnknownWrongCaseAndNonString() throws {
        let bad: [Any] = ["up", "", "LEFT", "Left", " left", "left ", "rightt", "above\n", 3, 1.5, true, NSNull(), ["left"], ["side": "left"]]
        for value in bad {
            let object: [String: Any] = ["bubbleSide": value, "walk": false, "motion": "lively", "bubble": false, "generation": 4]
            let settings = try #require(AppliedSettings.parse(try JSONSerialization.data(withJSONObject: object)))
            #expect(settings.scheduler.bubbleSide == .below, "\(value) falls to below")
            #expect(!settings.scheduler.walk && settings.scheduler.motion == .lively && !settings.scheduler.bubble && settings.generation == 4, "the other keys are unaffected by \(value)")
        }
    }
    @Test func Settings_bubbleSideRoundTripsAllFour() throws {
        for side in BubbleSide.allCases {
            let settings = try #require(AppliedSettings.parse(Data(#"{"bubbleSide":"\#(side.rawValue)"}"#.utf8)))
            #expect(settings.scheduler.bubbleSide == side)
            #expect(MenuSelection(settings: settings).bubbleSide == side)
        }
    }
    /// control.json is the only store: a fresh settings object built from the file a previous process wrote reads the same side.
    @Test func Settings_bubbleSideSurvivesARestart() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("bubble-side-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        for side in BubbleSide.allCases {
            try writeControl(root, ["bubbleSide": side.rawValue, "walk": false])
            let data = try Data(contentsOf: root.appendingPathComponent("control.json"))
            let reborn = try #require(AppliedSettings.parse(data))
            #expect(reborn.scheduler.bubbleSide == side && !reborn.scheduler.walk)
            #expect(SchedulerSettings(data: data).bubbleSide == side)
        }
    }

    /// c1ce603's rule, independent of today's style list. Every CLI and menu write must remain valid under it.
    private func previousExclusions(_ value: Any?) -> Set<Int>? {
        guard let list = value as? [Any] else { return nil }
        let numbers = list.compactMap { value -> Int? in
            guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID() else { return nil }
            let d = n.doubleValue
            guard d.isFinite, d == d.rounded(), abs(d) < 1e12 else { return nil }
            return Int(d)
        }
        let styles = Set(numbers)
        return numbers.count == list.count && styles.isSubset(of: 1...12) && styles.count < 12 ? styles : nil
    }

    @MainActor @Test func Settings_CLIAndMenuKeepBothExclusionKeysReadableAcrossRollback() async throws {
        for menu in [false, true] {
            let home = try artifactStore()
            let root = try OwnState(root: home.root.appendingPathComponent("Library/Application Support/clawd-pet"))
            // An installed control.json always holds keys (install writes generation and the settings). A bare `{}` is not one: plutil reads
            // it as an OpenStep plist and refuses to write it back, so the CLI's edit would fail on the fixture, not on the rule under test.
            try writeControl(root.root, ["generation": 0], bump: false)
            try root.write(Data(), to: "control.lock")
            try home.write(Data("#!/bin/bash\nexit 1\n".utf8), to: "launchctl-stub")
            let cli = repository.appendingPathComponent("bin/clawd-pet").path.replacingOccurrences(of: "'", with: "'\\''")
            try home.write(Data("#!/bin/bash\nCLAWD_LAUNCHCTL=\"$HOME/launchctl-stub\" exec /bin/bash '\(cli)' \"$@\"\n".utf8), to: "bin/clawd-pet")
            for path in ["launchctl-stub", "bin/clawd-pet"] { try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: home.root.appendingPathComponent(path).path) }
            let writer = MenuWriter(home: home.root, log: { _ in })
            let layout = MenuLayout(looks: ["plain"], drawnStyles: Set(1...15))
            var expected = Set<Int>()
            for (index, style) in [13, 4, 14, 15, 4, 13, 14, 15].enumerated() {
                let before = try #require(AppliedSettings.parse(Data(contentsOf: root.root.appendingPathComponent("control.json"))))
                let item = try #require(layout.items.first { $0.key == "style" && $0.value == String(style) })
                let action = try #require(MenuSelection(settings: before).action(for: item))
                let verb = expected.contains(style) ? "include" : "exclude"
                #expect(action.arguments == ["bubble", verb, String(style)])
                if menu {
                    writer.submit(MenuPick(id: index, action: action, gen: index))
                    // The writer's completion comes on the main queue, which the full suite's main-actor tests keep busy for up to 78 s
                    // under load (measured 2026-10-22); the child itself takes 0.05 s. menuWait's ceiling is the one the writer tests use.
                    let finished = await menuWait { !writer.isRunning }
                    try #require(finished, "menu write finished")
                } else {
                    let result = try execute(home.root.appendingPathComponent("bin/clawd-pet"), action.arguments, environment: ["HOME": home.root.path], timeout: 20)
                    #expect(result.code == 0, "\(result.output)")
                }
                if verb == "exclude" { expected.insert(style) } else { expected.remove(style) }
                let data = try Data(contentsOf: root.root.appendingPathComponent("control.json"))
                let object = try #require(JSONSerialization.jsonObject(with: data) as? [String: Any])
                #expect(previousExclusions(object["bubbleExcluded"]) == expected.intersection(1...12), "menu=\(menu), step \(index): the previous parser retains every old exclusion")
                #expect(object["bubbleExcluded"] as? [Int] == expected.filter { $0 <= 12 }.sorted())
                #expect(object["bubbleExcludedNew"] as? [Int] == expected.filter { $0 >= 13 }.sorted())
                let parsed = try #require(AppliedSettings.parse(data))
                #expect(parsed.scheduler.bubbleExcluded == expected)
                #expect(MenuSelection(settings: parsed).excludedStyles == expected)
                #expect(parsed.generation == index + 1, "both keys change in one generation")
            }
        }
        #expect(previousExclusions(Array(1...12)) == nil, "a rollback with only new styles enabled restores all twelve")
    }

    @Test func AgentState_newStylesAreSafeForThePreviousRestoreRule() throws {
        let position = SavedPosition(displayUUID: "display", xFrac: 0.4, feetFrac: 0.2, scale: 2)
        for style in 13...15 {
            let state = AgentState(position: position, look: "plain", lookSince: 1_800_000_000, recentLooks: ["plain"], lastBubbleStyle: style, helmetOffPending: true)
            // c1ce603 has the same Codable fields; only its allowed style list differs.
            let decoded = try JSONDecoder().decode(AgentState.self, from: JSONEncoder().encode(state))
            let previousStyle = decoded.lastBubbleStyle.flatMap { (1...12).contains($0) ? $0 : nil }
            #expect(previousStyle == nil)
            #expect(decoded.position == position && decoded.look == "plain" && decoded.lookSince == state.lookSince)
            #expect(decoded.recentLooks == ["plain"] && decoded.helmetOffPending == true)
        }
    }

    /// The restart right after a dictation that used style 14 (the swap, a reboot): state.json's lastBubbleStyle 14 comes back, so the next draw is never 14.
    @Test func AgentState_restoresALastBubbleStyleFromThirteenToFifteen() {
        let position = SavedPosition(displayUUID: nil, xFrac: 0.5, feetFrac: 0, scale: 1)
        let catalog = PetCatalog()
        let now = 1_800_000_000.0
        for style in [13, 14, 15] {
            let state = AgentState(position: position, lastBubbleStyle: style)
            #expect(state.persisted(catalog: catalog, nowEpoch: now).lastBubbleStyle == style, "style \(style) is restored")
        }
        #expect(AgentState(position: position, lastBubbleStyle: 16).persisted(catalog: catalog, nowEpoch: now).lastBubbleStyle == nil, "16 restores nothing")
        #expect(AgentState(position: position, lastBubbleStyle: 0).persisted(catalog: catalog, nowEpoch: now).lastBubbleStyle == nil)
        // the next draw after a restored 14 is never 14
        let enabled = SchedulerSettings().enabledBubbleStyles
        for unit in stride(from: 0.0, to: 1.0, by: 0.01) { #expect(BubbleStyles.draw(enabled: enabled, last: 14, unit: unit) != 14) }
    }

    @Test func Settings_helmetOnPinsTheHelmetAndHelmetOffGoesBackToPlainOnceThenRotationResumes() {
        var control = AgentControl(); control.helmet = true
        let on = AppliedSettings(control: control)
        #expect(on.effectiveScheduler(helmetOffPending: false).lookPin == "helmet")
        var alias = HelmetAlias(helmet: false)
        alias.settingsChanged(helmet: true, currentLook: "plain")
        alias.settingsChanged(helmet: false, currentLook: "helmet")
        #expect(alias.offPending)
        control.helmet = false
        #expect(AppliedSettings(control: control).effectiveScheduler(helmetOffPending: true).lookPin == "plain")
        let other = alias.lookChanged(to: "sunglasses")
        #expect(!other, "another look does not end the one-shot")
        let ended = alias.lookChanged(to: "plain")
        #expect(ended); #expect(!alias.offPending)
        #expect(AppliedSettings(control: control).effectiveScheduler(helmetOffPending: alias.offPending).lookPin == nil, "rotation resumes")
        var already = HelmetAlias(helmet: true)
        already.settingsChanged(helmet: false, currentLook: "plain")
        #expect(!already.offPending, "helmet off while plain is worn needs no pin")
        // An explicit look pin beats the alias.
        var scheduler = SchedulerSettings(); scheduler.lookPin = "sunglasses"
        #expect(AppliedSettings(control: on.control, scheduler: scheduler).effectiveScheduler(helmetOffPending: false).lookPin == "sunglasses")
    }

    @Test func Watcher_aReplacedControlFileIsAppliedAndConfirmedWithinTwoSeconds() throws {
        let store = try artifactStore()
        try writeControl(store.root, ["walk": true], bump: false)
        let watcher = SettingsWatcher(store: store, queue: DispatchQueue(label: "watcher.test"))
        let initial = watcher.load()
        #expect(initial.generation == 0)
        let sink = RecordingSink()
        watcher.start(sink: sink)
        #expect(sink.confirmed == [0], "the start applies what it loaded, so a CLI that saved while the agent was down is confirmed")
        try writeControl(store.root, ["walk": false])
        #expect(sink.wait(count: 2)); #expect(sink.applied.last?.scheduler.walk == false); #expect(sink.confirmed.last == 1)
        try writeControl(store.root, ["motion": "off", "scale": 2.0])
        #expect(sink.wait(count: 3)); #expect(sink.applied.last?.scheduler.motion == .off); #expect(sink.applied.last?.control.scale == 2)
        #expect(sink.applied.last?.scheduler.walk == false, "a write of one key keeps the others")
        watcher.stop()
    }
    @Test func Watcher_twoQuickReplacementsEndOnTheLastAndAnUnreadableFileIsLeftAlone() throws {
        let store = try artifactStore()
        try writeControl(store.root, [:], bump: false)
        let watcher = SettingsWatcher(store: store, queue: DispatchQueue(label: "watcher.test2"))
        _ = watcher.load()
        let sink = RecordingSink()
        watcher.start(sink: sink)
        for n in 1...20 { try writeControl(store.root, ["lookEveryHours": [2, 3, 4][n % 3]]) }
        let deadline = Date().addingTimeInterval(2)
        while (sink.confirmed.last ?? 0) < 20, Date() < deadline { usleep(10_000) }
        #expect(sink.confirmed.last == 20, "the last generation is the one applied: \(sink.confirmed)")
        try Data("{{{ not json".utf8).write(to: store.root.appendingPathComponent("control.json"))
        usleep(300_000)
        #expect(sink.confirmed.last == 20, "a damaged file changes nothing; the next good replacement is read again")
        try writeControl(store.root, ["walk": false])
        #expect(sink.wait(count: sink.confirmed.count + 1) || sink.confirmed.last == 21 || sink.applied.last?.scheduler.walk == false)
        watcher.stop()
    }
    @Test func Applied_theChatKeysAreParsedWithTheOtherSettingsAndAWrongOneKeepsItsDefault() throws {
        let data = Data(#"{"generation":3,"walk":false,"chatPermissions":"bypass","chatFolder":"~/work","chatModel":"bad model!"}"#.utf8)
        let parsed = try #require(AppliedSettings.parse(data))
        #expect(parsed.scheduler.walk == false)
        #expect(parsed.chat.permissions == .bypass)
        #expect(parsed.chat.folder == NSHomeDirectory() + "/work")
        #expect(parsed.chat.model == nil)
        #expect(try #require(AppliedSettings.parse(Data(#"{"generation":4}"#.utf8))).chat == ChatSettings())
    }
    @Test func Watcher_noOtherComponentReadsControlJsonAndBothHostsBuildTheSameWatcher() throws {
        let sources = try swiftSources()
        let readers = sources.filter { $0.text.contains("\"control.json\"") }.map { ($0.path as NSString).lastPathComponent }
        #expect(readers == ["SettingsWatcher.swift"], "files that name control.json: \(readers)")
        let desktop = try #require(sources.first { $0.path.hasSuffix("ClawdDesktop/AgentRuntime.swift") })
        let headless = try #require(sources.first { $0.path.hasSuffix("ClawdDesktop/SettingsRun.swift") })
        #expect(desktop.text.contains("SettingsWatcher(store:")); #expect(headless.text.contains("SettingsWatcher(store:"))
        #expect(desktop.text.contains("LiveSettings(runtime:")); #expect(headless.text.contains("LiveSettings(runtime:"))
    }
    @Test func Watcher_hasNoTimerAndNoPolling() throws {
        let watcher = try #require(try swiftSources().first { $0.path.hasSuffix("ClawdCore/SettingsWatcher.swift") })
        for banned in ["Timer", "asyncAfter", "usleep", "sleep(", "makeTimerSource", "scheduledTimer"] {
            #expect(!watcher.text.contains(banned), "the watcher is event-driven: found \(banned)")
        }
        #expect(watcher.text.contains("makeFileSystemObjectSource"))
    }
}

// MARK: the real agent binary

private struct HeadlessAgent {
    let process = Process()
    let out = Pipe()
    let store: OwnState
    let root: URL
    let pid: Int32
    init(seconds: Int = 60, preset: [String: Any] = ["scale": 1, "generation": 0]) throws {
        let home = try artifactStore().root
        root = home.appendingPathComponent("Library/Application Support/clawd-pet")
        store = try OwnState(root: root)
        try writeControl(root, preset, bump: false)
        process.executableURL = agentExecutable()
        process.arguments = ["--test-settings", String(seconds), root.path, artDirectory.path]
        var environment = ProcessInfo.processInfo.environment
        environment["HOME"] = home.path; environment.removeValue(forKey: "XPC_SERVICE_NAME")
        process.environment = environment
        process.standardOutput = out; process.standardError = out
        try process.run()
        pid = process.processIdentifier
        var seen = ""
        let deadline = Date().addingTimeInterval(20)
        while !seen.contains("SETTINGS-READY pid=\(pid)"), Date() < deadline {
            let chunk = out.fileHandleForReading.availableData
            if chunk.isEmpty { usleep(20_000) } else { seen += String(decoding: chunk, as: UTF8.self) }
        }
        guard seen.contains("SETTINGS-READY pid=\(pid)") else { throw FileFailure.unsafePath }
    }
    func stop() { process.terminate(); process.waitUntilExit() }
    var status: [String: Any] { (try? JSONSerialization.jsonObject(with: ReadOnlyFile.data(root.appendingPathComponent("status.json").path))) as? [String: Any] ?? [:] }
    var log: String { String(decoding: (try? ReadOnlyFile.data(root.appendingPathComponent("agent.log").path)) ?? Data(), as: UTF8.self) }
    /// Waits up to `limit` seconds for status.json to show `generation`; returns how long it took, or nil.
    func waitApplied(_ generation: Int, limit: Double = 2) -> Double? {
        let start = Date()
        while Date().timeIntervalSince(start) < limit {
            if (status["appliedGeneration"] as? Int ?? -1) >= generation { return Date().timeIntervalSince(start) }
            usleep(10_000)
        }
        return nil
    }
    /// The PLAN line of a generation (the agent simulates two hours of its scheduler after it applies one); waits for it.
    func plan(generation: Int, limit: Double = 8) -> (walks: Int, motions: Int, bubble: String)? {
        let deadline = Date().addingTimeInterval(limit)
        repeat {
            for line in log.split(separator: "\n") where line.contains("PLAN generation=\(generation) ") {
                func field(_ key: String) -> String? { line.components(separatedBy: key + "=").dropFirst().first?.components(separatedBy: " ").first }
                if let w = field("walks").flatMap(Int.init), let m = field("motions").flatMap(Int.init), let b = field("bubble") { return (w, m, b) }
            }
            usleep(50_000)
        } while Date() < deadline
        return nil
    }
}

@Suite("Settings applied by the real agent binary", .serialized)
struct SettingsAppliedSuite {
    @Test func Applied_eachChangeIsAppliedWithinTwoSecondsTheBehaviourChangesAndThePidStays() throws {
        let agent = try HeadlessAgent()
        defer { agent.stop() }
        #expect(agent.waitApplied(0) != nil, "the start confirms the generation it loaded")
        let baseline = try #require(agent.plan(generation: 0))
        #expect(baseline.walks > 0 && baseline.motions > 0 && baseline.bubble == "yes", "the default plans walks, motions and a bubble: \(baseline)")

        try writeControl(agent.root, ["walk": false])
        let walkOff = try #require(agent.waitApplied(1)); #expect(walkOff < 2)
        #expect(agent.log.contains("SETTINGS applied generation=1"))
        let log = agent.log
        let applied = try #require(log.range(of: "SETTINGS applied generation=1")), disabled = try #require(log.range(of: "WALK disabled"))
        #expect(applied.lowerBound < disabled.lowerBound, "the log says the generation, then that walking is disabled")
        #expect(agent.plan(generation: 1)?.walks == 0, "after walk off the scheduler plans no walk")
        #expect((agent.plan(generation: 1)?.motions ?? 0) > 0, "and still plans motions")

        try writeControl(agent.root, ["walk": true])
        #expect(agent.waitApplied(2) != nil)
        #expect(agent.log.range(of: "WALK enabled") != nil); #expect((agent.plan(generation: 2)?.walks ?? 0) > 0)

        try writeControl(agent.root, ["motion": "off"])
        #expect(agent.waitApplied(3) != nil)
        #expect(agent.plan(generation: 3)?.motions == 0); #expect(agent.plan(generation: 3)?.walks == 0)
        try writeControl(agent.root, ["motion": "lively"])
        #expect(agent.waitApplied(4) != nil)
        #expect((agent.plan(generation: 4)?.motions ?? 0) > (baseline.motions), "lively plans more than quiet")

        try writeControl(agent.root, ["bubble": false])
        #expect(agent.waitApplied(5) != nil); #expect(agent.plan(generation: 5)?.bubble == "no", "after bubble off no bubble frame is produced")
        try writeControl(agent.root, ["bubble": true, "lookEveryHours": 2, "hiddenUntil": -1])
        #expect(agent.waitApplied(6) != nil)
        #expect(agent.log.contains("HIDDEN")); #expect(agent.status["bubble"] as? Bool == true)
        #expect(agent.status["motion"] as? String == "lively"); #expect(agent.status["walk"] as? Bool == true)
        #expect(agent.status["look"] as? String == "plain")

        #expect(agent.process.isRunning, "the process was never restarted")
        #expect(agent.process.processIdentifier == agent.pid)
    }
}

/// With the real `bin/clawd-pet` (Sprint 4a's CLI) and a stub launchctl that reports the headless agent's pid, the CLI itself drives the
/// real agent: `walk off` returns 0 only after status.json shows the generation, and then agent.log shows WALK disabled.
@Suite("Settings through the real CLI", .serialized)
struct SettingsThroughCLISuite {
    private static let cliHasSettings: Bool = {
        guard let text = try? String(contentsOf: repository.appendingPathComponent("bin/clawd-pet"), encoding: .utf8) else { return false }
        return text.contains("cmd_walk") && text.contains("appliedGeneration")
    }()

    @Test(.enabled(if: SettingsThroughCLISuite.cliHasSettings, "needs the settings CLI of Sprint 4a in bin/clawd-pet"))
    func CLI_walkOffReturnsZeroOnlyAfterTheRunningAgentAppliedItThenWalkOnReturnsToTheStart() throws {
        let agent = try HeadlessAgent()
        defer { agent.stop() }
        let home = agent.root.deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        // clawd-pet reads $ROOT/control.json and takes $ROOT/control.lock; install creates both.
        let lock = agent.root.appendingPathComponent("control.lock")
        FileManager.default.createFile(atPath: lock.path, contents: Data())
        let stub = home.appendingPathComponent("launchctl-stub")
        try Data("#!/bin/sh\ncase \"$1\" in list) printf '{\\n\\t\"Label\" = \"com.tomtim.clawd-pet\";\\n\\t\"PID\" = \(agent.pid);\\n};\\n'; exit 0;; esac\nexit 0\n".utf8).write(to: stub)
        chmod(stub.path, 0o755)
        func cli(_ arguments: [String]) throws -> Execution {
            try execute(URL(fileURLWithPath: "/bin/bash"), [repository.appendingPathComponent("bin/clawd-pet").path] + arguments,
                        environment: ["HOME": home.path, "CLAWD_LAUNCHCTL": stub.path], timeout: 20)
        }
        let off = try cli(["walk", "off"])
        #expect(off.code == 0, "walk off: \(off.output)")
        #expect((agent.status["appliedGeneration"] as? Int ?? -1) >= 1, "returned only after the agent confirmed")
        #expect(agent.log.contains("WALK disabled"))
        let on = try cli(["walk", "on"])
        #expect(on.code == 0, "walk on: \(on.output)")
        #expect(agent.log.contains("WALK enabled")); #expect(agent.process.isRunning)
    }
}
