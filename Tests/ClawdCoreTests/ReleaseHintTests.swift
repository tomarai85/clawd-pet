import Testing
import Foundation
import ClawdCore

private func probeReport(leases: [ProbeLease]? = nil) -> ProbeReport {
    ProbeReport(registrationSucceeded: true, callbackCount: 3, baselineSucceeded: true, enumerationsSucceeded: true,
                promptWindowDetected: false, freshIdentityAttested: true,
                leases: leases ?? Array(repeating: ProbeLease(transitions: 1, gap: 0.6, openedRunning: true), count: 3))
}
private func edge(_ hint: inout ReleaseHintTracker, _ uid: String?, _ running: Bool?) -> Bool {
    hint.observe(uid: uid, running: running)
}
private func settings(_ json: String) throws -> String {
    let store = try artifactStore()
    try store.write(Data(json.utf8), to: "settings.json")
    return try store.url("settings.json").path
}

@Suite("Release-hint source B")
struct ReleaseHintSuite {
    @Test func ReleaseHint_trackerAcceptsOnlyTheFirstFallingEdgeOnTheSelectedDevice() {
        var hint = ReleaseHintTracker()
        hint.begin(uid: "fixture-device", running: true)
        let steady = edge(&hint, "fixture-device", true), first = edge(&hint, "fixture-device", false)
        let back = edge(&hint, "fixture-device", true), second = edge(&hint, "fixture-device", false)
        #expect(!steady); #expect(first); #expect(!back); #expect(!second)      // a second edge is never a hint
    }
    @Test func ReleaseHint_aLeaseOpenedWhileTheDeviceWasStoppedIsNeverEligible() {
        var hint = ReleaseHintTracker()
        hint.begin(uid: "fixture-device", running: false)
        let rise = edge(&hint, "fixture-device", true), fall = edge(&hint, "fixture-device", false)
        #expect(!rise); #expect(!fall)
        hint.begin(uid: "fixture-device", running: nil)
        #expect(!hint.eligible)
    }
    @Test func ReleaseHint_aDifferentDeviceIsIgnored() {
        var hint = ReleaseHintTracker()
        hint.begin(uid: "fixture-device", running: true)
        let other = edge(&hint, "other-device", false), own = edge(&hint, "fixture-device", false)
        #expect(!other); #expect(!own)                                      // the mismatch already invalidated the lease
    }
    @Test func ReleaseHint_aMissingDeviceOrUnreadableStateIsIgnored() {
        var hint = ReleaseHintTracker()
        hint.begin(uid: nil, running: true)
        let none = edge(&hint, nil, false)
        #expect(!hint.eligible); #expect(!none)
        hint.begin(uid: "fixture-device", running: true)
        let unreadable = edge(&hint, "fixture-device", nil), after = edge(&hint, "fixture-device", false)
        #expect(!unreadable); #expect(!after)
    }
    @Test func ReleaseHint_aChangedSelectedInputMidLeaseInvalidatesTheHint() {
        let rig = Rig(sourceB: true)
        var selected = "fixture-device"
        rig.controller.selectedUID = { selected }
        rig.start(); selected = "someone-switched-the-mic"
        rig.device.fire(running: false)
        #expect(rig.scene == .listening)                                   // no hint: the input changed under us
    }
    @Test func ReleaseHint_theSelectedInputIsReReadAtEveryLeaseOpenAndNotAtAnyOtherTime() {
        let rig = Rig(sourceB: true)
        var reads = 0
        rig.controller.selectedUID = { reads += 1; return "fixture-device" }
        rig.start(1); #expect(reads == 1)
        rig.lock(lease: 1); #expect(reads == 1)                                   // same lease: no re-read
        rig.complete(); rig.advance(6)
        rig.start(2); #expect(reads == 2)
        #expect(rig.device.startedUIDs.count == 2)
    }
    @Test func ReleaseHint_resolvesTheNativeMicrophoneIdFromSettings() throws {
        let path = try settings(#"{"token":"SECRET","useNativeAudio":true,"nativeMicrophone":{"id":"com.example.aqua.ear","name":"EarPods"},"lastUsedMicId":"other"}"#)
        #expect(AquaInput.selectedUID(settingsPath: path) == "com.example.aqua.ear")
    }
    @Test func ReleaseHint_settingsWithoutNativeAudioOrWithBadShapesYieldNoDevice() throws {
        let cases = [
            #"{"useNativeAudio":false,"nativeMicrophone":{"id":"x"}}"#, #"{"nativeMicrophone":{"id":"x"}}"#,
            #"{"useNativeAudio":true}"#, #"{"useNativeAudio":true,"nativeMicrophone":{"id":""}}"#,
            #"{"useNativeAudio":true,"nativeMicrophone":{"id":5}}"#, #"{"useNativeAudio":true,"nativeMicrophone":"x"}"#,
            "not json", "[]", "",
        ]
        for json in cases { #expect(AquaInput.selectedUID(settingsPath: try settings(json)) == nil, "\(json)") }
        #expect(AquaInput.selectedUID(settingsPath: "/nonexistent/settings.json") == nil)
    }
    @Test func ReleaseHint_onlyThePermittedKeyPathCanNameTheDeviceAndTokensNeverCan() throws {
        let path = try settings(#"{"token":"SECRET","useNativeAudio":true,"nativeMicrophone":{"id":"ok"},"lastUsedMicId":"nope"}"#)
        for key in ["token", "lastUsedMicId", "nativeMicrophone.name", "", "nativeMicrophone", "../token"] {
            #expect(AquaInput.selectedUID(keyPath: key, settingsPath: path) == nil, "\(key)")
        }
    }
    @Test func ReleaseHint_hintBeforeCompletedKeepsThinkingAndTheBoundIsFiveSeconds() {
        let rig = Rig(sourceB: true); rig.start(); rig.advance(1); rig.device.fire(running: false)
        #expect(rig.scene == .thinking)
        rig.advance(4.9); #expect(rig.scene == .thinking)
        rig.advance(0.2); #expect(rig.scene == .idle)                      // bounded: no completed, device still stopped
    }
    @Test func ReleaseHint_aSecondFallingEdgeInTheSameLeaseDoesNothingNew() {
        let rig = Rig(sourceB: true); rig.start(); rig.advance(1)
        rig.device.fire(running: false); rig.advance(2); rig.device.fire(running: true); rig.device.fire(running: false)
        let thinkingChanges = rig.changes.filter { $0.scene == .thinking }.count
        #expect(thinkingChanges == 1)
    }
    @Test func ReleaseHint_probeReportEnablesSourceBOnlyWhenEveryAssertionHolds() {
        var report = probeReport()
        #expect(report.enablesSourceB)
        report.promptWindowDetected = true; #expect(!report.enablesSourceB); report.promptWindowDetected = false
        report.enumerationsSucceeded = false; #expect(!report.enablesSourceB); report.enumerationsSucceeded = true
        report.baselineSucceeded = false; #expect(!report.enablesSourceB); report.baselineSucceeded = true
        report.callbackCount = 0; #expect(!report.enablesSourceB); report.callbackCount = 3
        report.registrationSucceeded = false; #expect(!report.enablesSourceB); report.registrationSucceeded = true
        report.freshIdentityAttested = false; #expect(!report.enablesSourceB); report.freshIdentityAttested = true
        report.schema = 2; #expect(!report.enablesSourceB)
    }
    @Test func ReleaseHint_probeLeaseGapMustBeBetweenTwoTenthsAndTwoSeconds() {
        for (gap, ok) in [(0.19, false), (0.2, true), (0.58, true), (2.0, true), (2.01, false)] as [(Double, Bool)] {
            #expect(ProbeLease(transitions: 1, gap: gap, openedRunning: true).passes == ok, "\(gap)")
        }
        #expect(!ProbeLease(transitions: 2, gap: 0.6, openedRunning: true).passes)
        #expect(!ProbeLease(transitions: 0, gap: 0.6, openedRunning: true).passes)
        #expect(!ProbeLease(transitions: 1, gap: nil, openedRunning: true).passes)
        #expect(!ProbeLease(transitions: 1, gap: 0.6, openedRunning: false).passes)
    }
    @Test func ReleaseHint_probeNeedsAtLeastThreeRealDictationsAllPassing() {
        let good = ProbeLease(transitions: 1, gap: 0.6, openedRunning: true)
        #expect(!probeReport(leases: [good, good]).enablesSourceB)
        #expect(probeReport(leases: [good, good, good, good]).enablesSourceB)
        #expect(!probeReport(leases: [good, good, ProbeLease(transitions: 2, gap: 0.6, openedRunning: true)]).enablesSourceB)
    }
    @Test func ReleaseHint_probeReportRoundTripsThroughJSON() throws {
        let store = try artifactStore()
        try store.writeJSON(probeReport(), to: "probe/probe-release.json")
        let back = try store.readJSON(ProbeReport.self, from: "probe/probe-release.json")
        #expect(back.enablesSourceB); #expect(back.leases.count == 3)
    }
    @Test func ReleaseHint_probeSourcesUseOnlyPropertyListenersAndNoWindowClasses() throws {
        let files = try swiftSources()
        let all = files.map(\.text).joined(separator: "\n")
        #expect(all.contains("kAudioDevicePropertyDeviceIsRunningSomewhere"))
        let audioMutators = ["AudioHardwareCreateAggregateDevice", "AudioHardwareCreateProcessTap", "AudioObjectSetPropertyData",
                             "AVAudioEngine", "AVCaptureDevice", "AudioDeviceCreateIOProcID", "AudioDeviceStart", "AudioQueueNewInput"]
        for name in audioMutators { #expect(!all.contains(name), "\(name)") }
        let probe = files.filter { $0.path.contains("/ClawdReleaseProbe/") }.map(\.text).joined(separator: "\n")
        #expect(!probe.isEmpty)
        for name in ["NSWindow", "NSPanel", "NSApplication", "NSMicrophoneUsageDescription"] { #expect(!probe.contains(name), "\(name)") }
        for owner in ["tccd", "UserNotificationCenter", "SecurityAgent", "CoreServicesUIAgent", "universalAccessAuthWarn"] {
            #expect(probe.contains(owner), "\(owner)")
        }
    }
    @Test func ReleaseHint_probeRefusesToRunWithoutAFreshSignedIdentityAndWritesNothing() throws {
        let store = try artifactStore()
        let output = try store.url("probe.json").path
        let usage = try execute(builtTool("clawd-release-probe"), [])
        #expect(usage.code == 2); #expect(usage.provedWindowless)
        let wrong = try execute(builtTool("clawd-release-probe"),
                                ["--output", output, "--fresh-identity", "com.tomtim.clawd-pet.probe.0", "--seconds", "10"])
        #expect(wrong.code == 2); #expect(wrong.output.contains("not attested"))
        #expect(!FileManager.default.fileExists(atPath: output))
        #expect(wrong.provedWindowless)
    }
}

@Suite("Release hints are disabled by default")
struct DefaultDisabledSuite {
    @Test func DefaultDisabled_controlDefaultsAreOffAndHelmetIsOptional() {
        let control = AgentControl()
        #expect(!control.releaseHintsEnabled); #expect(!control.helmet); #expect(!control.overFullScreen)
        #expect(control.scale == 1); #expect(control.selectedInputKeyPath == "nativeMicrophone.id")
        #expect(!PetController(clock: VirtualClock(), scheduler: FakeScheduler(clock: VirtualClock())).sourceBEnabled)
    }
    @Test func DefaultDisabled_anEmptyMissingOrCorruptControlFileDecodesToDefaults() throws {
        let decoder = JSONDecoder()
        #expect(try decoder.decode(AgentControl.self, from: Data("{}".utf8)) == AgentControl())
        #expect(try decoder.decode(AgentControl.self, from: Data(#"{"scale":7,"helmet":true}"#.utf8)).scale == 1)   // not an allowed size
        #expect(try decoder.decode(AgentControl.self, from: Data(#"{"scale":2,"helmet":true}"#.utf8)).helmet)
        let store = try artifactStore()
        #expect((try? store.readJSON(AgentControl.self, from: "control.json")) == nil)
        try store.write(Data("{{{ nope".utf8), to: "control.json")
        #expect((try? store.readJSON(AgentControl.self, from: "control.json")) == nil)
    }
    @Test func DefaultDisabled_theControllerNeverTouchesTheDeviceUnlessEnabled() {
        let rig = Rig()
        rig.controller.device = rig.device
        rig.device.state = true
        rig.controller.selectedUID = { "fixture-device" }
        rig.start(); rig.advance(1)
        rig.device.fire(running: false)                                    // a falling edge arrives anyway
        #expect(rig.scene == .listening)
        #expect(rig.device.startedUIDs.isEmpty)
        rig.complete(); #expect(rig.scene == .thinking)                    // THINKING then comes from completed only
    }
    @Test func DefaultDisabled_theFlagAloneIsNotEnoughWithoutAPassingProbeReport() {
        var control = AgentControl(); control.releaseHintsEnabled = true
        #expect(!SourceBPolicy.enabled(control: control, report: nil))
        var failing = probeReport(); failing.promptWindowDetected = true
        #expect(!SourceBPolicy.enabled(control: control, report: failing))
        #expect(SourceBPolicy.enabled(control: control, report: probeReport()))
        control.releaseHintsEnabled = false
        #expect(!SourceBPolicy.enabled(control: control, report: probeReport()))     // a passing report alone is not enough either
    }
    @Test func DefaultDisabled_theProductionRuntimeCreatesTheCoreAudioListenerOnlyBehindThePolicy() throws {
        let runtime = String(decoding: try ReadOnlyFile.data(repository.appendingPathComponent("Sources/ClawdDesktop/AgentRuntime.swift").path), as: UTF8.self)
        let policy = try #require(runtime.range(of: "SourceBPolicy.enabled"))
        let listener = try #require(runtime.range(of: "SelectedDeviceListener()"))
        #expect(policy.lowerBound < listener.lowerBound)
        #expect(runtime.contains("if controller.sourceBEnabled { controller.device = SelectedDeviceListener() }"))
        #expect(runtime.components(separatedBy: "SelectedDeviceListener()").count == 2)    // exactly one construction site
    }
}
