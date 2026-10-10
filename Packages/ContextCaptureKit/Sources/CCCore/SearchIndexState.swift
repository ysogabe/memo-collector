import Foundation

/// 検索索引の状態ファイル（データルート直下の `search-index.json`）。
///
/// アプリ（`SearchIndexMaintainer`）が書き、cc-mcp（別プロセス）が読む。**形式の定義はここだけ**（両方がこの型を使う）。
/// cc-mcp はここの `image_tokens` で同じ設定の埋め込みを作り、`index_signature` が自分のものと一致し
/// `status == .ready` のときだけベクトル検索を使う。
///
/// 形式（JSON。キーは snake_case、日時は ISO 8601（秒まで））:
/// ```json
/// { "dimension": 256, "image_tokens": 280, "index_signature": "...", "status": "ready",
///   "updated_at": "2026-10-10T12:00:00Z" }
/// ```
/// `failed_ids` は `status == "degraded"` のときだけ書く（任意。古いファイルには無い）。
public struct SearchIndexState: Codable, Equatable, Sendable {
    /// 索引の状態。知らない値も読めるように文字列のまま持つ（読めないファイルを「無い」と取り違えないため）。
    public struct Status: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
        public var rawValue: String
        public init(rawValue: String) { self.rawValue = rawValue }

        /// 全件がこのシグネチャで埋め込まれている。cc-mcp がベクトル検索を使うのはこのときだけ。
        public static let ready = Status(rawValue: "ready")
        /// 作り直しの途中（古いシグネチャのベクトルが混ざっている）。
        public static let rebuilding = Status(rawValue: "rebuilding")
        /// 作り直しは終わったが、一部の記録（`failedIDs`）の埋め込みに失敗した（古いベクトルのまま・無いまま）。
        /// 次の起動で失敗分だけ再試行する。
        public static let degraded = Status(rawValue: "degraded")

        public var description: String { rawValue }

        public init(from decoder: Decoder) throws {
            rawValue = try decoder.singleValueContainer().decode(String.self)
        }

        public func encode(to encoder: Encoder) throws {
            var c = encoder.singleValueContainer()
            try c.encode(rawValue)
        }
    }

    public var indexSignature: String
    public var imageTokens: Int
    public var dimension: Int
    public var status: Status
    public var updatedAt: Date
    /// `degraded` のとき、埋め込みに失敗した記録の id（次回の再試行の対象）。それ以外は nil。
    public var failedIDs: [String]?

    public static let fileName = "search-index.json"

    public init(indexSignature: String, imageTokens: Int, dimension: Int, status: Status, updatedAt: Date,
                failedIDs: [String]? = nil) {
        self.indexSignature = indexSignature
        self.imageTokens = imageTokens
        self.dimension = dimension
        self.status = status
        self.updatedAt = updatedAt
        self.failedIDs = failedIDs
    }

    enum CodingKeys: String, CodingKey {
        case indexSignature = "index_signature"
        case imageTokens = "image_tokens"
        case dimension
        case status
        case updatedAt = "updated_at"
        case failedIDs = "failed_ids"
    }

    /// `<dataRoot>/search-index.json`。
    public static func url(dataRoot: URL) -> URL { dataRoot.appendingPathComponent(fileName) }

    /// 読む。無い・読めない・形が違うときは nil。
    public static func read(from url: URL) -> SearchIndexState? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return try? decode(data)
    }

    /// データルートから読む。
    public static func read(paths: CCPaths) -> SearchIndexState? {
        read(from: paths.searchIndexStateURL)
    }

    public static func decode(_ data: Data) throws -> SearchIndexState {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .iso8601
        return try d.decode(SearchIndexState.self, from: data)
    }

    public func encoded() throws -> Data {
        let e = JSONEncoder()
        e.dateEncodingStrategy = .iso8601
        e.outputFormatting = [.prettyPrinted, .sortedKeys]
        return try e.encode(self)
    }

    /// 書く（親ディレクトリが無ければ作る。原子的に置き換える）。
    public func write(to url: URL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        try encoded().write(to: url, options: .atomic)
    }
}

extension CCPaths {
    /// 検索索引の状態ファイル（`<dataRoot>/search-index.json`）。
    public var searchIndexStateURL: URL { SearchIndexState.url(dataRoot: dataRoot) }
}
