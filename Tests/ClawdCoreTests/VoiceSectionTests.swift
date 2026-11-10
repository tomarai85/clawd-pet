import Testing
import Foundation
import AppKit
import ClawdCore
import ClawdRendering
import ClawdDesktop

// Stage SA, Sprint SA6: `aquaReact` (React off builds no log reader), the Voice section of the Settings window and its two restart-only rows.
// Nothing here reads the real Aqua Voice app or its log, shows a window, or touches the real state directory: the version comes from the
// runtime environment's seam (inert by default), the workspace centre is the test's own, and every write goes to the stub CLI.

@Suite("AquaReact", .serialized)
@MainActor
struct AquaReactSuite {
    private func reasons(_ rig: RuntimeRig) -> Set<QuietReason> { rig.stage.scheduler.quietReasons }

    @Test func AquaReact_offBuildsNoTailerResolvesIgnoreAndWritesNothing() throws {
        for setting in AquaSetting.allCases {
            for installed in [true, false] {
                let tag = "\(setting.rawValue) installed=\(installed)"
                let store = try artifactStore()
                try Data("{\"aqua\":\"\(setting.rawValue)\",\"aquaReact\":false,\"generation\":3}".utf8).write(to: try store.url("control.json"))
                let before = try Data(contentsOf: try store.url("control.json"))
                let rig = try RuntimeRig(store: store, aquaRunning: false, prepare: { $0.aquaInstalled = installed })
                #expect(!rig.runtime.aquaLogIsRead, "\(tag): no LogTailer and no LogWatch")
                #expect(rig.lines("AQUA mode=ignore setting=\(setting.rawValue) installed=\(installed ? "yes" : "no") react=off").count == 1, "\(tag): \(rig.log)")
                #expect(rig.stage.lastFrame != nil, "\(tag): ignore shows Clawd with Aqua not running")
                #expect(!reasons(rig).contains(.aquaNotRunning) && rig.runtime.controller.aquaRunning, "\(tag)")
                rig.machine.listChanged?()
                #expect(rig.stage.lastFrame != nil && !reasons(rig).contains(.aquaNotRunning), "\(tag)")
                #expect(rig.lines("QUIET on reason=aqua-not-running").isEmpty && rig.lines("TAIL").isEmpty, "\(tag): \(rig.log)")
                #expect(try rig.status.aquaMode == "ignore", "\(tag)")
                #expect(try Data(contentsOf: try store.url("control.json")) == before, "\(tag): control.json is byte-identical")
            }
        }
        // The positive control: with React on, the same file reads the log and follow keeps Clawd hidden while Aqua is not running.
        let on = try RuntimeRig(control: ["aqua": "follow", "generation": 0], aquaRunning: false)
        #expect(on.runtime.aquaLogIsRead, "React on reads the log")
        #expect(on.lines("AQUA mode=follow setting=follow installed=yes").count == 1 && !on.log.contains("react=off"), "\(on.log)")
        #expect(on.lines("QUIET on reason=aqua-not-running").count == 1)
    }

    @Test func AquaReact_offSurvivesAWake() async throws {
        let center = NotificationCenter()
        let rig = try RuntimeRig(control: ["aqua": "follow", "aquaReact": false, "generation": 0], aquaRunning: false, prepare: { $0.workspaceCenter = center })
        #expect(!rig.runtime.aquaLogIsRead)
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        await rig.spin(until: { reasons(rig).contains(.systemAsleep) }, limit: 5)
        #expect(reasons(rig).contains(.systemAsleep), "the workspace observer is there")
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        await rig.spin(until: { rig.monitor.status.wakeCount == 1 }, limit: 5)
        await rig.spin(until: { !reasons(rig).contains(.systemAsleep) }, limit: 5)
        #expect(rig.monitor.status.wakeCount == 1, "the wake was handled")
        #expect(!reasons(rig).contains(.systemAsleep), "the system-asleep reason is cleared")
        #expect(!rig.runtime.aquaLogIsRead && rig.lines("TAIL").isEmpty, "a wake with React off polls no tailer and builds none: \(rig.log)")
    }

    @Test func AquaReact_aStartWithoutAquaAndIgnoreRaisesNoAquaNotRunning() async throws {
        for (setting, installed) in [("ignore", false), ("ignore", true), ("auto", false)] {
            let tag = "\(setting) installed=\(installed)"
            let rig = try RuntimeRig(control: ["aqua": setting, "generation": 0], aquaRunning: false, prepare: { $0.aquaInstalled = installed })
            #expect(rig.runtime.aquaLogIsRead, "\(tag): React is on, so the log is read")
            #expect(rig.stage.lastFrame != nil && !reasons(rig).contains(.aquaNotRunning), "\(tag)")
            #expect(rig.lines("AQUA mode=ignore setting=\(setting) installed=\(installed ? "yes" : "no")").count == 1 && !rig.log.contains("react=off"), "\(tag): \(rig.log)")
            rig.machine.listChanged?()
            #expect(rig.lines("QUIET on reason=aqua-not-running").isEmpty && rig.stage.lastFrame != nil, "\(tag): \(rig.log)")
        }
    }

    @Test func AquaReact_isRestartOnlyAndReportedAsPending() async throws {
        #expect(AgentControl.restartKeyNames.contains("aquaReact"))
        var changed = AgentControl()
        changed.aquaReact = false
        #expect(changed.restartKeys(since: AgentControl()) == ["aquaReact"] && AgentControl().restartKeys(since: changed) == ["aquaReact"])
        func control(_ json: String) throws -> AgentControl { try JSONDecoder().decode(AgentControl.self, from: Data(json.utf8)) }
        #expect(try control("{}").aquaReact, "a missing key reads true: delivering SA6 changes none of Tom's settings")
        #expect(try control("{\"aquaReact\":\"no\"}").aquaReact && control("{\"aquaReact\":false,\"scale\":2}").scale == 2, "a bad value or a bad neighbour breaks nothing")
        let rig = try RuntimeRig(control: ["scale": 1, "generation": 0])
        await rig.spin(until: { (try? rig.status.appliedGeneration) == 0 })
        try JSONSerialization.data(withJSONObject: ["scale": 1, "aquaReact": false, "generation": 1]).write(to: try rig.store.url("control.json"), options: .atomic)
        await rig.spin(until: { (try? rig.status.restartRequired) != nil }, limit: 5)
        let status = try rig.status
        #expect(status.restartRequired == ["aquaReact"] && status.restartGeneration == 1, "status.json names the key: \(status)")
        #expect(status.appliedGeneration == 0, "the generation is not confirmed while a restart is owed")
        #expect(rig.runtime.aquaLogIsRead, "the running pet keeps reading the log until it restarts")
    }

    @Test func AquaReact_offKeepsTheWorkspaceObserverSoAnExamStillStandsDown() async throws {
        let center = NotificationCenter()
        let rig = try RuntimeRig(control: ["aqua": "follow", "aquaReact": false, "generation": 0], virtual: true, prepare: { $0.workspaceCenter = center })
        #expect(!rig.runtime.aquaLogIsRead)
        // The observer is there: the centre's sleep and wake reach the runtime (the same registration carries the application launches).
        center.post(name: NSWorkspace.willSleepNotification, object: nil)
        await rig.spin(until: { reasons(rig).contains(.systemAsleep) }, limit: 5)
        #expect(reasons(rig).contains(.systemAsleep), "the workspace observer survives React off")
        center.post(name: NSWorkspace.didWakeNotification, object: nil)
        await rig.spin(until: { !reasons(rig).contains(.systemAsleep) }, limit: 5)
        #expect(!reasons(rig).contains(.systemAsleep))
        // The application launch and quit registrations are there too: each notification (no payload) reaches the follower's reconcile.
        let beforeLaunch = rig.runtime.aquaReconcileCount
        center.post(name: NSWorkspace.didLaunchApplicationNotification, object: nil)
        await rig.spin(until: { rig.runtime.aquaReconcileCount > beforeLaunch }, limit: 5)
        #expect(rig.runtime.aquaReconcileCount > beforeLaunch, "the launch registration survives React off: \(rig.log)")
        let beforeQuit = rig.runtime.aquaReconcileCount
        center.post(name: NSWorkspace.didTerminateApplicationNotification, object: nil)
        await rig.spin(until: { rig.runtime.aquaReconcileCount > beforeQuit }, limit: 5)
        #expect(rig.runtime.aquaReconcileCount > beforeQuit, "the terminate registration survives React off: \(rig.log)")
        // A LockDown Browser application launching stands Clawd down, and its quit ends the stand-down.
        rig.machine.examRunning = true
        rig.runtime.workspaceApplication(launched: true, bundleIdentifier: "com.Respondus.LockDownBrowser", name: "LockDown Browser", pid: 77)
        #expect(rig.stage.scheduler.examActive && rig.lines("EXAM seen").count == 1, "\(rig.log)")
        rig.machine.examRunning = false
        rig.runtime.workspaceApplication(launched: false, bundleIdentifier: "com.Respondus.LockDownBrowser", name: "LockDown Browser", pid: 77)
        rig.advance(200)
        #expect(!rig.stage.scheduler.examActive, "the end of the stand-down: \(rig.log)")
        // An exam already running at the start: no window from the first picture.
        let boot = try RuntimeRig(control: ["aqua": "follow", "aquaReact": false, "generation": 0], virtual: true, prepare: { $0.examRunning = true })
        #expect(boot.lines("EXAM startup standing-down").count == 1 && boot.stage.scheduler.examActive, "\(boot.log)")
    }
}

@Suite("VoiceSection", .serialized)
@MainActor
struct VoiceSectionSuite {
    private func rig(_ control: [String: Any] = [:], installed: Bool = true, version: String? = nil) throws -> (SettingsRig, SettingsContent) {
        var file = control
        file["generation"] = 0
        let r = try SettingsRig(control: file, requestSeams: SettingsRestartSuite.rigSeams, aquaInstalled: installed, aquaVersion: version)
        try r.openFromMenuBar()
        let content = try #require(r.settings.content)
        content.show(.voice)
        return (r, content)
    }

    @Test func VoiceSection_notInstalledShowsNotInstalledAndTheFollowSwitchIsDisabledWhileOff() async throws {
        let (r, content) = try rig(["aqua": "ignore"], installed: false)
        #expect(content.voiceStatusLabel.stringValue == "Not installed", "\(content.voiceStatusLabel.stringValue)")
        let on = try #require(content.button(for: .follow(true))), off = try #require(content.button(for: .follow(false)))
        #expect(off.state == .on && on.state == .off, "the mode in effect is ignore")
        #expect(!on.isEnabled && !off.isEnabled, "it shows off and the app is not installed: it could only hide Clawd for good")
        press(on)
        await r.rig.spin(0.2)
        #expect(r.cliRuns.isEmpty && r.lines("MENU").isEmpty, "a disabled switch writes nothing: \(r.stub.calls)")
        #expect(content.button(for: .react(true))?.isEnabled == true, "React stays available")
        // A stored follow on a Mac without the app shows on and can be turned off.
        let (s, stored) = try rig(["aqua": "follow"], installed: false)
        #expect(stored.button(for: .follow(true))?.state == .on && stored.button(for: .follow(true))?.isEnabled == true && stored.button(for: .follow(false))?.isEnabled == true)
        #expect(stored.voiceStatusLabel.stringValue == "Not installed" && s.cliRuns.isEmpty)
        // Installed: the version against the tested one.
        for (version, words) in [("0.21.4", "Installed, version 0.21.4"),
                                 ("0.21.5", "Installed, version 0.21.5 (Clawd was tested with 0.21.4)"),
                                 (nil, "Installed, version unknown (Clawd was tested with 0.21.4)")] {
            let (_, found) = try rig([:], installed: true, version: version)
            #expect(found.voiceStatusLabel.stringValue == words, "\(version ?? "nil"): \(found.voiceStatusLabel.stringValue)")
        }
    }

    @Test func VoiceSection_aStoredAutoShowsItsResolvedModeWithTheAutomaticCaption() async throws {
        for (installed, follows) in [(true, true), (false, false)] {
            let (r, content) = try rig(["aqua": "auto"], installed: installed)
            #expect(content.button(for: .follow(follows))?.state == .on && content.button(for: .follow(!follows))?.state == .off, "installed=\(installed)")
            #expect(!content.voiceAutomaticCaption.isHidden && content.voiceAutomaticCaption.stringValue == "Automatic: follows \(DictationSources.aqua.displayName) if it is installed when Clawd starts and React is on.", "installed=\(installed)")
            #expect(try r.rig.status.aquaMode == (follows ? "follow" : "ignore"), "the shown mode is the one the pet runs")
        }
        let (_, missing) = try rig([:], installed: true)
        #expect(!missing.voiceAutomaticCaption.isHidden, "a missing key is auto")
        for setting in ["follow", "ignore"] {
            let (_, explicit) = try rig(["aqua": setting], installed: true)
            #expect(explicit.voiceAutomaticCaption.isHidden && explicit.button(for: .follow(setting == "follow"))?.state == .on, "\(setting)")
        }
        // The user's own pick is an explicit value: the caption goes with it.
        let (r, content) = try rig(["aqua": "auto"], installed: true)
        _ = try await pressChoice(r, content, .follow(false))
        #expect(content.voiceAutomaticCaption.isHidden && content.button(for: .follow(false))?.state == .on)
    }

    @Test func VoiceSection_followOnRereadsTheInstallStateBeforeItWrites() async throws {
        let (r, content) = try rig(["aqua": "ignore"], installed: true)
        let on = try #require(content.button(for: .follow(true))), off = try #require(content.button(for: .follow(false)))
        #expect(on.isEnabled && off.isEnabled && content.voiceStatusLabel.stringValue.hasPrefix("Installed"), "installed: Follow is available")
        let file = try r.rig.store.url("control.json")
        let before = try Data(contentsOf: file)
        // The machine's app goes away while Settings stays open on Voice.
        r.machine.aquaInstalled = false
        press(on)
        await r.rig.spin(0.2)
        #expect(r.stub.started.isEmpty && r.cliRuns.isEmpty && r.lines("MENU").isEmpty, "no verb was submitted: \(r.stub.calls) \(r.lines("MENU"))")
        #expect(try Data(contentsOf: file) == before, "control.json is byte-identical")
        #expect(content.voiceStatusLabel.stringValue == "Not installed", "\(content.voiceStatusLabel.stringValue)")
        #expect(!on.isEnabled && !off.isEnabled && !content.isPending(.follow), "Follow is disabled and nothing is pending")
        #expect(off.state == .on && on.state == .off, "the switch still shows off")
        // The app returns; showing Voice again (the sidebar's pick) enables Follow.
        r.machine.aquaInstalled = true
        let general = try #require(SettingsSection.listed.firstIndex(of: .general)), voice = try #require(SettingsSection.listed.firstIndex(of: .voice))
        content.sidebar.selectRowIndexes(IndexSet(integer: general), byExtendingSelection: false)
        content.sidebar.selectRowIndexes(IndexSet(integer: voice), byExtendingSelection: false)
        #expect(content.section == .voice && content.voiceStatusLabel.stringValue.hasPrefix("Installed"), "\(content.voiceStatusLabel.stringValue)")
        #expect(on.isEnabled && off.isEnabled, "Follow is enabled again")
        let args = try await pressChoice(r, content, .follow(true))
        #expect(args == ["aqua", "follow"], "\(args)")
    }

    @Test func VoiceSection_theFollowSwitchWritesOnlyFollowOrIgnore() async throws {
        let (r, content) = try rig(["aqua": "auto"], installed: true)
        let steps: [(SettingsChoice, [String])] = [(.follow(true), ["aqua", "follow"]), (.follow(false), ["aqua", "ignore"]), (.follow(true), ["aqua", "follow"]),
                                                   (.react(false), ["aqua", "react", "off"]), (.react(true), ["aqua", "react", "on"])]
        for (choice, expected) in steps {
            let args = try await pressChoice(r, content, choice)
            #expect(args == expected, "\(choice): \(args)")
            #expect(isAllowedSettingsVerb(args) && args != ["aqua", "auto"])
        }
        #expect(!r.stub.started.contains(["aqua", "auto"]), "the window never writes auto: \(r.stub.started)")
        #expect(SettingsActions.action(for: .follow(true), shownOn: true).arguments == ["aqua", "follow"] && SettingsActions.action(for: .follow(false), shownOn: true).arguments == ["aqua", "ignore"])
        #expect(SettingsActions.action(for: .follow(true), shownOn: true).queueKey == "aqua" && SettingsActions.action(for: .react(true), shownOn: true).queueKey == "aquaReact")
        #expect(SettingsChoice.follow(true).restartsPet && SettingsChoice.react(true).restartsPet, "both rows are restart-only")
    }

    @Test func VoiceSection_followRowFollowsTheRunningPetsReactNotTheFile() async throws {
        // The file says React is off, the running pet reads the log (it started with it on): the switch is enabled.
        let (r, content) = try rig([:], installed: true)
        #expect(content.button(for: .follow(true))?.isEnabled == true)
        try writeControlLikeTheCLI(r.rig.store.root, ["aquaReact": false])
        await r.rig.spin(until: { (try? r.rig.status.restartRequired) != nil }, limit: 5)
        #expect(try r.rig.status.restartRequired == ["aquaReact"])
        #expect(content.button(for: .follow(true))?.isEnabled == true && content.button(for: .follow(false))?.isEnabled == true,
                "the file says off, but this pet runs with React on")
        #expect(content.button(for: .react(true))?.state == .on, "React shows what the pet runs with")
        // The pet started with React off: the switch is disabled, and a file that now says on does not enable it until the restart.
        let (o, off) = try rig(["aquaReact": false, "aqua": "follow"], installed: true)
        #expect(off.button(for: .react(false))?.state == .on)
        #expect(off.button(for: .follow(true))?.isEnabled == false && off.button(for: .follow(false))?.isEnabled == false, "both false: disabled")
        #expect(off.button(for: .follow(false))?.state == .on, "React off resolves the mode to ignore")
        try writeControlLikeTheCLI(o.rig.store.root, ["aquaReact": true])
        await o.rig.spin(until: { (try? o.rig.status.restartRequired) != nil }, limit: 5)
        #expect(try o.rig.status.restartRequired == ["aquaReact"])
        #expect(off.button(for: .follow(true))?.isEnabled == false, "the file says on, but this pet runs with React off")
    }

    @Test func VoiceSection_everyStringThatNamesTheSourceTakesItFromTheDescriptor() throws {
        let other = DictationSource(id: "zed", displayName: "Zed Dictate", bundleIdentifier: "example.zed", reactKey: "zedReact", followKey: "zed", testedVersion: "9.9")
        let content = SettingsContent(values: SettingsValues(), icon: nil, sections: SettingsSection.listed, looks: [], drawnStyles: Set(1...12), stateFolder: "/x", source: other)
        content.show(.voice)
        content.setVoiceStatus(SettingsVoiceStatus(installed: true, version: "1.0"))
        let labels = allLabels(in: content.root)
        let aqua = DictationSources.aqua.displayName
        #expect(labels.contains("Zed Dictate") && labels.contains("Only show Clawd while Zed Dictate runs"), "\(labels)")
        #expect(labels.contains("Automatic: follows Zed Dictate if it is installed when Clawd starts and React is on."), "\(labels)")
        #expect(content.button(for: .follow(true))?.accessibilityLabel() == "Only show Clawd while Zed Dictate runs on" && content.button(for: .follow(false))?.accessibilityLabel() == "Only show Clawd while Zed Dictate runs off")
        #expect(labels.contains("Installed, version 1.0 (Clawd was tested with 9.9)"), "\(labels)")
        #expect(labels.contains(SettingsVoiceLine.intro) && SettingsVoiceLine.intro == "Dictation apps Clawd reacts to.")
        #expect(labels.allSatisfy { !$0.contains(aqua) }, "no string names the other source: \(labels)")
        for field in allTextFields(in: content.root) { #expect(!field.stringValue.contains(aqua) && !(field.accessibilityLabel() ?? "").contains(aqua)) }
        let wall = Date(timeIntervalSince1970: 1_793_000_000)
        #expect(SettingsStateLine.text(hiddenUntil: 0, wall: wall, quiet: .aquaNotRunning, source: other) == "Waiting for Zed Dictate")
        #expect(SettingsStateLine.text(hiddenUntil: 0, wall: wall, quiet: .aquaNotRunning) == "Waiting for " + aqua)
        // No Settings file spells the source's name in a string literal: the descriptor is the one place.
        for file in try settingsFiles() where (file.path as NSString).lastPathComponent != "SettingsRun.swift" {
            let code = file.text.split(separator: "\n", omittingEmptySubsequences: false).map { line -> String in
                if let comment = line.range(of: "//") { return String(line[line.startIndex..<comment.lowerBound]) }
                return String(line)
            }.joined(separator: "\n")
            #expect(code.range(of: #""[^"\n]*Aqua[^"\n]*""#, options: .regularExpression) == nil, "\((file.path as NSString).lastPathComponent) spells the source's name")
        }
    }
}
