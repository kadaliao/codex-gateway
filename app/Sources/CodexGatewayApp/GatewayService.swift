import Foundation

final class GatewayRuntime: @unchecked Sendable {
    private let server: HTTPServer
    private let router: GatewayRouter
    var port: UInt16 { server.port }

    init(providers: [String: ProviderConfig], activeProvider: String?, port: UInt16,
         snapshot: CatalogSnapshot? = nil, log: @escaping (String, String) -> Void = { _, _ in }) throws {
        let router = GatewayRouter(providers: providers, activeProvider: activeProvider,
                                   gatewayPort: Int(port), snapshot: snapshot, log: log)
        self.router = router
        self.server = try HTTPServer(port: port) { request, response in
            await router.handle(request, response: response)
        }
    }
    func start() async throws { try await server.start() }
    func update(providers: [String: ProviderConfig], snapshot: CatalogSnapshot) {
        router.update(providers: providers, snapshot: snapshot)
    }
    func stop() async { await server.stop() }
}

struct ConfigEdit: Codable {
    var section: String
    var key: String
    var before: String?
    var after: String
}

struct ConnectionState: Codable {
    var original: String
    var edits: [ConfigEdit]
    var configExisted: Bool
}

/// Only owns two fields. Journal first, atomic config write second; restoration
/// reverses our fields without overwriting unrelated edits made while connected.
final class CodexConfigWriter {
    let configURL: URL
    var directory: URL { configURL.deletingLastPathComponent().appendingPathComponent(".codex-gateway") }
    var stateURL: URL { directory.appendingPathComponent("connection.json") }
    var catalogURL: URL { directory.appendingPathComponent("models.json") }
    var isConnected: Bool { FileManager.default.fileExists(atPath: stateURL.path) }

    init(configURL: URL = CodexConfigLoader.defaultConfigURL()) { self.configURL = configURL }

    func state() throws -> ConnectionState? {
        guard isConnected else { return nil }
        return try JSONDecoder().decode(ConnectionState.self, from: Data(contentsOf: stateURL))
    }
    func currentText() throws -> String {
        guard FileManager.default.fileExists(atPath: configURL.path) else { return "" }
        return try String(contentsOf: configURL, encoding: .utf8)
    }
    func originalText() throws -> String {
        guard let state = try state() else { return try currentText() }
        return try restoredText(currentText(), edits: state.edits)
    }

    func writeCatalog(_ snapshot: CatalogSnapshot) throws {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        try Self.privateWrite(JSONSerialization.data(withJSONObject: snapshot.document, options: [.prettyPrinted, .sortedKeys]), to: catalogURL)
    }

    func apply(activeProvider: String, gatewayBase: String, snapshot: CatalogSnapshot) throws {
        guard !isConnected else { try writeCatalog(snapshot); return }
        let original = try currentText()
        var lines = original.components(separatedBy: "\n")
        var edits: [ConfigEdit] = []
        let section = activeProvider == "openai" ? "" : "model_providers.\(activeProvider)"
        let key = activeProvider == "openai" ? "openai_base_url" : "base_url"
        // Don't silently redirect a different existing installer or reserved backend.
        if ["ollama", "lmstudio", "amazon-bedrock"].contains(activeProvider) {
            throw GatewayError.message("当前内置 provider 暂不支持透明接入，原配置未改动。")
        }
        for (section, key, value) in [(section, key, gatewayBase), ("", "model_catalog_json", catalogURL.path)] {
            let index = try Self.fieldIndex(lines, section: section, key: key)
            let before = index.map { lines[$0] }
            let after = "\(key) = \(Self.quote(value))"
            if let index { lines[index] = after }
            else { lines.insert(after, at: try Self.insertionIndex(lines, section: section)) }
            edits.append(ConfigEdit(section: section, key: key, before: before, after: after))
        }
        let state = ConnectionState(original: original, edits: edits,
                                    configExisted: FileManager.default.fileExists(atPath: configURL.path))
        try writeCatalog(snapshot)
        try Self.privateWrite(JSONEncoder().encode(state), to: stateURL)
        // Refuse to overwrite a concurrent external config edit.
        guard try currentText() == original else {
            try FileManager.default.removeItem(at: stateURL)
            throw GatewayError.message("Codex 配置刚被其他程序修改，请重试。")
        }
        try Self.privateWrite(Data(lines.joined(separator: "\n").utf8), to: configURL)
    }

    @discardableResult func restore() throws -> Bool {
        guard let state = try state() else { return false }
        let current = try currentText()
        let restored = try restoredText(current, edits: state.edits)
        guard try currentText() == current else { throw GatewayError.message("恢复时配置发生变化，请重试。") }
        if !state.configExisted && restored.isEmpty {
            if FileManager.default.fileExists(atPath: configURL.path) { try FileManager.default.removeItem(at: configURL) }
        } else { try Self.privateWrite(Data(restored.utf8), to: configURL) }
        try FileManager.default.removeItem(at: stateURL)
        if FileManager.default.fileExists(atPath: catalogURL.path) { try FileManager.default.removeItem(at: catalogURL) }
        try removeEmptyDirectory()
        return true
    }

    func uninstall() throws {
        try restore()
        if FileManager.default.fileExists(atPath: catalogURL.path) { try FileManager.default.removeItem(at: catalogURL) }
        try removeEmptyDirectory()
    }

    private func removeEmptyDirectory() throws {
        if FileManager.default.fileExists(atPath: directory.path),
           try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty {
            try FileManager.default.removeItem(at: directory)
        }
    }

    private func restoredText(_ text: String, edits: [ConfigEdit]) throws -> String {
        var lines = text.components(separatedBy: "\n")
        for edit in edits.reversed() {
            guard let index = try Self.fieldIndex(lines, section: edit.section, key: edit.key) else { continue }
            if lines[index] == edit.after {
                if let before = edit.before { lines[index] = before } else { lines.remove(at: index) }
            } else {
                // Retain a deliberate external replacement, but never delete the
                // recovery journal while a reformatted value still points at us.
                let values = Toml.parse(lines[index])
                if let value = values[edit.key] as? String,
                   value == (Toml.parse(edit.after)[edit.key] as? String) {
                    if let before = edit.before { lines[index] = before } else { lines.remove(at: index) }
                }
            }
        }
        return lines.joined(separator: "\n")
    }

    static func quote(_ string: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(data: try! encoder.encode(string), encoding: .utf8)!
    }
    static func privateWrite(_ data: Data, to url: URL) throws {
        try data.write(to: url, options: [.atomic])
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    static func sectionName(_ line: String) -> String? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("["), let end = trimmed.firstIndex(of: "]") else { return nil }
        return String(trimmed[trimmed.index(after: trimmed.startIndex)..<end])
            .replacingOccurrences(of: "\"", with: "").replacingOccurrences(of: "'", with: "")
    }
    static func fieldIndex(_ lines: [String], section: String, key: String) throws -> Int? {
        var current = "", matches: [Int] = []
        for statement in Toml.statements(lines.joined(separator: "\n")) {
            let index = statement.index, line = statement.text
            if let name = sectionName(line) { current = name; continue }
            guard current == section, let eq = line.firstIndex(of: "=") else { continue }
            let field = line[..<eq].trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\"'"))
            if field == key {
                guard statement.index == statement.end else { throw GatewayError.message("连接字段使用了多行格式，请改成单行后重试。") }
                matches.append(index)
            }
        }
        guard matches.count <= 1 else { throw GatewayError.message("配置字段重复：\(section).\(key)") }
        return matches.first
    }
    static func insertionIndex(_ lines: [String], section: String) throws -> Int {
        if section.isEmpty { return 0 }
        guard let statement = Toml.statements(lines.joined(separator: "\n")).first(where: { sectionName($0.text) == section }) else {
            throw GatewayError.message("找不到 provider 配置段：\(section)，原配置未修改。")
        }
        return statement.end + 1
    }
    static func isGatewayProvider(_ provider: ProviderConfig, port: Int) -> Bool {
        guard let base = provider.baseURL, let url = URL(string: base), url.port == port else { return false }
        return ["localhost", "127.0.0.1", "::1"].contains(url.host ?? "")
    }
}
