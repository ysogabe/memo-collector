import CCCore
import Foundation

/// メモリ上の `RecordStore`。添付だけは一時ディレクトリに実ファイルとして書く（詳細画面が URL から画像を読むため）。
final class FakeRecordStore: RecordStore, @unchecked Sendable {
    // 状態はすべて lock の内側で触る。
    private let lock = NSLock()
    private var records: [String: ContextRecord] = [:]
    private var embeddings: [String: [Float]] = [:]
    /// 添付を置くデータルート（一時ディレクトリ）。
    let root: URL

    init(root: URL? = nil) {
        self.root = root ?? FileManager.default.temporaryDirectory
            .appendingPathComponent("ContextCapture-fake-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(at: self.root, withIntermediateDirectories: true)
    }

    /// 初期データを入れる（同期。組み立て時に使う）。
    func seedSync(_ items: [ContextRecord]) {
        lock.withLock { for r in items { records[r.id] = r } }
    }

    func insert(_ record: ContextRecord) async throws {
        try lock.withLock {
            guard records[record.id] == nil else { throw FakeStoreError.duplicate(record.id) }
            records[record.id] = record
        }
    }

    func update(_ record: ContextRecord) async throws {
        try lock.withLock {
            guard records[record.id] != nil else { throw FakeStoreError.notFound(record.id) }
            records[record.id] = record
        }
    }

    func get(id: String) async throws -> ContextRecord? {
        lock.withLock { records[id] }
    }

    func list(_ filter: InboxFilter) async throws -> [ContextRecord] {
        let all = lock.withLock { Array(records.values) }
        let matched = all.filter { Self.matches($0, filter) }.sorted { $0.capturedAt > $1.capturedAt }
        return Array(matched.dropFirst(filter.offset).prefix(filter.limit))
    }

    func count(_ filter: InboxFilter) async throws -> Int {
        lock.withLock { records.values.filter { Self.matches($0, filter) }.count }
    }

    func delete(id: String) async throws {
        lock.withLock {
            records[id] = nil
            embeddings[id] = nil
        }
    }

    func setEmbedding(id: String, vector: [Float]) async throws {
        lock.withLock { embeddings[id] = vector }
    }

    func search(vector: [Float], limit: Int) async throws -> [SearchHit] {
        let pairs: [(ContextRecord, [Float])] = lock.withLock {
            embeddings.compactMap { id, v in records[id].map { ($0, v) } }
        }
        return pairs
            .map { SearchHit(record: $0.0, score: zip($0.1, vector).reduce(0) { $0 + $1.0 * $1.1 }) }
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }

    func writeAttachment(_ data: Data, id: String, kind: AttachmentKind, ext: String, capturedAt: Date) async throws -> String {
        let rel = CCPaths.attachmentRelativePath(id: id, kind: kind, ext: ext, capturedAt: capturedAt)
        let url = root.appendingPathComponent(rel)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try data.write(to: url)
        return rel
    }

    func attachmentURL(for relativePath: String) async throws -> URL {
        root.appendingPathComponent(relativePath)
    }

    static func matches(_ r: ContextRecord, _ f: InboxFilter) -> Bool { f.matches(r) }
}

enum FakeStoreError: Error {
    case duplicate(String)
    case notFound(String)
}
