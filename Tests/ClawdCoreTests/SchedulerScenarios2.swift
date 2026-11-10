import Foundation
import CoreGraphics
import ClawdCore

private func lively(_ edit: (inout SchedulerSettings) -> Void = { _ in }) -> SchedulerSettings {
    var s = SchedulerSettings(); s.motion = .lively; edit(&s); return s
}

extension SchedulerScenarios {
    // MARK: S-5 idle gaps

    /// Seven days per level: every gap from the previous end to the next idle motion or walk lies inside the level's interval,
    /// and the mean is within 10% of its midpoint.
    static func s5(_ guards: SchedulerGuards, seed: UInt64 = 50, quick: Bool = false) -> Violations {
        var v = Violations(quick: quick)
        for (index, level) in [MotionLevel.quiet, .normal, .lively].enumerated() {
            let range = level.interval!
            let rig = SchedulerRig(settings: lively { $0.motion = level; $0.lookEveryHours = 2 }, seed: seed &+ UInt64(index), guards: guards, eventLimit: quick ? 100_000 : 400_000)
            rig.advance(7 * 86_400)
            var lastEnd = rig.started, afterLook = false
            var gaps: [Double] = [], lookGaps: [Double] = []
            // A gap that begins at a look change follows the 30 s distance of S-4, not the level's interval, once that is shorter than 30 s.
            func gap(_ t: Double) { if afterLook && range.lowerBound < 30 { lookGaps.append(t - lastEnd) } else { gaps.append(t - lastEnd) } }
            for item in rig.events.sorted(by: { $0.t < $1.t }) {
                switch item.event {
                case .motionStart(_, let use) where use == "idle" || use.hasPrefix("signature"): gap(item.t)
                case .walkStart: gap(item.t)
                case .motionEnd, .walkEnd: lastEnd = item.t; afterLook = false
                case .lookTransitionEnd: lastEnd = item.t; afterLook = true
                default: break
                }
            }
            v.check(lookGaps.allSatisfy { $0 >= 30 - 1e-6 }, "\(level): a motion came within 30 s after a look change: \(lookGaps.filter { $0 < 30 - 1e-6 }.prefix(3))")
            v.check(gaps.count > (level == .quiet ? 1500 : 4000), "\(level): only \(gaps.count) gaps in 7 days")
            let outside = gaps.filter { $0 < range.lowerBound - 1e-6 || $0 > range.upperBound + 1e-6 }
            v.check(outside.isEmpty, "\(level): \(outside.count) gaps outside \(range): \(outside.prefix(3).map { String(format: "%.1f", $0) })")
            let mean = gaps.reduce(0, +) / Double(max(1, gaps.count))
            let mid = (range.lowerBound + range.upperBound) / 2
            v.check(abs(mean - mid) <= 0.1 * mid, "\(level): mean gap \(mean) is not within 10% of \(mid)")
        }
        if v.done { return v }
        return v
    }

    // MARK: S-6 look cadence

    static func s6(_ guards: SchedulerGuards, seed: UInt64 = 6, quick: Bool = false) -> Violations {
        var v = Violations(quick: quick)
        for (name, level, hours) in [("motion off, 3 h", MotionLevel.off, 3), ("lively, 2 h", .lively, 2)] {
            let rig = SchedulerRig(settings: lively { $0.motion = level; $0.lookEveryHours = hours }, seed: seed, guards: guards, eventLimit: quick ? 20_000 : 400_000)
            // Each interval is the setting times the factors drawn for it (amendments D-3 and variety D-4): 1.0 for the first (the start state's), then one per change.
            var factors: [Double] = [1.0]
            var clockSince = rig.scheduler.persisted.lookSince
            rig.scheduler.onPersist = { if $0.lookSince != clockSince { clockSince = $0.lookSince; factors.append($0.lookDueFactor * $0.lookVarietyFactor) } }
            rig.advance(7 * 86_400)
            let starts = rig.events.filter { if case .lookTransition = $0.event { return true } else { return false } }.map(\.t)
            let swaps = rig.events.filter { isLookChange($0.event) }.map(\.t)
            v.check(swaps.count >= 7 * 24 / hours - 2, "\(name): only \(swaps.count) changes in 7 days")
            var due = rig.started + Double(hours) * 3600 * factors[0]
            for (i, swap) in swaps.enumerated() where i < starts.count && i < factors.count {
                let interval = Double(hours) * 3600 * factors[i]
                let delay = starts[i] - due
                v.check(delay >= -1e-3, "\(name): change \(i) started \(-delay) s before it was due")   // epoch arithmetic is good to a microsecond or two
                v.check(delay <= 60, "\(name): change \(i) came \(Int(delay)) s after it was due")
                if i > 0 { v.check(swap - swaps[i - 1] >= interval - 1e-6, "\(name): changes \(i - 1) and \(i) only \(Int(swap - swaps[i - 1])) s apart (drawn \(Int(interval)) s)") }
                if i + 1 < factors.count { due = swap + Double(hours) * 3600 * factors[i + 1] }
            }
        }
        if v.done { return v }
        return v
    }

    // MARK: S-7 walks

    struct WalkObservation {
        var dx: Double
        var samples: [(t: TimeInterval, offset: Double, use: String?, mirrored: Bool?)]
        var walked: Double
        var finished: Bool
    }

    /// Runs the rig until `count` walks have finished and samples each at 0.1 s.
    static func observeWalks(_ rig: SchedulerRig, count: Int, within limit: TimeInterval = 7 * 3600) -> [WalkObservation] {
        var found: [WalkObservation] = []
        let end = rig.now + limit
        while found.count < count, rig.now < end {
            let before = rig.events.count
            let started = rig.run(upTo: end - rig.now) { rig.eventsSince(before).contains { isWalkStart($0.event) } }
            guard started, let dx = rig.eventsSince(before).compactMap({ e -> Double? in if case .walkStart(let d) = e.event { return d } else { return nil } }).first else { break }
            var obs = WalkObservation(dx: dx, samples: [], walked: 0, finished: false)
            var guardCount = 0
            while guardCount < 2000 {
                guardCount += 1
                let f = rig.frame
                obs.samples.append((rig.now, f.walkOffset, f.playback?.use, f.playback?.mirrored))
                if let e = rig.eventsSince(before).compactMap({ e -> Double? in if case .walkEnd(let w) = e.event { return w } else { return nil } }).first {
                    obs.walked = e; obs.finished = true; break
                }
                rig.advance(0.1)
            }
            found.append(obs)
        }
        return found
    }

    /// The keep-out band as the spec states it (display centre +/- 120 pt), not read back from the implementation.
    private static func bandOverlap(_ geo: PetGeometry, _ stage: StageExtent, x: Double) -> Double {
        let r = geo.stageRect(stage, originX: x)
        let bandMin = Double(geo.displayFrame.midX) - 120, bandMax = Double(geo.displayFrame.midX) + 120
        return max(0, min(Double(r.maxX), bandMax) - max(Double(r.minX), bandMin))
    }

    static func s7(_ guards: SchedulerGuards, seed: UInt64 = 7, quick: Bool = false) -> Violations {
        var v = Violations(quick: quick)
        // Geometry cases: where Clawd lives, how big it is.
        let cases: [(String, PetGeometry, Bool)] = [
            ("left of the band (Aqua's default spot)", SchedulerFixture.geometry(homeX: 576), true),
            ("right of the band", SchedulerFixture.geometry(homeX: 900), true),
            ("near the left edge", SchedulerFixture.geometry(homeX: 100), true),
            ("size 2", SchedulerFixture.geometry(scale: 2, homeX: 500), true),
            ("near the right edge, another display beside it", SchedulerFixture.geometry(homeX: 1330), true),
            ("centred on the band", SchedulerFixture.geometry(homeX: 696), false),
        ]
        for (name, geo, possible) in cases {
            let rig = SchedulerRig(settings: lively(), geometry: geo, seed: seed, guards: guards)
            let walks = observeWalks(rig, count: 25)
            if !possible { v.check(walks.isEmpty, "\(name): \(walks.count) walks where none is possible"); continue }
            v.check(walks.count == 25, "\(name): only \(walks.count) walks")
            let homeX = Double(geo.homeOrigin.x), width = geo.width
            let homeOverlap = bandOverlap(geo, .none, x: homeX)
            for w in walks {
                let target = homeX + w.dx
                v.check(abs(w.dx) >= 1.5 * width - 1e-6 && abs(w.dx) <= 5 * width + 1e-6, "\(name): walk of \(w.dx) pt is outside 1.5-5 widths")
                v.check(w.finished, "\(name): walk did not finish")
                v.check(bandOverlap(geo, .none, x: target) == 0, "\(name): target \(target) is inside the keep-out band")
                v.check(geo.visibleFrame.contains(geo.canvasRect(originX: target)), "\(name): target \(target) is outside the visible frame")
                v.check((homeX + width / 2 < Double(geo.displayFrame.midX)) == (target + width / 2 < Double(geo.displayFrame.midX)),
                        "\(name): the walk crosses to the other side of the band")
                v.check(w.walked <= 30, "\(name): walking time \(w.walked) s")
                for s in w.samples {
                    let x = homeX + s.offset
                    v.check(geo.visibleFrame.contains(geo.canvasRect(originX: x)), "\(name): Clawd at \(x) is outside the visible frame")
                    v.check(bandOverlap(geo, .none, x: x) <= homeOverlap + 1e-6, "\(name): Clawd at \(x) is in the keep-out band")
                    if bandOverlap(geo, .none, x: x) > homeOverlap + 1e-6 { break }
                }
                v.check(abs(w.samples.last?.offset ?? 1) < 1e-6, "\(name): Clawd is not home at the end (\(w.samples.last?.offset ?? 99))")
                // Speed on the way out, from the time the walk cycle ran until Clawd stood at the target.
                let moving = w.samples.filter { $0.use == "walk" }
                if let first = moving.first, let arrived = w.samples.first(where: { abs($0.offset - w.dx) < 1e-6 }) {
                    let speed = abs(w.dx) / max(0.1, arrived.t - first.t + 0.05)
                    v.check(speed >= 20 * geo.scale - 4 && speed <= 80 * geo.scale + 4, "\(name): walking speed \(speed) pt/s at size \(geo.scale)")
                    v.check(moving.first?.mirrored == (w.dx < 0), "\(name): the first leg is not mirrored to the way it goes")
                }
                // The pause at the target lasts 1-3 s.
                let paused = w.samples.filter { abs($0.offset - w.dx) < 1e-6 }.count
                v.check(paused >= 9 && paused <= 33, "\(name): paused \(Double(paused) * 0.1) s at the target")
            }
        }
        if v.done { return v }
        // The pointer: stops when it comes within a width of the path ahead, goes on when it leaves, heads home after 5 s.
        do {
            let rig = SchedulerRig(settings: lively(), seed: 3, guards: guards)
            let before = rig.events.count
            v.check(rig.run(upTo: 7200) { rig.eventsSince(before).contains { isWalkStart($0.event) } }, "pointer: no walk started")
            rig.advance(1.0)
            let moved = rig.frame.walkOffset
            let ahead = CGPoint(x: Double(576) + moved - 30, y: 120)
            rig.scheduler.pointerMoved(ahead)
            rig.advance(0.2)
            let stopped = rig.frame.walkOffset
            v.check(rig.frame.playback == nil, "pointer: Clawd keeps walking with the pointer in the way")
            rig.advance(3.0)
            v.check(abs(rig.frame.walkOffset - stopped) < 1e-6, "pointer: Clawd moved while the pointer was in the way")
            rig.scheduler.pointerMoved(CGPoint(x: 1300, y: 600))
            rig.advance(0.5)
            v.check(rig.frame.walkOffset < stopped - 5, "pointer: Clawd did not go on after the pointer left (\(stopped) -> \(rig.frame.walkOffset))")
            let again = rig.frame.walkOffset
            rig.scheduler.pointerMoved(CGPoint(x: Double(576) + again - 30, y: 120))
            rig.advance(4.5)
            v.check(abs(rig.frame.walkOffset - again) < 1e-6, "pointer: Clawd turned home before 5 s (\(again) -> \(rig.frame.walkOffset))")
            rig.advance(1.0)
            v.check(rig.frame.walkOffset > again + 1, "pointer: Clawd did not head home after 5 s (\(again) -> \(rig.frame.walkOffset))")
            rig.scheduler.pointerMoved(nil)
            v.check(rig.run(upTo: 60) { rig.eventsSince(before).contains { if case .walkEnd = $0.event { return true } else { return false } } }, "pointer: Clawd never got home")
            v.check(abs(rig.frame.walkOffset) < 1e-6, "pointer: not home at the end")
            if let walked = rig.eventsSince(before).compactMap({ e -> Double? in if case .walkEnd(let w) = e.event { return w } else { return nil } }).first {
                v.check(walked <= 30, "pointer: walking time \(walked) s")
            }
        }
        if v.done { return v }
        // A dictation 1 s into a walk lasts 60 s: the walk ends in the same tick, the scene plays where Clawd stands, then Clawd walks home.
        do {
            let rig = SchedulerRig(settings: lively(), seed: 3, guards: guards)
            let before = rig.events.count
            v.check(rig.run(upTo: 7200) { rig.eventsSince(before).contains { isWalkStart($0.event) } }, "dictation: no walk started")
            rig.advance(1.0)
            let at = rig.frame.walkOffset
            rig.start()
            v.check(rig.frame.playback?.use == "listening", "dictation: the scene is not playing in the tick the lease opened")
            v.check(abs(rig.frame.walkOffset - at) < 1e-9, "dictation: Clawd moved in the tick the lease opened (\(at) -> \(rig.frame.walkOffset))")
            rig.advance(60)
            v.check(abs(rig.frame.walkOffset - at) < 1e-9, "dictation: Clawd moved during the dictation")
            rig.complete(); rig.advance(1.0); rig.ack()
            rig.advance(SceneMachine.sentDuration + 0.05)
            v.check(rig.frame.scene == .idle, "dictation: the scene did not end")
            rig.advance(0.5)
            v.check(rig.frame.walkOffset > at + 5 || rig.frame.walkOffset < at - 5, "dictation: Clawd did not walk home after the scene (\(at) -> \(rig.frame.walkOffset))")
            v.check(rig.run(upTo: 60) { rig.eventsSince(before).contains { if case .walkEnd = $0.event { return true } else { return false } } }, "dictation: Clawd never got home")
            v.check(abs(rig.frame.walkOffset) < 1e-6, "dictation: not home at the end")
            if let walked = rig.eventsSince(before).compactMap({ e -> Double? in if case .walkEnd(let w) = e.event { return w } else { return nil } }).first {
                v.check(walked <= 30, "dictation: walking time \(walked) s")
                let expected = 1.0 + abs(at) / 40
                v.check(abs(walked - expected) < 0.5, "dictation: walking time \(walked) s, expected about \(expected) (the 60 s of dictation do not count)")
            }
        }
        if v.done { return v }
        // A catalog whose stride gives 10 pt/s is outside the allowed 20-80: no walk rather than a 48 s walk.
        do {
            let slow = SchedulerFixture.catalog(walkStride: 10 * 2.3333 / 4)
            let rig = SchedulerRig(catalog: slow, settings: lively(), seed: 7, guards: guards)
            let walks = observeWalks(rig, count: 5, within: 6 * 3600)
            v.check(walks.allSatisfy { $0.walked <= 30 }, "slow stride: a walk of \(walks.map(\.walked).max() ?? 0) s")
            v.check(walks.isEmpty, "slow stride: \(walks.count) walks at a speed outside 20-80 pt/s")
        }
        if v.done { return v }
        return v
    }

    // MARK: S-8 only compatible, not excluded

    static func s8(_ guards: SchedulerGuards, seed: UInt64 = 8, quick: Bool = false) -> Violations {
        var v = Violations(quick: quick)
        let catalog = SchedulerFixture.catalog()
        let rig = SchedulerRig(catalog: catalog, settings: lively { $0.lookEveryHours = 2 }, seed: seed, guards: guards, refresh: false, eventLimit: quick ? 100_000 : 400_000)
        rig.scheduler.refresh()
        let driver = SeededRandom(seed: seed &* 11)
        let names = ["A10", "heart", "wizard", "a20-laptop", "coffee", "A5", "skateboard", "A19", "sunglasses", "D18", "A25-spark", "A6"]
        var timeline: [(TimeInterval, Set<String>)] = [(rig.now, [])]
        let end = rig.now + 7 * 86_400
        while rig.now < end {
            rig.advance(60 + driver.unit() * 2400)
            let pick = driver.unit()
            if pick < 0.35 {
                var s = rig.scheduler.settings
                let n = Int(driver.unit() * 4)
                s.excluded = Set((0..<n).map { _ in names[Int(driver.unit() * Double(names.count))].lowercased() })
                rig.scheduler.update(settings: s)
                timeline.append((rig.now, s.excluded))
            } else if pick < 0.55 { rig.dictate(listening: 1 + driver.unit() * 5) }
            else if pick < 0.75 { rig.scheduler.click() }
            else if pick < 0.90 { rig.scheduler.appear() }
            else { rig.scheduler.dragStarted(); rig.advance(1); rig.scheduler.dragEnded() }
        }
        if v.done { return v }
        func excluded(at t: TimeInterval) -> Set<String> { timeline.last(where: { $0.0 <= t + 1e-9 })?.1 ?? [] }
        func isExcluded(_ id: String, _ board: String, _ name: String, _ set: Set<String>) -> Bool {
            set.contains(id.lowercased()) || set.contains(board.lowercased()) || set.contains(name.lowercased())
        }
        if v.done { return v }
        let sorted = rig.events.sorted { $0.t < $1.t }
        var worn = "plain"
        var checked = 0
        var walkChecked = 0
        var lookChanges = 0
        for item in sorted {
            switch item.event {
            case .lookChange(_, let to):
                lookChanges += 1
                let look = catalog.look(id: to)!
                v.check(!isExcluded(look.id, look.board, look.name, excluded(at: item.t)) || to == "plain", "look \(to) worn at \(Int(item.t - rig.started)) s while excluded")
                worn = to
            case .motionStart(let id, _):
                let m = catalog.motion(id: id)!
                checked += 1
                v.check(catalog.isCompatible(m, with: worn), "\(id) played in the \(worn) look at \(Int(item.t - rig.started)) s")
                v.check(!isExcluded(m.id, m.board, m.name, excluded(at: item.t)), "\(id) played at \(Int(item.t - rig.started)) s while excluded \(excluded(at: item.t))")
            case .walkStart:
                walkChecked += 1
                let glides = catalog.look(id: worn)?.glides ?? false
                let walk = catalog.motion(id: "A5-walking")!
                if !glides {
                    v.check(catalog.isCompatible(walk, with: worn), "a walk in the \(worn) look at \(Int(item.t - rig.started)) s")
                    v.check(!isExcluded(walk.id, walk.board, walk.name, excluded(at: item.t)), "a walk at \(Int(item.t - rig.started)) s while A5 was excluded")
                }
            default: break
            }
        }
        if v.done { return v }
        v.check(checked > 2000, "only \(checked) motions started")
        v.check(walkChecked > 100, "only \(walkChecked) walks started")
        v.check(lookChanges > 40, "only \(lookChanges) look changes")
        return v
    }
}
