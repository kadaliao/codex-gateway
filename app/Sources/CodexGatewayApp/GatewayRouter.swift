import Foundation

final class GatewayRouter: @unchecked Sendable {
    private var providers: [String: ProviderConfig]
    private var snapshot: CatalogSnapshot?
    private var retiredModels: Set<String> = []
    private let lock = NSLock()
    let activeProvider: String
    let gatewayPort: Int
    private let log: (String, String) -> Void
    private let session: URLSession

    init(providers: [String: ProviderConfig], activeProvider: String?, gatewayPort: Int,
         snapshot: CatalogSnapshot? = nil, log: @escaping (String, String) -> Void = { _, _ in }) {
        self.providers = providers; self.activeProvider = activeProvider ?? "openai"
        self.gatewayPort = gatewayPort; self.snapshot = snapshot; self.log = log
        let config = URLSessionConfiguration.ephemeral
        config.httpCookieStorage = nil; config.urlCredentialStorage = nil
        config.timeoutIntervalForRequest = 300; config.timeoutIntervalForResource = 3600
        session = URLSession(configuration: config)
    }
    deinit { session.invalidateAndCancel() }
    func update(providers: [String: ProviderConfig], snapshot: CatalogSnapshot) {
        lock.lock(); defer { lock.unlock() }
        let previous = Set(self.snapshot?.routes.keys.map { $0 } ?? [])
        retiredModels.formUnion(previous.subtracting(snapshot.routes.keys))
        retiredModels.subtract(snapshot.models.compactMap { $0["slug"] as? String })
        self.providers = providers; self.snapshot = snapshot
    }
    func lookup(_ model: String) -> (ProviderConfig?, String) {
        lock.lock(); defer { lock.unlock() }
        if retiredModels.contains(model) { return (nil, model) }
        if let route = snapshot?.routes[model] { return (providers[route.providerID], route.modelID) }
        return (providers[activeProvider], model)
    }
    private func models() -> [[String: Any]] {
        lock.lock(); defer { lock.unlock() }
        return snapshot?.models ?? []
    }

    func handle(_ req: HTTPServer.Request, response: HTTPConnection) async {
        let start = Date(), requestID = String(UUID().uuidString.prefix(8))
        let path = req.path.split(separator: "?", maxSplits: 1).first.map(String.init) ?? req.path
        var routeLabel = activeProvider
        do {
            if req.method == "GET", path == "/health" {
                try await response.json(200, ["ok": true, "service": "codex-gateway"]); return
            }
            // Browser origins cannot use the local authenticated gateway.
            guard req.headers["origin"] == nil else {
                try await response.json(403, ["error": ["message": "Browser origins are not allowed"]]); return
            }
            if req.headers["upgrade"]?.lowercased() == "websocket" {
                try await webSocket(req, response: response, requestID: requestID); return
            }
            if req.method == "GET", ["/models", "/v1/models"].contains(path) {
                try await response.json(200, ["object": "list", "data": models().map {
                    ["id": $0["slug"] as? String ?? "", "object": "model"]
                }]); return
            }
            let decoded = try RequestCompression.decode(req.body, encoding: req.headers["content-encoding"])
            let object = (try? JSONSerialization.jsonObject(with: decoded)) as? [String: Any]
            let model = object?["model"] as? String ?? ""
            let (candidate, bare) = lookup(model)
            guard let provider = candidate else { throw GatewayError.message("所选模型的 provider 已停用、移除或不可用，请重新选择模型。") }
            routeLabel = provider.id
            log("request", "\(requestID) · \(req.method) \(path) → \(provider.id)\(model.isEmpty ? "" : " / " + model)")
            var body = req.body
            if provider.isCustom, var object {
                object["model"] = bare
                // Chat-only backends and third-party Responses gateways pair a tool
                // call with its output by position; keep the pair contiguous.
                object = ResponseTranslation.normalizeToolCallOrder(object)
                body = try JSONSerialization.data(withJSONObject: object)
                if !provider.isResponsesBackend {
                    guard ["/responses", "/v1/responses"].contains(path) else {
                        throw GatewayError.message("此自定义 Chat Completions 模型不支持该 Responses 操作。")
                    }
                    try await chat(provider, body: object, model: bare, incoming: req, response: response)
                    log("success", "\(requestID) · \(provider.id) · 完成 · \(elapsed(start)) ms")
                    return
                }
            }
            let request = try upstreamRequest(provider, incoming: req, body: body,
                                              suffix: req.path.hasPrefix("/v1/") ? String(req.path.dropFirst(3)) : req.path)
            let status = try await stream(request, to: response)
            log(status < 400 ? "success" : "error", "\(requestID) · \(routeLabel) · HTTP \(status) · \(elapsed(start)) ms")
        } catch {
            log("error", "\(requestID) · \(routeLabel) · \(safeError(error)) · \(elapsed(start)) ms")
            if !response.started {
                try? await response.json(502, ["error": ["message": safeError(error), "type": "gateway_error"]])
            }
        }
    }

    func upstreamRequest(_ provider: ProviderConfig, incoming: HTTPServer.Request,
                         body: Data, suffix: String) throws -> URLRequest {
        guard !CodexConfigWriter.isGatewayProvider(provider, port: gatewayPort),
              let value = provider.resolvedURL(path: suffix), let url = URL(string: value),
              ["http", "https"].contains(url.scheme) else { throw GatewayError.message("上游地址无效或指向网关自身") }
        var request = URLRequest(url: url)
        request.httpMethod = incoming.method; request.httpBody = body.isEmpty ? nil : body
        let hop: Set<String> = ["host", "connection", "content-length", "transfer-encoding", "upgrade", "expect", "proxy-authorization", "proxy-connection"]
        let connectionHeaders = Set((incoming.headers["connection"] ?? "").lowercased().split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) })
        // Original providers retain Codex's fresh auth and all end-to-end metadata.
        if !provider.isCustom {
            for (key, value) in incoming.headers where !hop.contains(key) && !connectionHeaders.contains(key) && !key.hasPrefix("sec-websocket-") {
                request.setValue(value, forHTTPHeaderField: key)
            }
        } else {
            request.setValue("application/json", forHTTPHeaderField: "Content-Type")
            request.setValue(incoming.headers["accept"] ?? "text/event-stream", forHTTPHeaderField: "Accept")
            for (key, value) in try provider.authorizationHeaders() { request.setValue(value, forHTTPHeaderField: key) }
        }
        return request
    }

    private func stream(_ request: URLRequest, to response: HTTPConnection) async throws -> Int {
        let (bytes, upstream) = try await session.bytes(for: request)
        guard let http = upstream as? HTTPURLResponse else { throw URLError(.badServerResponse) }
        var headers: [String: String] = [:]
        for (key, value) in http.allHeaderFields { headers[String(describing: key)] = String(describing: value) }
        try await response.begin(http.statusCode, headers: headers)
        let isSSE = http.value(forHTTPHeaderField: "content-type")?.contains("text/event-stream") == true
        var chunk = Data()
        for try await byte in bytes {
            chunk.append(byte)
            if chunk.count >= 16_384 || (isSSE && byte == 10) { try await response.send(chunk); chunk.removeAll(keepingCapacity: true) }
        }
        if !chunk.isEmpty { try await response.send(chunk) }
        return http.statusCode
    }

    private func chat(_ provider: ProviderConfig, body: [String: Any], model: String,
                      incoming: HTTPServer.Request, response: HTTPConnection) async throws {
        var payload: [String: Any] = ["model": model, "messages": ResponseTranslation.responsesToMessages(body), "stream": false]
        let tools = ResponseTranslation.responsesToChatTools(body)
        if !tools.isEmpty {
            payload["tools"] = tools
            payload["messages"] = ResponseTranslation.backfillReasoningContent(payload["messages"] as! [Any])
        }
        for key in ["temperature", "top_p", "parallel_tool_calls"] { if let value = body[key] { payload[key] = value } }
        if let value = body["max_output_tokens"] ?? body["max_tokens"] { payload["max_tokens"] = value }
        let request = try upstreamRequest(provider, incoming: incoming, body: JSONSerialization.data(withJSONObject: payload), suffix: "/chat/completions")
        let (data, upstream) = try await session.data(for: request)
        let status = (upstream as? HTTPURLResponse)?.statusCode ?? 502
        guard (200..<300).contains(status) else {
            try await response.json(status, ["error": ["message": "自定义服务返回 HTTP \(status)"]]); return
        }
        guard let chat = try JSONSerialization.jsonObject(with: data) as? [String: Any] else { throw URLError(.badServerResponse) }
        if body["stream"] as? Bool == false {
            try await response.json(200, ResponseTranslation.chatResponse(chat, model: model))
        } else {
            try await response.begin(200, headers: ["Content-Type": "text/event-stream", "Cache-Control": "no-cache"])
            try await response.send(ResponseTranslation.buildSSEFromChat(chat, model: model))
        }
    }

    private func webSocket(_ incoming: HTTPServer.Request, response: HTTPConnection, requestID: String) async throws {
        guard let key = incoming.headers["sec-websocket-key"], incoming.headers["sec-websocket-version"] == "13" else {
            throw GatewayError.message("WebSocket 握手无效")
        }
        try await response.upgradeWebSocket(key: key)
        guard let (first, opcode) = try await response.readWebSocket(),
              let object = try JSONSerialization.jsonObject(with: first) as? [String: Any],
              let model = object["model"] as? String,
              let provider = lookup(model).0 else { return }
        // Keep a native upstream socket, including incremental context and opaque events.
        guard provider.isResponsesBackend else {
            try await response.sendWebSocket(Data(ResponseTranslation.jsonString([
                "type": "error", "error": ["message": "该 Chat Completions 服务仅支持 HTTP Responses。", "code": "unsupported_protocol"]
            ]).utf8)); return
        }
        let suffix = incoming.path.hasPrefix("/v1/") ? String(incoming.path.dropFirst(3)) : incoming.path
        var request = try upstreamRequest(provider, incoming: incoming, body: Data(), suffix: suffix)
        request.httpMethod = "GET"
        var components = URLComponents(url: request.url!, resolvingAgainstBaseURL: false)!
        components.scheme = components.scheme == "https" ? "wss" : "ws"
        request.url = components.url
        let socket = session.webSocketTask(with: request)
        socket.resume()
        log("request", "\(requestID) · WebSocket → \(provider.id) / \(model)")
        defer { socket.cancel(with: .goingAway, reason: nil); response.close() }
        let receiving = Task {
            defer { response.close() }
            while !Task.isCancelled {
                switch try await socket.receive() {
                case .string(let value): try await response.sendWebSocket(Data(value.utf8))
                case .data(let value): try await response.sendWebSocket(value, opcode: 2)
                @unknown default: break
                }
            }
        }
        defer { receiving.cancel() }
        func forward(_ data: Data, opcode: UInt8) async throws {
            var outgoing = data
            if provider.isCustom, var object = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
               let model = object["model"] as? String {
                let route = lookup(model)
                guard route.0?.id == provider.id else { throw GatewayError.message("切换模型后请重新建立连接") }
                object["model"] = route.1
                outgoing = try JSONSerialization.data(withJSONObject: object)
            }
            if opcode == 1 { try await socket.send(.string(String(decoding: outgoing, as: UTF8.self))) }
            else { try await socket.send(.data(outgoing)) }
        }
        try await forward(first, opcode: opcode)
        while let (data, opcode) = try await response.readWebSocket() { try await forward(data, opcode: opcode) }
        log("success", "\(requestID) · WebSocket 已关闭")
    }
    private func elapsed(_ date: Date) -> Int { Int(Date().timeIntervalSince(date) * 1000) }
}

func safeError(_ error: Error) -> String {
    // Never put an upstream body, credential-bearing URL, or request in the log.
    if let error = error as? GatewayError { return error.localizedDescription }
    if let error = error as? URLError { return "网络错误 \(error.code.rawValue)：\(URLError.Code(rawValue: error.code.rawValue))" }
    if error is CancellationError { return "请求已取消" }
    return "操作失败（\((error as NSError).domain) / \((error as NSError).code)）"
}
