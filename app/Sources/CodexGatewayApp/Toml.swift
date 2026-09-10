import Foundation

/// A small, dependency-free TOML parser covering the subset Codex uses in
/// `~/.codex/config.toml` (tables, nested tables, string/bool/int/float values,
/// inline tables, and arrays). Produces nested `[String: Any]`.
enum Toml {
    static func parse(_ text: String) -> [String: Any] {
        var root: [String: Any] = [:]
        var path: [String] = []
        for statement in statements(text) {
            let line = statement.text.trimmingCharacters(in: .whitespacesAndNewlines)
            if line.isEmpty { continue }

            if line.hasPrefix("[") {
                let inner = line.dropFirst().dropLast()
                    .trimmingCharacters(in: .whitespaces)
                path = splitTopLevel(inner, separator: ".").map { unquoteKey($0.trimmingCharacters(in: .whitespaces)) }
                continue
            }

            guard let eq = firstUnquotedEqual(line) else { continue }
            let key = unquoteKey(String(line[..<eq]).trimmingCharacters(in: .whitespaces))
            let valueText = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
            guard let value = parseValue(valueText) else { continue }
            if path.isEmpty {
                root[key] = value
            } else {
                insert(&root, path: path, key: key, value: value)
            }
        }
        return root
    }

    static func unquoteKey(_ text: String) -> String {
        if text.hasPrefix("\"") || text.hasPrefix("'") { return parseValue(text) as? String ?? text }
        return text
    }

    struct Statement { let index: Int; let end: Int; let text: String }
    // Keep structural lines distinct from strings/arrays so config edits cannot
    // accidentally hit a provider-looking line inside developer instructions.
    static func statements(_ text: String) -> [Statement] {
        var result: [Statement] = [], value = "", start = 0, depth = 0
        var quote: Character?, triple = false, escaped = false
        let lines = text.components(separatedBy: "\n")
        for (lineIndex, line) in lines.enumerated() {
            if value.isEmpty { start = lineIndex }
            let chars = Array(line)
            var i = 0
            while i < chars.count {
                let ch = chars[i]
                if let q = quote {
                    value.append(ch)
                    if escaped { escaped = false; i += 1; continue }
                    if q == "\"", ch == "\\" { escaped = true; i += 1; continue }
                    if ch == q {
                        if triple {
                            if i + 2 < chars.count, chars[i + 1] == q, chars[i + 2] == q {
                                value.append(q); value.append(q); i += 2; quote = nil; triple = false
                            }
                        } else { quote = nil }
                    }
                } else {
                    if ch == "#" { break }
                    value.append(ch)
                    if ch == "\"" || ch == "'" {
                        quote = ch
                        if i + 2 < chars.count, chars[i + 1] == ch, chars[i + 2] == ch {
                            triple = true; value.append(ch); value.append(ch); i += 2
                        }
                    } else if ch == "[" || ch == "{" { depth += 1 }
                    else if ch == "]" || ch == "}" { depth -= 1 }
                }
                i += 1
            }
            if quote == nil && depth <= 0 {
                if !value.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    result.append(Statement(index: start, end: lineIndex, text: value))
                }
                value = ""; depth = 0
            } else { value += "\n"; escaped = false }
        }
        return result
    }

    private static func parseValue(_ text: String) -> Any? {
        if text.hasPrefix("\"\"\"") || text.hasPrefix("'''") { return String(text.dropFirst(3).dropLast(3)) }
        // Inline table: { k = "v", ... }
        if text.hasPrefix("{") {
            return parseInlineTable(text)
        }
        // Array: [ "a", "b" ]
        if text.hasPrefix("[") {
            return parseArray(text)
        }
        // Quoted string
        if (text.hasPrefix("\"") && text.hasSuffix("\"")) || (text.hasPrefix("'") && text.hasSuffix("'")) {
            let body = String(text.dropFirst().dropLast())
            if text.hasPrefix("\"") {
                if let decoded = try? JSONDecoder().decode(String.self, from: Data(text.utf8)) { return decoded }
                return body.replacingOccurrences(of: "\\\"", with: "\"")
                    .replacingOccurrences(of: "\\\\", with: "\\")
            }
            return body
        }
        if text == "true" { return true }
        if text == "false" { return false }
        if let intVal = Int(text) { return intVal }
        if let dblVal = Double(text) { return dblVal }
        return text
    }

    private static func parseInlineTable(_ text: String) -> [String: Any] {
        var result: [String: Any] = [:]
        let body = text.dropFirst().dropLast()
        for part in splitTopLevel(String(body), separator: ",") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            guard let eq = firstUnquotedEqual(trimmed) else { continue }
            let key = unquoteKey(trimmed[..<eq].trimmingCharacters(in: .whitespaces))
            let valText = trimmed[trimmed.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if let v = parseValue(valText) { result[key] = v }
        }
        return result
    }

    private static func parseArray(_ text: String) -> [Any] {
        let body = text.dropFirst().dropLast()
        return splitTopLevel(String(body), separator: ",").compactMap { part in
            parseValue(part.trimmingCharacters(in: .whitespaces))
        }
    }

    /// Split a string on a top-level separator (ignoring ones inside quotes/brackets/braces).
    private static func splitTopLevel(_ text: String, separator: Character) -> [String] {
        var result: [String] = []
        var current = ""
        var depth = 0
        var inQuote: Character? = nil
        for ch in text {
            if let q = inQuote {
                current.append(ch)
                if ch == q { inQuote = nil }
                continue
            }
            if ch == "\"" || ch == "'" { inQuote = ch; current.append(ch); continue }
            if ch == "[" || ch == "{" { depth += 1; current.append(ch); continue }
            if ch == "]" || ch == "}" { depth -= 1; current.append(ch); continue }
            if ch == separator && depth == 0 {
                result.append(current); current = ""; continue
            }
            current.append(ch)
        }
        result.append(current)
        return result
    }

    private static func firstUnquotedEqual(_ line: String) -> String.Index? {
        var inQuote: Character? = nil
        for (i, ch) in line.enumerated() {
            if let q = inQuote {
                if ch == q { inQuote = nil }
                continue
            }
            if ch == "\"" || ch == "'" { inQuote = ch; continue }
            if ch == "=" { return line.index(line.startIndex, offsetBy: i) }
        }
        return nil
    }

    private static func stripComment(_ line: String) -> String {
        var inQuote: Character? = nil
        for (i, ch) in line.enumerated() {
            if let q = inQuote {
                if ch == q { inQuote = nil }
                continue
            }
            if ch == "\"" || ch == "'" { inQuote = ch; continue }
            if ch == "#" {
                return String(line[..<line.index(line.startIndex, offsetBy: i)])
            }
        }
        return line
    }

    private static func insert(_ dict: inout [String: Any], path: [String], key: String, value: Any) {
        guard let head = path.first else {
            dict[key] = value
            return
        }
        if path.count == 1 {
            var sub = dict[head] as? [String: Any] ?? [:]
            sub[key] = value
            dict[head] = sub
            return
        }
        var sub = dict[head] as? [String: Any] ?? [:]
        insert(&sub, path: Array(path.dropFirst()), key: key, value: value)
        dict[head] = sub
    }
}
