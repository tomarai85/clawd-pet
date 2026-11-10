import Testing
import Foundation
import ClawdCore
import ClawdDesktop

// The `aqua` setting: follow, ignore, or auto (follow only when Aqua Voice is installed). Resolved once at the agent's start.

@Suite("Aqua optional", .serialized)
@MainActor
struct AquaOptionalTests {
    @Test func AquaOptional_resolutionTable() {
        let table: [(AquaSetting, Bool, AquaMode)] = [
            (.follow, true, .follow), (.follow, false, .follow),
            (.ignore, true, .ignore), (.ignore, false, .ignore),
            (.auto, true, .follow), (.auto, false, .ignore),
        ]
        for (setting, installed, expected) in table {
            #expect(AquaMode.resolve(setting, installed: installed) == expected, "\(setting) installed=\(installed)")
        }
    }

    @Test func AquaOptional_settingsParse() throws {
        func control(_ json: String) throws -> AgentControl { try JSONDecoder().decode(AgentControl.self, from: Data(json.utf8)) }
        #expect(try control("{\"scale\":2}").aqua == .auto, "an older control.json without the key")
        for setting in AquaSetting.allCases { #expect(try control("{\"aqua\":\"\(setting.rawValue)\"}").aqua == setting) }
        let bad = try control("{\"aqua\":\"bogus\",\"scale\":2,\"helmet\":true}")
        #expect(bad.aqua == .auto); #expect(bad.scale == 2); #expect(bad.helmet, "one bad value never breaks the others")
        #expect(try control("{\"aqua\":7}").aqua == .auto, "a value of the wrong type")
        #expect(try control("{\"aqua\":\"FOLLOW\"}").aqua == .auto, "the words are exact")
    }

    private func rig(setting: String?, installed: Bool, running: Bool) throws -> RuntimeRig {
        var control: [String: Any] = ["scale": 1, "generation": 0]
        if let setting { control["aqua"] = setting }
        return try RuntimeRig(control: control, aquaRunning: running, prepare: { $0.aquaInstalled = installed })
    }

    @Test func AquaOptional_ignoreShowsClawdWhileAquaIsNotRunning() throws {
        let rig = try rig(setting: "ignore", installed: true, running: false)
        #expect(rig.stage.lastFrame != nil, "the window is up with Aqua not running")
        #expect(!rig.stage.scheduler.quietReasons.contains(.aquaNotRunning)); #expect(rig.runtime.controller.aquaRunning)
        #expect(rig.lines("AQUA mode=ignore setting=ignore installed=yes").count == 1, "\(rig.log)")
        #expect(try rig.status.aquaMode == "ignore")
        // Every trigger that reconciles Aqua's liveness leaves it shown.
        rig.machine.listChanged?()
        #expect(rig.stage.lastFrame != nil); #expect(!rig.stage.scheduler.quietReasons.contains(.aquaNotRunning))
        #expect(rig.lines("QUIET on reason=aqua-not-running").isEmpty, "\(rig.log)")
    }

    @Test func AquaOptional_autoWithoutAquaInstalledShowsAndStaysShown() throws {
        let rig = try rig(setting: nil, installed: false, running: false)
        #expect(rig.stage.lastFrame != nil); #expect(rig.lines("AQUA mode=ignore setting=auto installed=no").count == 1, "\(rig.log)")
        rig.machine.listChanged?()
        #expect(rig.stage.lastFrame != nil); #expect(rig.lines("QUIET on reason=aqua-not-running").isEmpty)
    }

    @Test func AquaOptional_autoWithAquaInstalledFollowsAsBefore() throws {
        let quiet = try rig(setting: nil, installed: true, running: false)
        #expect(quiet.stage.lastFrame == nil, "installed but not running: quiet, exactly as before")
        #expect(quiet.lines("QUIET on reason=aqua-not-running").count == 1); #expect(quiet.lines("AQUA mode=follow setting=auto installed=yes").count == 1)
        #expect(try quiet.status.aquaMode == "follow")
        let running = try rig(setting: nil, installed: true, running: true)
        #expect(running.stage.lastFrame != nil)
    }

    @Test func AquaOptional_followWinsOverAMissingInstall() throws {
        let rig = try rig(setting: "follow", installed: false, running: false)
        #expect(rig.stage.lastFrame == nil); #expect(rig.lines("AQUA mode=follow setting=follow installed=no").count == 1, "\(rig.log)")
    }
}
