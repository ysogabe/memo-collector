import CCCore
import Foundation
import GRDB
import SearchEvaluation

public struct Evidence: Codable, Equatable {
    public var field: String
    public var matchedText: String
    public var utf16Offset: Int
    public var utf16Length: Int
}
public struct KeywordHit: Codable {
    public var recordID: String
    public var score: Double
    public var evidence: [Evidence]
}
public enum SearchText {
    public static func normalize(_ text: String) -> String { text.precomposedStringWithCompatibilityMapping.lowercased() }
    public static func terms(_ text: String) -> [String] {
        var seen = Set<String>()
        return normalize(text).split(whereSeparator: \.isWhitespace).map(String.init).filter { seen.insert($0).inserted }
    }
    public static func number(_ term: String) -> String? {
        guard term.hasPrefix("#"), term.count > 1, term.dropFirst().allSatisfy(\.isNumber) else { return nil }
        return String(term.dropFirst())
    }
    public static func identifier(_ term: String) -> Bool {
        term.range(of: #"^[a-z_][a-z0-9_]*$"#, options: .regularExpression) != nil
    }
    public static func exactLookup(_ text: String) -> Bool {
        let ts = terms(text)
        return ts.contains { number($0) != nil || $0.hasPrefix("https://") || $0.hasPrefix("http://") }
            || (ts.count == 1 && identifier(ts[0]))
    }
    public static func matches(_ term: String, in text: String) -> Bool {
        let normalized = normalize(text)
        if identifier(term) {
            let escaped = NSRegularExpression.escapedPattern(for: term)
            return normalized.range(of: "(?<![\\p{L}\\p{N}_])\(escaped)(?![\\p{L}\\p{N}_])", options: .regularExpression) != nil
        }
        return normalized.contains(term)
    }
}
/// An isolated projection. Only explicit fixture records are inserted; this does not open the product DB.
public final class KeywordIndex {
    let db: DatabaseQueue
    let records: [String: ContextRecord]
    public let sqliteVersion: String
    public init(records: [ContextRecord], file: URL) throws {
        self.records = Dictionary(uniqueKeysWithValues: records.map { ($0.id, $0) })
        db = try DatabaseQueue(path: file.path)
        sqliteVersion = try db.read { try String.fetchOne($0, sql: "SELECT sqlite_version()")! }
        try db.write { db in
            try db.execute(sql: "CREATE TABLE documents(id INTEGER PRIMARY KEY, record_id TEXT UNIQUE, status TEXT, body TEXT)")
            try db.execute(sql: "CREATE VIRTUAL TABLE word_fts USING fts5(body, tokenize=\"porter unicode61 remove_diacritics 2 categories 'L* N* Co M*'\")")
            try db.execute(sql: "CREATE VIRTUAL TABLE tri_fts USING fts5(body, tokenize='trigram')")
            for (i, record) in records.enumerated() {
                let body = SearchText.normalize(Self.fields(record).map(\.1).joined(separator: "\n"))
                try db.execute(sql: "INSERT INTO documents(id,record_id,status,body) VALUES(?,?,?,?)", arguments: [i+1, record.id, record.status.rawValue, body])
                for table in ["word_fts", "tri_fts"] { try db.execute(sql: "INSERT INTO \(table)(rowid,body) VALUES(?,?)", arguments: [i+1,body]) }
            }
        }
    }
    static func fields(_ record: ContextRecord) -> [(String, String)] {
        [("annotation", record.annotation.text), ("title", record.window?.title ?? ""), ("url", record.url ?? ""), ("app", record.app.name)]
    }
    public func search(_ text: String, includeArchived: Bool, trigram: Bool, limit: Int) throws -> [KeywordHit] {
        let terms = SearchText.terms(text)
        guard !terms.isEmpty, limit > 0 else { return [] }
        let table = trigram ? "tri_fts" : "word_fts"
        let ftsTerms = trigram ? terms.filter { $0.unicodeScalars.count >= 3 } : terms
        let patterns = ftsTerms.map { "\"" + $0.replacingOccurrences(of: "\"", with: "\"\"") + "\"" }
        let statusSQL = includeArchived ? "1" : "d.status != 'archived'"
        var candidates = Set<String>()
        if !patterns.isEmpty {
            let ids: [String] = try db.read { db in
                try String.fetchAll(db, sql: "SELECT d.record_id FROM \(table) JOIN documents d ON d.id=\(table).rowid WHERE \(table) MATCH ? AND \(statusSQL) ORDER BY bm25(\(table)), d.record_id LIMIT 500", arguments: [patterns.joined(separator: " OR ")])
            }
            candidates.formUnion(ids)
        }
        // trigram cannot represent <3 scalars. Structured lookup also needs the original identifier, including punctuation.
        let fallback = terms.filter { $0.unicodeScalars.count < 3 || SearchText.number($0) != nil || SearchText.identifier($0) || $0.hasPrefix("http") }
        for term in fallback {
            let ids: [String] = try db.read { db in
                try String.fetchAll(db, sql: "SELECT d.record_id FROM documents d WHERE \(statusSQL) AND instr(d.body,?) > 0", arguments: [term])
            }
            candidates.formUnion(ids)
        }
        var hits: [KeywordHit] = []
        for id in candidates {
            guard let record = records[id] else { continue }
            let fields = Self.fields(record)
            var matched = 0, evidence: [Evidence] = [], reject = false
            for term in terms {
                if let number = SearchText.number(term) {
                    let issue = record.url.flatMap(URL.init(string:))?.pathComponents
                    let actual = issue.flatMap { parts in parts.count > 2 && parts[parts.count-2] == "issues" ? parts.last : nil }
                    guard actual == number else { reject = true; break }
                }
                if term.hasPrefix("https://") || term.hasPrefix("http://") {
                    guard record.url.map(SearchText.normalize) == term else { reject = true; break }
                }
                let matching = fields.filter { SearchText.matches(term, in: $0.1) }
                guard !matching.isEmpty else { continue }
                matched += 1
                for (field, original) in matching {
                    // The range refers to the original field. Normalized matches without an original range have no fabricated excerpt.
                    if let range = original.range(of: term, options: [.caseInsensitive, .widthInsensitive]) {
                        let ns = NSRange(range, in: original)
                        evidence.append(Evidence(field: field, matchedText: String(original[range]), utf16Offset: ns.location, utf16Length: ns.length))
                    }
                }
            }
            guard !reject, matched > 0 else { continue }
            let coverage = Double(matched) / Double(terms.count)
            guard coverage >= 0.5 else { continue }
            hits.append(KeywordHit(recordID: id, score: coverage, evidence: evidence))
        }
        return Array(hits.sorted { $0.score != $1.score ? $0.score > $1.score : $0.recordID > $1.recordID }.prefix(limit))
    }
}
public enum Fusion {
    /// Scores are rank scores, never cosine probabilities. Each source contributes once per ID.
    public static func rrf(_ lists: [[RankedItem]], k: Double = 60, limit: Int = 30) -> [RankedItem] {
        var scores: [String: Double] = [:]
        for list in lists {
            var seen = Set<String>(), rank = 0
            for item in list where seen.insert(item.recordID).inserted {
                rank += 1; scores[item.recordID, default: 0] += 1 / (k + Double(rank))
            }
        }
        return scores.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key > $1.key }
            .prefix(max(0, limit)).map { RankedItem(recordID: $0.key, score: $0.value) }
    }
    public static func gate(_ list: [RankedItem], threshold: Double, exactLookup: Bool) -> [RankedItem] {
        exactLookup ? [] : list.filter { ($0.score ?? -.infinity) >= threshold }
    }
}
