import Testing
import Foundation
import AppKit
import ClawdCore
import ClawdRendering
import ClawdDesktop

// Sprint 11 (spec 9b item 16, item 7 of the brief): `helmet off` while the helmet is worn is a one-shot switch back to plain that used to live
// only in memory. It is saved in state.json (`helmetOffPending`, written only while true) before the generation is confirmed, carried by every
// later state write, and applied by the next process at its start.

@Suite("Sprint 11 helmet off", .serialized)
@MainActor
struct Sprint11HelmetOffSuite {
    @Test func HelmetOff_theSwitchBackToPlainIsSavedWhenItIsOwedAndAppliedByTheNextProcess() async throws {
        let position = SavedPosition(displayUUID: "D", xFrac: 0.4, feetFrac: 0.1, scale: 1)
        let worn = AgentState(position: position, look: "helmet", lookSince: Date().timeIntervalSince1970 - 600, recentLooks: ["plain"])
        let first = try HardenRig(state: worn, control: ["helmet": true, "generation": 0])
        await first.spin(until: { (try? first.status.appliedGeneration) == 0 })
        #expect(first.stage.scheduler.look == "helmet"); #expect(first.stage.settings.lookPin == "helmet")
        #expect(try first.state.helmetOffPending == nil, "nothing is owed while the helmet is on")
        // The first process is frozen (a lock) before the control file changes: the pin on plain is applied, but the switch to plain, which
        // the scheduler starts at once when it can and which clears the one-shot, cannot happen behind the test's back, however slow the
        // machine is. Frozen is also how a process looks that ends before the switch.
        first.machine.sink?.setQuiet(.screenLocked, active: true)
        try first.write(["helmet": false])                                   // clawd-pet helmet off
        await first.spin(until: { (try? first.status.appliedGeneration) == 1 })
        #expect(try first.status.appliedGeneration == 1, "generation 1 was applied: \(first.log)")
        #expect(first.stage.settings.lookPin == "plain", "the one-shot is in effect")
        #expect(try first.state.helmetOffPending == true, "and it is saved before the generation is confirmed: \(first.log)")
        #expect(try first.state.look == "helmet", "the helmet is still worn"); #expect(first.stage.scheduler.look == "helmet")
        // Every later write of state.json (a position, a look, a bubble style: all go through the one save) carries the one-shot.
        let persist = try #require(first.stage.scheduler.onPersist)
        persist(SchedulerPersisted(look: "helmet", lookSince: try #require(worn.lookSince), recentLooks: ["plain"], lastBubbleStyle: 4))
        #expect(try first.state.lastBubbleStyle == 4, "the write happened")
        #expect(try first.state.helmetOffPending == true, "and the one-shot went with it")
        // The next one starts over the same state directory, on a virtual clock: the switch to plain starts during the start, and on the real
        // clock a start slower than the 0.8 s sink (a loaded machine) committed it, and cleared the pin, before the check below could run.
        // The look's clock moves to the virtual wall (it starts at 1_800_000_000) still 10 min worn, so the rotation is not due and only the
        // owed one-shot can start the switch.
        var saved = try first.state
        saved.lookSince = 1_800_000_000 - 600
        let again = try RuntimeRig(store: first.store, state: saved, virtual: true)
        #expect(again.stage.settings.lookPin == "plain", "applied at the start: the pin on plain is in effect at once")
        #expect(again.stage.scheduler.look == "helmet", "and the switch it starts has not happened yet")
        #expect(try again.state.helmetOffPending == true, "the one-shot stays saved until the switch")
        var waited = 0.0
        while again.stage.scheduler.look != "plain", waited < 60 { again.advance(0.1); waited += 0.1 }
        #expect(again.stage.scheduler.look == "plain", "the helmet comes off")
        #expect(try again.state.look == "plain"); #expect(try again.state.helmetOffPending == nil, "the one-shot is written away together with the look that ends it")
        await again.spin(until: { again.stage.settings.lookPin == nil }, limit: 30)
        #expect(again.stage.settings.lookPin == nil, "and rotation resumes")
        let third = try HardenRig(store: again.store)
        #expect(third.stage.scheduler.look == "plain"); #expect(third.stage.settings.lookPin == nil, "nothing is owed after it")
    }

    @Test func HelmetOff_aOneShotIsDroppedWhenTheHelmetIsOnAgainOrPlainIsAlreadyWorn() async throws {
        let position = SavedPosition(displayUUID: "D", xFrac: 0.4, feetFrac: 0.1, scale: 1)
        let since = Date().timeIntervalSince1970 - 600
        // Owed, but the helmet is switched on again while the agent is down.
        let on = try HardenRig(state: AgentState(position: position, look: "helmet", lookSince: since, recentLooks: [], helmetOffPending: true),
                               control: ["helmet": true, "generation": 3])
        #expect(on.stage.settings.lookPin == "helmet")
        // Owed, but plain is the look in the file (the file cannot ask for a switch to the look already worn).
        let plain = try HardenRig(state: AgentState(position: position, look: "plain", lookSince: since, recentLooks: [], helmetOffPending: true),
                                  control: ["helmet": false, "generation": 3])
        #expect(plain.stage.settings.lookPin == nil)
        // A state file without the key (every file before Sprint 11) owes nothing.
        let old = try HardenRig(state: AgentState(position: position, look: "helmet", lookSince: since, recentLooks: []), control: ["helmet": false, "generation": 3])
        #expect(old.stage.settings.lookPin == nil)
    }

    @Test func HelmetOff_theStateFileKeepsV1sKeysAndWritesTheNewOneOnlyWhileItIsTrue() throws {
        let position = SavedPosition(displayUUID: "D", xFrac: 0.4, feetFrac: 0.1, scale: 1)
        let store = try artifactStore()
        try store.writeJSON(AgentState(position: position, persisted: SchedulerPersisted(look: "helmet", lookSince: 1_800_000_000)), to: "state.json")
        let quiet = String(decoding: try ReadOnlyFile.data(try store.url("state.json").path), as: UTF8.self)
        #expect(!quiet.contains("helmetOffPending"), "nothing is written while nothing is owed")
        try store.writeJSON(AgentState(position: position, persisted: SchedulerPersisted(look: "helmet", lookSince: 1_800_000_000), helmetOffPending: true), to: "state.json")
        let owed = String(decoding: try ReadOnlyFile.data(try store.url("state.json").path), as: UTF8.self)
        #expect(owed.contains("\"helmetOffPending\" : true"))
        #expect(try store.readJSON(SavedPosition.self, from: "state.json") == position, "v1 still reads its position")
        try store.write(Data(#"{"displayUUID":"D","xFrac":0.25,"feetFrac":0.2,"scale":1}"#.utf8), to: "state.json")
        #expect(try store.readJSON(AgentState.self, from: "state.json").helmetOffPending == nil, "a v1 file decodes")
    }
}
