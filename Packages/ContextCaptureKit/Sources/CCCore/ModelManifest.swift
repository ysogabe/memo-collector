import Foundation

// モデルの manifest.json（計画書 §2: 元リポジトリ・revision・sha256・手順の版）。
// 3 種（d1 / whisper / embedding）は担当ごとに作られて JSON の形が違うので、既存の manifest.json を読めるよう
// 形はそのまま残し、共通の見方として `ModelManifest`（どれか 1 つを包む）と `ModelManifestFile` を置く。
// 型は CCCore に置き、CCModels には同名の型エイリアスを残す（`CCModels.WhisperModelManifest` 等の既存の参照のため）。
// sha256 の計算（CryptoKit）と書き込みは CCModels 側。

/// manifest に載るファイル 1 つ（モデルディレクトリからの相対パス・バイト数・sha256 の 16 進小文字）。
/// whisper / embedding の `files` の要素そのもの（JSON: `{"path", "size", "sha256"}`）。
public struct ModelManifestFile: Codable, Equatable, Sendable, Hashable {
    public var path: String
    public var size: Int64
    public var sha256: String

    public init(path: String, size: Int64, sha256: String) {
        self.path = path
        self.size = size
        self.sha256 = sha256
    }
}

/// モデル 1 種の manifest の共通の見方。中身は各モデルの manifest 型そのもの（JSON の形は変えない）。
///
/// ```swift
/// let m = try ModelManifest.load(.whisper, paths: .resolve())
/// print(m.repo, m.revision, m.files.count)
/// ```
public enum ModelManifest: Sendable, Equatable {
    case d1(D1ModelManifest)
    case whisper(WhisperModelManifest)
    case embedding(EmbeddingModelManifest)

    /// どの置き場のものか。
    public var slot: ModelSlot {
        switch self {
        case .d1: return .d1
        case .whisper: return .whisper
        case .embedding: return .embedding
        }
    }

    /// 取得元の HF リポジトリ。
    public var repo: String {
        switch self {
        case .d1(let m): return m.repo
        case .whisper(let m): return m.repo
        case .embedding(let m): return m.repo
        }
    }

    /// 取得元の commit。
    public var revision: String {
        switch self {
        case .d1(let m): return m.revision
        case .whisper(let m): return m.revision
        case .embedding(let m): return m.revision
        }
    }

    /// 作成時刻。d1 は文字列で持つので ISO 8601 として読めなければ nil。
    public var createdAt: Date? {
        switch self {
        case .d1(let m): return ISO8601DateFormatter().date(from: m.createdAt)
        case .whisper(let m): return m.createdAt
        case .embedding(let m): return m.createdAt
        }
    }

    /// 準備手順の版（d1: `conversion_version`、embedding: `preparation_version`、whisper: `prepared_with`）。
    public var preparationVersion: String {
        switch self {
        case .d1(let m): return m.conversionVersion
        case .whisper(let m): return m.preparedWith
        case .embedding(let m): return m.preparationVersion
        }
    }

    /// 置き場にあるファイル（manifest.json 自身を除く。パス順）。d1 の辞書形式もこの形にする。
    public var files: [ModelManifestFile] {
        switch self {
        case .d1(let m):
            return m.files.sorted { $0.key < $1.key }
                .map { ModelManifestFile(path: $0.key, size: Int64($0.value.bytes), sha256: $0.value.sha256) }
        case .whisper(let m): return m.files
        case .embedding(let m): return m.files
        }
    }

    /// ファイルの合計バイト数。
    public var totalBytes: Int64 { files.reduce(0) { $0 + $1.size } }

    /// `slot` の形式として manifest.json を読む（各型の `decode` と同じ規則。d1 は既定の JSONDecoder）。
    public static func decode(_ data: Data, slot: ModelSlot) throws -> ModelManifest {
        switch slot {
        case .d1: return .d1(try JSONDecoder().decode(D1ModelManifest.self, from: data))
        case .whisper: return .whisper(try WhisperModelManifest.decode(data))
        case .embedding: return .embedding(try EmbeddingModelManifest.decode(data))
        }
    }

    /// `paths.manifestURL(slot)` を読む。無ければファイル読み込みのエラー。
    public static func load(_ slot: ModelSlot, paths: CCPaths) throws -> ModelManifest {
        try decode(Data(contentsOf: paths.manifestURL(slot)), slot: slot)
    }

    /// 各型の書き方で書き出す（読み直すと同じ値になる）。
    public func encoded() throws -> Data {
        switch self {
        case .d1(let m): return try D1ModelManifest.encoder().encode(m)
        case .whisper(let m): return try m.encoded()
        case .embedding(let m): return try m.encoded()
        }
    }
}

// MARK: - whisper

/// `<models>/whisperkit/manifest.json` の中身（計画書 §2: 元リポジトリ・revision・sha256・手順の版）。
public struct WhisperModelManifest: Codable, Equatable, Sendable {
    /// この形式の版（フィールドを変えたら上げる）。
    public var formatVersion: Int
    /// `argmaxinc/whisperkit-coreml`。
    public var repo: String
    /// `openai_whisper-large-v3-v20240930` など。
    public var variant: String
    /// 取得した commit（Hub の `.metadata` から読む。読めなければ "unknown"）。
    public var revision: String
    public var tokenizerRepo: String
    public var tokenizerRevision: String
    /// 準備した道具と版（例: "cc-models WhisperModelPreparer / WhisperKit 1.1.0"）。
    public var preparedWith: String
    public var createdAt: Date
    /// whisperkit ディレクトリからの相対パス順。
    public var files: [File]

    /// whisperkit ディレクトリからの相対パス・サイズ・sha256（共通の `ModelManifestFile`）。
    public typealias File = ModelManifestFile

    public static let currentFormatVersion = 1

    public init(
        formatVersion: Int = Self.currentFormatVersion,
        repo: String, variant: String, revision: String,
        tokenizerRepo: String, tokenizerRevision: String,
        preparedWith: String, createdAt: Date, files: [File]
    ) {
        self.formatVersion = formatVersion
        self.repo = repo
        self.variant = variant
        self.revision = revision
        self.tokenizerRepo = tokenizerRepo
        self.tokenizerRevision = tokenizerRevision
        self.preparedWith = preparedWith
        self.createdAt = createdAt
        self.files = files
    }

    enum CodingKeys: String, CodingKey {
        case formatVersion = "format_version"
        case repo, variant, revision
        case tokenizerRepo = "tokenizer_repo"
        case tokenizerRevision = "tokenizer_revision"
        case preparedWith = "prepared_with"
        case createdAt = "created_at"
        case files
    }

    /// ISO 8601（秒まで）・キー順固定・整形して書く。
    public func encoded() throws -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        enc.dateEncodingStrategy = .iso8601
        return try enc.encode(self)
    }

    public static func decode(_ data: Data) throws -> WhisperModelManifest {
        let dec = JSONDecoder()
        dec.dateDecodingStrategy = .iso8601
        return try dec.decode(WhisperModelManifest.self, from: data)
    }
}

// MARK: - embedding

/// `<models>/embeddinggemma-2/manifest.json` の中身（計画書 §2: 元リポジトリ・revision・sha256・手順の版）。
public struct EmbeddingModelManifest: Codable, Equatable, Sendable {
    /// embeddinggemma-2 ディレクトリ（`source_files` では HF リポジトリ）からの相対パス・サイズ・sha256（共通の `ModelManifestFile`）。
    public typealias File = ModelManifestFile

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

    public init(
        formatVersion: Int = Self.currentFormatVersion,
        repo: String, revision: String, baseModel: String, license: String,
        preparationVersion: String, preparedWith: String, compiledOn: String, createdAt: Date,
        sourceFiles: [File], files: [File]
    ) {
        self.formatVersion = formatVersion
        self.repo = repo
        self.revision = revision
        self.baseModel = baseModel
        self.license = license
        self.preparationVersion = preparationVersion
        self.preparedWith = preparedWith
        self.compiledOn = compiledOn
        self.createdAt = createdAt
        self.sourceFiles = sourceFiles
        self.files = files
    }

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

// MARK: - d1

/// `Models/d1-3b-text-q8/manifest.json`（CCModels.D1ModelPreparer が書く）。
/// ⚠️ 他の 2 つと形が違う（`files` が名前 → {sha256, bytes} の辞書、`created_at` が文字列、`format_version` が無い）。
/// 既存の manifest.json を読めるよう、形は変えない。共通の見方は `ModelManifest`。
public struct D1ModelManifest: Codable, Sendable, Equatable {
    public struct FileEntry: Codable, Sendable, Equatable {
        public var sha256: String
        public var bytes: Int

        public init(sha256: String, bytes: Int) {
            self.sha256 = sha256
            self.bytes = bytes
        }
    }
    public struct Quantization: Codable, Sendable, Equatable {
        public var bits: Int
        public var groupSize: Int
        public var mode: String
        enum CodingKeys: String, CodingKey { case bits, groupSize = "group_size", mode }

        public init(bits: Int, groupSize: Int, mode: String) {
            self.bits = bits
            self.groupSize = groupSize
            self.mode = mode
        }
    }
    public var repo: String
    public var revision: String
    public var conversionVersion: String
    public var createdAt: String
    /// 元ファイル → sha256。
    public var source: [String: String]
    public var quantization: Quantization
    public var tensorCount: Int
    /// 変換物の各ファイル（manifest.json 自身を除く）。
    public var files: [String: FileEntry]

    public init(
        repo: String, revision: String, conversionVersion: String, createdAt: String,
        source: [String: String], quantization: Quantization, tensorCount: Int, files: [String: FileEntry]
    ) {
        self.repo = repo
        self.revision = revision
        self.conversionVersion = conversionVersion
        self.createdAt = createdAt
        self.source = source
        self.quantization = quantization
        self.tensorCount = tensorCount
        self.files = files
    }

    enum CodingKeys: String, CodingKey {
        case repo, revision, source, quantization, files
        case conversionVersion = "conversion_version"
        case createdAt = "created_at"
        case tensorCount = "tensor_count"
    }

    /// D1ModelPreparer が manifest.json を書くときの JSONEncoder（整形・キー順固定）。
    public static func encoder() -> JSONEncoder {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return enc
    }
}
