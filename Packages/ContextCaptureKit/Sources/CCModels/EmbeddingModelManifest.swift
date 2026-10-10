import Foundation

/// `<models>/embeddinggemma-2/manifest.json` の中身（計画書 §2: 元リポジトリ・revision・sha256・手順の版）。
public struct EmbeddingModelManifest: Codable, Equatable, Sendable {
    public struct File: Codable, Equatable, Sendable {
        /// embeddinggemma-2 ディレクトリ（`source_files` では HF リポジトリ）からの相対パス。
        public var path: String
        public var size: Int64
        public var sha256: String

        public init(path: String, size: Int64, sha256: String) {
            self.path = path
            self.size = size
            self.sha256 = sha256
        }
    }

    /// この形式の版（フィールドを変えたら上げる）。
    public var formatVersion: Int
    /// `FluidInference/embeddinggemma-2-coreml`。
    public var repo: String
    /// 取得した commit（固定）。
    public var revision: String
    /// 元のモデル（帰属表示用）。
    public var baseModel: String
    public var license: String
    /// 準備手順の版（手順を変えたら上げる）。
    public var preparationVersion: String
    /// 準備した道具。
    public var preparedWith: String
    /// `.mlmodelc` をコンパイルした OS（`ProcessInfo.operatingSystemVersionString`）。
    public var compiledOn: String
    public var createdAt: Date
    /// HF から取った元ファイル（固定の sha256 と照合済み）。`.mlpackage` はコンパイル後に消すので置き場には無い。
    public var sourceFiles: [File]
    /// 置き場にあるファイル（manifest.json 自身を除く。パス順）。
    public var files: [File]

    public static let currentFormatVersion = 1

    enum CodingKeys: String, CodingKey {
        case formatVersion = "format_version"
        case repo, revision, license, files
        case baseModel = "base_model"
        case preparationVersion = "preparation_version"
        case preparedWith = "prepared_with"
        case compiledOn = "compiled_on"
        case createdAt = "created_at"
        case sourceFiles = "source_files"
    }

    /// ISO 8601（秒まで）・キー順固定・整形して書く。
    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(self)
    }

    public static func decode(_ data: Data) throws -> EmbeddingModelManifest {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(EmbeddingModelManifest.self, from: data)
    }
}
