import CCCore
import Foundation
import MCP

/// ツール引数（`[String: Value]?`）の検証。スキーマ違反は `MCPError.invalidParams`（JSON-RPC -32602）で投げる。
struct MCPArguments {
    let tool: CCMCPToolName
    let values: [String: Value]

    init(tool: CCMCPToolName, _ raw: [String: Value]?, allowed: Set<String>) throws {
        self.tool = tool
        self.values = raw ?? [:]
        let unknown = Set(values.keys).subtracting(allowed)
        if !unknown.isEmpty {
            throw invalid("未知の引数: \(unknown.sorted().joined(separator: ", "))")
        }
    }

    func invalid(_ message: String) -> MCPError {
        MCPError.invalidParams("\(tool.rawValue): \(message)")
    }

    /// 値が無い・null なら nil。
    private func present(_ key: String) -> Value? {
        guard let v = values[key] else { return nil }
        if case .null = v { return nil }
        return v
    }

    func string(_ key: String, required: Bool = false, maxLength: Int? = nil, trim: Bool = true) throws -> String? {
        guard let v = present(key) else {
            if required { throw invalid("\(key) は必須") }
            return nil
        }
        guard case let .string(raw) = v else { throw invalid("\(key) は文字列") }
        let s = trim ? raw.trimmingCharacters(in: .whitespacesAndNewlines) : raw
        if required, s.isEmpty { throw invalid("\(key) が空") }
        if let maxLength, s.count > maxLength { throw invalid("\(key) は \(maxLength) 文字まで（\(s.count) 文字）") }
        return s
    }

    func bool(_ key: String) throws -> Bool? {
        guard let v = present(key) else { return nil }
        guard case let .bool(b) = v else { throw invalid("\(key) は真偽値") }
        return b
    }

    /// 整数（`10.0` のような整数値の小数も受ける）。範囲外はエラー。
    func int(_ key: String, range: ClosedRange<Int>) throws -> Int? {
        guard let v = present(key) else { return nil }
        let n: Int
        switch v {
        case let .int(i): n = i
        case let .double(d) where d.rounded() == d && abs(d) < 1e9: n = Int(d)
        default: throw invalid("\(key) は整数")
        }
        guard range.contains(n) else { throw invalid("\(key) は \(range.lowerBound)〜\(range.upperBound)（\(n)）") }
        return n
    }

    /// ULID 形式の id（大文字に正規化して返す）。
    func id() throws -> String {
        guard let s = try string("id", required: true) else { throw invalid("id は必須") }
        guard let ulid = ULID(string: s) else { throw invalid("id が ULID 形式ではない") }
        return ulid.string
    }

    /// ISO 8601 の日時。日付だけ（YYYY-MM-DD）なら `timeZone` の 0 時。
    func date(_ key: String, timeZone: TimeZone) throws -> Date? {
        guard let s = try string(key) else { return nil }
        if let d = CCJSON.parseDate(s) { return d }
        let f = DateFormatter()
        f.calendar = Calendar(identifier: .gregorian)
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "yyyy-MM-dd"
        f.isLenient = false
        if s.count == 10, let d = f.date(from: s) { return d }
        throw invalid("\(key) が ISO 8601 の日時ではない（例 2026-10-10T09:00:00+09:00）")
    }
}
