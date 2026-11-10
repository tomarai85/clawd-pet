import Testing
import Foundation
import AppKit
import CoreGraphics
import ClawdCore
import ClawdRendering
import ClawdDesktop

/// What the desktop observers are told of the macOS appearance, and when (amendment D-6). The runtime learns of a change by an event, never by polling, and
/// reads the value after the change has taken effect.
private final class AppearanceSink: QuietSink {
    var appearances: [BubbleAppearance] = []
    func setQuiet(_ reason: QuietReason, active: Bool) {}
    func setReduceMotion(_ on: Bool) {}
    func setAppearance(_ appearance: BubbleAppearance) { appearances.append(appearance) }
}

private final class AppearanceSource: NSObject {
    @objc dynamic var effectiveAppearance = NSAppearance(named: .aqua)!
    var value: BubbleAppearance { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? .dark : .light }
    func observe(_ changed: @escaping () -> Void) -> NSKeyValueObservation {
        observe(\.effectiveAppearance, options: [.new]) { _, _ in changed() }
    }
}

@Suite("Appearance", .serialized)
struct AppearanceTests {
    /// Yields to the main queue until `condition` holds or `limit` seconds pass.
    @MainActor private func spin(limit: Double = 5, until condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(limit)
        while !condition(), Date() < deadline { try? await Task.sleep(nanoseconds: 10_000_000) }
    }

    /// The notification's deferred read finishes before AppKit changes the value; only KVO can deliver the later value.
    @MainActor @Test func DesktopObservers_anAppearanceNotificationBeforeTheValueChangesStillDeliversTheNewValue() async throws {
        let sink = AppearanceSink()
        let distributed = NotificationCenter()
        let source = AppearanceSource()
        let observers = DesktopObservers(sink: sink, workspace: NotificationCenter(), distributed: distributed,
                                         appearance: { source.value }, observeAppearance: source.observe)
        #expect(sink.appearances == [.light], "the state at start is reported once")
        distributed.post(name: DesktopObservers.appearanceChanged, object: nil)
        await spin { sink.appearances.count == 2 }
        #expect(sink.appearances == [.light, .light], "the notification has already read the old value")
        source.effectiveAppearance = NSAppearance(named: .darkAqua)!
        await spin { sink.appearances.last == .dark }
        #expect(sink.appearances.last == .dark, "the sink ends with the new value: \(sink.appearances)")
        #expect(sink.appearances == [.light, .light, .dark], "the later effective change is delivered")
        withExtendedLifetime(observers) {}

        // The same order with a bubble shown: the runtime is the sink, and the new value costs exactly one render.
        let clock = VirtualClock(), timer = FakeScheduler(clock: clock)
        var options = HeadlessOptions(); options.motion = .off
        let run = try IdleRenderRun(clock: clock, scheduler: timer, art: artDirectory, options: options, pixelScale: 1)
        run.controller.machine.onChange = { _ in run.runtime.sceneChanged() }
        var settings = SchedulerSettings(); settings.motion = .off
        settings.bubbleExcluded = Set(SchedulerSettings.bubbleStyles).subtracting([13])
        run.runtime.apply(settings: settings)
        run.runtime.setQuiet(.aquaNotRunning, active: false)
        run.runtime.start()
        run.controller.receive(line: startLine(clock).trimmingCharacters(in: .newlines))
        advanceVirtual(clock: clock, scheduler: timer, runtime: run.runtime, by: 0.3)
        #expect(run.runtime.lastFrame?.bubble != nil, "a bubble is shown")
        let shown = AppearanceSource()
        let center = NotificationCenter()
        var reads = 0
        let watching = DesktopObservers(sink: run.runtime, workspace: NotificationCenter(), distributed: center,
                                        appearance: { reads += 1; return shown.value }, observeAppearance: shown.observe)
        let renders = run.runtime.renderCount
        center.post(name: DesktopObservers.appearanceChanged, object: nil)
        await spin { reads == 2 }
        #expect(run.runtime.appearance == .light && run.runtime.renderCount == renders)
        shown.effectiveAppearance = NSAppearance(named: .darkAqua)!
        await spin { run.runtime.appearance == .dark }
        #expect(run.runtime.appearance == .dark, "the runtime holds the new value")
        #expect(run.runtime.renderCount == renders + 1, "and with a bubble shown it cost one render (\(run.runtime.renderCount - renders))")
        #expect(run.runtime.lastRequest?.content.appearance == .dark, "the new appearance travels with the bubble's content")
        withExtendedLifetime(watching) {}
    }

    @MainActor @Test func DesktopObservers_anAppearanceChangeWithoutANotificationDeliversTheFinalValue() async {
        let source = AppearanceSource(), sink = AppearanceSink()
        var observers: DesktopObservers? = DesktopObservers(sink: sink, workspace: NotificationCenter(), distributed: NotificationCenter(),
                                                            appearance: { source.value }, observeAppearance: source.observe)
        source.effectiveAppearance = NSAppearance(named: .darkAqua)!
        await spin { sink.appearances.last == .dark }
        #expect(sink.appearances == [.light, .dark])
        source.effectiveAppearance = NSAppearance(named: .aqua)!
        await spin { sink.appearances.last == .light }
        #expect(sink.appearances == [.light, .dark, .light])
        withExtendedLifetime(observers) {}
        observers = nil
        source.effectiveAppearance = NSAppearance(named: .darkAqua)!
        await Task.yield()
        #expect(sink.appearances == [.light, .dark, .light], "the observation ends with its owner")
    }

    @MainActor @Test func DesktopObservers_theAppearanceIsTheAppsEffectiveAppearanceAndChangesAreObservedWithoutPolling() throws {
        #expect(DesktopObservers.appearanceChanged.rawValue == "AppleInterfaceThemeChangedNotification")
        let now = DesktopObservers.currentAppearance()
        #expect([BubbleAppearance.light, .dark].contains(now))
        let source = try String(contentsOf: repository.appendingPathComponent("Sources/ClawdDesktop/DesktopObservers.swift"), encoding: .utf8)
        #expect(source.contains("NSApplication.shared.observe(\\.effectiveAppearance"))
        #expect(!source.contains("Timer") && !source.contains("scheduledTimer") && !source.contains("asyncAfter"), "no polling")
    }
}
