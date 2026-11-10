import AppKit
import CoreGraphics
import Foundation

// clawd-attended-sampler: the read-only observer behind scripts/attended-check.sh and scripts/post-install-check.sh.
// It creates no window, has no Dock icon, never activates itself, posts no event and asks for no permission. It reads two things:
// the pid of the frontmost application, and the window server's window list (owner pid, layer, on-screen flag and bounds only; window
// titles are not read, which is why no screen-recording permission is involved).
//
//   sample SECONDS INTERVAL_MS   a heartbeat on stdout: "SAMPLING pid=<own pid>", then one line "<uptime_ms> <frontmost pid>" on every tick
//                                (-1 when the frontmost application cannot be read), then "SAMPLES-WRITTEN <n>" when SECONDS have passed
//                                or SIGTERM/SIGINT arrives. NSWorkspace updates frontmostApplication through the main run loop, so the
//                                sampling is a Timer on that run loop; a busy loop without it would keep reading a stale value.
//   sample SECONDS INTERVAL_MS clicks
//                                the same, and on stderr (stdout and its format are untouched) a listen-only global mouse-down monitor
//                                (left, right and other buttons; no key events, no event tap, no permission request) writes
//                                "CLICKS-ON pid=<own pid>" once the monitor exists ("CLICKS-FAILED" when it does not), then one line per
//                                mouse-down of another application:
//                                "CLICK t=<systemUptime, %.3f> et=<event timestamp, %.6f> button=<left|right|other> ctrl=<0|1> x=<%.2f>
//                                y=<%.2f> target=<pid|none>". t is the clock of the samples (seconds); x and y are the event's location
//                                relative to the lower-left corner of the main display, none without a CGEvent. The attended menu check
//                                pairs these lines with the agent's lines by et.
//   windows                      "WINDOW <pid> <layer> <onscreen 0|1> <x> <y> <w> <h> <number>" for every window, then "WINDOWS <n>";
//                                exit 2 when the list cannot be read or is empty.
//
// The process runs with the .prohibited activation policy: it is never a candidate for the frontmost application itself. It also asks the
// system for a latency-critical activity, so App Nap cannot slow its timer.

setvbuf(stdout, nil, _IOLBF, 0)
let arguments = Array(CommandLine.arguments.dropFirst())

func uptimeMilliseconds() -> Int { Int((ProcessInfo.processInfo.systemUptime * 1000).rounded()) }

func usage() -> Never {
    fputs("usage: clawd-attended-sampler sample SECONDS INTERVAL_MS [clicks] | windows\n", stderr)
    exit(2)
}

var signalSources: [DispatchSourceSignal] = []
var activities: [NSObjectProtocol] = []
var samplesWritten = 0

/// One mouse-down of another application as a CLICK line on stderr (a single fputs, so two lines never interleave).
func reportClick(_ event: NSEvent) {
    let button: String
    switch event.type {
    case .leftMouseDown: button = "left"
    case .rightMouseDown: button = "right"
    default: button = "other"
    }
    let control = event.modifierFlags.contains(.control) ? 1 : 0
    var x = "none", y = "none", target = "none"
    if let low = event.cgEvent {
        let at = low.unflippedLocation
        x = String(format: "%.2f", at.x); y = String(format: "%.2f", at.y)
        target = String(low.getIntegerValueField(.eventTargetUnixProcessID))
    }
    fputs(String(format: "CLICK t=%.3f et=%.6f button=%@ ctrl=%d x=%@ y=%@ target=%@\n", ProcessInfo.processInfo.systemUptime, event.timestamp,
                 button, control, x, y, target), stderr)
}

func finishSampling() -> Never {
    print("SAMPLES-WRITTEN \(samplesWritten)")
    exit(0)
}

switch arguments.first {
case "sample":
    guard arguments.count == 3 || (arguments.count == 4 && arguments[3] == "clicks"), let seconds = Double(arguments[1]), seconds > 0,
          let intervalMs = Int(arguments[2]), intervalMs >= 5 else { usage() }
    let reportsClicks = arguments.count == 4
    let application = NSApplication.shared
    application.setActivationPolicy(.prohibited)
    // No App Nap and no timer coalescing: a 20 ms heartbeat that the system may stretch to a second would prove nothing.
    activities.append(ProcessInfo.processInfo.beginActivity(options: [.userInitiatedAllowingIdleSystemSleep, .latencyCritical],
                                                            reason: "attended focus sampling"))
    signal(SIGTERM, SIG_IGN)
    signal(SIGINT, SIG_IGN)
    for number in [SIGTERM, SIGINT] {
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler { finishSampling() }
        source.resume()
        signalSources.append(source)
    }
    let began = ProcessInfo.processInfo.systemUptime
    let timer = Timer(timeInterval: Double(intervalMs) / 1000, repeats: true) { _ in
        let front = NSWorkspace.shared.frontmostApplication?.processIdentifier ?? -1
        print("\(uptimeMilliseconds()) \(front)")
        samplesWritten += 1
        if ProcessInfo.processInfo.systemUptime - began >= seconds { finishSampling() }
    }
    timer.tolerance = 0
    RunLoop.main.add(timer, forMode: .common)
    print("SAMPLING pid=\(getpid())")
    var clickMonitor: Any?
    if reportsClicks {
        clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown, .otherMouseDown], handler: { event in reportClick(event) })
        fputs(clickMonitor != nil ? "CLICKS-ON pid=\(getpid())\n" : "CLICKS-FAILED\n", stderr)
    }
    application.run()

case "windows":
    guard arguments.count == 1 else { usage() }
    guard let raw = CGWindowListCopyWindowInfo([.optionAll], kCGNullWindowID) as? [[String: Any]], !raw.isEmpty else {
        fputs("the window list cannot be read\n", stderr)
        exit(2)
    }
    var shown = 0
    for window in raw {
        guard let pid = (window[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
              let boundsDictionary = window[kCGWindowBounds as String] as? NSDictionary,
              let bounds = CGRect(dictionaryRepresentation: boundsDictionary as CFDictionary) else { continue }
        let layer = (window[kCGWindowLayer as String] as? NSNumber)?.intValue ?? 0
        let onScreen = (window[kCGWindowIsOnscreen as String] as? NSNumber)?.boolValue ?? false
        let number = (window[kCGWindowNumber as String] as? NSNumber)?.intValue ?? -1
        print(String(format: "WINDOW %d %d %d %.1f %.1f %.1f %.1f %d", pid, layer, onScreen ? 1 : 0,
                     bounds.minX, bounds.minY, bounds.width, bounds.height, number))
        shown += 1
    }
    print("WINDOWS \(shown)")
    exit(shown > 0 ? 0 : 2)

default:
    usage()
}
