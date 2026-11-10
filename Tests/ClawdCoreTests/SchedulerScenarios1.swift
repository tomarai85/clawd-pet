import Foundation
import CoreGraphics
@testable import ClawdCore

/// What a scenario found wrong. Empty means the rule held. The negative controls run the same scenario with one rule switched off
/// and require a non-empty list.
struct Violations {
    private(set) var list: [String] = []
    /// A negative control needs one violation, not all of them: a scenario that sees it can stop.
    let quick: Bool
    init(quick: Bool = false) { self.quick = quick }
    var done: Bool { quick && !list.isEmpty }
    mutating func check(_ holds: Bool, _ message: @autoclosure () -> String) { if !holds { list.append(message()) } }
    var isEmpty: Bool { list.isEmpty }
    var summary: String { list.prefix(6).joined(separator: " | ") + (list.count > 6 ? " (+\(list.count - 6) more)" : "") }
}

private func lively(_ edit: (inout SchedulerSettings) -> Void = { _ in }) -> SchedulerSettings {
    var s = SchedulerSettings(); s.motion = .lively; edit(&s); return s
}
func isMotionStart(_ e: SchedulerEvent) -> Bool { if case .motionStart = e { return true } else { return false } }
func isWalkStart(_ e: SchedulerEvent) -> Bool { if case .walkStart = e { return true } else { return false } }
func isLookChange(_ e: SchedulerEvent) -> Bool { if case .lookChange = e { return true } else { return false } }

enum SchedulerScenarios {
    // MARK: S-1 nothing moves or renders while a quiet condition holds

    static func s1(_ guards: SchedulerGuards, quick: Bool = false) -> Violations {
        var v = Violations(quick: quick)
        for reason in QuietReason.allCases {
            let rig = SchedulerRig(settings: lively(), guards: guards)
            let playing = rig.run(upTo: 900) { rig.frame.playback?.use == "idle" || rig.frame.playback?.use == "walk" }
            v.check(playing, "\(reason): a motion was playing when the quiet condition came")
            rig.scheduler.setQuiet(reason, active: true)
            let events = rig.events.count, renders = rig.renders
            v.check(rig.frame.visibility == .quiet(reason), "\(reason): frame is not quiet")
            v.check(rig.frame.playback == nil && rig.frame.walkOffset == 0, "\(reason): something still moves in the frame")
            v.check(rig.scheduler.ownedTimers == 0, "\(reason): \(rig.scheduler.ownedTimers) timers owned at once")
            // A day with a dictation, clicks, a drag and pointer moves arriving meanwhile.
            for hour in 0..<24 {
                rig.advance(3600)
                if hour == 3 { rig.start(); rig.advance(1); rig.complete(); rig.advance(1.5); rig.ack() }
                if hour == 5 { rig.scheduler.click(); rig.scheduler.pointerMoved(CGPoint(x: 600, y: 120)) }
                if hour == 7 { rig.scheduler.dragStarted(); rig.scheduler.dragEnded() }
                v.check(rig.scheduler.ownedTimers == 0, "\(reason): \(rig.scheduler.ownedTimers) timers owned at hour \(hour)")
            }
            let during = rig.eventsSince(events).filter { $0.event != .quietOff }
            v.check(during.isEmpty, "\(reason): events during the quiet condition: \(during.prefix(3))")
            v.check(rig.renders == renders, "\(reason): \(rig.renders - renders) renders during the quiet condition")
            rig.scheduler.setQuiet(reason, active: false)
            v.check(rig.frame.visibility == .visible, "\(reason): not visible again after the condition ends")
            v.check(rig.scheduler.ownedTimers == 1, "\(reason): \(rig.scheduler.ownedTimers) timers owned after the condition")
            v.check(rig.count { $0 == .quietOff } == 1, "\(reason): QUIET off not logged once")
        }
        if v.done { return v }
        // SLEEP: one timer (the input idle re-read every 60 s) and nothing else.
        do {
            let rig = SchedulerRig(settings: lively(), guards: guards, refresh: false)
            rig.inputIdle = 700
            rig.scheduler.refresh()
            v.check(rig.frame.asleep, "asleep: Clawd did not doze off with 700 s of input idle time")
            v.check(rig.scheduler.ownedTimers == 1, "asleep: \(rig.scheduler.ownedTimers) timers owned")
            let events = rig.events.count, renders = rig.renders
            for _ in 0..<60 {
                rig.advance(60)
                v.check(rig.scheduler.ownedTimers == 1, "asleep: \(rig.scheduler.ownedTimers) timers owned during the sleep")
            }
            v.check(rig.events.count == events && rig.renders == renders, "asleep: something moved or rendered while asleep")
            v.check(rig.timer.armCount - 1 <= 60 + 5, "asleep: more than one input idle read a minute (\(rig.timer.armCount) arms in an hour)")
        }
        if v.done { return v }
        // Hidden: one timer for the end of a timed hide, none for a hide until `show`.
        do {
            let rig = SchedulerRig(settings: lively(), guards: guards)
            rig.advance(100)
            var hidden = rig.scheduler.settings; hidden.hiddenUntil = rig.wall + 600
            rig.scheduler.update(settings: hidden)
            v.check(rig.frame.visibility == .hidden, "hidden: frame is not hidden")
            v.check(rig.scheduler.ownedTimers == 1, "hidden with an end time: \(rig.scheduler.ownedTimers) timers owned")
            let events = rig.events.count, renders = rig.renders
            rig.advance(590)
            v.check(rig.eventsSince(events).filter { $0.event != .hidden }.isEmpty, "hidden: events while hidden: \(rig.eventsSince(events).prefix(3))")
            v.check(rig.renders == renders, "hidden: renders while hidden")
            rig.advance(20)
            v.check(rig.frame.visibility == .visible, "hidden: Clawd did not come back at the end of the hide")
            v.check(rig.count { $0 == .shown } == 1, "hidden: SHOWN not logged once")
            var forever = rig.scheduler.settings; forever.hiddenUntil = -1
            rig.scheduler.update(settings: forever)
            v.check(rig.scheduler.ownedTimers == 0, "hidden until show: \(rig.scheduler.ownedTimers) timers owned")
            let later = rig.events.count
            rig.advance(86_400)
            v.check(rig.events.count == later, "hidden until show: events during a day")
            var shown = rig.scheduler.settings; shown.hiddenUntil = 0
            rig.scheduler.update(settings: shown)
            v.check(rig.frame.visibility == .visible && rig.scheduler.ownedTimers == 1, "show: not visible with one timer")
        }
        if v.done { return v }
        return v
    }

    // MARK: S-2 a lease opening cuts everything in the same tick; a running transition finishes first

    static func s2(_ guards: SchedulerGuards, quick: Bool = false) -> Violations {
        var v = Violations(quick: quick)
        func opened(_ rig: SchedulerRig, _ what: String) {
            let f = rig.frame
            v.check(f.scene == .listening, "\(what): scene is \(f.scene)")
            v.check(f.playback?.use == "listening", "\(what): playing \(String(describing: f.playback?.use)) after the lease opened")
            v.check(f.bubble != nil, "\(what): no bubble in the same tick")
        }
        if v.done { return v }
        // An idle motion, a walk, an entrance and a touch reaction, each cut by the lease.
        do {
            let rig = SchedulerRig(settings: lively(), guards: guards)
            v.check(rig.run(upTo: 900) { rig.frame.playback?.use == "idle" }, "idle: no motion playing")
            rig.start(); opened(rig, "idle motion")
            v.check(rig.events.last(where: { if case .motionEnd = $0.event { return true } else { return false } })?.t == rig.now,
                    "idle motion: it did not end in the tick of the lease")
        }
        if v.done { return v }
        do {
            let rig = SchedulerRig(settings: lively(), guards: guards)
            v.check(rig.run(upTo: 1800) { rig.frame.playback?.use == "walk" }, "walk: none started")
            rig.advance(1.5)
            let offset = rig.frame.walkOffset
            v.check(abs(offset) > 1, "walk: Clawd had not moved (\(offset))")
            rig.start(); opened(rig, "walk")
            v.check(abs(rig.frame.walkOffset - offset) < 1e-9, "walk: Clawd moved after the lease opened (\(offset) -> \(rig.frame.walkOffset))")
        }
        if v.done { return v }
        do {
            let rig = SchedulerRig(settings: lively(), guards: guards)
            rig.scheduler.appear()
            v.check(rig.frame.playback?.use == "entrance", "entrance: not playing")
            rig.start(); opened(rig, "entrance")
        }
        if v.done { return v }
        do {
            let rig = SchedulerRig(settings: lively(), guards: guards)
            rig.scheduler.click()
            v.check(rig.frame.playback?.use == "touch", "touch: no reaction")
            rig.start(); opened(rig, "touch reaction")
        }
        if v.done { return v }
        // A running look transition finishes first: the bubble shows at once, the scene motion starts at its end, at most 2 s later.
        do {
            var settings = lively(); settings.motion = .off
            let rig = SchedulerRig(settings: settings, guards: guards,
                                   persisted: SchedulerPersisted(look: "plain", lookSince: 1_800_000_000 - 5 * 3600))
            rig.advance(0.4)
            let tf = rig.frame
            v.check(tf.transitionProgress != nil, "transition: none running at 0.4 s")
            let leased = rig.now
            rig.start()
            let f = rig.frame
            v.check(f.bubble != nil, "transition: no bubble at once")
            if case .transition? = f.playback?.source {} else { v.check(false, "transition: not shown any more after the lease: \(String(describing: f.playback?.source))") }
            rig.advance(2.0)
            let after = rig.frame
            v.check(after.playback?.use == "listening", "transition: scene motion not playing 2 s later")
            let started = after.playback?.startedAt ?? .infinity
            v.check(started - leased <= 2.0 + 1e-9, "transition: the scene motion started \(started - leased) s after the lease")
            v.check(started - leased >= PetScheduler.transitionDuration - 0.5 - 1e-9, "transition: the scene motion started before the transition ended (\(started - leased) s)")
            v.check(PetScheduler.transitionDuration <= 2.0, "transition: lasts \(PetScheduler.transitionDuration) s, more than 2.0 s")
            v.check(rig.count { if case .lookChange = $0 { return true } else { return false } } == 1, "transition: the look change did not complete")
            v.check(rig.count { $0 == .lookTransitionEnd } == 1, "transition: it did not run to its end")
        }
        if v.done { return v }
        return v
    }

    // MARK: S-3 no immediate repeats

    static func s3(_ guards: SchedulerGuards, quick: Bool = false) -> Violations {
        var v = Violations(quick: quick)
        // Motions: never the one just played; with at least 5 eligible, none of the last 3. The look is pinned so the pool is fixed.
        do {
            let rig = SchedulerRig(settings: lively { $0.lookPin = "plain"; $0.walk = false }, guards: guards)
            rig.advance(86_400)
            let ids = rig.ids("idle", "signature:plain")
            v.check(ids.count > 1000, "idle: only \(ids.count) motions in a day")
            for i in 1..<ids.count where ids[i] == ids[i - 1] { v.check(false, "idle: \(ids[i]) twice in a row at \(i)"); break }
            // The last-3 rule of the earlier picker is replaced by the family bag (variety D-2, tested by IdleBag_): inside one cycle no family
            // repeats, and across the boundary the family played last is not drawn first.
        }
        if v.done { return v }
        // Few eligible: two items alternate.
        do {
            let keep: Set<String> = ["a4-waving", "a9-dancing"]
            let drop = SchedulerFixture.catalog().motions.filter { $0.uses.contains(.idle) && !keep.contains($0.id.lowercased()) }.map { $0.id.lowercased() }
            let rig = SchedulerRig(settings: lively { $0.lookPin = "plain"; $0.walk = false; $0.excluded = Set(drop) }, guards: guards)
            rig.advance(6 * 3600)
            let ids = rig.ids("idle")
            v.check(ids.count > 100, "alternating: only \(ids.count) motions")
            for i in 1..<ids.count where ids[i] == ids[i - 1] { v.check(false, "two eligible items: \(ids[i]) twice in a row at \(i)"); break }
        }
        if v.done { return v }
        // Scene pools and the touch pool: never the one the pool played last.
        do {
            let rig = SchedulerRig(settings: lively { $0.motion = .off; $0.lookPin = "plain" }, guards: guards)
            var picks: [String: [String]] = [:]
            func record(_ key: String) {
                guard let p = rig.frame.playback else { return }
                let name: String
                switch p.source { case .pose(let n): name = "pose:" + n; case .motion(let id): name = id; default: name = "?" }
                picks[key, default: []].append(name)
            }
            for i in 0..<300 {
                rig.start(i + 1); record("listening"); rig.advance(1.2)
                rig.complete(i + 1); record("thinking"); rig.advance(1.0)
                rig.ack(); record("sent"); rig.advance(3)
            }
            for (key, list) in picks where list.count > 100 {
                v.check(Set(list).count >= 2, "\(key) pool offered one item only")
                for i in 1..<list.count where list[i] == list[i - 1] { v.check(false, "\(key): \(list[i]) twice in a row at \(i)"); break }
            }
            var touches: [String] = []
            for _ in 0..<200 {
                rig.advance(3)
                rig.scheduler.click()
                if let id = rig.frame.playback?.motionID { touches.append(id) }
            }
            v.check(touches.count >= 150, "touch: only \(touches.count) reactions")
            for i in 1..<touches.count where touches[i] == touches[i - 1] { v.check(false, "touch: \(touches[i]) twice in a row"); break }
        }
        if v.done { return v }
        // Looks: never the one worn; within a cycle of the rotation (the shuffle bag, amendment D-2) none worn twice by an automatic change.
        do {
            let rig = SchedulerRig(settings: lively { $0.motion = .off; $0.lookEveryHours = 2 }, guards: guards, eventLimit: quick ? 20_000 : 400_000)
            rig.advance(14 * 86_400)
            let changes = rig.events.compactMap { e -> (String, String)? in if case .lookChange(let f, let t) = e.event { return (f, t) } else { return nil } }
            v.check(changes.count > 150, "looks: only \(changes.count) changes in 14 days")
            let rotation = Set(rig.scheduler.rotationLooks.map(\.id))
            var worn = ["plain"], cycle: Set<String> = ["plain"]
            for (from, to) in changes {
                v.check(from == worn.last, "looks: change from \(from) but \(worn.last ?? "-") was worn")
                if to == from { v.check(false, "looks: \(to) worn twice in a row"); break }
                if cycle.contains(to) { v.check(false, "looks: \(to) is worn twice within one cycle of the rotation"); break }
                worn.append(to); cycle.insert(to)
                if rotation.isSubset(of: cycle) { cycle = [to] }
            }
            v.check(Set(worn).count >= 6, "looks: only \(Set(worn).count) different looks worn")
        }
        if v.done { return v }
        // Bubble styles: never the previous dictation's style.
        do {
            let rig = SchedulerRig(settings: SchedulerSettings(), guards: guards)
            var styles: [Int] = []
            for i in 0..<3000 {
                rig.scheduler.sceneChanged(.listening, lease: i + 1)
                if let s = rig.frame.bubble?.style { styles.append(s) }
                rig.scheduler.sceneChanged(.idle, lease: nil)
            }
            v.check(styles.count == 3000, "bubble: \(styles.count) styles")
            for i in 1..<styles.count where styles[i] == styles[i - 1] { v.check(false, "bubble: style \(styles[i]) twice in a row at \(i)"); break }
        }
        if v.done { return v }
        return v
    }

    // MARK: S-4 look changes keep their distance

    /// Seven days of lively idle life with dictations, clicks, drags, quiet conditions, hides and sleep thrown in.
    static func s4(_ guards: SchedulerGuards, seed: UInt64 = 4, quick: Bool = false) -> Violations {
        var v = Violations(quick: quick)
        let rig = SchedulerRig(settings: lively { $0.lookEveryHours = 2 }, seed: seed, guards: guards, refresh: false, eventLimit: quick ? 100_000 : 400_000)
        rig.inputIdle = nil
        rig.scheduler.refresh()
        let driver = SeededRandom(seed: seed &* 7919)
        var quiet: [(TimeInterval, TimeInterval)] = []
        var hides: [(TimeInterval, TimeInterval)] = []
        var drags: [(TimeInterval, TimeInterval)] = []
        var away: [(TimeInterval, TimeInterval)] = []
        let end = rig.now + 7 * 86_400
        while rig.now < end {
            rig.advance(20 + driver.unit() * 1500)
            let pick = driver.unit()
            if pick < 0.40 { rig.touchInput(); rig.dictate(listening: 1 + driver.unit() * 20) }
            else if pick < 0.55 { rig.touchInput(); rig.scheduler.click() }
            else if pick < 0.62 {
                rig.touchInput(); rig.scheduler.dragStarted(); let s = rig.now; rig.advance(1 + driver.unit() * 3); rig.scheduler.dragEnded(); drags.append((s, rig.now))
            } else if pick < 0.74 {
                let s = rig.now
                rig.scheduler.setQuiet(.displayAsleep, active: true); rig.advance(300 + driver.unit() * 3300)
                rig.scheduler.setQuiet(.displayAsleep, active: false); quiet.append((s, rig.now))
            } else if pick < 0.80 {
                let s = rig.now
                let length = 600 + driver.unit() * 1200
                var h = rig.scheduler.settings; h.hiddenUntil = rig.wall + length
                rig.scheduler.update(settings: h); rig.advance(length + 5)
                var back = rig.scheduler.settings; back.hiddenUntil = 0
                rig.scheduler.update(settings: back); hides.append((s, rig.now))
            } else if pick < 0.90 {
                // the user walks away: no input for 25-45 minutes. Clawd dozes off 10 minutes after their last input.
                rig.advance(25 * 60 + 20 * 60 * driver.unit())
                away.append((rig.lastInput + 600 + 0.001, rig.now))
                rig.touchInput()
                rig.advance(70)
            } else {
                rig.touchInput(); rig.scheduler.pointerMoved(CGPoint(x: 300 + driver.unit() * 600, y: 80 + driver.unit() * 100))
            }
            if rig.runaway { break }
        }
        if v.done { return v }
        let log = SpanLog(rig.events, endOfLog: rig.now)
        v.check(log.lookTransitions.count > 50, "only \(log.lookTransitions.count) look changes in 7 days")
        v.check(log.spans.filter(\.selfStarted).count > 1000, "only \(log.spans.filter(\.selfStarted).count) self-started motions")
        let busy: [(String, [(TimeInterval, TimeInterval)])] = [
            ("scene", rig.sceneSpans.map { ($0.start, $0.end ?? rig.now) }),
            ("touch", log.spans.filter { !$0.selfStarted && ($0.kind == "touch" || $0.kind == "multi-touch" || $0.kind == "drop") }.map { ($0.start, $0.end) }),
            ("drag", drags), ("quiet", quiet), ("hide", hides), ("sleep", log.sleeps.map { ($0.start, $0.end) }),
            ("input idle (user away, Clawd asleep)", away),
        ]
        for tr in log.lookTransitions {
            if v.done { break }
            for span in log.spans where span.selfStarted {
                let before = tr.start - span.end, after = span.start - tr.end
                if !(before >= 30 - 1e-6 || after >= 30 - 1e-6) {
                    v.check(false, "look change at \(Int(tr.start - rig.started)) s is \(Int(max(before, after))) s from a \(span.kind) motion (\(Int(span.start - rig.started))-\(Int(span.end - rig.started)))")
                    break
                }
            }
            for (name, spans) in busy {
                if let hit = spans.first(where: { $0.0 <= tr.start + 1e-9 && tr.start < $0.1 - 1e-9 }) {
                    v.check(false, "look change at \(Int(tr.start - rig.started)) s started during a \(name) (\(Int(hit.0 - rig.started))-\(Int(hit.1 - rig.started)))")
                    break
                }
            }
        }
        if v.done { return v }
        v.check(!rig.runaway, "the scheduler ran away (stalls \(rig.scheduler.stallCount), events \(rig.events.count))")
        return v
    }
}
