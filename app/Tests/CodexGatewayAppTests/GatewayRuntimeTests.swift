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

}
