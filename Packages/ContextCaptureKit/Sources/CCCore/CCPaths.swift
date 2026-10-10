import Foundation

/// 保存先の解決（計画書 §2）。
/// - データ: 既定 `~/Library/Application Support/ContextCapture/`、環境変数 `CC_DATA_DIR` で上書き
/// - モデル: 既定 `~/Library/Application Support/ContextCapture/Models/`、環境変数 `CC_MODELS_DIR` で上書き
///   （`CC_DATA_DIR` を変えてもモデルの既定位置は動かない。テストで一時データ置き場と実モデルを併用するため）
public struct CCPaths: Sendable, Equatable {
    public static let dataDirEnvironmentKey = "CC_DATA_DIR"
    public static let modelsDirEnvironmentKey = "CC_MODELS_DIR"
    /// SQLite のファイル名（データルート直下）。
    public static let databaseFileName = "ContextCapture.sqlite"
    /// 添付を置くディレクトリ名（データルート直下）。
    public static let capturesDirectoryName = "captures"
    /// 各モデルディレクトリに置くマニフェストのファイル名。
    public static let manifestFileName = "manifest.json"

    /// データルート（SQLite と captures/）。
    public let dataRoot: URL
    /// モデルルート（ModelSlot ごとのサブディレクトリ）。
    public let modelsRoot: URL

    public init(dataRoot: URL, modelsRoot: URL) {
        self.dataRoot = dataRoot.standardizedFileURL
        self.modelsRoot = modelsRoot.standardizedFileURL
    }

    /// 環境変数と既定値から解決する。空文字の環境変数は未設定とみなす。`~` は展開し、相対パスはカレントディレクトリ基準。
    public static func resolve(
        environment: [String: String] = ProcessInfo.processInfo.environment,
        homeDirectory: URL = FileManager.default.homeDirectoryForCurrentUser
    ) -> CCPaths {
        let defaultRoot = homeDirectory
            .appendingPathComponent("Library/Application Support/ContextCapture", isDirectory: true)
        let data = directoryURL(environment[dataDirEnvironmentKey]) ?? defaultRoot
        let models = directoryURL(environment[modelsDirEnvironmentKey])
            ?? defaultRoot.appendingPathComponent("Models", isDirectory: true)
        return CCPaths(dataRoot: data, modelsRoot: models)
    }

    private static func directoryURL(_ raw: String?) -> URL? {
        guard let raw, !raw.isEmpty else { return nil }
        let expanded = (raw as NSString).expandingTildeInPath
        return URL(fileURLWithPath: expanded, isDirectory: true)
    }

    /// SQLite ファイルの URL。
    public var databaseURL: URL { dataRoot.appendingPathComponent(Self.databaseFileName) }

    /// 添付ディレクトリ（`<dataRoot>/captures/`）。
    public var capturesRoot: URL { dataRoot.appendingPathComponent(Self.capturesDirectoryName, isDirectory: true) }

    /// モデル 1 種のディレクトリ。
    public func modelDirectory(_ slot: ModelSlot) -> URL {
        modelsRoot.appendingPathComponent(slot.directoryName, isDirectory: true)
    }

    /// モデル 1 種の manifest.json。
    public func manifestURL(_ slot: ModelSlot) -> URL {
        modelDirectory(slot).appendingPathComponent(Self.manifestFileName)
    }

    /// データルートとモデルルートを作る（既にあれば何もしない）。
    public func createDirectories(fileManager: FileManager = .default) throws {
        try fileManager.createDirectory(at: dataRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: capturesRoot, withIntermediateDirectories: true)
        try fileManager.createDirectory(at: modelsRoot, withIntermediateDirectories: true)
    }

    /// 添付の相対パス `captures/YYYY/MM/DD/<id><suffix>.<ext>` を作る。
    /// 日付は `timeZone`（既定は端末のタイムゾーン）での撮影日。`ext` は先頭の "." の有無を問わない。
    public static func attachmentRelativePath(
        id: String,
        kind: AttachmentKind,
        ext: String,
        capturedAt: Date,
        timeZone: TimeZone = .current
    ) -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = timeZone
        let d = cal.dateComponents([.year, .month, .day], from: capturedAt)
        let cleanExt = ext.hasPrefix(".") ? String(ext.dropFirst()) : ext
        let date = String(format: "%04d/%02d/%02d", d.year!, d.month!, d.day!)
        return "\(capturesDirectoryName)/\(date)/\(id)\(kind.fileSuffix).\(cleanExt)"
    }

    /// DB に入っている相対パスを絶対 URL にする。絶対パス・`..` を含むパス・空文字は `CCPathError.invalidRelativePath`。
    public func url(forRelativePath relativePath: String) throws -> URL {
        let parts = relativePath.split(separator: "/", omittingEmptySubsequences: false)
        guard !relativePath.isEmpty, !relativePath.hasPrefix("/"), !relativePath.hasPrefix("~"),
              !parts.contains(where: { $0 == ".." || $0 == "." || $0.isEmpty })
        else { throw CCPathError.invalidRelativePath(relativePath) }
        return dataRoot.appendingPathComponent(relativePath)
    }

    /// 相対パスを、**シンボリックリンクを解いた実体がデータルート内にある、実在する通常ファイル**の URL にする。
    /// 外部（MCP など）へファイルの中身を渡す前に使う（パストラバーサル・データルート外を指すリンク対策）。
    /// 返す URL はリンクを解いた実体のパス。
    /// - 不正な相対パス（`url(forRelativePath:)` が拒むもの）・実体がデータルート外 → `CCPathError.outsideDataRoot`
    /// - 無い・ディレクトリ・通常ファイルでない → `CCPathError.notRegularFile`
    public func resolveRegularFileInsideDataRoot(_ relativePath: String, fileManager: FileManager = .default) throws -> URL {
        let url: URL
        do {
            url = try self.url(forRelativePath: relativePath)
        } catch {
            throw CCPathError.outsideDataRoot(relativePath)
        }
        // 両側を解いて比べる（/var → /private/var のようにデータルート自体がリンク配下のこともある）。
        let root = dataRoot.resolvingSymlinksInPath().standardizedFileURL.path
        let real = url.resolvingSymlinksInPath().standardizedFileURL.path
        let rootPrefix = root.hasSuffix("/") ? root : root + "/"
        guard real.hasPrefix(rootPrefix) else { throw CCPathError.outsideDataRoot(relativePath) }

        var isDir: ObjCBool = false
        guard fileManager.fileExists(atPath: real, isDirectory: &isDir), !isDir.boolValue,
              (try? fileManager.attributesOfItem(atPath: real))?[.type] as? FileAttributeType == .typeRegular
        else { throw CCPathError.notRegularFile(relativePath) }
        return URL(fileURLWithPath: real)
    }
}

/// 添付の種類。同じ id で拡張子が重なっても衝突しないよう、ファイル名の接尾辞を持つ。
public enum AttachmentKind: String, Sendable, CaseIterable {
    /// スクショ（`<id>.<ext>`。MVP は HEIC（ImageIO が WebP を書けないため）。読み込み側は WebP・PNG なども受け付ける）。
    case screenshot
    /// マスク版スクショ（`<id>-masked.<ext>`。形式はスクショと同じ）。
    case maskedScreenshot
    /// 音声（`<id>.<ext>`。MVP は WAV 16kHz/16bit）。
    case audio

    /// ファイル名で id の後ろに付ける接尾辞。
    public var fileSuffix: String {
        switch self {
        case .screenshot, .audio: return ""
        case .maskedScreenshot: return "-masked"
        }
    }
}

/// モデルの置き場（`Models/<directoryName>/`、計画書 §2）。
public enum ModelSlot: String, Sendable, CaseIterable {
    /// d1-3B 言語モデル部の 8bit 量子化（MLX）。
    case d1
    /// EmbeddingGemma 2（Core ML。FluidInference/embeddinggemma-2-coreml をコンパイルした `.mlmodelc`）。
    case embedding
    /// WhisperKit の Core ML モデル。
    case whisper

    public var directoryName: String {
        switch self {
        case .d1: return "d1-3b-text-q8"
        case .embedding: return "embeddinggemma-2"
        case .whisper: return "whisperkit"
        }
    }
}

public enum CCPathError: Error, Equatable {
    /// データルート外を指しうる相対パス。
    case invalidRelativePath(String)
    /// シンボリックリンクを解いた実体がデータルート外（`resolveRegularFileInsideDataRoot`）。
    case outsideDataRoot(String)
    /// ファイルが無い・通常ファイルでない（`resolveRegularFileInsideDataRoot`）。
    case notRegularFile(String)
}
