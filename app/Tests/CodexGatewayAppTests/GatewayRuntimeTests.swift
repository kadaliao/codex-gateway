import XCTest
@testable import CodexGatewayApp

final class GatewayRuntimeTests: XCTestCase {

    // ---------------- Translation (deterministic, no network) ----------------
    func testResponsesToMessages() {
        // Reasoning + separator of function_call, then output.
        let items = [
            ["type": "message", "role": "user", "content": [["type": "input_text", "text": "hi"]]],
            ["type": "function_call", "call_id": "call_1", "name": "shell",
             "arguments": #"{"cmd":"ls"}"#],
            ["type": "function_call_output", "call_id": "call_1", "output": "ok"],
        ]
        let body: [String: Any] = ["instructions": "Be helpful", "input": items]
        let messages = ResponseTranslation.responsesToMessages(body)

        XCTAssertEqual(messages.count, 4)   // system, user, assistant(tool_calls), tool
        XCTAssertEqual((messages[0] as! [String: Any])["role"] as? String, "system")
        XCTAssertEqual((messages[1] as! [String: Any])["role"] as? String, "user")
        // assistant message carries the grouped tool_call
        let assistant = messages[2] as! [String: Any]
        XCTAssertEqual(assistant["role"] as? String, "assistant")
        XCTAssertNotNil(assistant["tool_calls"])
        // function_call_output becomes a tool message
        let last = messages[3] as! [String: Any]
        XCTAssertEqual(last["role"] as? String, "tool")
        XCTAssertEqual(last["tool_call_id"] as? String, "call_1")
    }

    func testToolCallOrderNormalizationMovesInterleavedTextBeforeItsCall() {
        let items: [Any] = [
            ["type": "message", "role": "user", "content": [["type": "input_text", "text": "hi"]]],
            ["type": "function_call", "call_id": "call_1", "name": "shell", "arguments": "{}"],
            ["type": "message", "id": "msg_text", "role": "assistant",
             "content": [["type": "output_text", "text": "running the command"]]],
            ["type": "function_call_output", "call_id": "call_1", "output": "ok"],
        ]
        let normalized = ResponseTranslation.normalizeToolCallOrder(["input": items])["input"] as! [[String: Any]]

        XCTAssertEqual(normalized.map { $0["type"] as? String },
                       ["message", "message", "function_call", "function_call_output"])
        XCTAssertEqual(normalized[1]["role"] as? String, "assistant")
        XCTAssertEqual(normalized[1]["id"] as? String, "msg_text")
        XCTAssertEqual(normalized[2]["call_id"] as? String, "call_1")
        XCTAssertEqual(normalized[3]["call_id"] as? String, "call_1")
    }

    func testToolCallOrderNormalizationMovesTextBeforeEveryCallOfTheGroup() {
        let items: [Any] = [
            ["type": "function_call", "call_id": "call_1", "name": "shell", "arguments": "{}"],
            ["type": "function_call", "call_id": "call_2", "name": "shell", "arguments": "{}"],
            ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "both"]]],
            ["type": "function_call_output", "call_id": "call_1", "output": "a"],
            ["type": "function_call_output", "call_id": "call_2", "output": "b"],
        ]
        let normalized = ResponseTranslation.normalizeToolCallOrder(["input": items])["input"] as! [[String: Any]]

        XCTAssertEqual(normalized.map { $0["type"] as? String },
                       ["message", "function_call", "function_call", "function_call_output", "function_call_output"])
        XCTAssertEqual(normalized[0]["role"] as? String, "assistant")
        XCTAssertEqual([normalized[1]["call_id"] as? String, normalized[2]["call_id"] as? String], ["call_1", "call_2"])
    }

    func testToolCallOrderNormalizationLeavesOtherHistoryAlone() {
        // Canonical pairs, text already preceding a call, a user turn in between,
        // and a call whose output is missing must all pass through untouched.
        let items: [Any] = [
            ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "first"]]],
            ["type": "function_call", "call_id": "call_1", "name": "shell", "arguments": "{}"],
            ["type": "function_call_output", "call_id": "call_1", "output": "ok"],
            ["type": "function_call", "call_id": "call_2", "name": "shell", "arguments": "{}"],
            ["type": "message", "role": "user", "content": [["type": "input_text", "text": "steer"]]],
            ["type": "function_call_output", "call_id": "call_2", "output": "ok"],
            ["type": "function_call", "call_id": "call_3", "name": "shell", "arguments": "{}"],
        ]
        let normalized = ResponseTranslation.normalizeToolCallOrder(["input": items])["input"] as! [Any]

        XCTAssertEqual(normalized.map { ($0 as! [String: Any])["call_id"] as? String ?? "?" },
                       ["?", "call_1", "call_1", "call_2", "?", "call_2", "call_3"])
        XCTAssertEqual(normalized.map { ($0 as! [String: Any])["role"] as? String ?? "-" },
                       ["assistant", "-", "-", "-", "user", "-", "-"])
        XCTAssertEqual(ResponseTranslation.normalizeToolCallOrder(["input": "plain string"])["input"] as? String,
                       "plain string")
    }

    func testResponsesToChatToolsMapsFunctionOnly() {
        let body: [String: Any] = [
            "tools": [
                ["type": "function", "name": "shell", "description": "run",
                 "parameters": ["type": "object", "properties": [:]]],
                ["type": "web_search"],
                ["type": "computer_use"],
            ],
        ]
        let tools = ResponseTranslation.responsesToChatTools(body)
        XCTAssertEqual(tools.count, 1)
        let fn = (tools[0] as! [String: Any])["function"] as! [String: Any]
        XCTAssertEqual(fn["name"] as? String, "shell")
    }

    func testBuildSSEFromChat() {
        let chat: [String: Any] = [
            "choices": [["message": [
                "content": "done",
                "tool_calls": [["id": "call_1", "type": "function",
                                "function": ["name": "shell", "arguments": "{}"]]],
            ]]],
            "usage": ["prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2],
        ]
        let sse = String(data: ResponseTranslation.buildSSEFromChat(chat, model: "deepseek-chat"),
                         encoding: .utf8) ?? ""
        XCTAssertTrue(sse.contains("response.completed"))
        XCTAssertTrue(sse.contains("response.output_item.added"))
        XCTAssertTrue(sse.contains("function_call"))
        XCTAssertTrue(sse.contains("deepseek-chat"))
    }

    // ---------------- TOML ----------------
    func testTomlParsesNestedProviders() {
        let toml = """
        model = "gpt-5"
        model_provider = "deepseek"
        [model_providers.deepseek]
        name = "DeepSeek"
        base_url = "https://api.deepseek.com/v1"
        env_key = "DEEPSEEK_API_KEY"
        requires_openai_auth = false
        [model_providers.deepseek.auth]
        command = "print-token"
        """
        let raw = Toml.parse(toml)
        XCTAssertEqual(raw["model"] as? String, "gpt-5")
        XCTAssertEqual(raw["model_provider"] as? String, "deepseek")
        let mp = raw["model_providers"] as! [String: Any]
        let ds = mp["deepseek"] as! [String: Any]
        XCTAssertEqual(ds["base_url"] as? String, "https://api.deepseek.com/v1")
        XCTAssertEqual(ds["requires_openai_auth"] as? Bool, false)
        let auth = ds["auth"] as! [String: Any]
        XCTAssertEqual(auth["command"] as? String, "print-token")
    }

    // ---------------- ModelInfo completeness ----------------
    func testCodexModelInfoHasAllRequiredFields() {
        let info = ModelCatalog.codexModelInfo(slug: "x/y")
        let required = ["slug", "display_name", "supported_reasoning_levels", "shell_type",
                        "visibility", "supported_in_api", "priority", "support_verbosity",
                        "truncation_policy", "experimental_supported_tools",
                        "web_search_tool_type", "base_instructions"]
        for key in required {
            XCTAssertNotNil(info[key], "missing \(key)")
        }
        XCTAssertEqual(info["shell_type"] as? String, "unified_exec")
        XCTAssertEqual(info["web_search_tool_type"] as? String, "text")
    }
    func testChatTranslationRetainsDeveloperInstructionsAsSystem() {
        let body: [String: Any] = ["input": [
            ["role": "developer", "content": [["type": "input_text", "text": "Keep the constraint"]]],
            ["role": "user", "content": "hello"],
        ]]
        let messages = ResponseTranslation.responsesToMessages(body) as! [[String: Any]]
        XCTAssertEqual(messages[0]["role"] as? String, "system")
        XCTAssertEqual(messages[0]["content"] as? String, "Keep the constraint")
        XCTAssertEqual(messages[1]["role"] as? String, "user")
    }

    // ---------------- Reasoning round trip (DeepSeek thinking mode) ----------------
    func testChatReplyTurnsReasoningContentIntoOneReplayableItem() {
        let chat: [String: Any] = ["choices": [["message": [
            "content": "",
            "reasoning_content": "I should list the directory first.",
            "tool_calls": [["id": "call_1", "type": "function",
                            "function": ["name": "shell", "arguments": #"{"cmd":"ls"}"#]]],
        ]]]]
        let response = ResponseTranslation.chatResponse(chat, model: "deepseek-flash")
        let items = response["output"] as! [[String: Any]]

        XCTAssertEqual(items.map { $0["type"] as? String }, ["reasoning", "function_call"])
        let summary = items[0]["summary"] as! [[String: Any]]
        XCTAssertEqual(summary.first?["text"] as? String, "I should list the directory first.")
        XCTAssertEqual(items[1]["call_id"] as? String, "call_1")

        // Codex replays what it received; the tool-call turn must still carry the thinking.
        let replayed: [String: Any] = ["input": [items[0], items[1],
                                                 ["type": "function_call_output", "call_id": "call_1", "output": "ok"]]]
        let messages = ResponseTranslation.responsesToMessages(replayed) as! [[String: Any]]
        let assistant = messages[0]
        XCTAssertEqual(assistant["role"] as? String, "assistant")
        XCTAssertEqual(assistant["reasoning_content"] as? String, "I should list the directory first.")
        XCTAssertEqual((assistant["tool_calls"] as? [Any])?.count, 1)
        XCTAssertEqual(messages[1]["role"] as? String, "tool")
    }

    func testChatTranslationKeepsTextReasoningAndToolCallsInOneAssistantTurn() {
        let body: [String: Any] = ["input": [
            ["type": "message", "role": "user", "content": [["type": "input_text", "text": "hi"]]],
            ["type": "reasoning", "summary": [["type": "summary_text", "text": "think"]]],
            ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "running it"]]],
            ["type": "function_call", "call_id": "call_1", "name": "shell", "arguments": "{}"],
            ["type": "function_call_output", "call_id": "call_1", "output": "ok"],
        ]]
        let messages = ResponseTranslation.responsesToMessages(body) as! [[String: Any]]

        XCTAssertEqual(messages.map { $0["role"] as? String }, ["user", "assistant", "tool"])
        XCTAssertEqual(messages[1]["content"] as? String, "running it")
        XCTAssertEqual(messages[1]["reasoning_content"] as? String, "think")
        XCTAssertEqual((messages[1]["tool_calls"] as? [Any])?.count, 1)
    }

    func testChatTranslationKeepsReasoningOnATextOnlyTurnWithoutToolCalls() {
        let body: [String: Any] = ["input": [
            ["type": "message", "role": "user", "content": [["type": "input_text", "text": "hi"]]],
            ["type": "reasoning", "summary": [["type": "summary_text", "text": "think"]]],
            ["type": "message", "role": "assistant", "content": [["type": "output_text", "text": "answer"]]],
            ["type": "message", "role": "user", "content": [["type": "input_text", "text": "again"]]],
        ]]
        let messages = ResponseTranslation.responsesToMessages(body) as! [[String: Any]]

        XCTAssertEqual(messages.map { $0["role"] as? String }, ["user", "assistant", "user"])
        XCTAssertEqual(messages[1]["content"] as? String, "answer")
        XCTAssertEqual(messages[1]["reasoning_content"] as? String, "think")
        XCTAssertNil(messages[1]["tool_calls"])
        // A dropped reasoning turn must not leak into the next user message.
        XCTAssertNil(messages[2]["reasoning_content"])
    }

    func testReasoningThatPrecedesAMissingTurnIsNotFabricatedAsAMessage() {
        let body: [String: Any] = ["input": [
            ["type": "message", "role": "user", "content": [["type": "input_text", "text": "hi"]]],
            ["type": "reasoning", "summary": [["type": "summary_text", "text": "think"]]],
        ]]
        let messages = ResponseTranslation.responsesToMessages(body) as! [[String: Any]]
        XCTAssertEqual(messages.map { $0["role"] as? String }, ["user"])
    }

    func testBackfillCoversAssistantTurnsWhoseReasoningWasLost() {
        let messages: [Any] = [
            ["role": "system", "content": "s"],
            ["role": "user", "content": "hi"],
            ["role": "assistant", "content": "", "tool_calls": [["id": "call_1"]]],
            ["role": "tool", "tool_call_id": "call_1", "content": "ok"],
            ["role": "assistant", "content": "done", "reasoning_content": "kept"],
        ]
        let filled = ResponseTranslation.backfillReasoningContent(messages) as! [[String: Any]]

        XCTAssertEqual(filled[2]["reasoning_content"] as? String, "")
        XCTAssertEqual(filled[4]["reasoning_content"] as? String, "kept")
        XCTAssertNil(filled[0]["reasoning_content"])
        XCTAssertNil(filled[1]["reasoning_content"])
        XCTAssertNil(filled[3]["reasoning_content"])
        // tool_calls preserved, tools-lacking assistants unchanged
        XCTAssertEqual((filled[2]["tool_calls"] as? [Any])?.count, 1)
        XCTAssertNil(filled[4]["tool_calls"])
    }

}
