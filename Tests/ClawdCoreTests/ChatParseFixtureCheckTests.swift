import Testing
import Foundation

/// Runs scripts/check-chat-fixtures.py (the system python, no bytecode) and returns its exit status and output.
private func runChecker(_ arguments: [String]) throws -> (status: Int32, output: String) {
    let process = Process()
    process.executableURL = URL(fileURLWithPath: "/usr/bin/python3")
    process.arguments = ["-B", repository.appendingPathComponent("scripts/check-chat-fixtures.py").path] + arguments
    let pipe = Pipe()
    process.standardOutput = pipe
    process.standardError = pipe
    try process.run()
    let data = pipe.fileHandleForReading.readDataToEndOfFile()
    process.waitUntilExit()
    return (process.terminationStatus, String(decoding: data, as: UTF8.self))
}

@Suite("Chat fixture check")
struct ChatParseFixtureCheckSuite {
    @Test func ChatParse_theFixtureCheckerRefusesTheLeakingSetAndNamesEachRule() throws {
        let bad = repository.appendingPathComponent("Tests/Fixtures/chat-bad").path
        let (status, output) = try runChecker([bad])
        #expect(status == 1, "\(output)")
        #expect(output.contains("home-path.jsonl:1: home path other than /Users/example"))
        #expect(output.contains("user-directory.jsonl:1: home path other than /Users/example"))
        #expect(output.contains("email.jsonl:1: email address outside an example domain"))
        #expect(output.contains("real-uuid.jsonl:1: UUID that is not a placeholder"))
        #expect(output.contains("real-api-id.jsonl:1: API id (toolu_, msg_, req_) that is not a placeholder") && !output.contains("toolu_01Xfvz"))
        #expect(!output.contains("janedoe") && !output.contains("person@gmail.com") && !output.contains("3b70edf5"))      // the matched text is never printed
    }

    @Test func ChatParse_theFixtureCheckerAcceptsTheCommittedFixtures() throws {
        let (status, output) = try runChecker([repository.appendingPathComponent("Tests/Fixtures/chat").path])
        #expect(status == 0, "\(output)")
    }

    @Test func ChatParse_theFixtureCheckersSelfTestPasses() throws {
        let (status, output) = try runChecker(["--self-test"])
        #expect(status == 0 && output.contains("self-test: pass"), "\(output)")
    }
}
