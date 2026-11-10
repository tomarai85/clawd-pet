import Testing
import Foundation
import ClawdCore

private func line(_ entry: ChatEntry) -> String {
    switch entry.kind {
    case .user: return "user: " + entry.text
    case .assistant: return "assistant: " + entry.text
    case .tool:
        let status = entry.status.map { "\($0)" } ?? "-"
        return "tool \(entry.tool ?? "?") [\(status)] " + entry.text
    case .notice: return "notice: " + entry.text
    case .error: return "error: " + entry.text
    case .footer: return "footer: " + entry.text
    case .divider: return "divider: " + entry.text
    }
}
private func lines(_ transcript: ChatTranscript) -> [String] { transcript.entries.map(line) }

private func transcript(of name: String, userTurns: [Int: String]) throws -> ChatTranscript {
    var t = ChatTranscript(timeZone: TimeZone(identifier: "UTC")!)
    for (number, text) in try chatFixtureLines(name).enumerated() {
        if let user = userTurns[number] { t.appendUser(user) }
        for event in ChatStreamParser.parse(line: text) { t.apply(event) }
    }
    return t
}
private func feed(_ t: inout ChatTranscript, _ lines: [String]) {
    for text in lines { for event in ChatStreamParser.parse(line: text) { t.apply(event) } }
}
private func delta(_ text: String, message: String = "m1", index: Int = 0) -> String {
    #"{"type":"stream_event","event":{"type":"content_block_delta","index":\#(index),"delta":{"type":"text_delta","text":"\#(text)"}},"api_message_id":"\#(message)","parent_tool_use_id":null}"#
}
private func finalText(_ text: String, message: String = "m1") -> String {
    #"{"type":"assistant","message":{"id":"\#(message)","content":[{"type":"text","text":"\#(text)"}]},"parent_tool_use_id":null}"#
}
private func blockStart(_ index: Int, type: String = "text", message: String = "m1") -> String {
    #"{"type":"stream_event","event":{"type":"content_block_start","index":\#(index),"content_block":{"type":"\#(type)"}},"api_message_id":"\#(message)","parent_tool_use_id":null}"#
}
private func blockStop(_ index: Int, message: String = "m1") -> String {
    #"{"type":"stream_event","event":{"type":"content_block_stop","index":\#(index)},"api_message_id":"\#(message)","parent_tool_use_id":null}"#
}
/// A line the parser cannot read (cut in the middle), which the transcript counts as lost.
private let malformedLine = #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","te"#
private func result(ms: Int = 1000, cost: Double = 0.1, error: Bool = false, text: String = "ok") -> String {
    #"{"type":"result","subtype":"success","is_error":\#(error),"result":"\#(text)","duration_ms":\#(ms),"total_cost_usd":\#(cost),"session_id":"s1"}"#
}

@Suite("Chat transcript")
struct ChatTranscriptSuite {
    @Test func ChatTranscript_goldenForTheSingleTurnProbe() throws {
        let t = try transcript(of: "probe.jsonl", userTurns: [0: "Reply with the word ok"])
        #expect(lines(t) == [
            "user: Reply with the word ok",
            "assistant: ok",
            "notice: 7-day usage at 96%",
            "footer: 4.8 s, $0.0107 (reported by Claude Code)",
        ])
        #expect(t.sessionId == "00000000-0000-4000-8000-000000000001")
        #expect(t.ignoredCounts.isEmpty, "the catalog frames are read now, not ignored: \(t.ignoredCounts)")
    }

    @Test func ChatTranscript_goldenForTheTwoTurnCapture() throws {
        let t = try transcript(of: "p1-two-turns.jsonl", userTurns: [0: "Reply with the word ok", 25: "Create hello.txt containing hi, then say done"])
        #expect(lines(t) == [
            "user: Reply with the word ok",
            "assistant: ok",
            "footer: 6.6 s, $0.4804 (reported by Claude Code)",
            "user: Create hello.txt containing hi, then say done",
            "tool Write [done] /private/tmp/clawd-p1.example/hello.txt",
            "tool Bash [done] cat /private/tmp/clawd-p1.example/hello.txt",
            "assistant: done. `/private/tmp/clawd-p1.example/hello.txt` contains `hi`; I checked it with `cat hello.txt`, which printed `hi`.",
            "footer: 12.3 s, $0.0956 (reported by Claude Code)",
        ])
        let footers = t.entries.filter { $0.kind == .footer }
        #expect(footers.map { $0.ms } == [6612, 12275])
        #expect(abs((footers[1].cost ?? 0) - (0.5760592 - 0.480432)) < 1e-9)      // the turn's cost is the difference of the totals
        #expect(t.parseErrorCount == 0)
    }

    @Test func ChatTranscript_textDeltasThenTheFinalBlockGiveOneEntryWithTheFinalText() {
        var t = ChatTranscript()
        t.appendUser("hi")
        feed(&t, [delta("Hel"), delta("lo wor")])
        #expect(lines(t) == ["user: hi", "assistant: Hello wor"])
        feed(&t, [finalText("Hello world!")])
        #expect(lines(t) == ["user: hi", "assistant: Hello world!"])
        feed(&t, [delta("late delta after the final block")])
        #expect(lines(t) == ["user: hi", "assistant: Hello world!"])
        // A second text block of the same message is a second entry, and the finals pair up in order.
        feed(&t, [delta("Second", index: 2), finalText("Second block")])
        #expect(lines(t) == ["user: hi", "assistant: Hello world!", "assistant: Second block"])
    }

    @Test func ChatTranscript_aFinalBlockWithoutStreamingGivesItsOwnEntry() {
        var t = ChatTranscript()
        feed(&t, [finalText("first", message: "a"), finalText("second", message: "b")])
        #expect(lines(t) == ["assistant: first", "assistant: second"])
    }

    @Test func ChatTranscript_aToolErrorResultMarksTheLineFailed() throws {
        var t = ChatTranscript()
        feed(&t, [
            #"{"type":"stream_event","event":{"type":"content_block_start","index":0,"content_block":{"type":"tool_use","id":"t1","name":"Bash","input":{}}},"api_message_id":"m1","parent_tool_use_id":null}"#,
            #"{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"false\nsecond line"}}]},"parent_tool_use_id":null}"#,
            #"{"type":"tool_progress","tool_use_id":"t1","elapsed_time_seconds":2.5}"#,
        ])
        #expect(lines(t) == ["tool Bash [running] false"])
        try #require(t.entries.count > 0, "t.entries needs 1 elements: \(t.entries.count)")
        #expect(t.entries[0].seconds == 2.5)
        feed(&t, [#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","content":"secret output","is_error":true}]},"parent_tool_use_id":null}"#])
        #expect(lines(t) == ["tool Bash [failed] false"])
        feed(&t, [
            #"{"type":"assistant","message":{"id":"m2","content":[{"type":"tool_use","id":"t2","name":"Read","input":{"file_path":"/x"}}]},"parent_tool_use_id":null}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2","content":"file text"}]},"parent_tool_use_id":null}"#,
        ])
        #expect(lines(t).suffix(1) == ["tool Read [done] /x"])
        #expect(!lines(t).joined().contains("secret output") && !lines(t).joined().contains("file text"))      // tool output is never kept
    }

    @Test func ChatTranscript_aToolThatNeverReportedBackEndsUnknownNotDone() {
        let toolLine = #"{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"sleep 5"}}]},"parent_tool_use_id":null}"#
        var t = ChatTranscript()
        feed(&t, [toolLine, result()])
        #expect(lines(t).first == "tool Bash [unknown] sleep 5")
        var failed = ChatTranscript()
        feed(&failed, [toolLine, result(error: true, text: "went wrong")])
        #expect(lines(failed).first == "tool Bash [unknown] sleep 5")
        #expect(lines(failed).contains("error: went wrong"))
        // A matching tool_result is the only thing that makes a tool done or failed.
        var reported = ChatTranscript()
        feed(&reported, [toolLine, #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1"}]},"parent_tool_use_id":null}"#, result()])
        #expect(lines(reported).first == "tool Bash [done] sleep 5")
    }

    @Test func ChatTranscript_aLaterTurnsResultNeverSettlesAnEarlierTurnsTool() {
        var t = ChatTranscript()
        t.appendUser("one")
        feed(&t, [#"{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"a"}}]},"parent_tool_use_id":null}"#])
        // The first turn never got a result (the child died); the second turn runs a tool of its own and ends well.
        t.appendUser("two")
        feed(&t, [#"{"type":"assistant","message":{"id":"m2","content":[{"type":"tool_use","id":"t2","name":"Bash","input":{"command":"b"}}]},"parent_tool_use_id":null}"#,
                  #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t2"}]},"parent_tool_use_id":null}"#, result()])
        let tools = lines(t).filter { $0.hasPrefix("tool ") }
        #expect(tools == ["tool Bash [unknown] a", "tool Bash [done] b"])
        // A tool_result for a tool of a finished turn changes nothing.
        feed(&t, [#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t1","is_error":true}]},"parent_tool_use_id":null}"#])
        #expect(lines(t).filter { $0.hasPrefix("tool ") } == tools)
    }

    @Test func ChatTranscript_subagentOutputNeverReachesTheTranscript() {
        var t = ChatTranscript()
        feed(&t, [
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"inner words"}},"api_message_id":"c1","parent_tool_use_id":"toolu_task"}"#,
            #"{"type":"assistant","message":{"id":"c1","content":[{"type":"text","text":"inner words"},{"type":"tool_use","id":"ti","name":"Bash","input":{"command":"ls"}}]},"parent_tool_use_id":"toolu_task"}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"ti","is_error":true}]},"parent_tool_use_id":"toolu_task"}"#,
            #"{"type":"assistant","message":{"id":"m1","content":[{"type":"tool_use","id":"toolu_task","name":"Task","input":{"description":"look around"}}]},"parent_tool_use_id":null}"#,
        ])
        #expect(lines(t) == ["tool Task [running] look around"])
        #expect(t.ignoredCounts["stream_event/subagent"] == 1 && t.ignoredCounts["assistant/subagent"] == 1 && t.ignoredCounts["user/subagent"] == 1)
    }

    @Test func ChatTranscript_aMessageOverTheCapIsCutWithOneNotice() {
        var t = ChatTranscript()
        let chunk = String(repeating: "a", count: 64 * 1024)
        for _ in 0..<5 { feed(&t, [delta(chunk)]) }                                    // 320 KiB streamed in 5 deltas
        let assistant = t.entries.filter { $0.kind == .assistant }
        #expect(assistant.count == 1)
        #expect(assistant[0].text.utf8.count == 256 * 1024)
        #expect(assistant[0].elided)
        #expect(t.entries.filter { $0.kind == .notice }.count == 1)
        feed(&t, [delta(chunk)])                                                        // more deltas add nothing and no second notice
        #expect(t.entries.filter { $0.kind == .assistant }[0].text.utf8.count == 256 * 1024)
        #expect(t.entries.filter { $0.kind == .notice }.count == 1)
        let big = String(repeating: "b", count: 256 * 1024 + 100)
        feed(&t, [finalText(big, message: "m2")])                                       // a final block over the cap is cut the same way
        #expect(t.entries.filter { $0.kind == .assistant }.last?.text.utf8.count == 256 * 1024)
    }

    @Test func ChatTranscript_aCutNeverSplitsACharacter() {
        var t = ChatTranscript()
        let wide = String(repeating: "\u{65E5}", count: 100_000)                        // 300000 bytes of 3-byte characters
        feed(&t, [finalText(wide)])
        let text = t.entries[0].text
        #expect(text.utf8.count <= 256 * 1024 && text.utf8.count > 256 * 1024 - 3)
        #expect(text.allSatisfy { $0 == "\u{65E5}" })
    }

    @Test func ChatTranscript_theConversationDropsTheOldestBehindOneMarker() {
        var t = ChatTranscript()
        let block = String(repeating: "x", count: 200 * 1024)
        for number in 0..<14 { t.appendUser("turn \(number) " + block) }               // 14 x 200 KiB > 2 MiB
        let total = t.entries.reduce(0) { $0 + $1.text.utf8.count }
        #expect(total <= 2 * 1024 * 1024 + ChatTranscript.trimMarker.utf8.count)
        #expect(t.entries.first?.kind == .notice && t.entries.first?.text == ChatTranscript.trimMarker)
        #expect(t.entries.filter { $0.text == ChatTranscript.trimMarker }.count == 1)
        #expect(t.entries.last?.text.hasPrefix("turn 13 ") == true)                    // the newest stays
        #expect(!t.entries.contains { $0.text.hasPrefix("turn 0 ") })                  // the oldest went first
    }

    @Test func ChatTranscript_anOutOfRangeUtilizationNeverTraps() {
        var t = ChatTranscript()
        for value in [1e100, Double.infinity, Double.nan, -3, 5000] {
            t.apply(.rateLimit(status: "allowed_warning", type: "five_hour", resetsAt: nil, utilization: value))
        }
        #expect(lines(t) == ["notice: 5-hour usage is high"])
        t.apply(.rateLimit(status: "rejected", type: "seven_day", resetsAt: 1e100, utilization: nil))
        #expect(lines(t).last == "notice: Usage limit reached")
    }

    @Test func ChatTranscript_aHugeUtilizationLineGivesTheUnreadableNoticeAndNothingElse() {
        var t = ChatTranscript()
        feed(&t, [#"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","rateLimitType":"five_hour","utilization":1e100}}"#])
        #expect(lines(t) == ["notice: Some output from Claude Code could not be read"])
        #expect(t.parseErrorCount == 1)
    }

    @Test func ChatTranscript_aFinalTextPairsWithTheBlockTheStreamOrderNamesNeverWithAnother() {
        func assistant(_ t: ChatTranscript) -> [String] { t.entries.filter { $0.kind == .assistant }.map(\.text) }
        // Trigger: block 0's final line is malformed, block 1's delta is malformed, then block 1's final arrives. The stop of block 0 and the
        // start of block 1 are read, so the final text belongs to block 1 and block 0 keeps what it streamed.
        var missingFinal = ChatTranscript()
        feed(&missingFinal, [blockStart(0), delta("Q", index: 0), malformedLine, blockStop(0), blockStart(1), malformedLine, finalText("R!"), blockStop(1)])
        #expect(assistant(missingFinal) == ["Q", "R!"])
        // Block 0 streams "Let me check" and its final is lost; block 1 streams less than block 0 did and its final starts with block 0's text.
        var prefix = ChatTranscript()
        feed(&prefix, [blockStart(0), delta("Let me check", index: 0), blockStop(0), blockStart(1), delta("Let me", index: 1), malformedLine,
                       finalText("Let me check again"), blockStop(1)])
        #expect(assistant(prefix) == ["Let me check", "Let me check again"])
        // The start and the deltas of block 1 are lost, the stop of block 0 is read: block 0 is closed, so block 1's final text (which also
        // contains block 0's text) is a new entry and block 0 keeps what it streamed.
        var closed = ChatTranscript()
        feed(&closed, [blockStart(0), delta("Let me check", index: 0), malformedLine, blockStop(0), malformedLine, malformedLine, finalText("Let me check again"), blockStop(1)])
        #expect(assistant(closed) == ["Let me check", "Let me check again"])
        // The stop of block 0, the start of block 1 and every delta of block 1 are lost: nothing names block 1, so block 0's text is not
        // overwritten. The final text becomes its own entry.
        var unnamed = ChatTranscript()
        feed(&unnamed, [blockStart(0), delta("Q", index: 0), malformedLine, malformedLine, malformedLine, finalText("R!")])
        #expect(assistant(unnamed) == ["Q", "R!"])
        // A final text that equals a streamed block is that block, even when the stream order names none.
        var equal = ChatTranscript()
        feed(&equal, [delta("one", index: 0), delta("two", index: 1), delta("three", index: 2), finalText("one"), finalText("three!")])
        #expect(assistant(equal) == ["one", "two", "three!"])
        // Block 0 never streamed (its delta line was malformed); block 1 did. Each final lands in its own entry.
        var unstreamed = ChatTranscript()
        feed(&unstreamed, [blockStart(0), malformedLine, finalText("A"), blockStop(0), blockStart(1), delta("B", index: 1), finalText("B!"), blockStop(1)])
        #expect(assistant(unstreamed) == ["A", "B!"])
        feed(&unstreamed, [delta("late delta of the unstreamed block", index: 0)])      // block 0 is final: a late delta adds nothing
        #expect(assistant(unstreamed) == ["A", "B!"])
        // Streamed blocks that all arrive: finals pair in block order, whatever the block numbers are.
        var all = ChatTranscript()
        feed(&all, [blockStart(1), delta("x", index: 1), finalText("x1"), blockStop(1), blockStart(3), delta("y", index: 3), finalText("y1"), blockStop(3)])
        #expect(assistant(all) == ["x1", "y1"])
        // A thinking block between two text blocks is not a text block: its start leaves no text block open.
        var thinking = ChatTranscript()
        feed(&thinking, [blockStart(0), delta("first", index: 0), finalText("first."), blockStop(0), blockStart(1, type: "thinking"), blockStop(1),
                         blockStart(2), malformedLine, finalText("third"), blockStop(2)])
        #expect(assistant(thinking) == ["first.", "third"])
    }

    @Test func ChatTranscript_aLostDeltaLineNeverLeavesAFragmentBesideTheFinalText() {
        // A middle delta is lost: the streamed fragment is not a prefix of the final text, but the stream order names the block.
        var middle = ChatTranscript()
        feed(&middle, [blockStart(0), delta("Hello "), malformedLine, delta("!"), finalText("Hello world!"), blockStop(0)])
        #expect(middle.entries.filter { $0.kind == .assistant }.map(\.text) == ["Hello world!"])
        // The FIRST delta is lost.
        var first = ChatTranscript()
        feed(&first, [blockStart(0), malformedLine, delta("world"), finalText("Hello world"), blockStop(0)])
        #expect(first.entries.filter { $0.kind == .assistant }.map(\.text) == ["Hello world"])
        // The LAST deltas are lost: a line went missing after the block's last read line, and the final text contains what was streamed.
        var last = ChatTranscript()
        feed(&last, [blockStart(0), delta("Hello "), malformedLine, finalText("Hello world!"), blockStop(0)])
        #expect(last.entries.filter { $0.kind == .assistant }.map(\.text) == ["Hello world!"])
        // An oversized line counts as a lost line too.
        var big = ChatTranscript()
        big.apply(.textDelta(messageKey: "m1", blockIndex: 0, text: "Hello "))
        big.apply(.oversized)
        big.apply(.textDelta(messageKey: "m1", blockIndex: 0, text: "!"))
        feed(&big, [finalText("Hello world!")])
        #expect(big.entries.filter { $0.kind == .assistant }.map(\.text) == ["Hello world!"])
    }

    @Test func ChatTranscript_aLostFinalLineNeverMovesTheNextBlocksFinalOntoIt() {
        func build(_ finals: (zero: String?, two: String?)) -> [String] {
            var t = ChatTranscript()
            var lines = [blockStart(0), delta("Let me check", index: 0)]
            if let text = finals.zero { lines.append(finalText(text)) }
            lines.append(blockStop(0))
            lines.append(contentsOf: [blockStart(2), delta("Let me check again", index: 2)])
            if let text = finals.two { lines.append(finalText(text)) }
            lines.append(blockStop(2))
            feed(&t, lines)
            return t.entries.filter { $0.kind == .assistant }.map(\.text)
        }
        // Block 0's final line is lost: block 2's final belongs to block 2.
        #expect(build((nil, "Let me check again.")) == ["Let me check", "Let me check again."])
        // Block 2's final line is lost: block 0's final stays with block 0.
        #expect(build(("Let me check.", nil)) == ["Let me check.", "Let me check again"])
        #expect(build(("Let me check.", "Let me check again.")) == ["Let me check.", "Let me check again."])
        // A streamed text equal to the final wins over a longer one that merely shares the prefix.
        var equal = ChatTranscript()
        feed(&equal, [delta("ab", index: 0), delta("a", index: 1), finalText("a")])
        #expect(equal.entries.filter { $0.kind == .assistant }.map(\.text) == ["ab", "a"])
    }

    @Test func ChatTranscript_emptyEntriesCountTowardTheConversationCap() {
        var t = ChatTranscript()
        for number in 0..<20_000 {
            feed(&t, [#"{"type":"assistant","message":{"id":"m\#(number)","content":[{"type":"tool_use","id":"t\#(number)","name":"Bash","input":{}}]},"parent_tool_use_id":null}"#])
        }
        #expect(t.entries.count < 12_000)
        #expect(t.entries.first?.text == ChatTranscript.trimMarker)
        #expect(t.entries.last?.tool == "Bash")
    }

    @Test func ChatTranscript_bookkeepingEndsWithTheTurn() {
        var t = ChatTranscript()
        for number in 0..<400 {
            t.appendUser("turn \(number)")
            feed(&t, [delta("par", message: "m\(number)"), finalText("partial", message: "m\(number)"),
                      #"{"type":"assistant","message":{"id":"m\#(number)","content":[{"type":"tool_use","id":"t\#(number)","name":"Bash","input":{}}]},"parent_tool_use_id":null}"#])
            #expect(t.bookkeepingCount > 0)
            feed(&t, [result()])
        }
        #expect(t.bookkeepingCount == 0)                                               // every finished turn released its tables
    }

    @Test func ChatTranscript_bookkeepingIsDroppedWhenItsEntriesAreTrimmed() {
        var t = ChatTranscript()
        for number in 0..<20_000 {                                                      // one endless turn: tables follow the entries that survive the trim
            feed(&t, [finalText("text \(number)", message: "m\(number)"),
                      #"{"type":"assistant","message":{"id":"m\#(number)","content":[{"type":"tool_use","id":"t\#(number)","name":"Bash","input":{}}]},"parent_tool_use_id":null}"#])
        }
        #expect(t.entries.count < 12_000)
        #expect(t.bookkeepingCount <= 2 * t.entries.count + 64)
    }

    @Test func ChatTranscript_anyOneEntryIsCutAtTheMessageCapWithTheNotice() {
        var t = ChatTranscript()
        let big = String(repeating: "e", count: 3 * 1024 * 1024)
        t.apply(.result(outcome: .error, durationMs: 10, totalCost: 0, sessionId: "s", text: big))
        let errors = t.entries.filter { $0.kind == .error }
        #expect(errors.count == 1 && errors[0].text.utf8.count == 256 * 1024)
        #expect(t.entries.contains { $0.kind == .notice && $0.text == ChatTranscript.elidedNotice })
        let size = t.entries.reduce(0) { $0 + $1.text.utf8.count }
        #expect(size <= 2 * 1024 * 1024)
        var user = ChatTranscript()
        user.appendUser(big)
        #expect(user.entries.first?.kind == .user && user.entries.first?.text.utf8.count == 256 * 1024)
        #expect(user.entries.contains { $0.text == ChatTranscript.elidedNotice })
    }

    @Test func ChatTranscript_theMessageCapCountsEveryBlockOfOneMessageId() {
        var t = ChatTranscript()
        let block = String(repeating: "b", count: 200 * 1024)
        feed(&t, [finalText(block, message: "m1"), finalText(block, message: "m1")])
        let first = t.entries.filter { $0.kind == .assistant }
        #expect(first.reduce(0) { $0 + $1.text.utf8.count } == 256 * 1024)
        #expect(t.entries.filter { $0.text == ChatTranscript.elidedNotice }.count == 1)
        feed(&t, [finalText("more", message: "m1")])                                   // the message is full: nothing more of it is shown
        #expect(t.entries.filter { $0.kind == .assistant }.reduce(0) { $0 + $1.text.utf8.count } == 256 * 1024)
        feed(&t, [finalText("other message", message: "m2")])                          // another message has its own 256 KiB
        #expect(t.entries.last?.text == "other message")
        var streamed = ChatTranscript()
        feed(&streamed, [delta(block, message: "s", index: 0), delta(block, message: "s", index: 1)])
        #expect(streamed.entries.filter { $0.kind == .assistant }.reduce(0) { $0 + $1.text.utf8.count } == 256 * 1024)
    }

    @Test func ChatTranscript_aSuccessResultsTextShowsOnlyWhenTheTurnHasNoAssistantText() {
        var lost = ChatTranscript()
        lost.appendUser("go")
        feed(&lost, ["{\"type\":\"assistant\",\"message\":{\"id\":\"m\",\"content\":[{\"type\":\"text\",\"text\":", result(text: "the answer")])
        #expect(lines(lost) == ["user: go", "notice: Some output from Claude Code could not be read", "assistant: the answer", "footer: 1.0 s, $0.1000 (reported by Claude Code)"])
        var seen = ChatTranscript()
        seen.appendUser("go")
        feed(&seen, [finalText("the answer"), result(text: "the answer")])
        #expect(lines(seen) == ["user: go", "assistant: the answer", "footer: 1.0 s, $0.1000 (reported by Claude Code)"])
        feed(&seen, [result(cost: 0.2, text: "second turn result")])                    // the flag was reset: this turn had no assistant text
        #expect(lines(seen).contains("assistant: second turn result"))
        var big = ChatTranscript()
        big.apply(.result(outcome: .success, durationMs: 1, totalCost: 0, sessionId: "s", text: String(repeating: "r", count: 300 * 1024)))
        #expect(big.entries.first?.text.utf8.count == 256 * 1024)
        var empty = ChatTranscript()
        feed(&empty, [result(text: "")])
        #expect(empty.entries.count == 1 && empty.entries[0].kind == .footer)
    }

    @Test func ChatTranscript_aSuccessResultsTextCompletesAnAnswerThatNeverFinalized() {
        func assistant(_ t: ChatTranscript) -> [String] { t.entries.filter { $0.kind == .assistant }.map(\.text) }
        // Trigger: the answer streamed one delta, then the rest of the deltas and the final line are malformed; the result carries the whole answer.
        var partial = ChatTranscript()
        partial.appendUser("go")
        feed(&partial, [blockStart(0), delta("Hello "), malformedLine, malformedLine, result(text: "Hello world!")])
        #expect(assistant(partial) == ["Hello world!"])
        // Trigger: only an interim explanation arrived (finalized); the answer block's lines are all malformed; the answer is in the result.
        var interim = ChatTranscript()
        interim.appendUser("go")
        feed(&interim, [blockStart(0), delta("Let me check"), finalText("Let me check"), blockStop(0), blockStart(1), malformedLine, malformedLine, blockStop(1),
                        result(text: "The answer is 4")])
        #expect(assistant(interim) == ["Let me check", "The answer is 4"])
        // The answer block started but nothing of it was read; the interim block lost its final line.
        var empty = ChatTranscript()
        feed(&empty, [blockStart(0), delta("Let me check"), blockStop(0), blockStart(1), blockStop(1), result(text: "The answer is 4")])
        #expect(assistant(empty) == ["Let me check", "The answer is 4"])
        // Never both: the final answer arrived whole, so the result adds nothing, also when only whitespace differs.
        var whole = ChatTranscript()
        feed(&whole, [blockStart(0), delta("The answer"), finalText("The answer is 4 "), blockStop(0), result(text: "The answer is 4")])
        #expect(assistant(whole) == ["The answer is 4 "])
        // A partial answer replaced by a result over the cap is cut like any entry, with the notice.
        var big = ChatTranscript()
        feed(&big, [blockStart(0), delta("partial"), malformedLine])
        big.apply(.result(outcome: .success, durationMs: 1, totalCost: 0, sessionId: "s", text: String(repeating: "r", count: 300 * 1024)))
        #expect(assistant(big).count == 1 && assistant(big)[0].utf8.count == 256 * 1024)
        #expect(big.entries.contains { $0.text == ChatTranscript.elidedNotice })
    }

    @Test func ChatTranscript_repeatedRateLimitRejectionsKeepOneNoticeRowPerWindowType() {
        var t = ChatTranscript(timeZone: TimeZone(identifier: "UTC")!)
        for number in 0..<2_000 {
            t.apply(.rateLimit(status: "rejected", type: "five_hour", resetsAt: 1_790_000_000 + Double(number) * 60, utilization: nil))
        }
        #expect(t.bookkeepingCount == 1)                                               // the latest reset of the one window type, nothing per rejection
        t.apply(.rateLimit(status: "rejected", type: "seven_day", resetsAt: 1_790_000_000, utilization: nil))
        #expect(t.bookkeepingCount == 2)
        let shown = t.entries.filter { $0.kind == .notice }.count
        t.apply(.rateLimit(status: "rejected", type: "seven_day", resetsAt: 1_790_000_000, utilization: nil))      // the same reset again is not a new notice
        #expect(t.entries.filter { $0.kind == .notice }.count == shown)
    }

    @Test func ChatTranscript_aRateLimitWarningShowsOncePerWindowType() {
        var t = ChatTranscript(timeZone: TimeZone(identifier: "UTC")!)
        let warn = { (type: String, utilization: String) in
            #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","rateLimitType":"\#(type)","utilization":\#(utilization),"resetsAt":1792940400}}"#
        }
        feed(&t, [warn("seven_day", "0.96"), warn("seven_day", "0.97"), warn("five_hour", "0.8"), warn("seven_day", "0.99")])
        #expect(lines(t) == ["notice: 7-day usage at 96%", "notice: 5-hour usage at 80%"])
        feed(&t, [#"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","rateLimitType":"five_hour"}}"#])
        #expect(t.entries.count == 2)
    }

    @Test func ChatTranscript_aRejectedLimitNamesTheResetTimeAndAnErrorDoesNotRepeatIt() {
        var t = ChatTranscript(timeZone: TimeZone(identifier: "UTC")!)
        t.appendUser("go")
        feed(&t, [
            #"{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","rateLimitType":"five_hour","resetsAt":1792807200}}"#,
            #"{"type":"assistant","message":{"id":"m","content":[]},"error":"rate_limit"}"#,
        ])
        #expect(lines(t) == ["user: go", "notice: Usage limit reached, resets Oct 24, 02:00"])
        var bare = ChatTranscript()
        feed(&bare, [#"{"type":"assistant","message":{"id":"m","content":[]},"error":"rate_limit"}"#])
        #expect(lines(bare) == ["error: Usage limit reached"])
    }

    @Test func ChatTranscript_failuresReadAsF25Says() {
        var t = ChatTranscript()
        feed(&t, [
            #"{"type":"assistant","message":{"id":"m","content":[]},"error":"authentication_failed"}"#,
            #"{"type":"assistant","message":{"id":"m","content":[]},"error":"authentication_failed"}"#,
            #"{"type":"system","subtype":"api_retry","attempt":1,"max_retries":3}"#,
            #"{"type":"system","subtype":"api_retry","attempt":2,"max_retries":3}"#,
            #"{"type":"system","subtype":"hook_response","hook_name":"SessionStart:startup","exit_code":7,"outcome":"error"}"#,
            #"{"type":"system","subtype":"hook_response","hook_name":"SessionStart:startup","exit_code":0,"outcome":"success"}"#,
            #"{"type":"system","subtype":"compact_boundary"}"#,
            "garbage", "more garbage",
        ])
        t.apply(.oversized)
        #expect(lines(t) == [
            "notice: " + ChatTranscript.notLoggedIn,
            "notice: Retrying (attempt 2 of 3)",
            "notice: Hook SessionStart:startup did not succeed (exit 7)",
            "notice: Conversation compacted",
            "notice: Some output from Claude Code could not be read",
            "notice: A very long line from Claude Code was skipped",
        ])
        #expect(t.parseErrorCount == 2)
        feed(&t, [result(error: true, text: "")])
        #expect(lines(t).suffix(2).first == "error: Claude Code reported an error")
    }

    @Test func ChatTranscript_initDifferencesFromTheRequestGiveOneNoticeEach() {
        var t = ChatTranscript()
        t.expectedSessionId = "11111111-1111-1111-1111-111111111111"
        t.expectedPermissionMode = "bypassPermissions"
        let init2 = #"{"type":"system","subtype":"init","session_id":"22222222-2222-2222-2222-222222222222","model":"m","permissionMode":"default","claude_code_version":"2.1.309"}"#
        feed(&t, [init2, init2])
        #expect(t.sessionId == "22222222-2222-2222-2222-222222222222")      // follows the latest init, not the request
        #expect(t.entries.count == 2 && t.entries.allSatisfy { $0.kind == .notice })
        var same = ChatTranscript()
        same.expectedSessionId = "22222222-2222-2222-2222-222222222222"
        same.expectedPermissionMode = "default"
        feed(&same, [init2])
        #expect(same.entries.isEmpty)
    }

    @Test func ChatTranscript_aSecondTurnsCostIsTheDifferenceAndAResetCountsFromZero() {
        var t = ChatTranscript()
        feed(&t, [result(ms: 2000, cost: 0.30), result(ms: 3000, cost: 0.50), result(ms: 1000, cost: 0.05)])
        let costs = t.entries.filter { $0.kind == .footer }.map { $0.cost ?? -1 }
        #expect(abs(costs[0] - 0.30) < 1e-9 && abs(costs[1] - 0.20) < 1e-9 && abs(costs[2] - 0.05) < 1e-9)
    }
}
