import Foundation
import CoreGraphics
import ClawdCore
import ClawdAudio
import Darwin

// Explicit standalone measurement only. No app object, no window and no audio IO.
let args = Array(CommandLine.arguments.dropFirst())
func argument(_ name: String) -> String? { guard let index = args.firstIndex(of: name), index + 1 < args.count else { return nil }; return args[index + 1] }
guard let output = argument("--output"), let identity = argument("--fresh-identity"),
      identity.hasPrefix("com.tomtim.clawd-pet.probe."),
      let seconds = argument("--seconds").flatMap(Double.init), seconds >= 10, seconds <= 3600 else {
    fputs("Usage: clawd-release-probe --output PATH --fresh-identity SIGNED_ID --seconds N [--input-key-path PATH]\n", stderr); exit(2)
}
let inputKeyPath = argument("--input-key-path") ?? AquaInput.defaultInputKeyPath
let executable = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
let signature = Process(); signature.executableURL = URL(fileURLWithPath: "/usr/bin/codesign")
signature.arguments = ["-d", "--verbose=4", executable.path]
let signaturePipe = Pipe(); signature.standardError = signaturePipe; signature.standardOutput = FileHandle.nullDevice
try signature.run()
let signatureData = signaturePipe.fileHandleForReading.readDataToEndOfFile(); signature.waitUntilExit()
let attested = signature.terminationStatus == 0 && String(decoding: signatureData, as: UTF8.self).split(separator: "\n").contains("Identifier=\(identity)") && executable.path.contains(identity)
guard attested else { fputs("Fresh signed path/identifier not attested; source B remains disabled\n", stderr); exit(2) }
let promptOwners: Set<String> = ["tccd", "UserNotificationCenter", "SecurityAgent", "CoreServicesUIAgent", "universalAccessAuthWarn"]
func windows() -> Set<String>? {
    guard let windows = CGWindowListCopyWindowInfo(.optionAll, kCGNullWindowID) as? [[String: Any]] else { return nil }
    return Set(windows.compactMap { window in
        guard let owner = window[kCGWindowOwnerName as String] as? String, promptOwners.contains(owner),
              let id = window[kCGWindowNumber as String] as? NSNumber,
              let pid = window[kCGWindowOwnerPID as String] as? NSNumber else { return nil }
        return "\(pid):\(id)"
    })
}
let baseline = windows()
var enumerationOK = baseline != nil
var promptDetected = false
var registrationOK = true
var callbackCount = 0
var leases: [ProbeLease] = []
var activeLease: Int?
var openedAt: Date?
var previousRunning: Bool?
var openedRunning = false
var transitions = 0
var falseAt: Date?
var selectedUID: String?
var deviceValid = true
let audio = SelectedDeviceListener()
audio.onChange = { uid, running in
    callbackCount += 1
    guard activeLease != nil else { return }
    if uid != selectedUID || running == nil || AquaInput.selectedUID(keyPath: inputKeyPath) != selectedUID { deviceValid = false }
    if previousRunning == true, running == false { transitions += 1; falseAt = Date() }
    previousRunning = running
}
let parser = EventParser()
let reader = LogTailer(path: AquaInput.logPath) { line in
    guard let event = parser.parse(line), Date().timeIntervalSince(event.timestamp) <= 10 else { return }
    switch event.kind {
    case .start, .lock:
        guard activeLease != event.lease else { return }
        if activeLease != nil { leases.append(ProbeLease(transitions: transitions, gap: nil, openedRunning: openedRunning)) }
        activeLease = event.lease; openedAt = event.timestamp; transitions = 0; falseAt = nil; deviceValid = true
        selectedUID = AquaInput.selectedUID(keyPath: inputKeyPath)
        previousRunning = audio.start(uid: selectedUID)
        registrationOK = registrationOK && audio.registrationStatus == 0 && selectedUID != nil
        openedRunning = previousRunning == true
    case .completed:
        guard activeLease == event.lease, let openedAt, event.timestamp >= openedAt else { return }
        leases.append(ProbeLease(transitions: transitions, gap: deviceValid ? falseAt.map { event.timestamp.timeIntervalSince($0) } : nil, openedRunning: openedRunning))
        activeLease = nil; audio.stop()
    case .canceled, .error, .bootstrap, .shutdown:
        if activeLease != nil { leases.append(ProbeLease(transitions: transitions, gap: nil, openedRunning: openedRunning)) }
        activeLease = nil; audio.stop()
    default: break
    }
}
reader.onBoundary = { parser.reset() }
let watch = LogWatch(reader: reader)
let timer = DispatchSource.makeTimerSource(queue: .main)
timer.schedule(deadline: .now(), repeating: .milliseconds(50), leeway: .milliseconds(1))
timer.setEventHandler {
    if let sample = windows(), let baseline { if !sample.subtracting(baseline).isEmpty { promptDetected = true } }
    else { enumerationOK = false }
}
timer.resume()
DispatchQueue.main.asyncAfter(deadline: .now() + seconds) {
    timer.cancel(); audio.stop()
    if activeLease != nil { leases.append(ProbeLease(transitions: transitions, gap: nil, openedRunning: openedRunning)) }
    let report = ProbeReport(registrationSucceeded: registrationOK, callbackCount: callbackCount,
        baselineSucceeded: baseline != nil, enumerationsSucceeded: enumerationOK,
        promptWindowDetected: promptDetected, freshIdentityAttested: attested, leases: leases)
    do {
        let destination = URL(fileURLWithPath: output).standardizedFileURL
        let state = try OwnState(root: destination.deletingLastPathComponent())
        try state.writeJSON(report, to: destination.lastPathComponent)
        print(report.enablesSourceB ? "PROBE PASS" : "PROBE FAIL: source B disabled")
        exit(report.enablesSourceB ? 0 : 1)
    } catch { fputs("Cannot write probe report; source B disabled\n", stderr); exit(2) }
}
withExtendedLifetime(watch) { dispatchMain() }
