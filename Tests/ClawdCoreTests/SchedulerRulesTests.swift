import Testing
import Foundation
import CoreGraphics
import ClawdCore

private func lively(_ edit: (inout SchedulerSettings) -> Void = { _ in }) -> SchedulerSettings {
    var s = SchedulerSettings(); s.motion = .lively; edit(&s); return s
}
private func calm(_ edit: (inout SchedulerSettings) -> Void = { _ in }) -> SchedulerSettings {
    var s = SchedulerSettings(); s.motion = .off; edit(&s); return s
}
private func json(_ text: String) -> Data { Data(text.utf8) }

/// The rest of spec section 6 that S-1 to S-13 do not name: the catalog and settings readers, SLEEP, touch, entrances, the drop landing,
/// looks, eligibility and the walk details.
@Suite("SchedulerTests rules", .serialized)
struct SchedulerTestsRules {
    // MARK: catalog

    @Test func Catalog_readsSchemaTwoAndNamesTheEntriesItSkips() {
        let atlas = json("""
        {"schema": 2, "unit": 4,
         "motions": [
           {"id": "A1-thinking", "board": "A1", "kind": "ported", "uses": ["idle", "signature:scientist"], "frames": ["a.png", "b.png"], "ms": [83, 84],
            "stage": {"left": 0, "right": 1.5, "up": 2.5, "down": 0}, "overheadClear": true, "weight": 0.5, "phase": 1, "compatibleLooks": ["plain", "helmet"]},
           {"id": "A15-snooze", "uses": ["sleep-entry"], "frames": 3, "ms": 100, "stage": [0, 1, 0, 0], "hold": true},
           {"id": "A5-walking", "uses": ["walk"], "ms": [100, 100], "strideUnits": 12.5},
           {"id": "A5-walking-mirrored", "uses": ["walk"], "ms": [100, 100], "mirrorOf": "A5-walking"},
           {"id": "bad-no-ms", "uses": ["idle"]},
           {"id": "bad-weight", "uses": ["idle"], "ms": [10], "weight": 0},
           {"uses": ["idle"], "ms": [10]},
           "not an object"],
         "looks": [{"id": "helmet", "board": "D1", "class": "costume", "weight": 0.5}, {"id": "wizard", "class": ["costume", "held"], "signature": ["A25-spark"]}, {"id": ""}]}
        """)
        let catalog = PetCatalog(atlasData: atlas)
        #expect(catalog.motions.map(\.id) == ["A1-thinking", "A15-snooze", "A5-walking", "A5-walking-mirrored"])
        #expect(catalog.issues.count == 5, "\(catalog.issues)")
        let a1 = catalog.motion(id: "A1-thinking")!
        #expect(abs(a1.duration - 0.167) < 1e-9 && a1.weight == 0.5 && a1.overheadClear && a1.stage.up == 2.5 && a1.stage.right == 1.5)
        #expect(a1.uses.contains(.signature("scientist")) && a1.compatibleLooks == ["plain", "helmet"])
        let snooze = catalog.motion(id: "A15-snooze")!
        #expect(abs(snooze.duration - 0.3) < 1e-9 && snooze.holdsLastFrame && snooze.stage.right == 1 && !snooze.overheadClear)
        #expect(snooze.compatibleLooks == nil && catalog.isCompatible(snooze, with: "plain") && !catalog.isCompatible(snooze, with: "helmet"))
        #expect(catalog.motion(id: "A5-walking")!.strideUnits == 12.5 && catalog.motion(id: "A5-walking-mirrored")!.mirrorOf == "A5-walking")
        #expect(catalog.looks.map(\.id) == ["plain", "helmet", "wizard"], "plain is always there")
        #expect(catalog.look(id: "wizard")!.classes == ["costume", "held"] && catalog.look(id: "helmet")!.weight == 0.5)
        #expect(PetCatalog(atlasData: json("not json")).motions.isEmpty && PetCatalog(atlasData: json("[]")).looks.map(\.id) == ["plain"])
    }

    @Test func Catalog_theV1AtlasAloneGivesAnEmptyCatalogAndAQuietPet() {
        let catalog = PetCatalog(atlasData: json(#"{"unit": 4, "canvas": {"w": 12, "h": 12}, "poses": {}}"#))
        #expect(catalog.motions.isEmpty && catalog.issues.isEmpty)
        let rig = SchedulerRig(catalog: catalog, settings: lively())
        rig.advance(86_400)
        #expect(rig.events.isEmpty, "a catalog without motions has nothing to schedule: \(rig.events.prefix(3))")
        #expect(rig.frame.playback == nil)
    }

    @Test func Catalog_theRealAtlasReadsCleanlyAndDrivesTheScheduler() throws {
        let data = try ReadOnlyFile.data(artDirectory.appendingPathComponent("clawd-atlas.json").path)
        let catalog = PetCatalog(atlasData: data)
        if catalog.motions.isEmpty { return }       // a v1-only atlas: nothing to check yet
        #expect(catalog.issues.isEmpty, "\(catalog.issues)")
        #expect(catalog.motions.count >= 37 && catalog.looks.contains { $0.id == "plain" })
        for m in catalog.motions {
            #expect(m.duration > 0 && m.weight > 0 && !m.uses.isEmpty, "\(m.id)")
            if m.duration > 8 { #expect(m.weight <= 0.5, "\(m.id) lasts \(m.duration) s but weighs \(m.weight)") }
        }
        // A day of lively idle life on the real catalog: every motion is compatible with the look worn, and the listening, thinking and
        // sent pools hold only overhead-clear motions.
        let rig = SchedulerRig(catalog: catalog, settings: lively { $0.lookEveryHours = 2 }, seed: 17)
        for i in 0..<30 { rig.dictate(listening: 1.5, lease: i + 1) ; rig.advance(40) }
        rig.advance(86_400)
        #expect(rig.runaway == false)
        var worn = "plain"
        var started = 0
        for item in rig.events.sorted(by: { $0.t < $1.t }) {
            switch item.event {
            case .lookChange(_, let to): worn = to
            case .motionStart(let id, _):
                started += 1
                #expect(catalog.isCompatible(catalog.motion(id: id)!, with: worn), "\(id) played in the \(worn) look")
            case .walkStart:
                // A5 declares no stride (Sprint 1, gap 8): a stepping walk waits until the host decides a speed. The skateboard glides in
                // the rest pose and needs no stride, so it is the only look that walks on the real catalog.
                #expect(catalog.look(id: worn)?.glides == true, "a walk without a declared stride in the \(worn) look")
            default: break
            }
        }
        #expect(started > 1000, "\(started) motions on the real catalog")
        let walking = SchedulerRig(catalog: catalog, settings: lively(), seed: 18, refresh: false)
        walking.scheduler.walkSpeedWhenStrideUndeclared = 40
        walking.scheduler.refresh()
        walking.advance(3600)
        #expect(walking.events.contains { isWalkStart($0.event) }, "no walk with a speed of 40 pt/s chosen by the host")
    }

    // MARK: settings

    @Test func Settings_eachKeyFallsBackOnItsOwn() {
        let defaults = SchedulerSettings()
        #expect(defaults.walk && defaults.motion == .quiet && defaults.lookEveryHours == 4 && defaults.lookPin == nil && defaults.excluded.isEmpty
                && defaults.bubble && defaults.bubbleExcluded.isEmpty && defaults.hiddenUntil == 0 && defaults.generation == 0)
        let good = SchedulerSettings(data: json("""
        {"walk": false, "motion": "lively", "lookEveryHours": 2, "lookPin": "coffee", "excluded": ["A12", " D16 ", "Heart"],
         "bubble": false, "bubbleExcluded": [3, 7], "hiddenUntil": 1800000600, "generation": 41}
        """))
        #expect(!good.walk && good.motion == .lively && good.lookEveryHours == 2 && good.lookPin == "coffee" && good.excluded == ["a12", "d16", "heart"]
                && !good.bubble && good.bubbleExcluded == [3, 7] && good.hiddenUntil == 1800000600 && good.generation == 41)
        // One bad value resets that key only.
        let bad: [(String, String, (SchedulerSettings) -> Bool)] = [
            ("walk", #""yes""#, { $0.walk }), ("walk", "1", { $0.walk }), ("motion", #""frantic""#, { $0.motion == .quiet }), ("motion", "2", { $0.motion == .quiet }),
            ("lookEveryHours", "5", { $0.lookEveryHours == 4 }), ("lookEveryHours", #""3""#, { $0.lookEveryHours == 4 }), ("lookEveryHours", "2.5", { $0.lookEveryHours == 4 }),
            ("lookPin", "7", { $0.lookPin == nil }), ("lookPin", #""random""#, { $0.lookPin == nil }), ("lookPin", #""""#, { $0.lookPin == nil }),
            ("excluded", #""A12""#, { $0.excluded.isEmpty }), ("excluded", #"["A12", 3]"#, { $0.excluded.isEmpty }), ("excluded", #"["A12", ""]"#, { $0.excluded.isEmpty }),
            ("bubble", "0", { $0.bubble }), ("bubbleExcluded", "[0]", { $0.bubbleExcluded.isEmpty }), ("bubbleExcluded", "[16]", { $0.bubbleExcluded.isEmpty }),
            ("bubbleExcluded", "[1.5]", { $0.bubbleExcluded.isEmpty }), ("bubbleExcluded", "[1,2,3,4,5,6,7,8,9,10,11,12,13,14,15]", { $0.bubbleExcluded.isEmpty }),
            ("hiddenUntil", "-5", { $0.hiddenUntil == 0 }), ("hiddenUntil", #""soon""#, { $0.hiddenUntil == 0 }), ("generation", "-1", { $0.generation == 0 }),
            ("generation", "1.5", { $0.generation == 0 }),
        ]
        for (key, value, ok) in bad {
            var base = ["walk": "false", "motion": #""normal""#, "bubble": "false"]
            base[key] = value
            let read = SchedulerSettings(data: json("{" + base.map { #""\#($0.key)": \#($0.value)"# }.joined(separator: ",") + "}"))
            #expect(ok(read), "\(key) = \(value) did not give its default")
            if key != "walk" { #expect(!read.walk, "\(key) = \(value) reset walk too") }
            if key != "motion" { #expect(read.motion == .normal, "\(key) = \(value) reset motion too") }
            if key != "bubble" { #expect(!read.bubble, "\(key) = \(value) reset bubble too") }
        }
        #expect(SchedulerSettings(data: json("garbage")) == defaults && SchedulerSettings(data: json("[1]")) == defaults)
        #expect(SchedulerSettings(data: json(#"{"hiddenUntil": -1}"#)).hiddenUntil == -1 && SchedulerSettings(data: json(#"{"hiddenUntil": -1}"#)).hidden(atWall: 5))
        #expect(MotionLevel.quiet.interval == 120...300 && MotionLevel.normal.interval == 45...100 && MotionLevel.lively.interval == 6...15 && MotionLevel.off.interval == nil)
    }

    @Test func Settings_exclusionMatchesBoardIdItemIdAndName() {
        let catalog = SchedulerFixture.catalog()
        let heart = catalog.motion(id: "A12-heart")!
        for word in ["a12", "A12-HEART", "heart", " Heart "] {
            #expect(SchedulerSettings(object: ["excluded": [word]]).excludes(heart), "\(word)")
        }
        #expect(!SchedulerSettings(object: ["excluded": ["A1"]]).excludes(heart))
        #expect(SchedulerSettings(object: ["excluded": ["D16"]]).excludes(CatalogLook(id: "cowboy", board: "D16")))
        let hidden = SchedulerSettings(object: ["hiddenUntil": 100.0])
        #expect(hidden.hidden(atWall: 99.9) && !hidden.hidden(atWall: 100))
    }

    // MARK: bubble style draw

    @Test func Bubble_theDrawFollowsSection4_2() {
        let all = Array(1...12)
        let shares = BubbleStyles.stationaryShares(enabled: all)
        #expect(abs(shares[6]! - 39.0 / 228) < 1e-12 && abs(shares[10]! - 39.0 / 228) < 1e-12 && abs(shares[1]! - 15.0 / 228) < 1e-12)
        #expect(abs(shares.values.reduce(0, +) - 1) < 1e-12)
        #expect(BubbleStyles.stationaryShares(enabled: [1, 6]) == [1: 0.5, 6: 0.5])
        // From L = 1 over {1, 6}: always 6 (probability 3 / (4 - 1) = 1); from L = 6: always 1.
        for unit in stride(from: 0.0, to: 1.0, by: 0.05) {
            #expect(BubbleStyles.draw(enabled: [1, 6], last: 1, unit: unit) == 6)
            #expect(BubbleStyles.draw(enabled: [1, 6], last: 6, unit: unit) == 1)
            #expect(BubbleStyles.draw(enabled: [7], last: 7, unit: unit) == 7)
        }
        // L = 6 over all twelve: the other eleven with w_j / (16 - 3); 10 is the only heavy one left.
        var counts = [Int: Int]()
        let source = SeededRandom(seed: 3)
        for _ in 0..<130_000 { counts[BubbleStyles.draw(enabled: all, last: 6, unit: source.unit())!, default: 0] += 1 }
        #expect(counts[6] == nil)
        #expect(abs(Double(counts[10]!) / 130_000 - 3.0 / 13) < 0.01 && abs(Double(counts[2]!) / 130_000 - 1.0 / 13) < 0.01)
        // A last style that is no longer enabled does not shrink the total.
        #expect(BubbleStyles.draw(enabled: [2, 3], last: 9, unit: 0.1) == 2 && BubbleStyles.draw(enabled: [2, 3], last: 9, unit: 0.9) == 3)
        #expect(BubbleStyles.draw(enabled: [], last: nil, unit: 0.5) == nil)
    }

    // MARK: determinism, timers

    @Test func Scheduler_sameSeedSameSchedule() {
        func day(_ seed: UInt64) -> [Logged] {
            let rig = SchedulerRig(settings: lively { $0.lookEveryHours = 2 }, seed: seed)
            for i in 0..<20 { rig.advance(900); rig.dictate(listening: 1.5, lease: i + 1); if i % 3 == 0 { rig.scheduler.click() } }
            rig.advance(86_400)
            return rig.events
        }
        let a = day(77), b = day(77), c = day(78)
        #expect(a.count > 1000 && a == b, "the same seed gave a different schedule")
        #expect(a != c)
    }

    @Test func Scheduler_owns_atMostOneTimerWhateverHappens() {
        let rig = SchedulerRig(settings: lively { $0.lookEveryHours = 2 }, seed: 19)
        var maxSeen = 0
        func sample() { maxSeen = max(maxSeen, rig.scheduler.ownedTimers) }
        for i in 0..<60 {
            rig.advance(400); sample()
            rig.dictate(listening: 2, lease: i + 1); sample()
            rig.scheduler.click(); sample()
            rig.scheduler.pointerMoved(CGPoint(x: 500, y: 120)); sample()
            if i % 7 == 0 { rig.scheduler.setQuiet(.screenLocked, active: true); sample(); rig.advance(30); rig.scheduler.setQuiet(.screenLocked, active: false); sample() }
            if i % 11 == 0 { rig.scheduler.dragStarted(); sample(); rig.scheduler.dragEnded(); sample() }
        }
        #expect(maxSeen <= 1 && rig.maxTimers <= 1, "timers seen: \(maxSeen) / \(rig.maxTimers)")
        #expect(rig.scheduler.stallCount == 0)
    }

    // MARK: SLEEP

    @Test func Sleep_dozesOffAfterTenMinutesWithoutInputAndPlaysTheSnoozeOnce() {
        let rig = SchedulerRig(settings: lively { $0.lookPin = "plain" }, refresh: false)
        rig.inputIdle = nil
        rig.scheduler.refresh()
        rig.advance(590)
        #expect(!rig.frame.asleep, "asleep before ten minutes without input")
        #expect(rig.count { $0 == .sleepStart } == 0)
        rig.advance(30)
        #expect(rig.frame.asleep && rig.count { $0 == .sleepStart } == 1)
        #expect(rig.frame.playback?.motionID == "A15-snooze" && rig.frame.playback?.holdsLastFrame == true, "\(String(describing: rig.frame.playback))")
        #expect(rig.scheduler.ownedTimers == 1)
        // No idle motion while asleep; the input idle time is re-read about once a minute.
        let arms = rig.timer.armCount, events = rig.events.count
        rig.advance(3600)
        #expect(rig.frame.asleep && rig.events.count == events)
        #expect(rig.timer.armCount - arms <= 61, "\(rig.timer.armCount - arms) timer arms in an hour asleep")
        // Input returns: Clawd wakes within a minute, to the rest pose, and the next idle motion waits a full interval.
        rig.touchInput()
        rig.advance(61)
        #expect(!rig.frame.asleep && rig.count { $0 == .wake } == 1)
        let wokeAt = rig.events.last(where: { $0.event == .wake })!.t
        rig.advance(300)
        let first = rig.events.first { isMotionStart($0.event) && $0.t > wokeAt }
        let full = MotionLevel.lively.interval!.lowerBound
        #expect(first != nil && first!.t - wokeAt >= full - 1e-6, "the first motion after waking came \(String(describing: first.map { $0.t - wokeAt })) s later")
    }

    @Test func Sleep_aClickWakesToTheRestPoseAndADictationWakesToo() {
        for how in ["click", "dictation", "drag"] {
            let rig = SchedulerRig(settings: lively(), refresh: false)
            rig.inputIdle = 700
            rig.scheduler.refresh()
            #expect(rig.frame.asleep, "\(how): not asleep")
            rig.inputIdle = 0       // the user is back: the click, the key and the drag are input
            switch how {
            case "click": rig.scheduler.click()
            case "dictation": rig.start()
            default: rig.scheduler.dragStarted()
            }
            #expect(!rig.frame.asleep && rig.count { $0 == .wake } == 1, "\(how): still asleep")
            if how == "click" { #expect(rig.frame.playback == nil && rig.count { $0 == .touch } == 0, "a click that wakes Clawd is not also a reaction") }
            if how == "dictation" { #expect(rig.frame.playback?.use == "listening") }
        }
    }

    @Test func Sleep_reduceMotionSkipsTheEntryAnimation() {
        let rig = SchedulerRig(settings: lively(), refresh: false)
        rig.inputIdle = 700
        rig.scheduler.setReduceMotion(true)
        rig.scheduler.refresh()
        #expect(rig.frame.asleep)
        if case .pose(let name)? = rig.frame.playback?.source { #expect(name == "sleep") } else { Issue.record("\(String(describing: rig.frame.playback))") }
    }

    // MARK: touch

    @Test func Touch_aClickPlaysAReactionThreeClicksPlayTheMultiTouchAndClicksAreIgnoredWhileItPlays() {
        let rig = SchedulerRig(settings: calm())
        rig.scheduler.click()
        #expect(rig.frame.playback?.use == "touch" && ["A3-jumping", "A4-waving", "A8-excited", "A12-heart", "A33-rose"].contains(rig.frame.playback?.motionID ?? ""))
        rig.advance(0.4); rig.scheduler.click()
        #expect(rig.count { $0 == .touch } == 2 && rig.count { $0 == .multiTouch } == 0)
        rig.advance(0.4); rig.scheduler.click()
        #expect(rig.count { $0 == .multiTouch } == 1 && rig.frame.playback?.use == "multi-touch" && rig.frame.playback?.motionID == "A6-turning")
        let triggered = rig.now
        rig.advance(1.0); rig.scheduler.click()
        rig.advance(1.0); rig.scheduler.click()
        #expect(rig.count { $0 == .touch } == 2 && rig.count { $0 == .multiTouch } == 1, "a click while the multi-touch reaction plays did something")
        rig.advance(0.5); rig.scheduler.click()
        #expect(rig.now - triggered > 2.42 && rig.count { $0 == .touch } == 3, "clicks still ignored after the multi-touch reaction (2.42 s) ended")
        // Three clicks spread over 2.4 s are no multi-touch; clicks 2.1 s apart are single reactions.
        let slow = SchedulerRig(settings: calm())
        slow.scheduler.click(); slow.advance(1.2); slow.scheduler.click(); slow.advance(1.2); slow.scheduler.click()
        #expect(slow.count { $0 == .multiTouch } == 0, "three clicks over 2.4 s are not three clicks within 2 s")
        let spaced = SchedulerRig(settings: calm())
        for _ in 0..<5 { spaced.scheduler.click(); spaced.advance(2.1) }
        #expect(spaced.count { $0 == .multiTouch } == 0 && spaced.count { $0 == .touch } == 5)
    }

    @Test func Touch_doNothingDuringADictationATransitionOrWhenQuiet() {
        let scene = SchedulerRig(settings: calm())
        scene.start(); scene.scheduler.click()
        #expect(scene.count { $0 == .touch } == 0 && scene.frame.playback?.use == "listening")
        let transition = SchedulerRig(settings: calm(), persisted: SchedulerPersisted(look: "plain", lookSince: 1_800_000_000 - 5 * 3600))
        transition.advance(0.4)
        #expect(transition.frame.transitionProgress != nil)
        transition.scheduler.click()
        #expect(transition.count { $0 == .touch } == 0)
        let quiet = SchedulerRig(settings: calm())
        quiet.scheduler.setQuiet(.displayAsleep, active: true); quiet.scheduler.click()
        #expect(quiet.count { $0 == .touch } == 0)
        // A click cuts an idle motion and a walk; the walk goes home afterwards.
        let walk = SchedulerRig(settings: lively(), seed: 3)
        #expect(walk.run(upTo: 7200) { walk.frame.playback?.use == "walk" })
        walk.advance(2)
        let away = walk.frame.walkOffset
        walk.scheduler.click()
        #expect(walk.frame.playback?.use == "touch" && abs(walk.frame.walkOffset - away) < 1e-9)
        let before = walk.events.count
        #expect(walk.run(upTo: 120) { walk.eventsSince(before).contains { if case .walkEnd = $0.event { return true } else { return false } } })
        #expect(abs(walk.frame.walkOffset) < 1e-6)
    }

    // MARK: entrances and the drop landing

    @Test func Entrance_appearancesPlayAnEntranceThatFitsAndAtOnceOtherwise() {
        let rig = SchedulerRig(settings: calm())
        var seen: [String] = []
        for _ in 0..<40 {
            rig.scheduler.appear()
            if let id = rig.frame.playback?.motionID { seen.append(id) }
            rig.advance(3)
        }
        #expect(seen.count == 40 && Set(seen).isSubset(of: ["C3-skip", "C6-peekaboo", "C7-drop", "C8-waddle", "C9-peek"]) && Set(seen).count >= 4)
        for i in 1..<seen.count { #expect(seen[i] != seen[i - 1], "entrance \(seen[i]) twice in a row") }
        // Home 20 pt from the left edge: the entrances come from 48 pt to the left and do not fit; C7 falls from above and does.
        let edge = SchedulerRig(settings: calm(), geometry: SchedulerFixture.geometry(homeX: 20))
        var edgeSeen = Set<String>()
        for _ in 0..<30 { edge.scheduler.appear(); if let id = edge.frame.playback?.motionID { edgeSeen.insert(id) }; edge.advance(3) }
        #expect(edgeSeen == ["C7-drop"], "\(edgeSeen)")
        let none = SchedulerRig(catalog: PetCatalog(), settings: calm())
        none.scheduler.appear()
        #expect(none.frame.playback == nil)
    }

    @Test func Entrance_wakeUnlockAquaStartAndTheEndOfAHideAppearButDisplaySleepDoesNot() {
        for (reason, enters) in [(QuietReason.systemAsleep, true), (.screenLocked, true), (.aquaNotRunning, true), (.displayAsleep, false),
                                 (.sessionInactive, false), (.notOnActiveSpace, false)] {
            let rig = SchedulerRig(settings: calm())
            rig.scheduler.setQuiet(reason, active: true); rig.advance(60); rig.scheduler.setQuiet(reason, active: false)
            #expect((rig.frame.playback?.use == "entrance") == enters, "\(reason)")
        }
        let rig = SchedulerRig(settings: calm())
        var hide = rig.scheduler.settings; hide.hiddenUntil = rig.wall + 30
        rig.scheduler.update(settings: hide)
        rig.advance(30.3)
        #expect(rig.frame.visibility == .visible && rig.frame.playback?.use == "entrance")
        // A dictation that is already running keeps the scene: no entrance over it.
        let busy = SchedulerRig(settings: calm())
        busy.scheduler.setQuiet(.screenLocked, active: true); busy.start(); busy.scheduler.setQuiet(.screenLocked, active: false)
        #expect(busy.frame.playback?.use == "listening")
    }

    @Test func Drag_cutsEverythingTheDropLandsAndTheDropBecomesHome() {
        let rig = SchedulerRig(settings: lively(), seed: 5)
        #expect(rig.run(upTo: 7200) { rig.frame.playback?.use == "walk" })
        rig.advance(2)
        rig.scheduler.dragStarted()
        var f = rig.frame
        var dangling = false
        if case .pose("dangle")? = f.playback?.source { dangling = true }
        #expect(f.dragging && f.walkOffset == 0 && dangling)
        #expect(rig.count { if case .walkEnd = $0 { return true } else { return false } } == 1, "a drag ends the walk")
        rig.scheduler.dragEnded(newHome: CGPoint(x: 300, y: 100))
        f = rig.frame
        #expect(!f.dragging && f.playback?.use == "drop" && f.playback?.motionID == "C7-drop")
        #expect(rig.scheduler.geometry.homeOrigin == CGPoint(x: 300, y: 100))
        // A drop during a dictation lands in the scene, not in the landing.
        rig.start()
        rig.scheduler.dragStarted(); rig.scheduler.dragEnded(newHome: CGPoint(x: 320, y: 100))
        #expect(rig.frame.playback?.use == "listening" && rig.frame.bubble != nil)
        // The bubble follows Clawd through the drag.
        rig.scheduler.dragStarted()
        #expect(rig.frame.bubble != nil && rig.frame.dragging)
        rig.scheduler.dragEnded()
        // Reduce Motion: no landing.
        let calmRig = SchedulerRig(settings: calm())
        calmRig.scheduler.setReduceMotion(true)
        calmRig.scheduler.dragStarted(); calmRig.scheduler.dragEnded()
        #expect(calmRig.frame.playback == nil)
    }

    // MARK: looks

    @Test func Look_aWornLookThatIsSwitchedOffChangesAtTheNextAllowedMoment() {
        let rig = SchedulerRig(settings: calm(), persisted: SchedulerPersisted(look: "coffee", lookSince: 1_800_000_000))
        #expect(rig.frame.look == "coffee")
        rig.advance(7200); #expect(rig.frame.look == "coffee", "nothing is due yet")
        var s = rig.scheduler.settings; s.excluded = ["d9"]
        rig.scheduler.update(settings: s)
        rig.advance(30)
        #expect(rig.frame.look != "coffee")
        rig.advance(86_400 * 3)
        #expect(!rig.events.contains { if case .lookChange(_, let to) = $0.event { return to == "coffee" } else { return false } }, "an excluded look came back")
    }

    @Test func Look_anUnknownPinIsIgnoredAndALookWithFewerThanSixMotionsIsNeverInRotation() {
        let rig = SchedulerRig(settings: calm { $0.lookPin = "no-such-look"; $0.lookEveryHours = 2 }, seed: 2)
        rig.advance(3 * 86_400)
        #expect(rig.count(where: isLookChange) > 20, "rotation did not go on with an unknown pin")
        // A catalog whose "thin" look wears only three idle motions.
        var motions = SchedulerFixture.catalog().motions
        for id in ["A4-waving", "A9-dancing", "A16-meditating"] { motions[motions.firstIndex { $0.id == id }!].compatibleLooks?.insert("thin") }
        let thin = PetCatalog(motions: motions, looks: SchedulerFixture.catalog().looks + [CatalogLook(id: "thin", classes: ["costume"])])
        #expect(thin.compatibleIdleCount(look: "thin") == 3)
        let thinRig = SchedulerRig(catalog: thin, settings: calm { $0.lookEveryHours = 2 }, seed: 3)
        thinRig.advance(14 * 86_400)
        #expect(thinRig.count(where: isLookChange) > 100)
        #expect(!thinRig.events.contains { if case .lookChange(_, let to) = $0.event { return to == "thin" } else { return false } }, "a look with 3 compatible idle motions was worn")
    }

    @Test func Look_theLighterLooksComeLaterInTheCycleAndAreOnlyModeratelyRarer() {
        // With the shuffle bag every look is worn once per cycle, so the weight 0.5 of shiny decides mostly where in the cycle it comes. Not
        // wholly: the look that ends a cycle sits out the next one (the bag restarts with it already counted), and the light look ends cycles
        // more often, so it is worn somewhat less often (156 against about 183 in 120 days with this seed). The test bounds that loss.
        let rig = SchedulerRig(settings: calm { $0.lookEveryHours = 2 }, seed: 8)
        rig.advance(120 * 86_400)
        var counts = [String: Int]()
        var worn: [String] = []
        for e in rig.events { if case .lookChange(_, let to) = e.event { counts[to, default: 0] += 1; worn.append(to) } }
        let heavy = ["helmet", "sunglasses", "headphones", "coffee", "skateboard", "wizard"].map { Double(counts[$0] ?? 0) }.filter { $0 > 0 }
        let shiny = Double(counts["shiny"] ?? 0)
        #expect(worn.count > 1000 && heavy.count >= 4)
        let others = heavy.reduce(0, +) / Double(heavy.count)
        #expect(shiny > 0.7 * others && shiny <= others, "shiny (weight 0.5) \(shiny) is at most a little rarer than the others \(heavy)")
        let cycle = Set(worn).count - 1                       // the looks a cycle adds after the first, which counts the look worn at its start
        var shinyPositions: [Double] = [], otherPositions: [Double] = []
        for (n, look) in worn.enumerated() {
            if look == "shiny" { shinyPositions.append(Double(n % cycle)) } else { otherPositions.append(Double(n % cycle)) }
        }
        let lateShiny = shinyPositions.reduce(0, +) / Double(shinyPositions.count), lateOthers = otherPositions.reduce(0, +) / Double(otherPositions.count)
        #expect(lateShiny > lateOthers, "shiny comes later in the cycle: mean position \(lateShiny) against \(lateOthers)")
    }

    @Test func Look_theLookAndItsClockPersistAndTheClockRunsAcrossSleep() {
        var saved: [SchedulerPersisted] = []
        let rig = SchedulerRig(settings: calm { $0.lookEveryHours = 2 }, seed: 9, refresh: false)
        rig.scheduler.onPersist = { saved.append($0) }
        rig.scheduler.refresh()
        rig.advance(2 * 3600 + 5)
        let change = rig.events.first { isLookChange($0.event) }
        #expect(change != nil && saved.count == 1)
        if let change, case .lookChange(_, let to) = change.event, let state = saved.first {
            #expect(state.look == to && state.recentLooks == ["plain"])
            #expect(abs(state.lookSince - (rig.startedWall.timeIntervalSince1970 + (change.t - rig.started))) < 1e-6, "lookSince is the wall time of the change")
        }
        // The Mac sleeps for five hours: the monotonic clock stands still, the wall clock moves on.
        let swaps = rig.count(where: isLookChange)
        rig.clock.wallNow.addTimeInterval(5 * 3600)
        rig.scheduler.refresh()
        rig.advance(45)
        #expect(rig.count(where: isLookChange) == swaps + 1, "the look due during the sleep did not change after waking")
        // A restart restores the look worn and the time of its change.
        let restored = SchedulerRig(settings: calm { $0.lookEveryHours = 2 }, persisted: SchedulerPersisted(look: "headphones", lookSince: 1_800_000_000 - 3600, recentLooks: ["plain"]))
        #expect(restored.frame.look == "headphones")
        restored.advance(3500); #expect(restored.count(where: isLookChange) == 0)
        restored.advance(200); #expect(restored.count(where: isLookChange) == 1)
        #expect(restored.scheduler.nextLookChange != nil)
    }

    // MARK: eligibility

    @Test func Eligibility_aStageThatDoesNotFitTheVisibleFrameIsNeverPlayed() {
        let rig = SchedulerRig(settings: lively { $0.lookPin = "plain" }, geometry: SchedulerFixture.geometry(homeX: 1380), seed: 4)
        rig.advance(86_400)
        let ids = Set(rig.ids("idle"))
        #expect(ids.count >= 8)
        for tooWide in ["A25-spark", "A33-rose", "A20-laptop", "A10-breakdancing"] { #expect(!ids.contains(tooWide), "\(tooWide) does not fit at the right edge") }
        for i in 0..<30 { rig.dictate(listening: 1.5, lease: i + 1) }
        #expect(!rig.ids("thinking", "listening", "sent").contains("A20-laptop"))
    }

    @Test func Eligibility_aMotionNeverStartsOverThePointer() {
        let rig = SchedulerRig(settings: lively { $0.lookPin = "plain"; $0.walk = false }, seed: 6, refresh: false)
        rig.scheduler.pointerMoved(CGPoint(x: 640, y: 120))      // right of Clawd, inside the stages of A33, A25 and A20
        rig.scheduler.refresh()
        rig.advance(86_400)
        let ids = Set(rig.ids("idle"))
        #expect(ids.count >= 8)
        for under in ["A33-rose", "A25-spark", "A20-laptop"] { #expect(!ids.contains(under), "\(under) started over the pointer") }
        rig.scheduler.pointerMoved(CGPoint(x: 1300, y: 600))
        rig.advance(86_400)
        #expect(Set(rig.ids("idle")).contains("A33-rose"), "A33 never played once the pointer left")
    }

    // MARK: walking details

    @Test func Walk_theSkateboardGlidesAndAMirroredEntryPlaysForLeftwardLegs() {
        let glide = SchedulerRig(settings: lively { $0.lookPin = "skateboard" }, seed: 11)
        glide.advance(10)
        #expect(glide.frame.look == "skateboard")
        let walks = SchedulerScenarios.observeWalks(glide, count: 6)
        #expect(walks.count == 6)
        for w in walks {
            let moving = w.samples.filter { $0.use == "walk" }
            #expect(!moving.isEmpty)
            if let first = moving.first, let arrived = w.samples.first(where: { abs($0.offset - w.dx) < 1e-6 }) {
                let speed = abs(w.dx) / max(0.1, arrived.t - first.t + 0.05)
                #expect(abs(speed - 40) < 4, "glide speed \(speed)")
            }
        }
        #expect(!glide.ids("idle").contains("A5-walking"))
        // The catalog's own mirrored entry is played for leftward legs.
        var motions = SchedulerFixture.catalog().motions
        let base = motions.first { $0.id == "A5-walking" }!
        var mirror = base; mirror.id = "A5-walking-mirrored"; mirror.mirrorOf = "A5-walking"; mirror.kind = "procedural"
        motions.append(mirror)
        let rig = SchedulerRig(catalog: PetCatalog(motions: motions, looks: SchedulerFixture.catalog().looks), settings: lively { $0.lookPin = "plain" }, seed: 12)
        var sources = Set<String>()
        for _ in 0..<12 {
            let before = rig.events.count
            _ = rig.run(upTo: 7200) { rig.eventsSince(before).contains { isWalkStart($0.event) } }
            for _ in 0..<400 {
                rig.advance(0.1)
                if let p = rig.frame.playback, p.use == "walk", let id = p.motionID { sources.insert(id + (p.mirrored ? "+flip" : "")) }
                if rig.eventsSince(before).contains(where: { if case .walkEnd = $0.event { return true } else { return false } }) { break }
            }
        }
        #expect(sources == ["A5-walking", "A5-walking-mirrored"], "\(sources)")
    }

    @Test func Walk_withoutADeclaredStrideThereIsNoWalkUntilTheHostChoosesASpeed() {
        let noStride = SchedulerFixture.catalog().motions.map { m -> CatalogMotion in var n = m; if n.id == "A5-walking" { n.strideUnits = nil }; return n }
        let catalog = PetCatalog(motions: noStride, looks: SchedulerFixture.catalog().looks)
        let none = SchedulerRig(catalog: catalog, settings: lively(), seed: 1)
        none.advance(6 * 3600)
        #expect(!none.events.contains { isWalkStart($0.event) })
        for refused in [10.0, 200.0, 0.0] {
            let rig = SchedulerRig(catalog: catalog, settings: lively(), seed: 1, refresh: false)
            rig.scheduler.walkSpeedWhenStrideUndeclared = refused
            #expect(rig.scheduler.walkSpeedWhenStrideUndeclared == nil, "\(refused) pt/s is outside 20-80")
        }
        let rig = SchedulerRig(catalog: catalog, settings: lively(), seed: 1, refresh: false)
        rig.scheduler.walkSpeedWhenStrideUndeclared = 30
        rig.scheduler.refresh()
        let walks = SchedulerScenarios.observeWalks(rig, count: 5)
        #expect(walks.count == 5 && walks.allSatisfy { $0.walked <= 30 })
    }

    @Test func Walk_aHomeNextToTheScreenEdgeWalksTheOtherWay() {
        let rig = SchedulerRig(settings: lively(), geometry: SchedulerFixture.geometry(homeX: 4), seed: 21)
        let walks = SchedulerScenarios.observeWalks(rig, count: 8)
        #expect(walks.count == 8 && walks.allSatisfy { $0.dx > 0 }, "\(walks.map(\.dx))")
    }

    @Test func Walk_aboutOneIdleSlotInTwoIsAWalk() {
        let rig = SchedulerRig(settings: lively { $0.lookPin = "plain" }, seed: 41)
        rig.advance(5 * 86_400)
        let walks = Double(rig.count(where: isWalkStart))
        let motions = Double(rig.ids("idle", "signature:plain").count)
        let share = walks / (walks + motions)
        #expect(walks + motions > 10_000 && abs(share - 0.5) < 0.05, "\(walks) walks, \(motions) motions: \(share)")
    }

    // MARK: any order of everything

    /// Thousands of random inputs in random order, every setting and condition included; after each one the frame and the log are checked.
    @Test func Fuzz_anyOrderOfEverythingKeepsTheFrameAndTheLogConsistent() {
        var covered = Set<String>()
        for seed: UInt64 in 1...8 { covered.formUnion(fuzz(seed: seed)) }
        let wanted: Set<String> = ["idle", "walk", "entrance", "touch", "multi-touch", "drop", "listening", "thinking", "sent", "sleep-entry",
                                   "lookChange", "lookTransition", "sleepStart", "wake", "quietOn", "hidden", "shown", "bubbleStyle", "walkEnabled", "walkDisabled"]
        #expect(wanted.subtracting(covered).isEmpty, "the fuzz never reached: \(wanted.subtracting(covered).sorted())")
    }

    private func fuzz(seed: UInt64) -> Set<String> {
        var covered = Set<String>()
        let catalogs = [SchedulerFixture.catalog(), PetCatalog(), SchedulerFixture.catalog(walkStride: 12)]
        let rig = SchedulerRig(catalog: catalogs[0], settings: lively { $0.lookEveryHours = 2 }, seed: seed, refresh: false, eventLimit: 2_000_000)
        rig.inputIdle = nil
        rig.scheduler.refresh()
        let d = SeededRandom(seed: seed &* 31 &+ 7)
        var lease = 0
        var seen = 0
        var open = (motion: 0, walk: 0, sleep: 0, transition: 0, quiet: 0)
        let reasons = QuietReason.allCases
        func setting(_ edit: (inout SchedulerSettings) -> Void) { var s = rig.scheduler.settings; edit(&s); rig.scheduler.update(settings: s) }
        for step in 0..<12000 {
            let r = d.unit()
            rig.inputIdle = d.unit() < 0.9 ? 0 : nil      // mostly at the Mac; sometimes the idle time runs from the last input
            rig.advance(r < 0.3 ? d.unit() * 3 : r < 0.6 ? d.unit() * 60 : d.unit() * 600)
            switch Int(d.unit() * 27) {
            case 0: lease += 1; rig.touchInput(); rig.start(lease)
            case 1: rig.complete(lease)
            case 2: rig.ack(d.unit() < 0.9)
            case 3: rig.cancel(lease)
            case 4: rig.fail()
            case 5: rig.touchInput(); rig.scheduler.click()
            case 6: rig.scheduler.dragStarted()
            case 7: rig.scheduler.dragEnded(newHome: d.unit() < 0.5 ? nil : CGPoint(x: 20 + d.unit() * 1300, y: 100))
            case 8: rig.scheduler.pointerMoved(d.unit() < 0.2 ? nil : CGPoint(x: d.unit() * 1440, y: 80 + d.unit() * 200))
            case 9: rig.scheduler.setQuiet(reasons[Int(d.unit() * Double(reasons.count))], active: d.unit() < 0.3)
            case 10: rig.scheduler.setReduceMotion(d.unit() < 0.5)
            case 11: rig.scheduler.appear()
            case 12: setting { $0.walk.toggle() }
            case 13: setting { $0.motion = MotionLevel.allCases[Int(d.unit() * 4)] }
            case 14: setting { $0.excluded = Set(["a10", "heart", "wizard", "a5", "c3", "a15", "skateboard", "a6"].filter { _ in d.unit() < 0.25 }) }
            case 15: setting { $0.lookPin = [nil, "plain", "coffee", "skateboard", "no-such-look", "wizard"][Int(d.unit() * 6)] }
            case 16: setting { $0.bubble = d.unit() < 0.7; $0.bubbleExcluded = Set((1...12).filter { _ in d.unit() < 0.3 }) }
            case 17: setting { $0.hiddenUntil = d.unit() < 0.6 ? 0 : (d.unit() < 0.05 ? -1 : rig.wall + d.unit() * 900) }
            case 18:
                let scale = [1.0, 1.5, 2, 3, 4][Int(d.unit() * 5)]
                rig.scheduler.update(geometry: SchedulerFixture.geometry(scale: scale, homeX: 4 + d.unit() * 1300))
            case 19: rig.scheduler.update(catalog: catalogs[Int(d.unit() * 3)])
            case 20: rig.touchInput()
            case 21: setting { $0.lookEveryHours = [2, 3, 4][Int(d.unit() * 3)] }
            case 22: rig.clock.wallNow.addTimeInterval(d.unit() * 6 * 3600); rig.scheduler.refresh()
            case 23: lease += 1; rig.touchInput(); rig.dictate(listening: d.unit() * 10, lease: lease)
            case 24: for _ in 0..<3 { rig.scheduler.click(); rig.advance(0.2) }
            case 25: lease += 1; rig.touchInput(); rig.start(lease); rig.advance(d.unit() * 3); rig.complete(lease); rig.advance(d.unit() * 2)
            default: rig.scheduler.refresh()
            }
            let f = rig.frame
            let tag = "seed \(seed) step \(step)"
            #expect(rig.scheduler.stallCount == 0, "\(tag): the scheduler stalled")
            guard rig.scheduler.stallCount == 0 else { return covered }
            #expect(rig.scheduler.ownedTimers <= 1, "\(tag): timers")
            if f.visibility != .visible {
                #expect(f.playback == nil && f.walkOffset == 0 && !f.dragging && f.bubble == nil, "\(tag): \(f.visibility) but something is shown")
            }
            if f.dragging { if case .pose("dangle")? = f.playback?.source {} else { Issue.record("\(tag): dragging but \(String(describing: f.playback?.source))") } }
            if f.bubble != nil { #expect(f.scene != .idle, "\(tag): bubble without a scene") }
            if f.asleep { #expect(f.scene == .idle && !f.dragging && f.visibility == .visible, "\(tag): asleep during \(f.scene)") }
            if let id = f.playback?.motionID { #expect(rig.scheduler.catalog.motion(id: id) != nil, "\(tag): \(id) is not in the catalog") }
            if f.walkOffset != 0 {
                let geo = rig.scheduler.geometry
                #expect(geo.visibleFrame.contains(geo.canvasRect(originX: Double(geo.homeOrigin.x) + f.walkOffset)), "\(tag): Clawd walked out of the frame (\(f.walkOffset))")
            }
            for item in rig.events[seen...] {
                switch item.event {
                case .motionStart(_, let use): covered.insert(use)
                case .lookChange: covered.insert("lookChange")
                case .lookTransition: covered.insert("lookTransition")
                case .sleepStart: covered.insert("sleepStart")
                case .wake: covered.insert("wake")
                case .quietOn: covered.insert("quietOn")
                case .hidden: covered.insert("hidden")
                case .shown: covered.insert("shown")
                case .bubbleStyle: covered.insert("bubbleStyle")
                case .walkEnabled: covered.insert("walkEnabled")
                case .walkDisabled: covered.insert("walkDisabled")
                case .walkStart: covered.insert("walk")
                case .multiTouch: covered.insert("multi-touch")
                default: break
                }
                switch item.event {
                case .motionStart: open.motion += 1
                case .motionEnd: open.motion -= 1
                case .walkStart: open.walk += 1
                case .walkEnd: open.walk -= 1
                case .sleepStart: open.sleep += 1
                case .wake: open.sleep -= 1
                case .lookTransition: open.transition += 1
                case .lookTransitionEnd: open.transition -= 1
                case .quietOn: open.quiet += 1
                case .quietOff: open.quiet -= 1
                default: break
                }
            }
            seen = rig.events.count
            #expect((0...1).contains(open.motion) && (0...1).contains(open.walk) && (0...1).contains(open.sleep)
                    && (0...1).contains(open.transition) && (0...1).contains(open.quiet), "\(tag): unbalanced log \(open), last events \(rig.events.suffix(7).map { "\(Int($0.t - rig.started)) \($0.event)" })")
            if !(0...1).contains(open.motion) || !(0...1).contains(open.walk) || !(0...1).contains(open.sleep) || !(0...1).contains(open.transition) { return covered }
        }
        return covered
    }
}
