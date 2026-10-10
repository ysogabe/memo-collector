import CryptoKit
import Foundation

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

    public struct File: Codable, Equatable, Sendable {
        /// whisperkit ディレクトリからの相対パス。
        public var path: String
        public var size: Int64
        public var sha256: String

        public init(path: String, size: Int64, sha256: String) {
            self.path = path
            self.size = size
            self.sha256 = sha256
        }
    }

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

extension WhisperModelManifest {
    /// ファイルの SHA-256（16 進小文字）。大きいファイルを 8MB ずつ読む。
    public static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try autoreleasepool { try handle.read(upToCount: 8 << 20) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
