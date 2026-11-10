import Foundation
import Darwin

// A test helper for the chat bridge tests, not shipped. Unlike /bin/sleep and the system shells it is not a platform binary, so the kernel lets
// the bridge read its environment (KERN_PROCARGS2), which is how the spawn token finds a process.
//   clawd-chat-stub detached SECONDS   leave the caller's session and process group, ignore SIGTERM, and sleep
//   clawd-chat-stub sleep SECONDS      sleep
//   clawd-chat-stub tree FILE          the two escapees of `escapees`, their pids written to FILE, then sleep (the guard tests' stand-in for claude)
//   clawd-chat-stub tty WORD...        the terminal path's stand-in for claude (spec Sprint T1, Part B). Every word is a command; words it does
//                                      not know (claude's own flags and ids) are ignored. It reports on its terminal, in raw mode:
//     R pid=<p> pgid=<g> sid=<s> isatty=<0>,<1>,<2> tty=<ok|no> fds=<numbers> token=<token|-> env=<names> size=<C>x<R> args=<count>
//     W <C>x<R>              at every SIGWINCH
//     H <hex>                for every chunk read from the terminal
//     report                 the descriptor list alone ("F 0,1,2"), then sleep
//     escapees               two token-carrying escapees (a setsid grandchild and a double-forked orphan), then "E <pid> <pid>"
//     stop-self              SIGSTOP once after the report, then "RESUMED"
//     record=FILE            a line "HUP" or "CONT" in FILE for every SIGHUP or SIGCONT (SIGHUP no longer ends the stub)
//     title=TEXT             an OSC 0 title
//     bracketed              DECSET 2004 (bracketed paste)
//     kitty                  the kitty keyboard protocol on (CSI > 1 u)
//     focus                  DECSET 1004 (focus reports), as claude 2.1.310 turns it on
//     hup-exit=N             on SIGHUP, exit with status N (claude's 129)
//     orphan-clean=FILE      its own child, an intermediate in a session of its own with an empty environment (`env -i perl`), starts G (this stub in
//                            `carry`, empty environment, so no token) and exits once FILE exists, which leaves G orphaned (ppid 1) outside this
//                            group and session; then "O <intermediate pid> <G pid>"
//     deaf                   never reads the terminal
//     exec-late=FILE         a perl in a session of its own, started by a subshell that exits; when FILE exists it execs this stub in `carry`;
//                            then "L <perl pid>"
//     carry                  sleep, with the environment it was given
//     resume-fail            exits 1 at once, printing "No conversation found", when --resume is among the words
//   A chunk that starts with byte 0x01 is a remote-control line (the tests' way to change the stub while it runs): `title TEXT`, `exit N`,
//   `bracketed`, `kitty [FLAGS]` (CSI > FLAGS u, default 1), `deaf` (stop reading), `say TEXT`, `query` (a DA query and an OSC 11 colour query, so
//   the terminal answers), `carry` (starts `clawd-chat-stub carry` as its own child, with the environment it was given).
let arguments = CommandLine.arguments

func out(_ text: String) {
    let bytes = Array(text.utf8)
    var offset = 0
    while offset < bytes.count {
        let n = bytes[offset...].withUnsafeBufferPointer { write(1, $0.baseAddress, $0.count) }
        if n > 0 { offset += n } else if n < 0, errno == EINTR { continue } else { return }
    }
}

func descriptors() -> String {
    (0..<256).filter { fcntl(Int32($0), F_GETFD) != -1 }.map(String.init).joined(separator: ",")
}

func windowSize() -> String {
    var size = winsize()
    guard ioctl(1, TIOCGWINSZ, &size) == 0 else { return "?" }
    return "\(size.ws_col)x\(size.ws_row)"
}

/// Starts the two escapees: a setsid grandchild and a double-forked orphan. Both inherit the environment, so both carry the token.
func startEscapees() -> (Int32, Int32) {
    let stub = CommandLine.arguments[0]
    let direct = Process()
    direct.executableURL = URL(fileURLWithPath: stub); direct.arguments = ["detached", "300"]
    try? direct.run()
    let orphan = Process()
    orphan.executableURL = URL(fileURLWithPath: "/bin/sh")
    orphan.arguments = ["-c", "( \"$0\" detached 300 >/dev/null 2>&1 & echo $! ) ; exit 0", stub]
    let pipe = Pipe()
    orphan.standardOutput = pipe
    try? orphan.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    orphan.waitUntilExit()
    let second = Int32(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)) ?? -1
    return (direct.processIdentifier, second)
}

func runTerminal(_ words: [String]) -> Never {
    let has = { (name: String) in words.contains(name) }
    let value = { (name: String) in words.first { $0.hasPrefix(name + "=") }.map { String($0.dropFirst(name.count + 1)) } }
    if has("resume-fail"), has("--resume") {
        out("No conversation found with session ID: stub\r\n")
        exit(1)
    }
    var original = termios()
    if tcgetattr(0, &original) == 0 {
        var raw = original
        cfmakeraw(&raw)
        tcsetattr(0, TCSANOW, &raw)
    }
    if has("report") {
        out("F \(descriptors())\r\n")
        sleep(300)
        exit(0)
    }
    let tty = open("/dev/tty", O_RDWR)
    if tty >= 0 { close(tty) }
    let names = ProcessInfo.processInfo.environment.keys.sorted().joined(separator: ",")
    let token = ProcessInfo.processInfo.environment["CLAWD_CHAT_SPAWN"] ?? "-"
    out("R pid=\(getpid()) pgid=\(getpgrp()) sid=\(getsid(0)) isatty=\(isatty(0)),\(isatty(1)),\(isatty(2)) tty=\(tty >= 0 ? "ok" : "no") "
        + "fds=\(descriptors()) token=\(token) env=\(names) size=\(windowSize()) args=\(words.count)\r\n")

    var sources: [DispatchSourceSignal] = []
    func watch(_ number: Int32, _ body: @escaping () -> Void) {
        signal(number, SIG_IGN)
        let source = DispatchSource.makeSignalSource(signal: number, queue: .main)
        source.setEventHandler(handler: body)
        source.resume()
        sources.append(source)
    }
    watch(SIGWINCH) { out("W \(windowSize())\r\n") }
    if let file = value("record") {
        func note(_ text: String) {
            let handle = open(file, O_WRONLY | O_CREAT | O_APPEND, 0o600)
            if handle >= 0 { _ = text.withCString { write(handle, $0, strlen($0)) }; close(handle) }
        }
        watch(SIGHUP) { note("HUP \(DispatchTime.now().uptimeNanoseconds)\n") }
        watch(SIGCONT) { note("CONT \(DispatchTime.now().uptimeNanoseconds)\n") }
    } else {
        // Default: SIGCONT is noted on the terminal; SIGHUP keeps its default action.
        watch(SIGCONT) { out("CONT\r\n") }
    }
    if let text = value("title") { out("\u{1b}]0;\(text)\u{7}") }
    if has("bracketed") { out("\u{1b}[?2004h") }
    if has("kitty") { out("\u{1b}[>1u") }
    if has("focus") { out("\u{1b}[?1004h") }
    if let status = value("hup-exit").flatMap({ Int32($0) }) { watch(SIGHUP) { exit(status) } }
    if has("escapees") {
        let pids = startEscapees()
        out("E \(pids.0) \(pids.1)\r\n")
    }
    if let file = value("exec-late") {
        let stub = CommandLine.arguments[0]
        let script = "( /usr/bin/perl -e 'use POSIX qw(setsid); setsid(); while (!-e $ARGV[0]) { select(undef, undef, undef, 0.05) } exec { $ARGV[1] } $ARGV[1], \"carry\"' \"$1\" \"$2\" >/dev/null 2>&1 & echo $! ) ; exit 0"
        let shell = Process()
        shell.executableURL = URL(fileURLWithPath: "/bin/sh")
        shell.arguments = ["-c", script, "sh", file, stub]
        let pipe = Pipe()
        shell.standardOutput = pipe
        try? shell.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        shell.waitUntilExit()
        out("L \(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))\r\n")
    }
    if let file = value("orphan-clean") {
        let stub = CommandLine.arguments[0]
        let script = "use POSIX qw(setsid); $| = 1; setsid(); my $g = fork(); if (!$g) { close STDOUT; exec { $ARGV[1] } $ARGV[1], 'carry' } print \"$g\\n\"; close STDOUT; while (!-e $ARGV[0]) { select(undef, undef, undef, 0.05) }"
        let middle = Process()
        middle.executableURL = URL(fileURLWithPath: "/usr/bin/env")
        middle.arguments = ["-i", "/usr/bin/perl", "-e", script, file, stub]
        let pipe = Pipe()
        middle.standardOutput = pipe
        try? middle.run()
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        out("O \(middle.processIdentifier) \(String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines))\r\n")
    }
    if has("stop-self") {
        raise(SIGSTOP)
        out("RESUMED\r\n")
    }
    if !has("deaf") {
        let input = DispatchSource.makeReadSource(fileDescriptor: 0, queue: .main)
        input.setEventHandler { [unowned input] in
            var buffer = [UInt8](repeating: 0, count: 65536)
            let count = read(0, &buffer, buffer.count)
            if count <= 0 { exit(0) }
            if buffer[0] == 0x01 {
                let line = String(decoding: buffer[1..<count], as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                switch parts.first ?? "" {
                case "title": out("\u{1b}]0;\(parts.count > 1 ? parts[1] : "")\u{7}")
                case "exit": exit(Int32(parts.count > 1 ? parts[1] : "0") ?? 0)
                case "bracketed": out("\u{1b}[?2004h")
                case "kitty": out("\u{1b}[>\(parts.count > 1 ? parts[1] : "1")u")
                case "query": out("\u{1b}[c\u{1b}]11;?\u{1b}\\")
                case "carry":
                    let child = Process()
                    child.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]); child.arguments = ["carry"]
                    try? child.run()
                case "deaf": input.cancel()
                case "say": out((parts.count > 1 ? parts[1] : "") + "\r\n")
                default: break
                }
                return
            }
            out("H " + buffer[0..<count].map { String(format: "%02x", $0) }.joined() + "\r\n")
        }
        input.resume()
        withExtendedLifetime((input, sources)) { dispatchMain() }
    }
    withExtendedLifetime(sources) { dispatchMain() }
}

if arguments.count >= 2, arguments[1] == "tty" { runTerminal(Array(arguments.dropFirst(2))) }
if arguments.count == 2, arguments[1] == "carry" { sleep(300); exit(0) }
if arguments.count == 3, arguments[1] == "tree" {
    let pids = startEscapees()
    try? "\(pids.0) \(pids.1)\n".write(toFile: arguments[2], atomically: true, encoding: .utf8)
    sleep(300)
    exit(0)
}
guard arguments.count == 3, let seconds = UInt32(arguments[2]) else {
    FileHandle.standardError.write(Data("usage: clawd-chat-stub detached|sleep SECONDS | tty WORD... | carry\n".utf8))
    exit(2)
}
if arguments[1] == "detached" {
    _ = setsid()
    signal(SIGTERM, SIG_IGN)
}
sleep(seconds)
