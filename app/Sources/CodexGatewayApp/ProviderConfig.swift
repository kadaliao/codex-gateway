import Foundation

/// A provider definition resolved from the codex config.toml (`[model_providers.X]`)
/// or from a user-defined custom provider (added in the app's panel).
struct ProviderConfig: Codable, Identifiable, Hashable {
    var id: String                 // table key / provider id, e.g. "deepseek"
    var name: String
    var baseURL: String?
    var envKey: String?
    var requiresOpenaiAuth: Bool
    var bearerToken: String?
    var httpHeaders: [String: String]
    var envHttpHeaders: [String: String]
    var queryParams: [String: String]
    var authCommand: String?
    var authArgs: [String]
    var wireAPI: String = "responses"
    var isCustom: Bool             // true for user-added providers, false for codex-configured

    init(id: String, name: String, baseURL: String? = nil, envKey: String? = nil,
         requiresOpenaiAuth: Bool = false, bearerToken: String? = nil,
         httpHeaders: [String: String] = [:], envHttpHeaders: [String: String] = [:],
         queryParams: [String: String] = [:], authCommand: String? = nil,
         authArgs: [String] = [], isCustom: Bool = false) {
        self.id = id
        self.name = name
        self.baseURL = baseURL
        self.envKey = envKey
        self.requiresOpenaiAuth = requiresOpenaiAuth
        self.bearerToken = bearerToken
        self.httpHeaders = httpHeaders
        self.envHttpHeaders = envHttpHeaders
        self.queryParams = queryParams
        self.authCommand = authCommand
        self.authArgs = authArgs
        self.isCustom = isCustom
    }

    // MARK: - Conversion from a parsed TOML table
    init(id: String, table: [String: Any], isCustom: Bool) {
        var headers: [String: String] = [:]
        if let h = table["http_headers"] as? [String: Any] {
            for (k, v) in h { headers[k] = String(describing: v) }
        }
        var envHeaders: [String: String] = [:]
        if let h = table["env_http_headers"] as? [String: Any] {
            for (k, v) in h { envHeaders[k] = String(describing: v) }
        }
        var query: [String: String] = [:]
        if let q = table["query_params"] as? [String: Any] {
            for (k, v) in q { query[k] = String(describing: v) }
        }
        var authCommand: String?
        var authArgs: [String] = []
        if let auth = table["auth"] as? [String: Any] {
            authCommand = auth["command"] as? String
            if let args = auth["args"] as? [Any] {
                authArgs = args.map { String(describing: $0) }
            }
        }
        self.init(
            id: id,
            name: (table["name"] as? String) ?? id,
            baseURL: table["base_url"] as? String,
            envKey: table["env_key"] as? String,
            requiresOpenaiAuth: (table["requires_openai_auth"] as? Bool) ?? false,
            bearerToken: table["experimental_bearer_token"] as? String,
            httpHeaders: headers,
            envHttpHeaders: envHeaders,
            queryParams: query,
            authCommand: authCommand,
            authArgs: authArgs,
            isCustom: isCustom
        )
        self.wireAPI = (table["wire_api"] as? String) ?? "responses"
    }

    // MARK: - Backend classification/
    var isOpenAIAPI: Bool { baseURL?.hasPrefix("https://api.openai.com") ?? false }
    var isChatGPTBackend: Bool {
        guard let base = baseURL?.lowercased() else { return false }
        return base.hasPrefix("https://chatgpt.com/backend-api/codex") || base.contains("chatgpt.com")
    }

    /// Whether this backend speaks the Responses API natively (so we pass through).
    var isResponsesBackend: Bool { wireAPI == "responses" }

    func resolvedURL(path: String) -> String? {
        guard let base = baseURL, var components = URLComponents(string: base) else { return nil }
        let parts = path.split(separator: "?", maxSplits: 1, omittingEmptySubsequences: false)
        components.path = components.path.trimmingCharacters(in: CharacterSet(charactersIn: "/"))
            .split(separator: "/").map(String.init).reduce("") { $0 + "/" + $1 } + String(parts[0])
        var items = components.queryItems ?? []
        if parts.count == 2 { items += URLComponents(string: "http://local/?" + parts[1])?.queryItems ?? [] }
        for (key, value) in queryParams where !items.contains(where: { $0.name == key }) {
            items.append(URLQueryItem(name: key, value: value))
        }
        if !items.isEmpty { components.queryItems = items }
        return components.url?.absoluteString
    }

    // MARK: - Auth
    struct ResolvedAuth {
        var bearer: String?
        var extraHeaders: [String: String]
    }

    func resolveAuth() -> Result<ResolvedAuth, Error> {
        let env = ProcessInfo.processInfo.environment
        var auth = ResolvedAuth(bearer: nil, extraHeaders: [:])
        auth.extraHeaders = httpHeaders
        for (key, envVar) in envHttpHeaders {
            if let val = env[envVar], !val.isEmpty { auth.extraHeaders[key] = val }
        }

        if let envKey = envKey {
            if let token = env[envKey], !token.isEmpty {
                auth.bearer = token
                return .success(auth)
            }
            return .failure(GatewayError.missingEnv(provider: id, envKey: envKey))
        }
        if let token = bearerToken { auth.bearer = token; return .success(auth) }
        if let command = authCommand {
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: command)
            proc.arguments = authArgs
            let pipe = Pipe()
            proc.standardOutput = pipe
            proc.standardError = FileHandle.nullDevice
            do { try proc.run() } catch { return .failure(GatewayError.message("认证命令无法启动")) }
            let data = pipe.fileHandleForReading.readDataToEndOfFile()
            proc.waitUntilExit()
            let token = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            guard proc.terminationStatus == 0, !token.isEmpty else {
                return .failure(GatewayError.message("认证命令未返回有效令牌"))
            }
            auth.bearer = token
            return .success(auth)
        }
        if requiresOpenaiAuth {
            // Best effort: OPENAI_API_KEY env, else codex auth.json access token.
            if let key = env["OPENAI_API_KEY"], !key.isEmpty {
                auth.bearer = key
                return .success(auth)
            }
            if let tokens = codexAUTHJSON()["tokens"] as? [String: Any],
               let access = tokens["access_token"] as? String {
                auth.bearer = access
                return .success(auth)
            }
            return .failure(GatewayError.missingOpenAIauth(provider: id))
        }
        return .success(auth)
    }

    func authorizationHeaders() throws -> [String: String] {
        let auth = try resolveAuth().get()
        var headers = auth.extraHeaders
        if let bearer = auth.bearer { headers["Authorization"] = "Bearer \(bearer)" }
        return headers
    }
}

/// The parsed codex config.toml.
struct CodexConfig {
    var model: String?
    var modelProvider: String?
    var providers: [String: ProviderConfig]
}

enum GatewayError: LocalizedError {
    case missingEnv(provider: String, envKey: String)
    case missingOpenAIauth(provider: String)
    case invalidPort(UInt16)
    case message(String)

    var errorDescription: String? {
        switch self {
        case .message(let message): return message
        case .missingEnv(let p, let e): return "provider '\(p)' needs env var \(e)"
        case .missingOpenAIauth(let p): return "provider '\(p)' needs OpenAI auth (OPENAI_API_KEY or login)"
        case .invalidPort(let p): return "invalid port \(p)"
        }
    }
}

// MARK: - Loading codex config
enum CodexConfigLoader {
    static func codexHome() -> URL {
        if let env = ProcessInfo.processInfo.environment["CODEX_HOME"], !env.isEmpty {
            return URL(fileURLWithPath: env).standardizedFileURL
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".codex")
    }

    static func defaultConfigURL() -> URL {
        codexHome().appendingPathComponent("config.toml")
    }

    static func load(configURL: URL? = nil) -> CodexConfig {
        let url = configURL ?? defaultConfigURL()
        guard let text = try? String(contentsOf: url, encoding: .utf8) else {
            return CodexConfig(model: nil, modelProvider: nil, providers: [:])
        }
        let raw = Toml.parse(text)
        var providers: [String: ProviderConfig] = [:]
        if let mp = raw["model_providers"] as? [String: Any] {
            for (pid, table) in mp {
                if let t = table as? [String: Any] {
                    providers[pid] = ProviderConfig(id: pid, table: t, isCustom: false)
                }
            }
        }
        return CodexConfig(
            model: raw["model"] as? String,
            modelProvider: raw["model_provider"] as? String,
            providers: providers
        )
    }
}

/// A user-defined custom provider (edited in the app's panel).
struct CustomProvider: Codable, Identifiable, Hashable {
    var id: String
    var name: String
    var baseURL: String
    var key: String   // raw API key stored by the app, or an env var name

    var wireAPI: String? = "responses"
    var models: [String]? = []
    var enabled: Bool? = true

    func toProviderConfig() -> ProviderConfig {
        let usesEnv = key.hasPrefix("env:")
        var config = ProviderConfig(
            id: id, name: name, baseURL: baseURL,
            envKey: usesEnv ? String(key.dropFirst(4)) : nil,
            requiresOpenaiAuth: false,
            bearerToken: usesEnv ? nil : (!key.isEmpty ? key : nil),
            isCustom: true
        )
        config.wireAPI = wireAPI ?? "chat"
        return config
    }
}

/// Read codex's `auth.json` (best-effort) to reuse ChatGPT/API auth for OpenAI pass-through.
func codexAUTHJSON() -> [String: Any] {
    let url = CodexConfigLoader.codexHome().appendingPathComponent("auth.json")
    guard let data = try? Data(contentsOf: url),
          let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
        return [:]
    }
    return json
}
