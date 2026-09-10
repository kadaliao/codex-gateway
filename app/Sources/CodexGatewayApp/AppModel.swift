import Foundation
import Combine
import AppKit

struct GatewayLog: Identifiable {
    let id = UUID()
    let date = Date()
    let level: String
    let message: String
    var line: String { "\(date.formatted(date: .omitted, time: .standard)) [\(level)] \(message)" }
}

@MainActor
final class AppModel: ObservableObject {
    @Published var codexProviders: [String: ProviderConfig] = [:]
    @Published var customProviders: [CustomProvider] = []
    @Published var snapshot: CatalogSnapshot?
    @Published var discoveryStatus: [String: String] = [:]
    @Published var discovered: [String: [String]] = [:]
    @Published var logs: [GatewayLog] = []
    @Published var isRunning = false
    @Published var isBusy = false
    @Published var status = "未连接"
    @Published var onError: String?
    @Published var activeProvider = "openai"
    @Published var activeModel = ""
    @Published var selectedPage = "overview"
    let port: UInt16
    let writer: CodexConfigWriter
    let dataDirectory: URL
    private let defaults: UserDefaults
    private var originalCatalog: [String: Any] = [:]
    private var runtime: GatewayRuntime?
    private var instanceLock: InstanceLock?
    private var ownsInstance = false
    private var uninstalled = false
    private let defaultsKey = "codexGateway.customProviders"
    var gatewayBase: String { "http://127.0.0.1:\(port)/v1" }
    var providersURL: URL { dataDirectory.appendingPathComponent("providers.json") }
    var logURL: URL { dataDirectory.appendingPathComponent("gateway.log") }
    var allProviders: [String: ProviderConfig] {
        var result = codexProviders
        for custom in customProviders where custom.enabled != false && result[custom.id] == nil { result[custom.id] = custom.toProviderConfig() }
        return result
    }
    var enabledCount: Int { customProviders.filter { $0.enabled != false }.count }

    init(configURL: URL = CodexConfigLoader.defaultConfigURL(), dataDirectory: URL? = nil,
         defaults: UserDefaults = .standard, port: UInt16 = 4000) {
        self.writer = CodexConfigWriter(configURL: configURL)
        self.dataDirectory = dataDirectory ?? ProcessInfo.processInfo.environment["CODEX_GATEWAY_HOME"].map { URL(fileURLWithPath: $0) }
            ?? FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library/Application Support/Codex Gateway")
        self.defaults = defaults; self.port = port
        do {
            try FileManager.default.createDirectory(at: self.dataDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
            instanceLock = try InstanceLock(url: self.dataDirectory.appendingPathComponent("instance.lock"))
            ownsInstance = true
            if FileManager.default.fileExists(atPath: logURL.path) {
                let lines = try String(contentsOf: logURL, encoding: .utf8).split(separator: "\n").suffix(100)
                logs = lines.map { GatewayLog(level: "history", message: String($0)) }
            }
            if FileManager.default.fileExists(atPath: providersURL.path) {
                customProviders = try JSONDecoder().decode([CustomProvider].self, from: Data(contentsOf: providersURL))
            } else if let data = defaults.data(forKey: defaultsKey) {
                customProviders = try JSONDecoder().decode([CustomProvider].self, from: data)
                try persistProviders(customProviders)
                defaults.removeObject(forKey: defaultsKey)
            }
            if try writer.restore() { log("info", "已恢复上次未正常退出留下的连接设置。") }
            try reloadCodexConfig()
            log("info", "已加载 \(customProviders.count) 个自定义 provider。")
        } catch { fail(error) }
    }

    func reloadCodexConfig() throws {
        let original = try writer.originalText()
        let raw = Toml.parse(original)
        activeProvider = raw["model_provider"] as? String ?? "openai"
        activeModel = raw["model"] as? String ?? "Codex 默认"
        var providers: [String: ProviderConfig] = [:]
        for (id, table) in raw["model_providers"] as? [String: [String: Any]] ?? [:] {
            providers[id] = ProviderConfig(id: id, table: table, isCustom: false)
        }
        if activeProvider == "openai" {
            let apiKeyLogin = codexAUTHJSON()["OPENAI_API_KEY"] as? String != nil
            let base = raw["openai_base_url"] as? String ?? (apiKeyLogin ? "https://api.openai.com/v1" : "https://chatgpt.com/backend-api/codex")
            providers["openai"] = ProviderConfig(id: "openai", name: "OpenAI", baseURL: base, requiresOpenaiAuth: true)
        }
        guard let active = providers[activeProvider], !CodexConfigWriter.isGatewayProvider(active, port: Int(port)) else {
            throw GatewayError.message("找不到原始上游地址；请先停止并恢复 Codex 连接，再重新接入。")
        }
        codexProviders = providers
        originalCatalog = try ModelCatalog.loadOriginal(configText: original, configDir: writer.configURL.deletingLastPathComponent())
        try rebuildCatalog()
    }

    @discardableResult func refresh() async -> Bool {
        guard !isBusy, ownsInstance else { return false }
        isBusy = true; defer { isBusy = false }
        do {
            try reloadCodexConfig()
            let providers = customProviders.filter { $0.enabled != false }
            // Discovery is concurrent; a failed provider cannot erase a successful result.
            let results = await withTaskGroup(of: (String, [String]?, String?).self) { group in
                for provider in providers {
                    discoveryStatus[provider.id] = "发现中…"
                    group.addTask {
                        do { return (provider.id, try await ModelCatalog.listProviderModels(provider.toProviderConfig()), nil) }
                        catch { return (provider.id, nil, safeError(error)) }
                    }
                }
                var values: [(String, [String]?, String?)] = []
                for await result in group { values.append(result) }
                return values
            }
            for (id, models, error) in results {
                if let models { discovered[id] = models; discoveryStatus[id] = "已发现 \(models.count) 个模型"; log("success", "\(id) · 发现 \(models.count) 个模型") }
                else { discoveryStatus[id] = error; log("error", "\(id) · \(error ?? "发现失败")") }
            }
            try rebuildCatalog()
            return true
        } catch { fail(error); return false }
    }

    private func rebuildCatalog() throws {
        var custom: [String: [String]] = [:]
        for provider in customProviders where provider.enabled != false {
            guard codexProviders[provider.id] == nil else { throw GatewayError.message("自定义 provider ID 与原配置冲突：\(provider.id)，请编辑改名。") }
            let manual = provider.models ?? []
            custom[provider.id] = manual.isEmpty ? (discovered[provider.id] ?? []) : manual
        }
        let updated = try ModelCatalog.merge(original: originalCatalog, custom: custom)
        if writer.isConnected { try writer.writeCatalog(updated) }
        runtime?.update(providers: allProviders, snapshot: updated)
        snapshot = updated
    }

    func saveProvider(_ value: CustomProvider, replacing oldID: String? = nil) async -> Bool {
        guard !isBusy, ownsInstance else { return false }
        do {
            let provider = try Self.validated(value)
            guard codexProviders[provider.id] == nil, !customProviders.contains(where: { $0.id == provider.id && $0.id != oldID }) else {
                throw GatewayError.message("这个 provider ID 已存在，请使用不同的 ID。")
            }
            var updated = customProviders.filter { $0.id != oldID }; updated.append(provider)
            try persistProviders(updated)
            customProviders = updated.sorted { $0.id < $1.id }
            if let oldID { discovered.removeValue(forKey: oldID); discoveryStatus.removeValue(forKey: oldID) }
            log("info", "已保存 provider：\(provider.id)")
            try rebuildCatalog()
        } catch { fail(error); return false }
        await refresh()
        return true
    }
    func removeProvider(_ id: String) {
        guard !isBusy else { return }
        do {
            let updated = customProviders.filter { $0.id != id }
            try persistProviders(updated); customProviders = updated
            discovered.removeValue(forKey: id); discoveryStatus.removeValue(forKey: id)
            try rebuildCatalog(); log("info", "已移除 provider：\(id)")
        } catch { fail(error) }
    }
    func toggleProvider(_ id: String) {
        guard !isBusy, let index = customProviders.firstIndex(where: { $0.id == id }) else { return }
        do {
            var updated = customProviders; updated[index].enabled = updated[index].enabled == false
            try persistProviders(updated); customProviders = updated
            try rebuildCatalog()
        } catch { fail(error) }
    }
    private func persistProviders(_ providers: [CustomProvider]) throws {
        try CodexConfigWriter.privateWrite(JSONEncoder().encode(providers), to: providersURL)
    }
    static func validated(_ input: CustomProvider) throws -> CustomProvider {
        var value = input
        value.id = value.id.trimmingCharacters(in: .whitespacesAndNewlines)
        value.name = value.name.trimmingCharacters(in: .whitespacesAndNewlines)
        value.baseURL = value.baseURL.trimmingCharacters(in: .whitespacesAndNewlines).trimmingCharacters(in: CharacterSet(charactersIn: "/"))
        value.key = value.key.trimmingCharacters(in: .whitespacesAndNewlines)
        guard value.id.range(of: "^[a-zA-Z0-9][a-zA-Z0-9_-]*$", options: .regularExpression) != nil else {
            throw GatewayError.message("ID 只能使用字母、数字、下划线和短横线。")
        }
        guard let url = URLComponents(string: value.baseURL), ["http", "https"].contains(url.scheme),
              url.host?.isEmpty == false, url.user == nil, url.password == nil, url.query == nil, url.fragment == nil else {
            throw GatewayError.message("填写完整的 http(s) 服务地址，不要把密钥放进地址。")
        }
        if value.name.isEmpty { value.name = value.id }
        value.models = Array(Set((value.models ?? []).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }.filter { !$0.isEmpty })).sorted()
        return value
    }

    func connect() async {
        guard !isBusy, !isRunning, ownsInstance else { return }
        guard await refresh() else { return }
        isBusy = true; status = "正在连接…"; defer { isBusy = false }
        do {
            guard let snapshot, !snapshot.routes.isEmpty else { throw GatewayError.message("还没有可接入的自定义模型。请刷新列表或手动填写模型 ID。") }
            let runtime = try GatewayRuntime(providers: allProviders, activeProvider: activeProvider, port: port, snapshot: snapshot) { [weak self] level, message in
                Task { @MainActor in self?.log(level, message) }
            }
            self.runtime = runtime
            try await runtime.start()
            try writer.apply(activeProvider: activeProvider, gatewayBase: gatewayBase, snapshot: snapshot)
            isRunning = true; status = "已连接 Codex"
            log("success", "本地网关已就绪；保留 \(snapshot.originalCount) 个原模型，追加 \(snapshot.routes.count) 个模型。")
            log("info", "Codex 在启动时读取模型目录，首次接入后需重新加载 Codex。")
        } catch {
            // If restoring fails, keep the listener and recovery journal available.
            do { try writer.restore(); await runtime?.stop(); runtime = nil; status = "未连接" }
            catch { isRunning = true; status = "恢复失败，保留网关"; fail(error) }
            fail(error)
        }
    }
    @discardableResult func stop() async -> Bool {
        guard ownsInstance else { return true }
        guard !isBusy else { return false }
        isBusy = true; defer { isBusy = false }
        do {
            let restored = try writer.restore()
            await runtime?.stop(); runtime = nil; isRunning = false; status = "未连接"
            log("info", restored ? "已恢复 Codex 原连接，网关及请求已停止。已运行的 Codex 需重新加载配置。" : "网关已停止。")
            return true
        } catch { fail(error); status = "恢复失败，保留网关"; return false }
    }
    func uninstall(removeApp: Bool) async -> Bool {
        guard ownsInstance, await stop() else { return false }
        do {
            try writer.uninstall()
            if removeApp && Bundle.main.bundleURL.pathExtension == "app" {
                try FileManager.default.trashItem(at: Bundle.main.bundleURL, resultingItemURL: nil)
            }
            defaults.removeObject(forKey: defaultsKey)
            if removeApp {
                let identifier = Bundle.main.bundleIdentifier ?? "com.kadaliao.codex-gateway"
                defaults.removePersistentDomain(forName: identifier)
                defaults.synchronize()
                let library = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent("Library")
                for relative in ["Caches/\(identifier)", "HTTPStorages/\(identifier)", "Saved Application State/\(identifier).savedState"] {
                    let path = library.appendingPathComponent(relative)
                    if FileManager.default.fileExists(atPath: path.path) { try FileManager.default.removeItem(at: path) }
                }
            }
            uninstalled = true
            if FileManager.default.fileExists(atPath: dataDirectory.path) { try FileManager.default.removeItem(at: dataDirectory) }
            customProviders = []; discovered = [:]; logs = []; snapshot = nil
            return true
        } catch { uninstalled = false; fail(error); return false }
    }
    func log(_ level: String, _ message: String) {
        guard !uninstalled, ownsInstance else { return }
        var message = message.replacingOccurrences(of: "\n", with: " ").replacingOccurrences(of: "\r", with: " ")
        for provider in customProviders where !provider.key.isEmpty && !provider.key.hasPrefix("env:") {
            message = message.replacingOccurrences(of: provider.key, with: "[REDACTED]")
        }
        let entry = GatewayLog(level: level, message: String(message.prefix(1500)))
        logs.append(entry); if logs.count > 500 { logs.removeFirst(logs.count - 500) }
        do {
            if let size = try? FileManager.default.attributesOfItem(atPath: logURL.path)[.size] as? Int, size > 2_000_000 {
                let archive = dataDirectory.appendingPathComponent("gateway.log.1")
                if FileManager.default.fileExists(atPath: archive.path) { try FileManager.default.removeItem(at: archive) }
                try FileManager.default.moveItem(at: logURL, to: archive)
            }
            if !FileManager.default.fileExists(atPath: logURL.path) { try CodexConfigWriter.privateWrite(Data(), to: logURL) }
            let file = try FileHandle(forWritingTo: logURL); defer { try? file.close() }
            try file.seekToEnd(); try file.write(contentsOf: Data((entry.line + "\n").utf8))
        } catch { onError = "日志无法写入磁盘：\(safeError(error))" }
    }
    func clearLogs() {
        do {
            try CodexConfigWriter.privateWrite(Data(), to: logURL)
            let archive = dataDirectory.appendingPathComponent("gateway.log.1")
            if FileManager.default.fileExists(atPath: archive.path) { try FileManager.default.removeItem(at: archive) }
            logs = []
        } catch { fail(error) }
    }
    func fail(_ error: Error) { onError = safeError(error); log("error", safeError(error)) }
}
