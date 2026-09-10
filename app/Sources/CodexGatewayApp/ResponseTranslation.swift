import Foundation

/// Translates between Codex's Responses items and OpenAI chat-completions
/// messages.
enum ResponseTranslation {

    static func extractText(_ content: Any?) -> String {
        guard let content = content else { return "" }
        if let s = content as? String { return s }
        if let parts = content as? [Any] {
            var out: [String] = []
            for p in parts {
                if let s = p as? String { out.append(s) }
                else if let d = p as? [String: Any] {
                    let type = d["type"] as? String
                    if type == "input_text" || type == "output_text" || type == "text" {
                        if let text = d["text"] as? String { out.append(text) }
                    }
                }
            }
            return out.joined(separator: "\n")
        }
        return ""
    }

    /// One Chat Completions assistant message is one model turn: visible text,
    /// thinking and tool calls live in the same object. DeepSeek's thinking mode
    /// rejects a request that carries `tools` unless each replayed turn still has
    /// its `reasoning_content`, so reasoning has to survive the round trip.
    static func responsesToMessages(_ body: [String: Any]) -> [Any] {
        var messages: [Any] = []
        if let instructions = body["instructions"] {
            var text = ""
            if let s = instructions as? String { text = s }
            else if let arr = instructions as? [Any] { text = extractText(arr) }
            if !text.isEmpty { messages.append(["role": "system", "content": text]) }
        }

        var assistant: [String: Any]? = nil
        var pendingReasoning: String? = nil

        func turn() -> [String: Any] {
            var current = assistant ?? ["role": "assistant", "content": ""]
            if let reasoning = pendingReasoning {
                current["reasoning_content"] = reasoning
                pendingReasoning = nil
            }
            assistant = current
            return current
        }

        func flush() {
            guard let current = assistant else { return }
            var a = current
            if let reasoning = pendingReasoning {
                a["reasoning_content"] = reasoning
                pendingReasoning = nil
            }
            let hasContent = !((a["content"] as? String) ?? "").isEmpty
            let hasReasoning = !((a["reasoning_content"] as? String) ?? "").isEmpty
            let hasTools = !((a["tool_calls"] as? [Any]) ?? []).isEmpty
            if !hasTools { a.removeValue(forKey: "tool_calls") }
            if hasContent || hasReasoning || hasTools { messages.append(a) }
            assistant = nil
        }

        let input = body["input"]
        if let s = input as? String {
            messages.append(["role": "user", "content": s])
            return messages
        }
        guard let items = input as? [Any] else { return messages }

        for item in items {
            guard let it = item as? [String: Any] else { continue }
            switch (it["type"] as? String) ?? (it["role"] != nil ? "message" : "") {
            case "message":
                let inputRole = (it["role"] as? String) ?? "user"
                let role = inputRole == "developer" ? "system" : inputRole
                if role == "assistant" {
                    var a = turn()
                    let text = extractText(it["content"])
                    let existing = (a["content"] as? String) ?? ""
                    if !text.isEmpty { a["content"] = existing.isEmpty ? text : existing + "\n" + text }
                    assistant = a
                } else {
                    flush()
                    pendingReasoning = nil
                    messages.append(["role": role, "content": extractText(it["content"])])
                }
            case "function_call":
                var a = turn()
                let callID = (it["call_id"] as? String) ?? (it["id"] as? String) ?? "call_\(messages.count)"
                var tools = (a["tool_calls"] as? [Any]) ?? []
                tools.append([
                    "id": callID,
                    "type": "function",
                    "function": [
                        "name": (it["name"] as? String) ?? "",
                        "arguments": (it["arguments"] as? String) ?? "{}",
                    ],
                ])
                a["tool_calls"] = tools
                assistant = a
            case "function_call_output":
                flush()
                let callID = (it["call_id"] as? String) ?? (it["id"] as? String) ?? ""
                var output = it["output"]
                if output is [Any] || output is [String: Any] {
                    output = jsonString(output as Any)
                }
                messages.append([
                    "role": "tool",
                    "tool_call_id": callID,
                    "content": "\(output as? String ?? "")",
                ])
            case "reasoning":
                var text = ""
                if let summary = it["summary"] as? [Any] {
                    text = summary.compactMap { ($0 as? [String: Any])?["text"] as? String }.joined(separator: "\n")
                } else if let s = it["summary"] as? String {
                    text = s
                }
                if !text.isEmpty { pendingReasoning = text }
            default:
                break
            }
        }
        flush()
        return messages
    }

    /// DeepSeek's thinking mode rejects any request that carries `tools` while an
    /// assistant message in the history has no `reasoning_content` — including
    /// turns that never called a tool. Real thinking is carried by
    /// ``responsesToMessages(_:)``; this only backfills history whose reasoning a
    /// client already dropped, where an empty value is all that can be recovered.
    static func backfillReasoningContent(_ messages: [Any]) -> [Any] {
        messages.map { message in
            guard var m = message as? [String: Any], (m["role"] as? String) == "assistant",
                  m["reasoning_content"] == nil else { return message }
            m["reasoning_content"] = ""
            return m
        }
    }

    /// Third-party Responses backends pair a `function_call` with its
    /// `function_call_output` by position. When a model returns visible text and a
    /// tool call in one turn, Codex emits `function_call`, then that assistant
    /// message, then the output — such backends answer "No tool output found for
    /// tool call <id>". Move the interleaved assistant messages in front of the
    /// call so the pair stays contiguous.
    static func normalizeToolCallOrder(_ body: [String: Any]) -> [String: Any] {
        func type(_ item: Any) -> String? { (item as? [String: Any])?["type"] as? String }
        func callID(_ item: Any) -> String? {
            let item = item as? [String: Any]
            return (item?["call_id"] as? String) ?? (item?["id"] as? String)
        }
        guard let items = body["input"] as? [Any] else { return body }
        var ordered: [Any] = []
        ordered.reserveCapacity(items.count)
        var index = 0
        while index < items.count {
            guard type(items[index]) == "function_call" else { ordered.append(items[index]); index += 1; continue }
            var calls: [Any] = [], callIDs = Set<String>()
            var next = index
            while next < items.count, type(items[next]) == "function_call" {
                if let id = callID(items[next]) { callIDs.insert(id) }
                calls.append(items[next]); next += 1
            }
            var texts: [Any] = [], afterText = next
            while afterText < items.count, type(items[afterText]) == "message",
                  (items[afterText] as? [String: Any])?["role"] as? String == "assistant" {
                texts.append(items[afterText]); afterText += 1
            }
            let answered = afterText < items.count && type(items[afterText]) == "function_call_output"
                && callIDs.contains(callID(items[afterText]) ?? "")
            if !texts.isEmpty, answered {
                ordered.append(contentsOf: texts); ordered.append(contentsOf: calls); index = afterText
            } else {
                ordered.append(contentsOf: calls); index = next
            }
        }
        guard ordered.count == items.count else { return body }
        var body = body
        body["input"] = ordered
        return body
    }

    static func responsesToChatTools(_ body: [String: Any]) -> [Any] {
        var tools: [Any] = []
        for tool in (body["tools"] as? [Any]) ?? [] {
            guard let t = tool as? [String: Any], (t["type"] as? String) == "function" else { continue }
            tools.append([
                "type": "function",
                "function": [
                    "name": (t["name"] as? String) ?? "",
                    "description": (t["description"] as? String) ?? "",
                    "parameters": (t["parameters"] as? [String: Any]) ?? ["type": "object", "properties": [:]],
                ],
            ])
        }
        return tools
    }

    static func chatToResponseItems(_ msg: [String: Any]) -> [[String: Any]] {
        var items: [[String: Any]] = []
        if let reasoning = msg["reasoning_content"] as? String, !reasoning.isEmpty {
            items.append([
                "type": "reasoning",
                "id": "reason_\(UUID().uuidString)",
                "summary": [["type": "summary_text", "text": reasoning]],
            ])
        }
        let text = extractText(msg["content"])
        if !text.isEmpty {
            items.append([
                "type": "message",
                "id": "msg_\(UUID().uuidString)",
                "status": "completed",
                "role": "assistant",
                "content": [["type": "output_text", "text": text, "annotations": []]],
            ])
        }
        for tc in (msg["tool_calls"] as? [Any]) ?? [] {
            guard let t = tc as? [String: Any], let id = t["id"] as? String else { continue }
            let fn = t["function"] as? [String: Any] ?? [:]
            items.append([
                "type": "function_call",
                "id": id,
                "call_id": id,
                "name": (fn["name"] as? String) ?? "",
                "arguments": (fn["arguments"] as? String) ?? "{}",
                "status": "completed",
            ])
        }
        return items
    }

    static func chatResponse(_ chat: [String: Any], model: String) -> [String: Any] {
        let choice = (chat["choices"] as? [Any])?.first as? [String: Any] ?? [:]
        let msg = choice["message"] as? [String: Any] ?? [:]
        let items = chatToResponseItems(msg)
        let usage = chat["usage"] as? [String: Any] ?? [:]
        let response: [String: Any] = [
            "id": "resp_\(UUID().uuidString)",
            "object": "response",
            "created_at": Int(Date().timeIntervalSince1970),
            "status": "completed",
            "model": model,
            "output": items,
            "parallel_tool_calls": true,
            "usage": [
                "input_tokens": usage["prompt_tokens"] ?? 0,
                "output_tokens": usage["completion_tokens"] ?? 0,
                "total_tokens": usage["total_tokens"] ?? 0,
            ],
            "error": NSNull(),
        ]
        return response
    }

    static func buildSSEFromChat(_ chat: [String: Any], model: String) -> Data {
        let response = chatResponse(chat, model: model)
        let items = response["output"] as? [[String: Any]] ?? []
        var events: [String] = []
        func event(_ object: [String: Any]) {
            var object = object
            object["sequence_number"] = events.count
            events.append("event: \(object["type"] as? String ?? "")\ndata: \(jsonString(object))\n\n")
        }
        var created = response; created["status"] = "in_progress"; created["output"] = []
        event(["type": "response.created", "response": created])
        for (index, item) in items.enumerated() {
            event(["type": "response.output_item.added", "output_index": index, "item": item])
            event(["type": "response.output_item.done", "output_index": index, "item": item])
        }
        event(["type": "response.completed", "response": response])
        return Data(events.joined().utf8)
    }

    static func bareModel(_ model: String) -> String {
        if let idx = model.firstIndex(of: "/") { return String(model[model.index(after: idx)...]) }
        return model
    }

    static func jsonString(_ obj: Any) -> String {
        guard let d = try? JSONSerialization.data(withJSONObject: obj, options: []),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }
}
