import Testing
import Foundation
import ClawdCore

func chatFixtureLines(_ name: String) throws -> [String] {
    try fixture("chat/" + name).split(separator: "\n", omittingEmptySubsequences: true).map(String.init)
}
func chatEvents(_ name: String) throws -> [ChatEvent] {
    try chatFixtureLines(name).flatMap { ChatStreamParser.parse(line: $0) }
}
func chatParseOne(_ json: String) -> [ChatEvent] { ChatStreamParser.parse(line: json) }

private func isParseError(_ events: [ChatEvent]) -> Bool {
    if events.count == 1, case .parseError = events[0] { return true }
    return false
}

/// A short, comparable form of an event; adjacent repeats collapse to `x N`.
private func digest(_ events: [ChatEvent]) -> [String] {
    var runs: [(text: String, count: Int)] = []
    for event in events {
        let text = describe(event)
        if let last = runs.last, last.text == text { runs[runs.count - 1].count += 1 } else { runs.append((text, 1)) }
    }
    return runs.map { $0.count > 1 ? "\($0.text) x\($0.count)" : $0.text }
}
private func describe(_ event: ChatEvent) -> String {
    switch event {
    case .initialized(let session, _, let mode, let version, _): return "init \(session.suffix(2)) \(mode) \(version)"
    case .textDelta(_, let index, _): return "delta[\(index)]"
    case .blockStarted(_, let index, let isText): return "start[\(index)] " + (isText ? "text" : "other")
    case .blockStopped(_, let index): return "stop[\(index)]"
    case .assistantBlocks(_, let blocks):
        return "blocks " + blocks.map { block -> String in
            switch block {
            case .text(let t): return "text(\(t.prefix(12)))"
            case .toolUse(_, let name): return "tool(\(name))"
            }
        }.joined(separator: ",")
    case .toolStarted(_, let name): return "toolStarted \(name)"
    case .toolInput(_, let summary): return "toolInput \(summary)"
    case .toolResult(_, let isError): return "toolResult error=\(isError)"
    case .toolProgress(_, let seconds): return "toolProgress \(seconds)"
    case .retry(let a, let m): return "retry \(a)/\(m)"
    case .rateLimit(let status, let type, _, let utilization): return "rate \(status) \(type) \(utilization.map { String($0) } ?? "-")"
    case .assistantError(let kind): return "assistantError \(kind)"
    case .hook(let name, let code, let outcome): return "hook \(name) \(code) \(outcome)"
    case .compacted: return "compacted"
    case .commandCatalog(let frame):
        switch frame.body {
        case .names(let names, _, let hidden): return "catalog names \(names.count) hidden \(hidden.count)"
        case .descriptors(let descriptors): return "catalog descriptors \(descriptors.count)"
        }
    case .conversationReset(let trigger, _): return "reset \(trigger)"
    case .controlResponse(let id, let ok, let still, let cancelled, let withdrawn): return "response \(id.suffix(2)) \(ok) \(still.count) \(cancelled.count) \(withdrawn)"
    case .replay(let uuid): return "replay \(uuid.suffix(2))"
    case .sessionState(let state): return "state \(state)"
    case .commandLifecycle(let uuid, let state): return "lifecycle \(uuid.suffix(2)) \(state)"
    case .result(let outcome, let ms, _, _, _, _): return "result \(outcome) \(ms)"
    case .controlRequest(_, let subtype, _): return "control \(subtype)"
    case .controlCancel: return "cancel"
    case .parseError(let reason): return "parseError \(reason)"
    case .oversized: return "oversized"
    case .ignored(let type): return "ignored \(type)"
    }
}

@Suite("Chat stream parser")
struct ChatParseSuite {
    @Test func ChatParse_theSingleTurnProbeParsesToItsEventSequence() throws {
        #expect(digest(try chatEvents("probe.jsonl")) == [
            "hook SessionStart:startup 0 success x4",
            "init 01 default 2.1.309",
            "catalog names 3 hidden 4",
            "catalog descriptors 2",
            "blocks text(ok)",
            "rate allowed_warning seven_day 0.96",
            "result success 4756",
        ])
    }

    @Test func ChatParse_theTwoTurnCaptureParsesToItsEventSequence() throws {
        let events = try chatEvents("p1-two-turns.jsonl")
        #expect(digest(events) == [
            "hook SessionStart:startup 0 success x4",
            "init 01 bypassPermissions 2.1.309",
            "catalog names 3 hidden 4",
            "catalog descriptors 2",
            "ignored system/status",
            "start[0] other",
            "stop[0]",
            "start[1] text",
            "delta[1]",
            "blocks text(ok)",
            "stop[1]",
            "rate allowed five_hour 0.35",
            "result success 6612",
            "init 01 bypassPermissions 2.1.309",
            "catalog names 3 hidden 4",
            "ignored system/status",
            "start[0] other",
            "toolStarted Write",
            "blocks tool(Write)",
            "toolInput /private/tmp/clawd-p1.example/hello.txt",
            "stop[0]",
            "toolResult error=false",
            "ignored system/status",
            "start[0] other",
            "stop[0]",
            "start[1] other",
            "toolStarted Bash",
            "blocks tool(Bash)",
            "toolInput cat /private/tmp/clawd-p1.example/hello.txt",
            "stop[1]",
            "rate allowed five_hour 0.36",
            "toolResult error=false",
            "ignored system/status",
            "start[0] text",
            "delta[0] x10",
            "blocks text(done. `/priv)",
            "stop[0]",
            "result success 12275",
        ])
        let streamed = events.compactMap { event -> String? in
            if case .textDelta(_, 0, let text) = event { return text }
            return nil
        }.joined()
        #expect(streamed == "done. `/private/tmp/clawd-p1.example/hello.txt` contains `hi`; I checked it with `cat hello.txt`, which printed `hi`.")
    }

    @Test func ChatParse_everyBypassFormInitsAsBypassPermissions() throws {
        for name in ["p1-bypass-allow-flag.jsonl", "p1-bypass-dangerous-flag.jsonl", "p1-two-turns.jsonl"] {
            let modes = try chatEvents(name).compactMap { event -> String? in
                if case .initialized(_, _, let mode, _, _) = event { return mode }
                return nil
            }
            #expect(!modes.isEmpty && modes.allSatisfy { $0 == "bypassPermissions" }, "\(name)")
        }
        let results = try chatEvents("p1-bypass-allow-flag.jsonl").filter { if case .result = $0 { return true } else { return false } }
        #expect(results.count == 1)
    }

    @Test func ChatParse_noLineOfAnyFixtureIsAParseError() throws {
        for name in ["probe.jsonl", "p1-bypass-allow-flag.jsonl", "p1-bypass-dangerous-flag.jsonl", "p1-two-turns.jsonl"] {
            for line in try chatFixtureLines(name) {
                for event in ChatStreamParser.parse(line: line) {
                    if case .parseError(let reason) = event { Issue.record("\(name): \(reason)") }
                }
            }
        }
    }

    @Test func ChatParse_assistantLinesOfTheFixturesCarryOneBlockEach() throws {
        for line in try chatFixtureLines("p1-two-turns.jsonl") {
            guard let data = line.data(using: .utf8), let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  object["type"] as? String == "assistant", let message = object["message"] as? [String: Any],
                  let content = message["content"] as? [Any] else { continue }
            #expect(content.count == 1)
        }
    }

    @Test func ChatParse_unknownTypesAndSubtypesAreIgnoredAndCounted() {
        #expect(chatParseOne(#"{"type":"future_thing","x":1}"#) == [.ignored(type: "future_thing")])
        #expect(chatParseOne(#"{"type":"system","subtype":"brand_new"}"#) == [.ignored(type: "system/brand_new")])
        #expect(chatParseOne(#"{"type":"stream_event","event":{"type":"brand_new"},"parent_tool_use_id":null}"#) == [.ignored(type: "stream_event/brand_new")])
        #expect(chatParseOne(#"{"type":"keep_alive"}"#) == [.ignored(type: "keep_alive")])
        #expect(chatParseOne(#"{"type":"user","message":{"role":"user","content":"hello"}}"#) == [.ignored(type: "user")])
        #expect(chatParseOne("   \n").isEmpty)
    }

    @Test func ChatParse_nonJsonTruncatedAndWrongTypedLinesGiveParseErrors() {
        let bad = [
            "this is not json",
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","te"#,
            "[1,2,3]",
            #"{"type":5}"#,
            #"{"subtype":"init"}"#,
            #"{"type":"system","subtype":["init"]}"#,
            #"{"type":"system","subtype":"init","session_id":42}"#,
            #"{"type":"stream_event","event":"oops"}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":5}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":"zero","delta":{"type":"text_delta","text":"a"}}}"#,
            #"{"type":"assistant","message":{"id":"m","content":7}}"#,
            #"{"type":"assistant","message":{"id":"m","content":[{"type":"text","text":{"a":1}}]}}"#,
            #"{"type":"assistant","message":{"id":"m","content":[{"type":"tool_use","id":1,"name":"Bash","input":{}}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":["x"]}]}}"#,
            #"{"type":"user","message":{"content":{"a":1}}}"#,
            #"{"type":"result","subtype":"success","session_id":"s","duration_ms":"fast"}"#,
            #"{"type":"rate_limit_event","rate_limit_info":{"status":3}}"#,
            #"{"type":"tool_progress","tool_use_id":"t","elapsed_time_seconds":"long"}"#,
            #"{"type":"control_request","request_id":1,"request":{"subtype":"x"}}"#,
        ]
        for line in bad { #expect(isParseError(chatParseOne(line)), "\(line)") }
        let deep = String(repeating: "[", count: 20000)
        #expect(isParseError(chatParseOne(deep)))
    }

    @Test func ChatParse_parseErrorReasonsNeverCarryTheLinesContent() {
        let secret = "SECRET-WORDS-IN-THE-LINE"
        for line in [#"{"type":"assistant","message":{"id":"\#(secret)","content":7}}"#, #"{"type":"\#(secret)""#, #"{"type":["\#(secret)"]}"#] {
            for event in chatParseOne(line) {
                if case .parseError(let reason) = event { #expect(!reason.contains(secret)) }
            }
        }
    }

    @Test func ChatParse_subagentMessagesProduceNoTranscriptEvents() {
        let child = #""parent_tool_use_id":"toolu_parent""#
        #expect(chatParseOne(#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"hidden"}},"api_message_id":"m",\#(child)}"#)
                == [.ignored(type: "stream_event/subagent")])
        #expect(chatParseOne(#"{"type":"assistant","message":{"id":"m","content":[{"type":"text","text":"hidden"},{"type":"tool_use","id":"t","name":"Bash","input":{"command":"ls"}}]},\#(child)}"#)
                == [.ignored(type: "assistant/subagent")])
        #expect(chatParseOne(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","is_error":true}]},\#(child)}"#)
                == [.ignored(type: "user/subagent")])
        #expect(chatParseOne(#"{"type":"tool_progress","tool_use_id":"t","elapsed_time_seconds":3,\#(child)}"#) == [.ignored(type: "tool_progress/subagent")])
        // The same shapes on the main thread (null parent) do produce events.
        #expect(chatParseOne(#"{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"shown"}},"api_message_id":"m","parent_tool_use_id":null}"#)
                == [.textDelta(messageKey: "m", blockIndex: 0, text: "shown")])
    }

    @Test func ChatParse_toolSummariesFollowTheTableAndAreCut() {
        func summary(_ tool: String, _ input: String) -> String? {
            let line = #"{"type":"assistant","message":{"id":"m","content":[{"type":"tool_use","id":"t","name":"\#(tool)","input":\#(input)}]}}"#
            for event in chatParseOne(line) { if case .toolInput(_, let text) = event { return text } }
            return nil
        }
        #expect(summary("Bash", #"{"command":"ls -la\nrm nothing"}"#) == "ls -la")
        #expect(summary("Read", #"{"file_path":"/a/b.swift"}"#) == "/a/b.swift")
        #expect(summary("Edit", #"{"file_path":"/a/c.swift","old_string":"x"}"#) == "/a/c.swift")
        #expect(summary("Write", #"{"file_path":"/a/d.txt","content":"hi"}"#) == "/a/d.txt")
        #expect(summary("NotebookEdit", #"{"file_path":"/a/n.ipynb"}"#) == "/a/n.ipynb")
        #expect(summary("Grep", #"{"pattern":"foo.*bar"}"#) == "foo.*bar")
        #expect(summary("Glob", #"{"pattern":"**/*.swift"}"#) == "**/*.swift")
        #expect(summary("Task", #"{"description":"find the bug"}"#) == "find the bug")
        #expect(summary("Agent", #"{"description":"review"}"#) == "review")
        #expect(summary("WebFetch", #"{"url":"https://example.invalid/x"}"#) == "https://example.invalid/x")
        #expect(summary("WebSearch", #"{"query":"swift testing"}"#) == "swift testing")
        #expect(summary("TodoWrite", #"{"todos":[]}"#) == nil)
        #expect(summary("Bash", #"{"command":null}"#) == nil)
        #expect(summary("Bash", #"{}"#) == nil)
        let long = String(repeating: "x", count: 300)
        #expect(summary("Bash", #"{"command":"\#(long)"}"#)?.count == 120)
        let wide = String(repeating: "\u{65E5}", count: 200)
        #expect(summary("Bash", #"{"command":"\#(wide)"}"#)?.count == 120)
    }

    @Test func ChatParse_aNonFiniteOrHugeUtilizationOrResetIsAParseErrorNotAnEvent() {
        func rate(_ fields: String) -> [ChatEvent] {
            chatParseOne(#"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed_warning","rateLimitType":"five_hour",\#(fields)}}"#)
        }
        for fields in [#""utilization":1e100"#, #""utilization":1e999"#, #""utilization":-1"#, #""utilization":100000"#,
                       #""resetsAt":1e100"#, #""resetsAt":-5"#, #""unifiedWindows":{"five_hour":{"utilization":1e100}}"#] {
            #expect(isParseError(rate(fields)), "\(fields)")
        }
        #expect(rate(#""utilization":0.96"#) == [.rateLimit(status: "allowed_warning", type: "five_hour", resetsAt: nil, utilization: 0.96)])
        #expect(rate(#""utilization":96,"resetsAt":1792940400"#) == [.rateLimit(status: "allowed_warning", type: "five_hour", resetsAt: 1792940400, utilization: 96)])
    }

    @Test func ChatParse_aBooleanIsNeverANumberAndAFractionIsNeverAnInteger() {
        let bad = [
            #"{"type":"result","subtype":"success","session_id":"s","duration_ms":true}"#,
            #"{"type":"result","subtype":"success","session_id":"s","total_cost_usd":false}"#,
            #"{"type":"result","subtype":"success","session_id":"s","duration_ms":1.5}"#,
            #"{"type":"result","subtype":"success","session_id":"s","duration_ms":1e300}"#,
            #"{"type":"tool_progress","tool_use_id":"t","elapsed_time_seconds":true}"#,
            #"{"type":"system","subtype":"api_retry","attempt":2.5,"max_retries":5}"#,
            #"{"type":"system","subtype":"api_retry","attempt":true,"max_retries":5}"#,
            #"{"type":"system","subtype":"hook_response","hook_name":"h","exit_code":0.5}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":0.5,"delta":{"type":"text_delta","text":"a"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_delta","index":true,"delta":{"type":"text_delta","text":"a"}}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_stop","index":true}}"#,
            #"{"type":"stream_event","event":{"type":"content_block_start","index":1.5,"content_block":{"type":"text"}}}"#,
            #"{"type":"rate_limit_event","rate_limit_info":{"status":"allowed","utilization":true}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","is_error":1}]}}"#,
            #"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","is_error":"true"}]}}"#,
            #"{"type":"result","subtype":"success","session_id":"s","is_error":0}"#,
        ]
        for line in bad { #expect(isParseError(chatParseOne(line)), "\(line)") }
        #expect(chatParseOne(#"{"type":"result","subtype":"success","session_id":"s","duration_ms":1500.0,"total_cost_usd":1}"#)
                == [.result(outcome: .success, durationMs: 1500, totalCost: 1, sessionId: "s", text: "")])
        #expect(chatParseOne(#"{"type":"user","message":{"content":[{"type":"tool_result","tool_use_id":"t","is_error":true}]}}"#) == [.toolResult(id: "t", isError: true)])
        #expect(chatParseOne(#"{"type":"stream_event","event":{"type":"content_block_stop","index":2},"api_message_id":"m"}"#) == [.blockStopped(messageKey: "m", blockIndex: 2)])
    }

    @Test func ChatParse_aWrongTypedFieldTheParserReadsIsAParseErrorArrayElementsIncluded() {
        func isError(_ line: String) -> Bool { isParseError(chatParseOne(line)) }
        let tool = { (name: String, input: String) in
            #"{"type":"assistant","message":{"id":"m","content":[{"type":"tool_use","id":"t","name":"\#(name)","input":\#(input)}]}}"#
        }
        #expect(isError(tool("Bash", #"{"command":5}"#)))
        #expect(isError(tool("Read", #"{"file_path":["a"]}"#)))
        #expect(isError(tool("Grep", #"{"pattern":{"a":1}}"#)))
        #expect(!isError(tool("Bash", #"{"command":"ls","timeout":5}"#)))          // a field the parser does not read may have any type
        #expect(!isError(tool("TodoWrite", #"{"todos":5}"#)))
        #expect(isError(#"{"type":"result","subtype":"error_during_execution","session_id":"s","errors":[5]}"#))
        #expect(isError(#"{"type":"result","subtype":"error_during_execution","session_id":"s","errors":["a",null]}"#))
        #expect(isError(#"{"type":"result","subtype":"error_during_execution","session_id":"s","errors":"boom"}"#))
        #expect(!isError(#"{"type":"result","subtype":"success","session_id":"s","result":"ok","errors":[5]}"#))      // errors are read only when result is empty
    }

    @Test func ChatParse_anUnknownResultSubtypeIsIgnoredAndCountedLikeAnyOther() {
        #expect(chatParseOne(#"{"type":"result","subtype":"brand_new","session_id":"s","duration_ms":5}"#) == [.ignored(type: "result/brand_new")])
        #expect(chatParseOne(#"{"type":"result","subtype":"brand_new"}"#) == [.ignored(type: "result/brand_new")])
        for subtype in ["success", "error_during_execution", "error_max_turns", "error_max_budget_usd", "error_max_structured_output_retries"] {
            let events = chatParseOne(#"{"type":"result","subtype":"\#(subtype)","session_id":"s","duration_ms":5,"total_cost_usd":0.5}"#)
            #expect(events == [.result(outcome: subtype == "success" ? .success : .error, durationMs: 5, totalCost: 0.5, sessionId: "s", text: "")], "\(subtype)")
        }
    }

    @Test func ChatParse_resultsRetriesHooksAndControlLinesAreRead() {
        #expect(chatParseOne(#"{"type":"result","subtype":"success","is_error":false,"result":"all done","duration_ms":1500,"total_cost_usd":0.25,"session_id":"s1"}"#)
                == [.result(outcome: .success, durationMs: 1500, totalCost: 0.25, sessionId: "s1", text: "all done")])
        #expect(chatParseOne(#"{"type":"result","subtype":"success","is_error":true,"result":"boom","duration_ms":10,"total_cost_usd":0,"session_id":"s1"}"#)
                == [.result(outcome: .error, durationMs: 10, totalCost: 0, sessionId: "s1", text: "boom")])
        #expect(chatParseOne(#"{"type":"result","subtype":"error_during_execution","duration_ms":10,"total_cost_usd":1,"session_id":"s1","errors":["one","two"]}"#)
                == [.result(outcome: .error, durationMs: 10, totalCost: 1, sessionId: "s1", text: "one\ntwo")])
        #expect(chatParseOne(#"{"type":"system","subtype":"api_retry","attempt":2,"max_retries":5,"retry_delay_ms":500,"error_status":529}"#) == [.retry(attempt: 2, max: 5)])
        #expect(chatParseOne(#"{"type":"system","subtype":"hook_response","hook_name":"SessionStart:startup","exit_code":2,"outcome":"error"}"#)
                == [.hook(name: "SessionStart:startup", exitCode: 2, outcome: "error")])
        #expect(chatParseOne(#"{"type":"system","subtype":"hook_started","hook_name":"x"}"#).isEmpty)
        #expect(chatParseOne(#"{"type":"system","subtype":"compact_boundary"}"#) == [.compacted])
        #expect(chatParseOne(#"{"type":"tool_progress","tool_use_id":"t9","elapsed_time_seconds":4.5}"#) == [.toolProgress(id: "t9", seconds: 4.5)])
        #expect(chatParseOne(#"{"type":"control_cancel_request","request_id":"r2"}"#) == [.controlCancel(id: "r2")])
        let request = chatParseOne(#"{"type":"control_request","request_id":"r1","request":{"subtype":"can_use_tool","tool_name":"Bash"}}"#)
        #expect(request == [.controlRequest(id: "r1", subtype: "can_use_tool", payload: #"{"subtype":"can_use_tool","tool_name":"Bash"}"#)])
        #expect(chatParseOne(#"{"type":"assistant","message":{"id":"m","content":[]},"error":"authentication_failed"}"#) == [.assistantError(kind: "authentication_failed")])
        #expect(chatParseOne(#"{"type":"rate_limit_event","rate_limit_info":{"status":"rejected","resetsAt":1792807200,"rateLimitType":"five_hour"}}"#)
                == [.rateLimit(status: "rejected", type: "five_hour", resetsAt: 1792807200, utilization: nil)])
    }
}
