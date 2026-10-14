import CCCore
import Foundation

public struct RecordFixture: Codable {
    public var record: ContextRecord
    public var group: String
    public var split: String
    public var screen: String?
}
public struct Corpus: Codable {
    public var schemaVersion: Int
    public var corpusID: String
    public var records: [RecordFixture]
    public func validate() throws {
        guard schemaVersion == 1, !records.isEmpty else { throw EvaluationError.invalid("corpus schema/empty") }
        let ids = records.map { $0.record.id }
        guard Set(ids).count == ids.count else { throw EvaluationError.invalid("duplicate record ID") }
        var splits: [String: String] = [:]
        for row in records {
            guard ULID.isValid(row.record.id), !row.group.isEmpty else { throw EvaluationError.invalid("invalid record ID/group") }
            if let screen = row.screen, screen.hasPrefix("/") || screen.split(separator: "/").contains("..") { throw EvaluationError.invalid("screen outside fixture root") }
            guard ["dev", "holdout"].contains(row.split) else { throw EvaluationError.invalid("unknown split") }
            if let old = splits[row.group], old != row.split { throw EvaluationError.invalid("group crosses splits") }
            splits[row.group] = row.split
        }
    }
}
public struct Relevant: Codable, Equatable {
    public var recordID: String
    public var grade: Int
    public init(_ recordID: String, grade: Int = 1) { self.recordID = recordID; self.grade = grade }
}
public struct QueryFixture: Codable {
    public var id: String
    public var text: String
    public var relevant: [Relevant]
    public var tags: [String]
    public var group: String
    public var split: String
    public var includeArchived: Bool
}
public struct QuerySet: Codable {
    public var schemaVersion: Int
    public var corpusID: String
    public var queries: [QueryFixture]
    public func validate(corpus: Corpus) throws {
        try corpus.validate()
        guard schemaVersion == 1, corpusID == corpus.corpusID, !queries.isEmpty else { throw EvaluationError.invalid("query schema/corpus/empty") }
        guard Set(queries.map(\.id)).count == queries.count else { throw EvaluationError.invalid("duplicate query ID") }
        let records = Dictionary(uniqueKeysWithValues: corpus.records.map { ($0.record.id, $0) })
        var splits = Dictionary(corpus.records.map { ($0.group, $0.split) }, uniquingKeysWith: { a, _ in a })
        var textSplits: [String: String] = [:]
        for q in queries {
            if let split = textSplits[q.text], split != q.split { throw EvaluationError.invalid("query text crosses splits") }
            textSplits[q.text] = q.split
            guard !q.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
                  ["dev", "holdout"].contains(q.split), !q.tags.isEmpty,
                  Set(q.relevant.map(\.recordID)).count == q.relevant.count else { throw EvaluationError.invalid("invalid query \(q.id)") }
            if let split = splits[q.group], split != q.split { throw EvaluationError.invalid("query group crosses splits") }
            splits[q.group] = q.split
            for rel in q.relevant {
                guard let row = records[rel.recordID], row.split == q.split, (1...3).contains(rel.grade),
                      q.includeArchived || row.record.status != .archived else { throw EvaluationError.invalid("invalid relevance \(q.id)/\(rel.recordID)") }
            }
        }
    }
}
public enum EvaluationError: Error, CustomStringConvertible {
    case invalid(String)
    public var description: String { switch self { case .invalid(let message): return message } }
}

public struct QueryMetrics: Codable, Equatable {
    public let recall: [String: Double]?
    public let hitRate: [String: Double]?
    public let ndcg: [String: Double]?
    public let reciprocalRank: Double?
    public let emptyResult: Bool
}
public enum Metrics {
    public static let cutoffs = [1, 3, 10]
    public static func evaluate(rankedIDs: [String], relevant: [Relevant]) -> QueryMetrics {
        var seen = Set<String>()
        let ids = rankedIDs.filter { seen.insert($0).inserted }
        guard !relevant.isEmpty else { return QueryMetrics(recall: nil, hitRate: nil, ndcg: nil, reciprocalRank: nil, emptyResult: ids.isEmpty) }
        let grades = Dictionary(relevant.map { ($0.recordID, $0.grade) }, uniquingKeysWith: max)
        var recall: [String: Double] = [:], hit: [String: Double] = [:], ndcg: [String: Double] = [:]
        let ideal = grades.values.sorted(by: >)
        func dcg(_ values: [Int]) -> Double {
            values.enumerated().reduce(0) { $0 + (pow(2.0, Double($1.element)) - 1) / log2(Double($1.offset + 2)) }
        }
        for k in cutoffs {
            let found = ids.prefix(k).filter { grades[$0] != nil }.count
            recall[String(k)] = Double(found) / Double(grades.count)
            hit[String(k)] = found > 0 ? 1 : 0
            let normalizer = dcg(Array(ideal.prefix(k)))
            ndcg[String(k)] = normalizer > 0 ? dcg(ids.prefix(k).map { grades[$0] ?? 0 }) / normalizer : 0
        }
        let rr = ids.firstIndex { grades[$0] != nil }.map { 1 / Double($0 + 1) } ?? 0
        return QueryMetrics(recall: recall, hitRate: hit, ndcg: ndcg, reciprocalRank: rr, emptyResult: ids.isEmpty)
    }
    /// Nearest-rank percentile, including the cold first invocation only when it is in the input.
    public static func percentile(_ values: [Double], _ p: Double) -> Double? {
        guard !values.isEmpty else { return nil }
        let sorted = values.sorted()
        let index = max(0, min(sorted.count - 1, Int(ceil(p * Double(sorted.count))) - 1))
        return sorted[index]
    }
}
public struct RankedItem: Codable {
    public var recordID: String
    public var score: Double?
    public init(recordID: String, score: Double? = nil) { self.recordID = recordID; self.score = score }
}
public struct QueryResult: Codable {
    public var queryID: String
    public var split: String
    public var tags: [String]
    public var items: [RankedItem]
    public var milliseconds: [Double]
    public var metrics: QueryMetrics
    public init(query: QueryFixture, items: [RankedItem], milliseconds: [Double]) {
        queryID = query.id; split = query.split; tags = query.tags; self.items = items
        self.milliseconds = milliseconds
        metrics = Metrics.evaluate(rankedIDs: items.map(\.recordID), relevant: query.relevant)
    }
}
public struct Summary: Codable {
    public var queryCount: Int
    public var answerableCount: Int
    public var noAnswerCount: Int
    public var recall: [String: Double]
    public var hitRate: [String: Double]
    public var ndcg: [String: Double]
    public var mrr: Double?
    public var noAnswerEmptyRate: Double?
    public var noAnswerFalseHitRate: Double?
    public var p50Milliseconds: Double?
    public var p95Milliseconds: Double?
    public var firstPassP95Milliseconds: Double?
    public static func aggregate(_ rows: [QueryResult]) -> Summary {
        let positive = rows.filter { $0.metrics.recall != nil }
        let negative = rows.filter { $0.metrics.recall == nil }
        func average(_ values: [Double]) -> Double? { values.isEmpty ? nil : values.reduce(0,+) / Double(values.count) }
        var r: [String: Double] = [:], h: [String: Double] = [:], n: [String: Double] = [:]
        for k in Metrics.cutoffs.map(String.init) {
            r[k] = average(positive.compactMap { $0.metrics.recall?[k] })
            h[k] = average(positive.compactMap { $0.metrics.hitRate?[k] })
            n[k] = average(positive.compactMap { $0.metrics.ndcg?[k] })
        }
        let empty = average(negative.map { $0.metrics.emptyResult ? 1 : 0 })
        let warm = rows.flatMap { Array($0.milliseconds.dropFirst()) }
        return Summary(queryCount: rows.count, answerableCount: positive.count, noAnswerCount: negative.count,
                       recall: r, hitRate: h, ndcg: n, mrr: average(positive.compactMap { $0.metrics.reciprocalRank }),
                       noAnswerEmptyRate: empty, noAnswerFalseHitRate: empty.map { 1 - $0 },
                       p50Milliseconds: Metrics.percentile(warm, 0.5), p95Milliseconds: Metrics.percentile(warm, 0.95),
                       firstPassP95Milliseconds: Metrics.percentile(rows.compactMap { $0.milliseconds.first }, 0.95))
    }
}
