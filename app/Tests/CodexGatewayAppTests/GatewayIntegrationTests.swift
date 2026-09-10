import XCTest
import Network
@testable import CodexGatewayApp

final class GatewayIntegrationTests: XCTestCase {
    private func directory() throws -> URL {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("gateway-test-" + UUID().uuidString)
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
        addTeardownBlock { try? FileManager.default.removeItem(at: url) }
        return url
    }
    private func baseline() -> [String: Any] {
        var model = ModelCatalog.codexModelInfo(slug: "original")
        model["context_window"] = 987654
        model["future_capability"] = ["anything": [1, 2, 3]]
        model["base_instructions"] = "Original instructions exactly"
        model["supported_reasoning_levels"] = [["effort": "high", "description": "Keep"]]
        return ["models": [model], "future_root": "keep"]
    }
    private func snapshot() throws -> CatalogSnapshot {
        try ModelCatalog.merge(original: baseline(), custom: ["custom": ["added", "original", "org/model"]])
    }
    func testCatalogPreservesEveryOriginalFieldAndOnlyPrefixesCollisions() throws {
        let original = baseline()
        let result = try ModelCatalog.merge(original: original, custom: ["a": ["original", "unique", "same", "b/same"], "b": ["same"]])
        XCTAssertEqual(result.models[0] as NSDictionary, (original["models"] as! [[String: Any]])[0] as NSDictionary)
        XCTAssertEqual(result.document["future_root"] as? String, "keep")
        XCTAssertNil(result.routes["original"])
        XCTAssertEqual(result.routes["a/original"]?.modelID, "original")
        XCTAssertEqual(result.routes["unique"]?.providerID, "a")
        XCTAssertEqual(result.routes["a/same"]?.providerID, "a")
        XCTAssertEqual(result.routes["b/same"]?.providerID, "a")
        XCTAssertEqual(result.routes["b/same-2"]?.providerID, "b")
        XCTAssertEqual(Set(result.models.compactMap { $0["slug"] as? String }).count, result.models.count)
    }
    func testOriginalRoutesAreNeverInferredFromSlashPrefix() throws {
        let original: [String: Any] = ["models": [ModelCatalog.codexModelInfo(slug: "custom/native")]]
        let result = try ModelCatalog.merge(original: original, custom: ["custom": ["org/model"]])
        let providers = ["base": ProviderConfig(id: "base", name: "Base"), "custom": ProviderConfig(id: "custom", name: "Custom", isCustom: true)]
        let router = GatewayRouter(providers: providers, activeProvider: "base", gatewayPort: 1234, snapshot: result)
        XCTAssertEqual(router.lookup("custom/native").0?.id, "base")
        XCTAssertEqual(router.lookup("org/model").0?.id, "custom")
        XCTAssertEqual(router.lookup("org/model").1, "org/model")
        XCTAssertEqual(router.lookup("unknown").0?.id, "base")
    }
    func testConfigRoundTripAndRepeatedApplyPreserveOriginalAndProfileBytes() throws {
        let dir = try directory(), config = dir.appendingPathComponent("config.toml")
        let original = """
        # user comment
        model = "original"
        model_provider = "base"
        model_reasoning_effort = "high"
        [profiles.work]
        model = "profile-model"
        model_catalog_json = "/profile/models.json"
        [model_providers.base]
        name = "Original"
        base_url='https://original.example/v1' # keep comment
        supports_websockets = true
        [model_providers.base.http_headers]
        base_url = "this-is-a-header"
        """
        try original.write(to: config, atomically: true, encoding: .utf8)
        let writer = CodexConfigWriter(configURL: config), result = try snapshot()
        try writer.apply(activeProvider: "base", gatewayBase: "http://127.0.0.1:4000/v1", snapshot: result)
        try writer.apply(activeProvider: "base", gatewayBase: "http://127.0.0.1:4000/v1", snapshot: result)
        let connected = try String(contentsOf: config)
        XCTAssertTrue(connected.contains("model = \"original\""))
        XCTAssertTrue(connected.contains("model_provider = \"base\""))
        XCTAssertTrue(connected.contains("model_catalog_json = \"/profile/models.json\""))
        XCTAssertTrue(connected.contains("supports_websockets = true"))
        XCTAssertTrue(connected.contains("base_url = \"this-is-a-header\""))
        XCTAssertEqual(try writer.originalText(), original)
        try writer.restore()
        XCTAssertEqual(try String(contentsOf: config), original)
        XCTAssertFalse(FileManager.default.fileExists(atPath: writer.directory.path))
        XCTAssertFalse(try writer.restore())
    }
    func testRestoreKeepsConcurrentUnrelatedAndManagedExternalEdits() throws {
        let dir = try directory(), config = dir.appendingPathComponent("config.toml")
        let original = "model_provider = \"base\"\n[model_providers.base]\nbase_url = \"https://old.example/v1\"\n"
        try original.write(to: config, atomically: true, encoding: .utf8)
        let writer = CodexConfigWriter(configURL: config)
        try writer.apply(activeProvider: "base", gatewayBase: "http://127.0.0.1:4000/v1", snapshot: snapshot())
        var live = try String(contentsOf: config)
        live = "model = \"new-user-choice\"\n" + live.replacingOccurrences(of: "http://127.0.0.1:4000/v1", with: "https://new.example/v1")
        try live.write(to: config, atomically: true, encoding: .utf8)
        try writer.restore()
        let restored = try String(contentsOf: config)
        XCTAssertTrue(restored.hasPrefix("model = \"new-user-choice\""))
        XCTAssertTrue(restored.contains("https://new.example/v1"))
        XCTAssertFalse(restored.contains("model_catalog_json"))
    }
    func testBuiltinOpenAIKeepsProviderIDAndRemovesNewConfigOnRestore() throws {
        let dir = try directory(), config = dir.appendingPathComponent("config.toml")
        let writer = CodexConfigWriter(configURL: config)
        try writer.apply(activeProvider: "openai", gatewayBase: "http://127.0.0.1:4000/v1", snapshot: snapshot())
        let text = try String(contentsOf: config)
        XCTAssertTrue(text.contains("openai_base_url")); XCTAssertFalse(text.contains("model_provider"))
        try writer.uninstall()
        XCTAssertFalse(FileManager.default.fileExists(atPath: config.path))
        XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: dir.path), [])
    }
    func testDiscoveryRejectsUnauthorizedAndPreservesSlashedIDs() async throws {
        let upstream = try HTTPServer(port: 0) { request, response in
            if request.headers["authorization"] == "Bearer correct" {
                try? await response.json(200, ["data": [["id": "org/model"], ["id": "org/model"]]])
            } else { try? await response.json(401, ["data": [["id": "fake"]]]) }
        }
        try await upstream.start()
        var provider = ProviderConfig(id: "custom", name: "Custom", baseURL: "http://127.0.0.1:\(upstream.port)/v1", bearerToken: "wrong", isCustom: true)
        do { _ = try await ModelCatalog.listProviderModels(provider); XCTFail("401 must not create fake models") }
        catch { XCTAssertTrue(error.localizedDescription.contains("401")) }
        provider.bearerToken = "correct"
        let models = try await ModelCatalog.listProviderModels(provider)
        XCTAssertEqual(models, ["org/model"])
        await upstream.stop()
    }
    func testStreamingAndOriginalAuthBodyHeadersPreserved() async throws {
        let captured = expectation(description: "upstream receives original request")
        let originalBody = Data("{ \"model\": \"original\", \"stream\": true, \"unknown\": [1, 2] }".utf8)
        let upstream = try HTTPServer(port: 0) { request, response in
            XCTAssertEqual(request.body, originalBody)
            XCTAssertEqual(request.headers["authorization"], "Bearer fresh-codex-token")
            XCTAssertEqual(request.headers["chatgpt-account-id"], "original-account")
            XCTAssertEqual(request.path, "/v1/responses?api-version=one")
            captured.fulfill()
            try? await response.begin(200, headers: ["Content-Type": "text/event-stream", "x-request-id": "upstream-trace"])
            try? await response.send(Data("data: first\n\n".utf8))
            try? await Task.sleep(nanoseconds: 900_000_000)
            try? await response.send(Data("data: last\n\n".utf8))
        }
        try await upstream.start()
        let provider = ProviderConfig(id: "base", name: "Base", baseURL: "http://127.0.0.1:\(upstream.port)/v1", envKey: "MISSING_UNUSED_AUTH", queryParams: ["api-version": "one"])
        let gateway = try GatewayRuntime(providers: ["base": provider], activeProvider: "base", port: 0, snapshot: snapshot())
        try await gateway.start()
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(gateway.port)/v1/responses")!)
        request.httpMethod = "POST"; request.httpBody = originalBody
        request.setValue("Bearer fresh-codex-token", forHTTPHeaderField: "Authorization")
        request.setValue("original-account", forHTTPHeaderField: "ChatGPT-Account-Id")
        let start = Date()
        let (bytes, response) = try await URLSession.shared.bytes(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "x-request-id"), "upstream-trace")
        var first = true, text = ""
        for try await line in bytes.lines {
            if first { XCTAssertLessThan(Date().timeIntervalSince(start), 0.8); first = false }
            text += line
        }
        XCTAssertTrue(text.contains("first")); XCTAssertTrue(text.contains("last"))
        await fulfillment(of: [captured], timeout: 1)
        await gateway.stop(); await upstream.stop()
    }
    func testCustomRouteUsesOwnCredentialsAndPreservesUpstreamJSONStatus() async throws {
        let upstream = try HTTPServer(port: 0) { request, response in
            XCTAssertEqual(request.headers["authorization"], "Bearer custom-key")
            XCTAssertNil(request.headers["chatgpt-account-id"])
            let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]
            XCTAssertEqual(body?["model"] as? String, "original")
            try? await response.json(429, ["error": ["message": "upstream limited"]])
        }
        try await upstream.start()
        let custom = ProviderConfig(id: "custom", name: "Custom", baseURL: "http://127.0.0.1:\(upstream.port)/v1", bearerToken: "custom-key", isCustom: true)
        let gateway = try GatewayRuntime(providers: ["custom": custom], activeProvider: "base", port: 0, snapshot: snapshot())
        try await gateway.start()
        var request = URLRequest(url: URL(string: "http://127.0.0.1:\(gateway.port)/v1/responses")!)
        request.httpMethod = "POST"; request.httpBody = Data("{\"model\":\"custom/original\"}".utf8)
        request.setValue("Bearer ORIGINAL_SECRET", forHTTPHeaderField: "Authorization")
        request.setValue("ORIGINAL_ACCOUNT", forHTTPHeaderField: "ChatGPT-Account-Id")
        let (data, response) = try await URLSession.shared.data(for: request)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 429)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("upstream limited"))
        XCTAssertTrue((response as? HTTPURLResponse)?.value(forHTTPHeaderField: "content-type")?.contains("application/json") == true)
        await gateway.stop(); await upstream.stop()
    }
    func testCustomUpstreamReceivesContiguousToolCallPairsWhileOriginalKeepsCodexOrder() async throws {
        // Models that answer with text plus a tool call make Codex send
        // call → assistant text → output; third-party gateways reject that shape.
        let history: [[String: Any]] = [
            ["type": "message", "role": "user", "content": [["type": "input_text", "text": "hi"]]],
            ["type": "function_call", "id": "call_1", "call_id": "call_1", "name": "shell", "arguments": "{}"],
            ["type": "message", "id": "msg_text", "role": "assistant",
             "content": [["type": "output_text", "text": "running"]]],
            ["type": "function_call_output", "id": "fco_1", "call_id": "call_1", "output": "ok"],
        ]
        let upstream = try HTTPServer(port: 0) { request, response in
            let body = try? JSONSerialization.jsonObject(with: request.body) as? [String: Any]
            let items = body?["input"] as? [[String: Any]] ?? []
            if body?["model"] as? String == "added" {
                XCTAssertEqual(items.map { $0["type"] as? String },
                               ["message", "message", "function_call", "function_call_output"])
                XCTAssertEqual(items[1]["role"] as? String, "assistant")
                XCTAssertEqual(items[1]["id"] as? String, "msg_text")
                XCTAssertEqual(items[2]["call_id"] as? String, "call_1")
                XCTAssertEqual(items[3]["call_id"] as? String, "call_1")
            } else {
                XCTAssertEqual(items.map { $0["type"] as? String },
                               ["message", "function_call", "message", "function_call_output"])
            }
            try? await response.json(200, ["ok": true])
        }
        try await upstream.start()
        let custom = ProviderConfig(id: "custom", name: "Custom",
                                    baseURL: "http://127.0.0.1:\(upstream.port)/v1",
                                    bearerToken: "key", isCustom: true)
        let original = ProviderConfig(id: "base", name: "Base", baseURL: "http://127.0.0.1:\(upstream.port)/v1")
        let gateway = try GatewayRuntime(providers: ["custom": custom, "base": original],
                                         activeProvider: "base", port: 0, snapshot: try snapshot())
        try await gateway.start()
        for model in ["added", "original"] {
            var request = URLRequest(url: URL(string: "http://127.0.0.1:\(gateway.port)/v1/responses")!)
            request.httpMethod = "POST"
            request.httpBody = try JSONSerialization.data(withJSONObject: ["model": model, "input": history])
            let (data, response) = try await URLSession.shared.data(for: request)
            XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
            XCTAssertEqual((try JSONSerialization.jsonObject(with: data) as? [String: Any])?["ok"] as? Bool, true)
        }
        await gateway.stop(); await upstream.stop()
    }
    func testLargeFragmentedAndChunkedRequest() async throws {
        let completed = expectation(description: "parsed full chunked body")
        let server = try HTTPServer(port: 0) { request, response in
            XCTAssertEqual(request.body.count, 140_000)
            completed.fulfill()
            try? await response.json(200, ["ok": true])
        }
        try await server.start()
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: server.port)!, using: .tcp)
        connection.start(queue: .global())
        let client = HTTPConnection(connection: connection)
        for part in ["POST /responses HTTP/1.1\r\nHo", "st: localhost\r\nTransfer-Encoding: chu", "nked\r\n\r\n"] {
            try await client.send(Data(part.utf8))
        }
        for _ in 0..<2 {
            try await client.send(Data("11170\r\n".utf8))
            for _ in 0..<7 { try await client.send(Data(repeating: 65, count: 10_000)) }
            try await client.send(Data("\r\n".utf8))
        }
        try await client.send(Data("0\r\n\r\n".utf8))
        await fulfillment(of: [completed], timeout: 3)
        client.close(); await server.stop()
    }
    func testWebSocketPassThroughWithNativeEventsAndAuth() async throws {
        let seen = expectation(description: "native websocket preserved")
        let upstream = try HTTPServer(port: 0) { request, response in
            XCTAssertEqual(request.headers["authorization"], "Bearer native-auth")
            do {
                try await response.upgradeWebSocket(key: request.headers["sec-websocket-key"]!)
                if let (data, _) = try await response.readWebSocket() {
                    XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("response.create"))
                    try await response.sendWebSocket(Data("{\"type\":\"response.completed\",\"opaque\":true}".utf8))
                    seen.fulfill()
                }
            } catch { XCTFail("\(error)") }
        }
        try await upstream.start()
        let provider = ProviderConfig(id: "base", name: "Base", baseURL: "http://127.0.0.1:\(upstream.port)/v1")
        let gateway = try GatewayRuntime(providers: ["base": provider], activeProvider: "base", port: 0, snapshot: snapshot())
        try await gateway.start()
        var request = URLRequest(url: URL(string: "ws://127.0.0.1:\(gateway.port)/v1/responses")!)
        request.setValue("Bearer native-auth", forHTTPHeaderField: "Authorization")
        let socket = URLSession.shared.webSocketTask(with: request); socket.resume()
        try await socket.send(.string("{\"type\":\"response.create\",\"model\":\"original\"}"))
        let message = try await socket.receive()
        if case .string(let text) = message { XCTAssertTrue(text.contains("opaque")) } else { XCTFail("expected text event") }
        socket.cancel(with: .normalClosure, reason: nil)
        await fulfillment(of: [seen], timeout: 3)
        await gateway.stop(); await upstream.stop()
    }
    @MainActor func testSavedProviderMigrationVisibleAndUninstallRemovesAllOwnedData() async throws {
        let dir = try directory(), config = dir.appendingPathComponent("config.toml")
        let catalog = dir.appendingPathComponent("original.json")
        try JSONSerialization.data(withJSONObject: baseline()).write(to: catalog)
        let text = "model_provider = \"base\"\nmodel_catalog_json = \"\(catalog.path)\"\n[model_providers.base]\nbase_url = \"https://example.com/v1\"\n"
        try text.write(to: config, atomically: true, encoding: .utf8)
        let name = "gateway-tests-" + UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        // This is the old v0.1 payload, with no new fields.
        defaults.set(Data("[{\"id\":\"saved\",\"name\":\"Saved\",\"baseURL\":\"http://localhost:1/v1\",\"key\":\"PRIVATE_SECRET\"}]".utf8), forKey: "codexGateway.customProviders")
        let dataDir = dir.appendingPathComponent("data")
        let model = AppModel(configURL: config, dataDirectory: dataDir, defaults: defaults)
        XCTAssertEqual(model.customProviders.map(\.id), ["saved"])
        XCTAssertNil(defaults.data(forKey: "codexGateway.customProviders"))
        let permissions = try FileManager.default.attributesOfItem(atPath: model.providersURL.path)[.posixPermissions] as? Int
        XCTAssertEqual(permissions, 0o600)
        model.log("error", "accidental PRIVATE_SECRET")
        XCTAssertFalse(try String(contentsOf: model.logURL).contains("PRIVATE_SECRET"))
        let removed = await model.uninstall(removeApp: false)
        XCTAssertTrue(removed)
        XCTAssertFalse(FileManager.default.fileExists(atPath: dataDir.path))
        XCTAssertEqual(try String(contentsOf: config), text)
        XCTAssertEqual(try JSONSerialization.jsonObject(with: Data(contentsOf: catalog)) as? NSDictionary, baseline() as NSDictionary)
    }
    func testMultilineInstructionsCannotMasqueradeAsProviderFields() throws {
        let dir = try directory(), config = dir.appendingPathComponent("config.toml")
        let original = "model_provider = \"base\"\ndeveloper_instructions = \"\"\"\n[model_providers.base]\nbase_url = 'keep this text'\n\"\"\"\n[model_providers.\"base\"]\nbase_url = 'https://real.example/v1'\n"
        try original.write(to: config, atomically: true, encoding: .utf8)
        let parsed = Toml.parse(original)
        XCTAssertEqual((parsed["model_providers"] as? [String: [String: Any]])?["base"]?["base_url"] as? String, "https://real.example/v1")
        let writer = CodexConfigWriter(configURL: config)
        try writer.apply(activeProvider: "base", gatewayBase: "http://127.0.0.1:4000/v1", snapshot: snapshot())
        let applied = try String(contentsOf: config)
        XCTAssertTrue(applied.contains("base_url = 'keep this text'"))
        try writer.restore()
        XCTAssertEqual(try String(contentsOf: config), original)
    }
    func testZstdCompressedRequestDecoding() throws {
        let paths = ["/opt/homebrew/bin/zstd", "/usr/local/bin/zstd"]
        guard let binary = paths.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw XCTSkip("zstd CLI unavailable")
        }
        let body = Data("{\"model\":\"org/model\",\"input\":\"compressed request\"}".utf8)
        let process = Process(), input = Pipe(), output = Pipe()
        process.executableURL = URL(fileURLWithPath: binary); process.arguments = ["-q", "-c"]
        process.standardInput = input; process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run(); try input.fileHandleForWriting.write(contentsOf: body); try input.fileHandleForWriting.close()
        let compressed = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(try RequestCompression.decode(compressed, encoding: "zstd"), body)
        XCTAssertThrowsError(try RequestCompression.decode(Data("garbage".utf8), encoding: "zstd"))
    }
    func testInstalledCodexAcceptsMergedCatalogWithoutChangingUserConfig() throws {
        let binary = "/Applications/Codex.app/Contents/Resources/codex"
        guard FileManager.default.isExecutableFile(atPath: binary) else { throw XCTSkip("Codex app is not installed") }
        let dir = try directory(), catalog = dir.appendingPathComponent("models.json")
        let result = try snapshot()
        try JSONSerialization.data(withJSONObject: result.document).write(to: catalog)
        let originalConfig = try Data(contentsOf: CodexConfigLoader.defaultConfigURL())
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["debug", "models", "-c", "model_catalog_json=\(CodexConfigWriter.quote(catalog.path))"]
        process.standardOutput = output; process.standardError = errors
        try process.run(); let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit()
        XCTAssertEqual(process.terminationStatus, 0, String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self))
        let object = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let models = object["models"] as! [[String: Any]]
        XCTAssertTrue(models.contains { $0["slug"] as? String == "org/model" })
        XCTAssertTrue(models.contains { $0["slug"] as? String == "custom/original" })
        XCTAssertEqual(models.first { $0["slug"] as? String == "original" }?["context_window"] as? Int, 987654)
        XCTAssertEqual(try Data(contentsOf: CodexConfigLoader.defaultConfigURL()), originalConfig)
    }
    @MainActor func testPortConflictCannotApplyCodexAndSecondInstanceCannotRestoreOwner() async throws {
        let dir = try directory(), config = dir.appendingPathComponent("config.toml")
        let catalog = dir.appendingPathComponent("original.json")
        try JSONSerialization.data(withJSONObject: baseline()).write(to: catalog)
        let upstream = try HTTPServer(port: 0) { _, response in try? await response.json(200, ["data": [["id": "added"]]]) }
        try await upstream.start()
        let text = "model_provider = \"base\"\nmodel_catalog_json = \"\(catalog.path)\"\n[model_providers.base]\nbase_url = \"https://example.com/v1\"\n"
        try text.write(to: config, atomically: true, encoding: .utf8)
        let dataDir = dir.appendingPathComponent("data")
        let name = "gateway-tests-" + UUID().uuidString, defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        let first = AppModel(configURL: config, dataDirectory: dataDir, defaults: defaults, port: upstream.port)
        _ = await first.saveProvider(CustomProvider(id: "custom", name: "Custom", baseURL: "http://127.0.0.1:\(upstream.port)/v1", key: "", models: ["added"]))
        await first.connect()
        XCTAssertFalse(first.isRunning)
        XCTAssertEqual(try String(contentsOf: config), text)
        XCTAssertFalse(first.writer.isConnected)
        try first.writer.apply(activeProvider: "base", gatewayBase: "http://127.0.0.1:4000/v1", snapshot: snapshot())
        let applied = try String(contentsOf: config)
        let second = AppModel(configURL: config, dataDirectory: dataDir, defaults: defaults)
        XCTAssertNotNil(second.onError)
        _ = await second.stop()
        XCTAssertEqual(try String(contentsOf: config), applied)
        _ = await first.stop()
        XCTAssertEqual(try String(contentsOf: config), text)
        await upstream.stop()
    }
    func testStopClosesPortAndInflightConnections() async throws {
        let gateway = try GatewayRuntime(providers: [:], activeProvider: nil, port: 0)
        try await gateway.start()
        let port = gateway.port
        let connection = NWConnection(host: "127.0.0.1", port: NWEndpoint.Port(rawValue: port)!, using: .tcp)
        connection.start(queue: .global())
        let client = HTTPConnection(connection: connection)
        try await client.send(Data("POST /responses HTTP/1.1\r\nContent-Length: 10000\r\n\r\npartial".utf8))
        await gateway.stop()
        let replacement = try HTTPServer(port: port) { _, response in try? await response.json(200, ["ok": true]) }
        try await replacement.start()
        let (_, response) = try await URLSession.shared.data(from: URL(string: "http://127.0.0.1:\(port)/health")!)
        XCTAssertEqual((response as? HTTPURLResponse)?.statusCode, 200)
        await replacement.stop(); client.close()
    }

    // Explicitly opt in; the normal test suite never calls a paid model.
    func testOptInLiveCodexTurn() async throws {
        let env = ProcessInfo.processInfo.environment
        guard let selectedModel = env["CODEX_GATEWAY_LIVE_MODEL"],
              let providerID = env["CODEX_GATEWAY_LIVE_PROVIDER"] else { throw XCTSkip("Live inference is opt-in") }
        let binary = "/Applications/Codex.app/Contents/Resources/codex"
        let providerFile = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Codex Gateway/providers.json")
        let custom = try JSONDecoder().decode([CustomProvider].self, from: Data(contentsOf: providerFile))
        let provider = try XCTUnwrap(custom.first { $0.id == providerID })
        let dir = try directory()
        let snapshot = try ModelCatalog.merge(original: ["models": []], custom: [providerID: [selectedModel]])
        let gateway = try GatewayRuntime(providers: [providerID: provider.toProviderConfig()], activeProvider: "s2a", port: 0, snapshot: snapshot)
        try await gateway.start()
        let catalog = dir.appendingPathComponent("models.json")
        try JSONSerialization.data(withJSONObject: snapshot.document).write(to: catalog)
        let config = "model_provider = \"s2a\"\nmodel_catalog_json = \(CodexConfigWriter.quote(catalog.path))\n[model_providers.s2a]\nname = \"Gateway smoke test\"\nbase_url = \"http://127.0.0.1:\(gateway.port)/v1\"\nwire_api = \"responses\"\n"
        try config.write(to: dir.appendingPathComponent("config.toml"), atomically: true, encoding: .utf8)
        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)
        try "GATEWAY_SMOKE_OK".write(to: dir.appendingPathComponent("smoke-input.txt"), atomically: true, encoding: .utf8)
        let needsTool = env["CODEX_GATEWAY_LIVE_TOOL"] == "1"
        let prompt = needsTool ? "Use a shell command to read smoke-input.txt from the current directory. Reply with exactly its contents. You must actually use the shell tool." : "Reply with exactly GATEWAY_SMOKE_OK. Do not use tools."
        process.arguments = ["exec", "--ephemeral", "--skip-git-repo-check", "--json", "-s", "read-only", "-m", selectedModel,
                             prompt]
        var environment = env; environment["CODEX_HOME"] = dir.path
        process.environment = environment; process.currentDirectoryURL = dir
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = errors
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 60, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile(); process.waitUntilExit(); timeout.cancel()
        await gateway.stop()
        if process.terminationStatus != 0 {
            let diagnostic = String(decoding: errors.fileHandleForReading.readDataToEndOfFile() + data, as: UTF8.self)
            print(String(diagnostic.replacingOccurrences(of: provider.key, with: "[REDACTED]").suffix(5000)))
        }
        XCTAssertEqual(process.terminationStatus, 0, "Isolated Codex turn failed; no user config was changed")
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(text.contains("GATEWAY_SMOKE_OK"), "Codex did not receive the expected assistant message")
        if needsTool { XCTAssertTrue(text.contains("command_execution"), "Expected a real Codex command execution") }
    }

    func testRemovingCustomRouteDoesNotFallThroughToOriginalProvider() throws {
        let providers = ["base": ProviderConfig(id: "base", name: "Base"), "custom": ProviderConfig(id: "custom", name: "Custom", isCustom: true)]
        let router = GatewayRouter(providers: providers, activeProvider: "base", gatewayPort: 1234, snapshot: try snapshot())
        XCTAssertEqual(router.lookup("added").0?.id, "custom")
        router.update(providers: ["base": providers["base"]!], snapshot: try ModelCatalog.merge(original: baseline(), custom: [:]))
        XCTAssertNil(router.lookup("added").0)
        XCTAssertEqual(router.lookup("original").0?.id, "base")
    }

    /// A real Codex turn against a mock Chat Completions upstream that enforces
    /// DeepSeek's thinking-mode rule: while `tools` are sent, the assistant turn
    /// with the tool call must carry `reasoning_content` back, and Codex itself
    /// has to replay the reasoning item it received.
    func testChatTranslationCarriesThinkingThroughARealCodexToolTurn() async throws {
        let binary = "/Applications/Codex.app/Contents/Resources/codex"
        guard FileManager.default.isExecutableFile(atPath: binary) else { throw XCTSkip("Codex app is not installed") }
        let recorded = ReasoningRecorder()
        let upstream = try HTTPServer(port: 0) { request, response in
            guard let body = (try? JSONSerialization.jsonObject(with: request.body)) as? [String: Any],
                  let messages = body["messages"] as? [[String: Any]] else {
                try? await response.json(400, ["error": ["message": "unparseable"]]); return
            }
            recorded.add(body)
            let hasTools = (body["tools"] as? [Any])?.isEmpty == false
            if hasTools {
                for m in messages where (m["role"] as? String) == "assistant" && m["reasoning_content"] == nil {
                    try? await response.json(400, ["error": ["message":
                        "The `reasoning_content` in the thinking mode must be passed back to the API."]]); return
                }
            }
            let answered = messages.contains { ($0["role"] as? String) == "tool" }
            let message: [String: Any] = answered
                ? ["role": "assistant", "content": "THINKING-ROUNDTRIP-OK"]
                : ["role": "assistant", "content": "", "reasoning_content": "I will read marker.txt.",
                   "tool_calls": [["id": "call_1", "type": "function",
                                   "function": ["name": "exec_command", "arguments": #"{"cmd":"cat marker.txt"}"#]]]]
            try? await response.json(200, ["choices": [["index": 0, "message": message]],
                                           "usage": ["prompt_tokens": 1, "completion_tokens": 1, "total_tokens": 2]])
        }
        try await upstream.start()
        var provider = ProviderConfig(id: "probe", name: "Probe",
                                      baseURL: "http://127.0.0.1:\(upstream.port)/v1",
                                      bearerToken: "key", isCustom: true)
        provider.wireAPI = "chat"
        let snapshot = try ModelCatalog.merge(original: ["models": []], custom: ["probe": ["deepseek-flash"]])
        let gateway = try GatewayRuntime(providers: ["probe": provider], activeProvider: "probe", port: 0, snapshot: snapshot)
        try await gateway.start()

        let dir = try directory(), catalog = dir.appendingPathComponent("models.json")
        try JSONSerialization.data(withJSONObject: snapshot.document).write(to: catalog)
        try "MARKER\n".write(to: dir.appendingPathComponent("marker.txt"), atomically: true, encoding: .utf8)
        let config: String = "model = \"deepseek-flash\"\nmodel_provider = \"probe\"\n"
            + "model_catalog_json = \(CodexConfigWriter.quote(catalog.path))\n"
            + "[model_providers.probe]\nname = \"Probe\"\nbase_url = \"http://127.0.0.1:\(gateway.port)/v1\"\nwire_api = \"responses\"\n"
        try config.write(to: dir.appendingPathComponent("config.toml"), atomically: true, encoding: String.Encoding.utf8)

        let process = Process(), output = Pipe(), errors = Pipe()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["exec", "--ephemeral", "--skip-git-repo-check", "--json", "-s", "read-only",
                             "-m", "deepseek-flash", "Read marker.txt with exec_command, then answer."]
        var environment = ProcessInfo.processInfo.environment
        environment["CODEX_HOME"] = dir.path
        process.environment = environment
        process.currentDirectoryURL = dir
        process.standardInput = FileHandle.nullDevice
        process.standardOutput = output; process.standardError = errors
        try process.run()
        let timeout = DispatchWorkItem { if process.isRunning { process.terminate() } }
        DispatchQueue.global().asyncAfter(deadline: .now() + 90, execute: timeout)
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit(); timeout.cancel()
        await gateway.stop(); await upstream.stop()

        let stderr = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        let tail = String(stderr.suffix(1000))
        XCTAssertEqual(process.terminationStatus, 0, tail)
        XCTAssertGreaterThanOrEqual(recorded.all.count, 2, "Codex never replayed the tool-call turn")
        let assistant = (recorded.all.last?["messages"] as? [[String: Any]])?.first { ($0["role"] as? String) == "assistant" }
        XCTAssertEqual(assistant?["reasoning_content"] as? String, "I will read marker.txt.")
        XCTAssertEqual((assistant?["tool_calls"] as? [Any])?.count, 1)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("THINKING-ROUNDTRIP-OK"))
    }

}

/// Collects the chat-completions bodies an upstream receives across threads.
final class ReasoningRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [[String: Any]] = []
    func add(_ body: [String: Any]) { lock.lock(); storage.append(body); lock.unlock() }
    var all: [[String: Any]] { lock.lock(); defer { lock.unlock() }; return storage }
}
