import Foundation
import ClawdCore
import ClawdDesktop
import Darwin

// Order is part of the contract (spec section 5 B1): read-only and headless modes first,
// then the launchd-only guard, then the single-instance lock, and only then the app object.
let args = Array(CommandLine.arguments.dropFirst())
// The terminal path's two headless modes come first of all: the trampoline closes the descriptors it inherited before anything else runs.
if args.first == "--pty-exec" { TermExec.run(Array(args.dropFirst())) }
if args.first == "--term-guard" { exit(TermGuard.run(Array(args.dropFirst()))) }
if args.first == "--own-pids" { exit(OwnPids.run(arguments: Array(args.dropFirst()))) }
if args.first?.hasPrefix("--test-") == true { exit(HeadlessModes.run(args)) }
guard LaunchGuard.allowed() else { exit(0) }
let root = PetHome.stateRoot
var store: OwnState?
do {
    let state = try OwnState(root: root); store = state
    // A second instance exits quietly before it touches the window server.
    guard let lock = try? state.lock() else { exit(0) }
    // Whatever an earlier agent's terminal child left running is swept before anything can spawn, also during an exam stand-down.
    TermStartSweep.run(store: state) { try? state.append("\(Date().timeIntervalSince1970) \($0)\n", to: OwnState.agentLogName) }
    // The Settings window's reopen request after a restart is read and removed here, once, before anything boots; AgentRuntime acts on it after its
    // exam check.
    let request = SettingsRequestFile.take(store: state, seams: .system)
    let host = AppKitBootHost(root: root, store: state, settingsRequest: request)
    _ = try withExtendedLifetime(lock) { try AgentBoot.start(host: host) }
} catch {
    // A start-up failure is written to the agent's own log and the process exits 0, so launchd does not respawn it in a loop.
    try? store?.append("\(Date().timeIntervalSince1970) STARTUP_FAILED \(error)\n", to: OwnState.agentLogName)
    fputs("clawd-pet startup unavailable: \(error)\n", stderr); exit(0)
}
