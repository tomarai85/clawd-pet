import Testing
import Foundation
import CoreGraphics
import ClawdCore
import ClawdRendering
import ClawdDesktop

// Amendment "multi-touch fallback", D-1: when the worn look has no eligible multi-touch motion (wizard and scientist have none), a triple
// click plays an eligible touch motion as the multi-touch reaction, so the click-ignoring rule, the counters and the TOUCH multi line apply
// to it unchanged, and its MOTION start line carries fallback=touch.

@Suite("Multi-touch fallback", .serialized)
struct MultiTouchFallback {
    private func realCatalog() throws -> PetCatalog {
        PetCatalog(atlasData: try ReadOnlyFile.data(artDirectory.appendingPathComponent("clawd-atlas.json").path))
    }
    private func rig(_ catalog: PetCatalog, look: String, homeX: Double = 576, excluded: Set<String> = [], seed: UInt64 = 1,
                     lookSince: Double = 1_800_000_000) -> SchedulerRig {
        var settings = FeelFixture.calm()
        settings.excluded = excluded
        return SchedulerRig(catalog: catalog, settings: settings, geometry: SchedulerFixture.geometry(homeX: homeX), seed: seed,
                            persisted: SchedulerPersisted(look: look, lookSince: lookSince))
    }
    private func tripleClick(_ rig: SchedulerRig) {
        rig.scheduler.click(); rig.advance(0.3); rig.scheduler.click(); rig.advance(0.3); rig.scheduler.click()
    }
    private func ignored(_ rig: SchedulerRig) -> Int { rig.count { if case .clickIgnored = $0 { return true } else { return false } } }
    private func touchIDs(_ catalog: PetCatalog) -> Set<String> { Set(catalog.motions.filter { $0.uses.contains(.touch) }.map(\.id)) }

    @Test func Click_aTripleClickInAWizardOrScientistLookPlaysATouchReaction() throws {
        let catalog = try realCatalog()
        let touch = touchIDs(catalog)
        let multi = Set(catalog.motions.filter { $0.uses.contains(.multiTouch) }.map(\.id))
        for look in ["wizard", "scientist"] {
            #expect(!catalog.motions.contains { $0.uses.contains(.multiTouch) && catalog.isCompatible($0, with: look) },
                    "\(look) has no multi-touch motion of its own, which is the case this amendment is for")
        }
        // Near the left edge, in the middle and near the right edge of the 1440 pt fixture display, and with the menu closed just before.
        for look in ["wizard", "scientist", "plain"] {
            for homeX in [0.0, 576, 1392] {
                for menuJustClosed in [false, true] {
                    let rig = rig(catalog, look: look, homeX: homeX)
                    let at = "\(look) at x=\(homeX)\(menuJustClosed ? " after the menu" : "")"
                    try #require(rig.scheduler.look == look, "\(at): the look worn")
                    if menuJustClosed { _ = rig.scheduler.menuOpened(); rig.advance(0.2); rig.scheduler.menuClosed() }
                    tripleClick(rig)
                    let playback = try #require(rig.frame.playback, "\(at): a reaction plays")
                    let id = try #require(playback.motionID)
                    #expect(playback.use == "multi-touch" && rig.count { $0 == .multiTouch } == 1, "\(at): played as the multi-touch reaction")
                    if look == "plain", homeX == 576 {
                        #expect(multi.contains(id) && rig.scheduler.fallback(forMotion: id) == nil, "\(at): plain keeps its own multi-touch motion (\(id))")
                    } else if look != "plain" {
                        #expect(touch.contains(id) && rig.scheduler.fallback(forMotion: id) == "touch", "\(at): a touch motion in its place (\(id))")
                    }
                }
            }
        }
    }

    @Test func Click_theFallbackReactionIgnoresClicksExactlyWhileItPlays() throws {
        let rig = rig(try realCatalog(), look: "wizard")
        tripleClick(rig)
        let playback = try #require(rig.frame.playback)
        try #require(playback.use == "multi-touch" && playback.duration > 0.3)
        let end = playback.startedAt + playback.duration
        let touches = rig.scheduler.counters.touches
        rig.advance(0.2); rig.scheduler.click()
        #expect(ignored(rig) == 1 && rig.scheduler.counters.touches == touches, "a click inside the fallback reaction is dropped")
        #expect(rig.frame.playback == playback, "and the reaction goes on unchanged")
        rig.clock.advance(end - rig.now)
        #expect(rig.now == end)
        rig.scheduler.click()
        #expect(ignored(rig) == 1 && rig.scheduler.counters.touches == touches + 1 && rig.frame.playback?.use == "touch",
                "a click at the exact end reacts")
    }

    @Test func Click_noEligibleMotionAtAllStillPlaysNothing() throws {
        let catalog = FeelFixture.catalog(dizzy: false)
        let rig = rig(catalog, look: "plain", excluded: Set(touchIDs(catalog).map { $0.lowercased() }))      // exclusions match lowercased
        tripleClick(rig)
        #expect(rig.count { $0 == .multiTouch } == 1 && rig.frame.playback?.use != "multi-touch", "the spell is counted but nothing plays")
        rig.advance(0.1); rig.scheduler.click()
        #expect(ignored(rig) == 0 && rig.count { $0 == .touch } == 3, "nothing plays, so nothing is ignored")
    }

    /// The case the retired scheduler-feel test held: a catalog with no multi-touch motion at all, touch motions free. The triple click now plays a
    /// touch motion as the reaction, and a click inside it is ignored.
    @Test func Click_aCatalogWithNoMultiTouchMotionFallsBackAndIgnoresClicksInside() throws {
        let catalog = FeelFixture.catalog(dizzy: false)
        #expect(!catalog.motions.contains { $0.uses.contains(.multiTouch) })
        let rig = rig(catalog, look: "plain")
        tripleClick(rig)
        let id = try #require(rig.frame.playback?.motionID)
        #expect(rig.frame.playback?.use == "multi-touch" && touchIDs(catalog).contains(id) && rig.scheduler.fallback(forMotion: id) == "touch")
        let touches = rig.scheduler.counters.touches
        rig.advance(0.1); rig.scheduler.click()
        #expect(ignored(rig) == 1 && rig.scheduler.counters.touches == touches, "the click inside the stand-in reaction is dropped")
    }

    @Test func Click_onlyMultiTouchExcludedFallsBackToTouch() throws {
        let catalog = try realCatalog()
        let multi = Set(catalog.motions.filter { $0.uses.contains(.multiTouch) }.map { $0.id.lowercased() })
        #expect(multi == ["a6-turning", "d5-dizzy"], "the catalog's multi-touch motions: \(multi)")
        let rig = rig(catalog, look: "plain", excluded: multi)
        tripleClick(rig)
        let id = try #require(rig.frame.playback?.motionID)
        #expect(rig.frame.playback?.use == "multi-touch" && touchIDs(catalog).contains(id) && rig.scheduler.fallback(forMotion: id) == "touch")
        rig.advance(0.2); rig.scheduler.click()
        #expect(ignored(rig) == 1, "the stand-in reaction ignores clicks like a multi-touch one")
    }

    @Test func Click_theFallbackSharesTheTouchHistoryAndLogsIt() throws {
        let catalog = try realCatalog()
        // The touch pool's no-repeat history: the fallback pick is never the touch motion the second click just played, and the next single
        // click never repeats the fallback pick. Several seeds, because each pick is random.
        for seed in UInt64(1)...12 {
            let rig = rig(catalog, look: "scientist", seed: seed)
            rig.scheduler.click(); rig.advance(0.3); rig.scheduler.click()
            let second = try #require(rig.frame.playback?.motionID)
            rig.advance(0.3); rig.scheduler.click()
            let playback = try #require(rig.frame.playback)
            let fallback = try #require(playback.motionID)
            #expect(fallback != second, "seed \(seed): the fallback repeated the touch motion just played (\(second))")
            #expect(rig.scheduler.counters.touches == 2, "seed \(seed): the third click counts as a multi-touch, not a touch")
            rig.clock.advance(playback.startedAt + playback.duration - rig.now); rig.scheduler.click()
            #expect(rig.frame.playback?.use == "touch" && rig.frame.playback?.motionID != fallback, "seed \(seed): the next touch repeated \(fallback)")
        }
        // The log through the stage runtime: one TOUCH multi line, and the MOTION start line of the stand-in carries fallback=touch.
        let clock = VirtualClock(now: 1000)
        let timer = FakeScheduler(clock: clock)
        let runtime = try StageRuntime(clock: clock, timer: timer, art: artDirectory, settings: FeelFixture.calm(), geometry: Screens.geometry(),
                                       persisted: SchedulerPersisted(look: "wizard", lookSince: clock.wallNow.timeIntervalSince1970), random: { 0.9 })
        var lines: [String] = []
        runtime.log = { lines.append($0) }
        runtime.hostGeometry = { StageHostGeometry(geometry: Screens.geometry(), pixelScale: 2) }
        runtime.start()
        try #require(runtime.scheduler.look == "wizard")
        func click() { runtime.perform { runtime.scheduler.click() } }
        click(); clock.advance(0.3); click(); clock.advance(0.3); click()
        let id = try #require(runtime.lastRequest?.frame.playback?.motionID)
        #expect(lines.filter { $0 == "TOUCH multi" }.count == 1)
        #expect(lines.last { $0.hasPrefix("MOTION start") } == "MOTION start id=\(id) use=multi-touch fallback=touch", "\(lines.suffix(4))")
        #expect(!lines.contains { $0.hasPrefix("MOTION start") && $0.contains("use=touch") && $0.contains("fallback") }, "plain touches carry no fallback")
        // After the stand-in ends, the next touch and a dictation scene's motion start without the field.
        let playback = try #require(runtime.lastRequest?.frame.playback)
        clock.advance(playback.startedAt + playback.duration - clock.now + 0.05)
        let before = lines.count
        click()
        runtime.perform { runtime.scheduler.sceneChanged(.listening, lease: 1) }
        let starts = lines[before...].filter { $0.hasPrefix("MOTION start") }
        // The random source draws near the end of every pool, so the scene picks one of its motions (the plain pose is the pool's first item).
        #expect(starts.contains { $0.contains("use=touch") } && starts.contains { $0.contains("use=listening") }, "a touch and a scene motion started: \(starts)")
        #expect(!starts.contains { $0.contains("fallback") }, "no later MOTION start line carries fallback: \(starts)")
    }

    @Test func Click_scenesTransitionsAndSleepKeepTheirClickRules() throws {
        let catalog = try realCatalog()
        // A dictation scene: clicks return early, nothing is counted or played.
        let scene = rig(catalog, look: "wizard")
        scene.start()
        tripleClick(scene)
        #expect(scene.count { $0 == .multiTouch } == 0 && scene.count { $0 == .touch } == 0 && scene.frame.playback?.use == "listening")
        // A look transition: the same.
        let transition = rig(catalog, look: "wizard", lookSince: 1_800_000_000 - 5 * 3600)
        transition.advance(0.4)
        try #require(transition.frame.transitionProgress != nil, "a look transition is running")
        transition.scheduler.click(); transition.advance(0.05); transition.scheduler.click(); transition.advance(0.05); transition.scheduler.click()
        #expect(transition.frame.transitionProgress != nil, "the three clicks landed inside the transition")
        #expect(transition.count { $0 == .multiTouch } == 0 && transition.count { $0 == .touch } == 0)
        // Asleep: the first click wakes Clawd and is not counted, so three clicks are no multi-touch.
        let sleep = rig(catalog, look: "wizard")
        sleep.inputIdle = PetScheduler.sleepAfter + 100
        sleep.advance(PetScheduler.sleepAfter + 70)
        try #require(sleep.count { $0 == .sleepStart } == 1, "asleep")
        sleep.inputIdle = 0
        tripleClick(sleep)
        #expect(sleep.count { $0 == .wake } == 1 && sleep.count { $0 == .multiTouch } == 0 && sleep.count { $0 == .touch } == 2)
    }
}
