import Foundation
import CoreGraphics
import ClawdCore

private func lively(_ edit: (inout SchedulerSettings) -> Void = { _ in }) -> SchedulerSettings {
    var s = SchedulerSettings(); s.motion = .lively; edit(&s); return s
}
private func calm(_ edit: (inout SchedulerSettings) -> Void = { _ in }) -> SchedulerSettings {
    var s = SchedulerSettings(); s.motion = .off; edit(&s); return s
}

extension SchedulerScenarios {
    // MARK: S-9 bubble style per lease

    static func s9(_ guards: SchedulerGuards, quick: Bool = false) -> Violations {
        var v = Violations(quick: quick)
        // Constant within a lease, a new one for each lease.
        do {
            let rig = SchedulerRig(settings: calm(), seed: 9, guards: guards)
            var previous: Int?
            for lease in 1...200 {
                rig.start(lease)
                var styles = [rig.frame.bubble?.style]
                rig.advance(1.5); styles.append(rig.frame.bubble?.style)
                rig.complete(lease); styles.append(rig.frame.bubble?.style)
                rig.advance(1.0); rig.ack(); styles.append(rig.frame.bubble?.style)
                rig.advance(1.0); styles.append(rig.frame.bubble?.style)
                rig.advance(3.0)
                v.check(styles[0] != nil && Set(styles).count == 1, "lease \(lease): styles within the lease \(styles)")
                if let first = styles[0] {
                    v.check(first != previous, "lease \(lease): style \(first) twice in a row")
                    previous = first
                }
            }
            v.check(rig.count { if case .bubbleStyle = $0 { return true } else { return false } } == 200, "one style is drawn per lease")
        }
        if v.done { return v }
        // A listening scene resumed by the release hint is the same lease; a new lease during SENT is a new one.
        do {
            let rig = SchedulerRig(settings: calm(), seed: 10, guards: guards)
            rig.start(1)
            let first = rig.frame.bubble?.style
            rig.advance(1)
            rig.machine.releaseHint()
            v.check(rig.frame.scene == .thinking, "hint: scene \(rig.frame.scene)")
            rig.machine.deviceChanged(running: true)
            rig.advance(6)
            v.check(rig.frame.scene == .listening, "hint: scene \(rig.frame.scene) after the resume")
            v.check(rig.frame.bubble?.style == first, "hint: the style changed within the lease (\(String(describing: first)) -> \(String(describing: rig.frame.bubble?.style)))")
        }
        if v.done { return v }
        // Stationary shares over 100,000 seeded leases (spec 4.2, amendment R-BUBBLES): the five that weigh 3 (6, 10, 13, 14 and 15) get 3 x 22 / 570 each, the
        // other ten 24 / 570.
        do {
            let rig = SchedulerRig(settings: calm(), seed: 99, guards: guards)
            var counts = [Int: Int]()
            let leases = quick ? 12_000 : 100_000
            for i in 0..<leases {
                rig.scheduler.sceneChanged(.listening, lease: i + 1)
                if let s = rig.frame.bubble?.style { counts[s, default: 0] += 1 }
                rig.scheduler.sceneChanged(.idle, lease: nil)
            }
            for style in 1...15 {
                let expected = [6, 10, 13, 14, 15].contains(style) ? 66.0 / 570 : 24.0 / 570
                let share = Double(counts[style] ?? 0) / Double(leases)
                v.check(abs(share - expected) <= 0.01, "style \(style): share \(share) differs from \(expected) by more than 1 point")
            }
        }
        if v.done { return v }
        // Two enabled styles {1, 6}: 50% each and the draw alternates.
        do {
            var settings = calm(); settings.bubbleExcluded = Set(2...15).subtracting([6])
            let rig = SchedulerRig(settings: settings, seed: 5, guards: guards)
            var seen: [Int] = []
            for i in 0..<10_000 {
                rig.scheduler.sceneChanged(.listening, lease: i + 1)
                if let s = rig.frame.bubble?.style { seen.append(s) }
                rig.scheduler.sceneChanged(.idle, lease: nil)
            }
            v.check(Set(seen) == [1, 6], "two styles: drew \(Set(seen).sorted())")
            v.check(abs(Double(seen.filter { $0 == 1 }.count) / Double(seen.count) - 0.5) <= 0.01, "two styles: not 50% each")
            for i in 1..<seen.count where seen[i] == seen[i - 1] { v.check(false, "two styles: did not alternate at \(i)"); break }
        }
        if v.done { return v }
        // One enabled style: always that style.
        do {
            var settings = calm(); settings.bubbleExcluded = Set(1...15).subtracting([7])
            let rig = SchedulerRig(settings: settings, seed: 6, guards: guards)
            for i in 0..<50 {
                rig.scheduler.sceneChanged(.listening, lease: i + 1)
                v.check(rig.frame.bubble?.style == 7, "one style: drew \(String(describing: rig.frame.bubble?.style))")
                rig.scheduler.sceneChanged(.idle, lease: nil)
            }
        }
        if v.done { return v }
        return v
    }

    // MARK: S-10 scene pools are overhead-clear; SENT motions last at most 2.0 s

    static func s10(_ guards: SchedulerGuards, quick: Bool = false) -> Violations {
        var v = Violations(quick: quick)
        let catalog = SchedulerFixture.catalog()
        var played: [String: Set<String>] = [:]
        func inspect(_ scene: String, _ rig: SchedulerRig) {
            guard let id = rig.frame.playback?.motionID, let m = catalog.motion(id: id) else { return }
            played[scene, default: []].insert(id)
            v.check(m.overheadClear, "\(scene): \(id) is not overhead-clear")
            if scene == "sent" { v.check(m.duration <= 2.0, "sent: \(id) lasts \(m.duration) s") }
        }
        if v.done { return v }
        for look in SchedulerFixture.looks {
            let rig = SchedulerRig(catalog: catalog, settings: calm { $0.lookPin = look }, seed: 10, guards: guards)
            rig.advance(10)
            v.check(rig.frame.look == look, "\(look): not worn")
            for i in 0..<120 {
                rig.start(i + 1); inspect("listening", rig); rig.advance(1.2)
                rig.complete(i + 1); inspect("thinking", rig); rig.advance(1.0)
                rig.ack(); inspect("sent", rig); rig.advance(2.1)
                rig.start(1000 + i); rig.advance(0.5); rig.cancel(1000 + i); inspect("interrupted", rig); rig.advance(1.6)
                rig.start(2000 + i); rig.advance(0.5); rig.fail(); inspect("error", rig); rig.advance(1.6)
            }
        }
        if v.done { return v }
        v.check(!(played["listening"] ?? []).isEmpty && !(played["thinking"] ?? []).isEmpty && !(played["sent"] ?? []).isEmpty,
                "the pools offered no catalog motion at all: \(played)")
        return v
    }

    // MARK: S-11 Reduce Motion

    static func s11(_ guards: SchedulerGuards, quick: Bool = false) -> Violations {
        var v = Violations(quick: quick)
        func idleLife(_ rig: SchedulerRig) -> Int {
            rig.count { e in
                switch e {
                case .motionStart(_, let use): return use == "idle" || use.hasPrefix("signature") || use == "entrance"
                case .walkStart, .lookTransition: return true
                default: return false
                }
            }
        }
        if v.done { return v }
        do {
            let rig = SchedulerRig(settings: lively { $0.lookEveryHours = 2 }, seed: 11, guards: guards, refresh: false)
            rig.scheduler.setReduceMotion(true)
            rig.scheduler.refresh()
            rig.scheduler.appear()
            v.check(rig.frame.playback == nil, "entrance under Reduce Motion: \(String(describing: rig.frame.playback?.source))")
            rig.advance(2 * 86_400)
            v.check(idleLife(rig) == 0, "Reduce Motion: \(idleLife(rig)) idle motions, walks, entrances or transitions in two days")
            v.check(rig.count(where: isLookChange) >= 20, "Reduce Motion: looks changed only \(rig.count(where: isLookChange)) times (they change as a cut)")
            // Dictation scenes use v1's own poses only.
            for i in 0..<60 {
                rig.start(i + 1)
                if case .pose? = rig.frame.playback?.source {} else { v.check(false, "scene under Reduce Motion plays \(String(describing: rig.frame.playback?.source))") }
                rig.advance(1.2); rig.complete(i + 1); rig.advance(1.0); rig.ack(); rig.advance(2.1)
            }
            rig.scheduler.appear()
            v.check(rig.frame.playback == nil, "appear under Reduce Motion")
        }
        if v.done { return v }
        // Switched on in the middle of a motion, a walk and a transition.
        do {
            let rig = SchedulerRig(settings: lively(), seed: 12, guards: guards)
            v.check(rig.run(upTo: 900) { rig.frame.playback?.use == "idle" }, "no idle motion")
            rig.scheduler.setReduceMotion(true)
            v.check(rig.frame.playback == nil, "idle motion goes on after Reduce Motion came on")
            let n = rig.events.count
            rig.advance(86_400)
            v.check(!rig.eventsSince(n).contains { isMotionStart($0.event) || isWalkStart($0.event) }, "idle life after Reduce Motion came on")
        }
        if v.done { return v }
        do {
            let rig = SchedulerRig(settings: lively(), seed: 13, guards: guards)
            v.check(rig.run(upTo: 1800) { rig.frame.playback?.use == "walk" }, "no walk")
            rig.advance(1.5)
            v.check(abs(rig.frame.walkOffset) > 1, "the walk had not started")
            rig.scheduler.setReduceMotion(true)
            v.check(rig.frame.playback == nil && rig.frame.walkOffset == 0, "the walk goes on after Reduce Motion came on")
        }
        if v.done { return v }
        do {
            let rig = SchedulerRig(settings: calm(), seed: 14, guards: guards,
                                   persisted: SchedulerPersisted(look: "plain", lookSince: 1_800_000_000 - 5 * 3600))
            rig.advance(0.4)
            v.check(rig.frame.transitionProgress != nil, "no transition running")
            rig.scheduler.setReduceMotion(true)
            v.check(rig.frame.transitionProgress == nil && rig.frame.playback == nil, "the transition goes on after Reduce Motion came on")
            v.check(rig.count(where: isLookChange) == 1, "the look did not change as a cut")
        }
        if v.done { return v }
        return v
    }

    // MARK: S-12 settings changed in the middle of things

    static func s12(_ guards: SchedulerGuards, quick: Bool = false) -> Violations {
        var v = Violations(quick: quick)
        // Exclude the playing item.
        do {
            let rig = SchedulerRig(settings: lively { $0.lookPin = "plain" }, seed: 21, guards: guards)
            v.check(rig.run(upTo: 900) { rig.frame.playback?.use == "idle" }, "exclude: no motion")
            let id = rig.frame.playback?.motionID ?? ""
            var s = rig.scheduler.settings; s.excluded.insert(id.lowercased())
            rig.scheduler.update(settings: s)
            v.check(rig.frame.playback?.motionID != id, "exclude: \(id) still plays at the next frame")
            let n = rig.events.count
            rig.advance(6 * 3600)
            v.check(!rig.eventsSince(n).contains { if case .motionStart(let x, _) = $0.event { return x == id } else { return false } }, "exclude: \(id) played again")
        }
        if v.done { return v }
        // motion off in the middle of a motion.
        do {
            let rig = SchedulerRig(settings: lively(), seed: 22, guards: guards)
            v.check(rig.run(upTo: 900) { rig.frame.playback?.use == "idle" }, "motion off: no motion")
            var s = rig.scheduler.settings; s.motion = .off
            rig.scheduler.update(settings: s)
            v.check(rig.frame.playback == nil, "motion off: the motion plays at the next frame")
            let n = rig.events.count
            rig.advance(86_400)
            v.check(!rig.eventsSince(n).contains { isMotionStart($0.event) || isWalkStart($0.event) }, "motion off: idle life went on")
        }
        if v.done { return v }
        // walk off in the middle of a walk: Clawd goes home, no new walk.
        do {
            let rig = SchedulerRig(settings: lively { $0.lookPin = "plain" }, seed: 23, guards: guards)
            v.check(rig.run(upTo: 1800) { rig.frame.playback?.use == "walk" }, "walk off: no walk")
            rig.advance(2.0)
            let away = rig.frame.walkOffset
            let outward = rig.frame.playback?.mirrored
            var s = rig.scheduler.settings; s.walk = false
            rig.scheduler.update(settings: s)
            v.check(rig.count { $0 == .walkDisabled } == 1, "walk off: WALK disabled not logged")
            v.check(abs(rig.frame.walkOffset - away) < 1e-9, "walk off: Clawd jumped")
            v.check(rig.frame.playback?.use == "walk" && rig.frame.playback?.mirrored == !(outward ?? true), "walk off: Clawd is not walking back (\(String(describing: rig.frame.playback?.use)))")
            rig.advance(0.5)
            v.check(abs(rig.frame.walkOffset) < abs(away) - 5, "walk off: Clawd did not move home (\(away) -> \(rig.frame.walkOffset))")
            let before = rig.events.count
            v.check(rig.run(upTo: 60) { rig.eventsSince(before).contains { if case .walkEnd = $0.event { return true } else { return false } } }, "walk off: never home")
            v.check(abs(rig.frame.walkOffset) < 1e-6, "walk off: not home")
            let n = rig.events.count
            rig.advance(6 * 3600)
            v.check(!rig.eventsSince(n).contains { isWalkStart($0.event) }, "walk off: a new walk started")
            var on = rig.scheduler.settings; on.walk = true
            rig.scheduler.update(settings: on)
            rig.advance(3 * 3600)
            v.check(rig.eventsSince(n).contains { isWalkStart($0.event) }, "walk on: no walk in three hours of lively idle life")
        }
        if v.done { return v }
        // hide in the middle of a motion.
        do {
            let rig = SchedulerRig(settings: lively(), seed: 24, guards: guards)
            v.check(rig.run(upTo: 900) { rig.frame.playback?.use == "idle" }, "hide: no motion")
            var s = rig.scheduler.settings; s.hiddenUntil = rig.wall + 300
            rig.scheduler.update(settings: s)
            v.check(rig.frame.visibility == .hidden && rig.frame.playback == nil, "hide: still visible at the next frame")
            let n = rig.events.count
            rig.advance(290)
            v.check(!rig.eventsSince(n).contains { isMotionStart($0.event) || isWalkStart($0.event) }, "hide: motion while hidden")
        }
        if v.done { return v }
        // bubble off in the middle of a dictation, then on again.
        do {
            let rig = SchedulerRig(settings: calm(), seed: 25, guards: guards)
            rig.start()
            v.check(rig.frame.bubble != nil, "bubble: none at the start")
            var off = rig.scheduler.settings; off.bubble = false
            rig.scheduler.update(settings: off)
            v.check(rig.frame.bubble == nil, "bubble off: still shown at the next frame")
            rig.advance(1.5); rig.complete(); rig.advance(1.0)
            v.check(rig.frame.bubble == nil, "bubble off: shown later in the dictation")
            var on = rig.scheduler.settings; on.bubble = true
            rig.scheduler.update(settings: on)
            v.check(rig.frame.bubble != nil, "bubble on: not shown again")
        }
        if v.done { return v }
        // look pin: the pinned look comes within 60 s at an allowed moment, rotation stops, release restarts the clock.
        do {
            let rig = SchedulerRig(settings: lively { $0.lookEveryHours = 2 }, seed: 26, guards: guards)
            rig.advance(3600)
            let pinnedAt = rig.now
            var pin = rig.scheduler.settings; pin.lookPin = "coffee"
            rig.scheduler.update(settings: pin)
            rig.advance(61)
            let changes = rig.events.filter { isLookChange($0.event) }
            if let last = changes.last, case .lookChange(_, let to) = last.event, last.t >= pinnedAt {
                v.check(to == "coffee", "pin: changed to \(to)")
                v.check(last.t - pinnedAt <= 61, "pin: took \(last.t - pinnedAt) s")
            } else { v.check(rig.frame.look == "coffee", "pin: coffee not worn 61 s after the pin (\(rig.frame.look))") }
            let n = rig.events.count
            rig.advance(24 * 3600)
            v.check(!rig.eventsSince(n).contains { isLookChange($0.event) }, "pin: rotation went on")
            var free = rig.scheduler.settings; free.lookPin = nil
            rig.scheduler.update(settings: free)
            let released = rig.now
            // The look is in rotation again: the interval starts now and is the setting times the factors of the look (variety D-4; coffee
            // offers few families, so it is shorter than two hours).
            let span = (rig.scheduler.persisted.lookDueAt ?? 0) - rig.wall
            v.check(span > 0 && span <= 2 * 3600 * 1.25, "pin released: the interval is \(span) s")
            rig.advance(max(0, span - 60))
            v.check(!rig.events.contains { isLookChange($0.event) && $0.t > released }, "pin released: a change before its due time")
            rig.advance(10 * 60)
            v.check(rig.events.contains { isLookChange($0.event) && $0.t > released }, "pin released: no change after its due time")
        }
        if v.done { return v }
        return v
    }

    // MARK: S-13 bubble timing

    static func s13(_ guards: SchedulerGuards, quick: Bool = false) -> Violations {
        var v = Violations(quick: quick)
        func bubble(_ rig: SchedulerRig) -> Bool { rig.frame.bubble != nil }
        // Normal dictation: from the first scene until 2.0 s after the last scene starts.
        do {
            let rig = SchedulerRig(settings: calm(), seed: 31, guards: guards)
            v.check(!bubble(rig), "idle: bubble before the dictation")
            rig.start(); v.check(bubble(rig), "listening: no bubble")
            rig.advance(1.5); v.check(bubble(rig), "listening 1.5 s: no bubble")
            rig.complete(); v.check(bubble(rig), "thinking: no bubble")
            rig.advance(1.0); rig.ack()
            let sent = rig.now
            v.check(rig.frame.scene == .sent && bubble(rig), "sent: no bubble")
            while rig.now < sent + 2.5 {
                rig.advance(0.05)
                let age = rig.now - sent
                if age < 1.99 { v.check(bubble(rig), "sent +\(age): bubble gone early") }
                if age > 2.0 + 1e-6 { v.check(!bubble(rig), "sent +\(age): bubble still shown after 2.0 s") }
            }
        }
        if v.done { return v }
        // INTERRUPTED and ERROR.
        for (name, act) in [("interrupted", { (r: SchedulerRig) in r.cancel() }), ("error", { (r: SchedulerRig) in r.fail() })] {
            let rig = SchedulerRig(settings: calm(), seed: 32, guards: guards)
            rig.start(); rig.advance(1); act(rig)
            let at = rig.now
            v.check(bubble(rig), "\(name): no bubble")
            while rig.now < at + 2.5 {
                rig.advance(0.05)
                if rig.now - at > 2.0 + 1e-6 { v.check(!bubble(rig), "\(name) +\(rig.now - at): bubble still shown after 2.0 s") }
            }
        }
        if v.done { return v }
        // Lost events: v1's timeouts bound the bubble (LISTENING 180 s, THINKING 5 s).
        do {
            let rig = SchedulerRig(settings: calm(), seed: 33, guards: guards)
            rig.start(); rig.advance(179); v.check(bubble(rig), "listening 179 s: gone early")
            rig.advance(3); v.check(!bubble(rig), "listening 182 s: still shown (v1 times out at 180 s)")
            rig.start(2); rig.advance(1); rig.complete(2); rig.advance(4.9); v.check(bubble(rig), "thinking 4.9 s: gone early")
            rig.advance(0.3); v.check(!bubble(rig), "thinking 5.2 s: still shown (v1 times out at 5 s)")
        }
        if v.done { return v }
        // The host never reports the end of a final scene: the scheduler's own cap holds.
        do {
            let rig = SchedulerRig(settings: calm(), seed: 34, guards: guards)
            rig.scheduler.sceneChanged(.sent, lease: nil)
            v.check(bubble(rig), "stuck sent: no bubble at the start")
            rig.advance(1.9); v.check(bubble(rig), "stuck sent 1.9 s: gone early")
            rig.advance(0.3); v.check(!bubble(rig), "stuck sent 2.2 s: still shown")
        }
        if v.done { return v }
        // bubble off, hidden, quiet: never.
        do {
            let rig = SchedulerRig(settings: calm { $0.bubble = false }, seed: 35, guards: guards)
            rig.start()
            for _ in 0..<40 { rig.advance(0.2); v.check(!bubble(rig), "bubble off: shown"); }
            rig.complete(); rig.advance(1); rig.ack(); rig.advance(2.5)
        }
        if v.done { return v }
        do {
            let rig = SchedulerRig(settings: calm(), seed: 36, guards: guards)
            rig.start()
            rig.scheduler.setQuiet(.displayAsleep, active: true)
            v.check(!bubble(rig), "quiet: bubble in a quiet condition")
            rig.scheduler.setQuiet(.displayAsleep, active: false)
            v.check(bubble(rig), "quiet over: the dictation's bubble did not come back")
            var hide = rig.scheduler.settings; hide.hiddenUntil = rig.wall + 60
            rig.scheduler.update(settings: hide)
            v.check(!bubble(rig), "hidden: bubble while hidden")
        }
        if v.done { return v }
        return v
    }
}
