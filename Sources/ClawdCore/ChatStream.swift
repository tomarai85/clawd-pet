import Foundation

/// One content block of a main-thread `assistant` line. Thinking blocks are dropped by the parser.
public enum ChatBlock: Equatable {
    case text(String)
    case toolUse(id: String, name: String)
}

public enum ChatResultOutcome: Equatable {
    case success
    case error
}

/// What one stdout line of `claude -p --output-format stream-json` means to Clawd. Every case is a value; nothing here keeps the raw line.
/// `messageKey` names the API message a text belongs to: the `message.id` of the final `assistant` lines, and for the stream the `api_message_id` of a
/// `stream_event` (the same id, as the fixtures show; the stream's own `message_start` line carries it in `event.message.id`). `blockIndex` is the
/// content block's index in that message, as `content_block_delta` carries it.
public enum ChatEvent: Equatable {
    /// `capabilities`: what the init frame says this CLI can do (`interrupt_cancel_queued_v1` is the one Q13 reads).
    case initialized(sessionId: String, model: String, permissionMode: String, version: String, capabilities: [String] = [])
    case textDelta(messageKey: String, blockIndex: Int, text: String)
    /// A content block opened / closed in the stream. In the P-1 captures a block's final `assistant` line sits after its last delta and before its
    /// stop, so the block that is open when a final text arrives is the block that text belongs to.
    case blockStarted(messageKey: String, blockIndex: Int, isText: Bool)
    case blockStopped(messageKey: String, blockIndex: Int)
    case assistantBlocks(messageKey: String, blocks: [ChatBlock])
    case toolStarted(id: String, name: String)
    case toolInput(id: String, summary: String)
    case toolResult(id: String, isError: Bool)
    case toolProgress(id: String, seconds: Double)
    case retry(attempt: Int, max: Int)
    case rateLimit(status: String, type: String, resetsAt: Double?, utilization: Double?)
    case assistantError(kind: String)
    case hook(name: String, exitCode: Int, outcome: String)
    case compacted
    /// The `/` catalog a frame carried: init's name arrays, or `commands_changed`'s descriptors (Q9).
    case commandCatalog(ChatCatalogFrame)
    /// The CLI started a new conversation (`/clear`): `trigger` says why and `newConversationId` is the id it reported for it (Q25).
    case conversationReset(trigger: String, newConversationId: String)
    /// `userMessageUuids`: the result's `user_message_uuids`, the uuids of the user frames this result answers; nil when the field is absent or is
    /// anything but an array of strings (Q13).
    case result(outcome: ChatResultOutcome, durationMs: Int, totalCost: Double, sessionId: String, text: String, userMessageUuids: [String]? = nil)
    /// A root `user` frame that is a replay of a user frame Clawd wrote (`isReplay: true`, a string uuid). Its content is never read (Q13).
    case replay(uuid: String)
    /// `system/session_state_changed` (Q13): `running`, `idle` or `requires_action`.
    case sessionState(String)
    /// `command_lifecycle` (Q13): the CLI's verdict on one user frame, named by the `uuid` Clawd gave it. `state` is `queued`, `started`,
    /// `completed`, `cancelled`, `discarded`, `refused` or a state a newer CLI adds.
    case commandLifecycle(uuid: String, state: String)
    case controlRequest(id: String, subtype: String, payload: String)
    case controlCancel(id: String)
    /// The CLI's answer to a control request Clawd wrote (Q13): `ok` says it succeeded; `stillQueued` and `cancelled` are the interrupt receipt's uuid
    /// lists (the sends an interrupt left queued, and the ones it withdrew when asked to), `withdrawn` the answer of `cancel_async_message`.
    case controlResponse(requestId: String, ok: Bool, stillQueued: [String], cancelled: [String], withdrawn: Bool)
    case parseError(reason: String)
    case oversized
    case ignored(type: String)
}

/// Pure parser for one stdout line. A subagent's messages (non-null `parent_tool_use_id`) never produce transcript events; they come back as
/// `.ignored`. Unknown types and subtypes come back as `.ignored`; text that is not JSON, or a known field of the wrong type, as `.parseError`
/// (the reason names the field, never its content). Nothing in here can trap on input.
public enum ChatStreamParser {
    public static let summaryLimit = 120
    /// A usage figure is a fraction (0.96) or a percentage (96); anything outside this range is not one.
    static let utilizationRange: ClosedRange<Double> = 0...1000
    /// `resetsAt` is an epoch in seconds (about 1.8e9 today); the bound only keeps a date formatter away from absurd values.
    static let resetsAtRange: ClosedRange<Double> = 0...1e13

    private struct Wrong: Error { let field: String }

    public static func parse(line: String) -> [ChatEvent] {
        if line.allSatisfy({ $0 == " " || $0 == "\t" || $0 == "\r" || $0 == "\n" }) { return [] }
        guard let data = line.data(using: .utf8),
              let root = try? JSONSerialization.jsonObject(with: data, options: []) else {
            return [.parseError(reason: "not json")]
        }
        guard let object = root as? [String: Any] else { return [.parseError(reason: "not an object")] }
        do { return try events(object) } catch let wrong as Wrong { return [.parseError(reason: "wrong type: " + wrong.field)] } catch {
            return [.parseError(reason: "unreadable")]
        }
    }

    // MARK: field access

    private static func string(_ d: [String: Any], _ key: String, path: String = "") throws -> String? {
        guard let value = d[key], !(value is NSNull) else { return nil }
        guard let text = value as? String else { throw Wrong(field: path + key) }
        return text
    }
    private static func object(_ d: [String: Any], _ key: String, path: String = "") throws -> [String: Any]? {
        guard let value = d[key], !(value is NSNull) else { return nil }
        guard let inner = value as? [String: Any] else { throw Wrong(field: path + key) }
        return inner
    }
    private static func array(_ d: [String: Any], _ key: String, path: String = "") throws -> [Any]? {
        guard let value = d[key], !(value is NSNull) else { return nil }
        guard let inner = value as? [Any] else { throw Wrong(field: path + key) }
        return inner
    }
    /// A JSON number: finite, never a JSON boolean (which Foundation also hands over as an NSNumber), and inside `range` when one is given.
    private static func number(_ d: [String: Any], _ key: String, path: String = "", in range: ClosedRange<Double>? = nil) throws -> Double? {
        guard let value = d[key], !(value is NSNull) else { return nil }
        guard let n = value as? NSNumber, CFGetTypeID(n) != CFBooleanGetTypeID(), n.doubleValue.isFinite, range?.contains(n.doubleValue) ?? true else {
            throw Wrong(field: path + key)
        }
        return n.doubleValue
    }
    /// A JSON number with no fraction that an Int holds exactly.
    private static func integer(_ d: [String: Any], _ key: String, path: String = "") throws -> Int? {
        guard let n = try number(d, key, path: path) else { return nil }
        guard n == n.rounded(.towardZero), abs(n) < 9e15 else { throw Wrong(field: path + key) }
        return Int(n)
    }
    private static func bool(_ d: [String: Any], _ key: String, path: String = "") throws -> Bool? {
        guard let value = d[key], !(value is NSNull) else { return nil }
        guard let n = value as? NSNumber, CFGetTypeID(n) == CFBooleanGetTypeID() else { throw Wrong(field: path + key) }
        return n.boolValue
    }

    // MARK: lines

    private static func events(_ d: [String: Any]) throws -> [ChatEvent] {
        guard let type = try string(d, "type") else { throw Wrong(field: "type") }
        let subagent = d["parent_tool_use_id"].map { !($0 is NSNull) } ?? false
        switch type {
        case "system": return try system(d)
        case "stream_event":
            if subagent { return [.ignored(type: "stream_event/subagent")] }
            return try streamEvent(d)
        case "assistant":
            if subagent { return [.ignored(type: "assistant/subagent")] }
            return try assistant(d)
        case "user":
            if subagent { return [.ignored(type: "user/subagent")] }
            return try user(d)
        case "tool_progress":
            if subagent { return [.ignored(type: "tool_progress/subagent")] }
            guard let id = try string(d, "tool_use_id"), let seconds = try number(d, "elapsed_time_seconds") else { throw Wrong(field: "tool_progress") }
            return [.toolProgress(id: id, seconds: seconds)]
        case "rate_limit_event": return try rateLimit(d)
        case "result": return try result(d)
        case "control_request":
            guard let id = try string(d, "request_id"), let request = try object(d, "request"), let subtype = try string(request, "subtype") else {
                throw Wrong(field: "control_request")
            }
            return [.controlRequest(id: id, subtype: subtype, payload: compact(request))]
        case "control_cancel_request":
            guard let id = try string(d, "request_id") else { throw Wrong(field: "request_id") }
            return [.controlCancel(id: id)]
        case "control_response":
            guard let response = try object(d, "response"), let id = try string(response, "request_id") else { return [.ignored(type: "control_response")] }
            let body = response["response"] as? [String: Any] ?? [:]
            func strings(_ key: String) -> [String] { (body[key] as? [Any])?.compactMap { $0 as? String } ?? [] }
            let withdrawn = (body["cancelled"] as? NSNumber).map { CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue } ?? false
            return [.controlResponse(requestId: id, ok: response["subtype"] as? String == "success", stillQueued: strings("still_queued"),
                                     cancelled: strings("cancelled"), withdrawn: withdrawn)]
        case "command_lifecycle":
            if subagent { return [.ignored(type: "command_lifecycle/subagent")] }
            guard let uuid = try string(d, "command_uuid"), let state = try string(d, "state") else { return [.ignored(type: "command_lifecycle")] }
            return [.commandLifecycle(uuid: uuid, state: state)]
        case "conversation_reset":
            if subagent { return [.ignored(type: "conversation_reset/subagent")] }
            return [.conversationReset(trigger: try string(d, "trigger") ?? "", newConversationId: try string(d, "new_conversation_id") ?? "")]
        default: return [.ignored(type: type)]
        }
    }

    private static func system(_ d: [String: Any]) throws -> [ChatEvent] {
        guard let subtype = try string(d, "subtype") else { throw Wrong(field: "subtype") }
        switch subtype {
        case "init":
            guard let session = try string(d, "session_id") else { throw Wrong(field: "session_id") }
            let started = ChatEvent.initialized(sessionId: session, model: try string(d, "model") ?? "", permissionMode: try string(d, "permissionMode") ?? "",
                                                version: try string(d, "claude_code_version") ?? "",
                                                capabilities: (d["capabilities"] as? [Any])?.compactMap { $0 as? String } ?? [])
            return [started] + (catalogFrame(d, subtype: subtype).map { [.commandCatalog($0)] } ?? [])
        case "hook_response":
            guard let name = try string(d, "hook_name") else { throw Wrong(field: "hook_name") }
            let code = try integer(d, "exit_code") ?? 0
            return [.hook(name: name, exitCode: code, outcome: try string(d, "outcome") ?? "")]
        case "api_retry":
            return [.retry(attempt: try integer(d, "attempt") ?? 0, max: try integer(d, "max_retries") ?? 0)]
        case "compact_boundary": return [.compacted]
        case "commands_changed":
            return catalogFrame(d, subtype: subtype).map { [.commandCatalog($0)] } ?? [.ignored(type: "system/commands_changed")]
        case "session_state_changed":
            guard let state = try string(d, "state"), ["running", "idle", "requires_action"].contains(state) else { return [.ignored(type: "system/session_state_changed")] }
            return [.sessionState(state)]
        case "hook_started": return []
        default: return [.ignored(type: "system/" + subtype)]
        }
    }

    /// Orca's reading of a catalog frame (MC/claude-slash-command-catalog.ts:99-103, 139-175): name arrays when `slash_commands` is an array, else
    /// descriptors when a `commands_changed` carries a `commands` array; any other shape carries no catalog.
    private static func catalogFrame(_ d: [String: Any], subtype: String) -> ChatCatalogFrame? {
        if d["slash_commands"] is [Any] {
            return ChatCatalogFrame(.names(slashCommands: ChatCatalogRules.names(d["slash_commands"]), skills: ChatCatalogRules.names(d["skills"]),
                                           terminal: ChatCatalogRules.names(d["terminal_slash_commands"])))
        }
        if subtype == "commands_changed", d["commands"] is [Any] { return ChatCatalogFrame(.descriptors(ChatCatalogRules.descriptors(d["commands"]))) }
        return nil
    }

    private static func streamEvent(_ d: [String: Any]) throws -> [ChatEvent] {
        guard let event = try object(d, "event"), let kind = try string(event, "type") else { throw Wrong(field: "event") }
        let key = try string(d, "api_message_id") ?? ""
        switch kind {
        case "content_block_start":
            guard let block = try object(event, "content_block", path: "event."), let blockType = try string(block, "type") else {
                throw Wrong(field: "event.content_block")
            }
            let opened = try integer(event, "index", path: "event.").map { [ChatEvent.blockStarted(messageKey: key, blockIndex: $0, isText: blockType == "text")] } ?? []
            if blockType == "tool_use" {
                guard let id = try string(block, "id"), let name = try string(block, "name") else { throw Wrong(field: "event.content_block.id") }
                return opened + [.toolStarted(id: id, name: name)]
            }
            return opened
        case "content_block_stop":
            return try integer(event, "index", path: "event.").map { [.blockStopped(messageKey: key, blockIndex: $0)] } ?? []
        case "content_block_delta":
            guard let delta = try object(event, "delta", path: "event."), let deltaType = try string(delta, "type") else { throw Wrong(field: "event.delta") }
            guard deltaType == "text_delta" else { return [] }
            guard let text = try string(delta, "text", path: "event.delta."), let index = try integer(event, "index", path: "event.") else {
                throw Wrong(field: "event.delta.text")
            }
            return [.textDelta(messageKey: key, blockIndex: index, text: text)]
        case "message_start", "message_delta", "message_stop": return []
        default: return [.ignored(type: "stream_event/" + kind)]
        }
    }

    private static func assistant(_ d: [String: Any]) throws -> [ChatEvent] {
        guard let message = try object(d, "message") else { throw Wrong(field: "message") }
        var events: [ChatEvent] = []
        var blocks: [ChatBlock] = []
        var inputs: [ChatEvent] = []
        for raw in try array(message, "content", path: "message.") ?? [] {
            guard let block = raw as? [String: Any], let type = try string(block, "type", path: "message.content.") else {
                throw Wrong(field: "message.content")
            }
            switch type {
            case "text":
                guard let text = try string(block, "text", path: "message.content.") else { throw Wrong(field: "message.content.text") }
                blocks.append(.text(text))
            case "tool_use":
                guard let id = try string(block, "id", path: "message.content."), let name = try string(block, "name", path: "message.content.") else {
                    throw Wrong(field: "message.content.id")
                }
                blocks.append(.toolUse(id: id, name: name))
                let input = try object(block, "input", path: "message.content.") ?? [:]
                let summary = try summarize(tool: name, input: input)
                if !summary.isEmpty { inputs.append(.toolInput(id: id, summary: summary)) }
            default: break
            }
        }
        if !blocks.isEmpty { events.append(.assistantBlocks(messageKey: try string(message, "id") ?? "", blocks: blocks)) }
        events.append(contentsOf: inputs)
        if let kind = try string(d, "error") { events.append(.assistantError(kind: kind)) }
        return events
    }

    private static func user(_ d: [String: Any]) throws -> [ChatEvent] {
        // A replay of a user frame Clawd wrote: only its uuid is read, never its content (it can hold a local command's whole output).
        if (d["isReplay"] as? NSNumber).map({ CFGetTypeID($0) == CFBooleanGetTypeID() && $0.boolValue }) == true {
            if let uuid = d["uuid"] as? String, !uuid.isEmpty { return [.replay(uuid: uuid)] }
            return [.ignored(type: "user/replay")]
        }
        guard let message = try object(d, "message") else { throw Wrong(field: "message") }
        if message["content"] == nil || message["content"] is NSNull || message["content"] is String { return [.ignored(type: "user")] }
        guard let content = message["content"] as? [Any] else { throw Wrong(field: "message.content") }
        var events: [ChatEvent] = []
        for raw in content {
            guard let block = raw as? [String: Any] else { throw Wrong(field: "message.content") }
            guard try string(block, "type", path: "message.content.") == "tool_result" else { continue }
            guard let id = try string(block, "tool_use_id", path: "message.content.") else { throw Wrong(field: "message.content.tool_use_id") }
            events.append(.toolResult(id: id, isError: try bool(block, "is_error", path: "message.content.") ?? false))
        }
        return events
    }

    private static func rateLimit(_ d: [String: Any]) throws -> [ChatEvent] {
        guard let info = try object(d, "rate_limit_info"), let status = try string(info, "status") else { throw Wrong(field: "rate_limit_info") }
        let type = try string(info, "rateLimitType") ?? ""
        var utilization = try number(info, "utilization", path: "rate_limit_info.", in: utilizationRange)
        if utilization == nil, let windows = try object(info, "unifiedWindows", path: "rate_limit_info."), let window = try object(windows, type) {
            utilization = try number(window, "utilization", in: utilizationRange)
        }
        return [.rateLimit(status: status, type: type, resetsAt: try number(info, "resetsAt", path: "rate_limit_info.", in: resetsAtRange), utilization: utilization)]
    }

    private static let resultSubtypes: Set<String> = ["success", "error_during_execution", "error_max_turns", "error_max_budget_usd", "error_max_structured_output_retries"]

    private static func result(_ d: [String: Any]) throws -> [ChatEvent] {
        guard let subtype = try string(d, "subtype") else { throw Wrong(field: "result") }
        guard resultSubtypes.contains(subtype) else { return [.ignored(type: "result/" + subtype)] }
        guard let session = try string(d, "session_id") else { throw Wrong(field: "result") }
        let flagged = try bool(d, "is_error") ?? false
        var text = try string(d, "result") ?? ""
        if text.isEmpty, let errors = try array(d, "errors") {
            text = try errors.map { element -> String in
                guard let line = element as? String else { throw Wrong(field: "errors") }
                return line
            }.joined(separator: "\n")
        }
        return [.result(outcome: flagged || subtype != "success" ? .error : .success, durationMs: try integer(d, "duration_ms") ?? 0,
                        totalCost: try number(d, "total_cost_usd") ?? 0, sessionId: session, text: text, userMessageUuids: messageUuids(d))]
    }

    // MARK: helpers

    /// The result's `user_message_uuids`: an array of strings, else absent.
    private static func messageUuids(_ d: [String: Any]) -> [String]? {
        guard let raw = d["user_message_uuids"] as? [Any] else { return nil }
        let strings = raw.compactMap { $0 as? String }
        return strings.count == raw.count ? strings : nil
    }

    /// One line of what a tool is doing, per F3: Bash the first line of the command, file tools the path, Grep/Glob the pattern, Task/Agent the
    /// description, WebFetch the url, WebSearch the query; every other tool shows its name only. Cut to `summaryLimit` characters.
    static func summarize(tool: String, input: [String: Any]) throws -> String {
        let key: String
        switch tool {
        case "Bash": key = "command"
        case "Read", "Edit", "Write", "NotebookEdit": key = "file_path"
        case "Grep", "Glob": key = "pattern"
        case "Task", "Agent": key = "description"
        case "WebFetch": key = "url"
        case "WebSearch": key = "query"
        default: return ""
        }
        guard let raw = input[key], !(raw is NSNull) else { return "" }
        guard let value = raw as? String else { throw Wrong(field: "message.content.input." + key) }
        let first = value.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false).first.map(String.init) ?? ""
        return String(first.prefix(summaryLimit))
    }

    private static func compact(_ value: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: value, options: [.sortedKeys]) else { return "{}" }
        return String(decoding: data, as: UTF8.self)
    }
}
