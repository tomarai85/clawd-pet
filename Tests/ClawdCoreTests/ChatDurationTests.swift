import Testing
import Foundation
import Darwin
@testable import ClawdCore
import ClawdDesktop

struct ChatDurationTests {
    @Test func ChatPanel_aHugeToolDurationFromTheStreamShowsNoDurationAndNeverCrashesTheAgent() throws {
        for text in ["1e300", "-1e300", "9.3e18", "1e19", "100000", "99999.6"] {
            let run = try execute(agentExecutable(), ["--test-chat-tool-line", text])
            #expect(run.code == 0, "\(text): the render must not trap (code \(run.code)): \(run.output)")
            #expect(run.output.contains("TOOLLINE ") && !run.output.contains("s)"), "\(text): no duration is shown: \(run.output)")
        }
        for (text, shown) in [("7.4", "(7s)"), ("99999", "(99999s)"), ("1", "(1s)")] {
            let run = try execute(agentExecutable(), ["--test-chat-tool-line", text])
            #expect(run.code == 0 && run.output.contains(shown), "\(text): \(run.output)")
        }
    }
}

