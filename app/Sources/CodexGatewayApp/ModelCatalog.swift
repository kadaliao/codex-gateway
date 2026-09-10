import Foundation

struct ModelRoute: Equatable {
    let providerID: String
    let modelID: String
}

struct CatalogSnapshot {
    var document: [String: Any]
    var routes: [String: ModelRoute]
    var models: [[String: Any]] { document["models"] as? [[String: Any]] ?? [] }
    var originalCount: Int
}

enum ModelCatalog {
    static func codexModelInfo(slug: String) -> [String: Any] {
        ["slug": slug, "display_name": slug, "description": "自定义模型",
         "supported_reasoning_levels": [], "shell_type": "unified_exec",
         "visibility": "list", "supported_in_api": true, "priority": 100,
         "support_verbosity": false, "truncation_policy": ["mode": "tokens", "limit": 100_000],
         "experimental_supported_tools": [], "web_search_tool_type": "text",
         "base_instructions": "You are Codex, an AI coding agent. Help the user solve their task.",
         "input_modalities": ["text"], "context_window": 128_000]
    }

    // Keep the original objects, including unknown/future capability fields.
    static func merge(original: [String: Any], custom: [String: [String]]) throws -> CatalogSnapshot {
        guard let existing = original["models"] as? [[String: Any]],
              existing.allSatisfy({ $0["slug"] is String }) else {
            throw GatewayError.message("原模型目录格式不正确，已保留原配置。")
        }
        var models = existing
        var used = Set(existing.compactMap { $0["slug"] as? String })
        let entries = custom.keys.sorted().flatMap { provider in
            Array(Set(custom[provider] ?? [])).sorted().map { ModelRoute(providerID: provider, modelID: $0) }
        }
        let counts = Dictionary(grouping: entries, by: \.modelID).mapValues(\.count)
        // Reserve bare names before allocating aliases (including names with '/').
        let bareNames = Set(entries.filter { counts[$0.modelID] == 1 && !used.contains($0.modelID) }.map(\.modelID))
        var routes: [String: ModelRoute] = [:]
        for entry in entries {
            var slug = entry.modelID
            if used.contains(slug) || counts[slug, default: 0] > 1 {
                let base = "\(entry.providerID)/\(entry.modelID)"
                slug = base
                var suffix = 2
                while used.contains(slug) || bareNames.contains(slug) {
                    slug = "\(base)-\(suffix)"; suffix += 1
                }
            }
            used.insert(slug)
            routes[slug] = entry
            var info = codexModelInfo(slug: slug)
            info["description"] = "\(entry.providerID) · \(entry.modelID)"
            models.append(info)
        }
        var document = original
        document["models"] = models
        return CatalogSnapshot(document: document, routes: routes, originalCount: existing.count)
    }

    static func listProviderModels(_ provider: ProviderConfig) async throws -> [String] {
        guard let value = provider.resolvedURL(path: "/models"), let url = URL(string: value) else {
            throw GatewayError.message("服务地址无效")
        }
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        for (k, v) in try provider.authorizationHeaders() { request.setValue(v, forHTTPHeaderField: k) }
        let (data, response) = try await URLSession.shared.data(for: request)
        let status = (response as? HTTPURLResponse)?.statusCode ?? 0
        guard (200..<300).contains(status) else { throw GatewayError.message("模型发现失败：HTTP \(status)") }
        guard let object = try JSONSerialization.jsonObject(with: data) as? [String: Any],
              let array = object["data"] as? [Any] else {
            throw GatewayError.message("/models 未返回标准模型列表，请手动填写模型 ID。")
        }
        let ids = array.compactMap { ($0 as? String) ?? ($0 as? [String: Any])?["id"] as? String }
            .filter { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        guard !ids.isEmpty else { throw GatewayError.message("服务返回空列表，请手动填写模型 ID。") }
        return Array(Set(ids)).sorted()
    }

    static func loadOriginal(configText: String, configDir: URL) throws -> [String: Any] {
        if let path = Toml.parse(configText)["model_catalog_json"] as? String {
            let expanded = NSString(string: path).expandingTildeInPath
            let url = expanded.hasPrefix("/") ? URL(fileURLWithPath: expanded) : configDir.appendingPathComponent(expanded)
            return try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as? [String: Any] ?? [:]
        }
        // Ask the installed Codex for its actual catalog; don't fabricate original models.
        let process = Process()
        let candidates = ["/Applications/Codex.app/Contents/Resources/codex",
                          FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".local/bin/codex").path,
                          "/opt/homebrew/bin/codex", "/usr/local/bin/codex"]
        guard let binary = candidates.first(where: { FileManager.default.isExecutableFile(atPath: $0) }) else {
            throw GatewayError.message("找不到 Codex，无法读取原模型目录。请先安装 Codex。")
        }
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["debug", "models", "--bundled"]
        let output = Pipe(); process.standardOutput = output; process.standardError = FileHandle.nullDevice
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw GatewayError.message("读取 Codex 原模型目录失败。") }
        let value = try JSONSerialization.jsonObject(with: data)
        if let object = value as? [String: Any], object["models"] != nil { return object }
        if let models = value as? [[String: Any]] { return ["models": models] }
        throw GatewayError.message("Codex 返回了无法识别的模型目录。")
    }
}
