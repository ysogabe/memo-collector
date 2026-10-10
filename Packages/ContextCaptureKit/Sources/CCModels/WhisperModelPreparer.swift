import CCCore
import Foundation
import WhisperKit

/// WhisperKit の Core ML モデル（large-v3-turbo）を `<models>/whisperkit/` に用意する（`cc-models prepare whisper`）。
///
/// 配置（CCSTT の `WhisperModelLayout` と同じ。Hub / WhisperKit のダウンロード先レイアウトそのもの）:
/// ```
/// <models>/whisperkit/
/// ├── manifest.json
/// └── models/
///     ├── argmaxinc/whisperkit-coreml/<variant>/   … *.mlmodelc, config.json, generation_config.json
///     └── openai/whisper-large-v3/                 … tokenizer.json, tokenizer_config.json, config.json
/// ```
/// - Note: CCModels は CCSTT に依存できない（Package.swift）ので、配置の定数は CCSTT と重複している。
public struct WhisperModelPreparer: Sendable {
    public static let defaultVariant = "openai_whisper-large-v3-v20240930"
    public static let modelRepo = "argmaxinc/whisperkit-coreml"
    public static let tokenizerRepo = "openai/whisper-large-v3"
    /// 取得する commit を固定する（スパイクで CER 7.72% を測ったもの）。
    public static let pinnedModelRevision = "0f63a7800b00dd0226abd051b906c246e1907482"
    public static let pinnedTokenizerRevision = "06f233fe06e710322aca913c1bc4249a0d71fce1"
    /// トークナイザで取るファイル（WhisperKit の読み込みに要るもの）。
    public static let tokenizerFiles = ["tokenizer.json", "tokenizer_config.json", "config.json"]
    public static let requiredModelNames = ["MelSpectrogram", "AudioEncoder", "TextDecoder"]
    public static let preparedWith = "cc-models WhisperModelPreparer / WhisperKit 1.1.0"

    /// `<models>/whisperkit/`。
    public let root: URL
    public let variant: String
    public let modelRevision: String
    public let tokenizerRevision: String

    public init(
        root: URL,
        variant: String = Self.defaultVariant,
        modelRevision: String = Self.pinnedModelRevision,
        tokenizerRevision: String = Self.pinnedTokenizerRevision
    ) {
        self.root = root.standardizedFileURL
        self.variant = variant
        self.modelRevision = modelRevision
        self.tokenizerRevision = tokenizerRevision
    }

    public init(paths: CCPaths = .resolve(), variant: String = Self.defaultVariant) {
        self.init(root: paths.modelDirectory(.whisper), variant: variant)
    }

    public var manifestURL: URL { root.appendingPathComponent(CCPaths.manifestFileName) }
    public var modelFolder: URL { root.appendingPathComponent("models/\(Self.modelRepo)/\(variant)", isDirectory: true) }
    public var tokenizerFolder: URL { root.appendingPathComponent("models/\(Self.tokenizerRepo)", isDirectory: true) }

    // MARK: - 検証（書き込まない）

    public enum VerificationLevel: Sendable {
        /// サイズだけ比べる（数ミリ秒。アプリ起動時向け）。
        case size
        /// sha256 まで比べる（1.5GB を読むので数秒）。
        case sha256
    }

    public enum Status: Sendable, Equatable {
        /// manifest があり、全ファイルが一致。
        case ready(WhisperModelManifest)
        /// 読み込みに要るファイルが無い（未取得）。
        case missing([String])
        /// ファイルは揃っているが manifest が無い（スパイクの取得物など）。
        case unmanifested
        /// manifest と食い違うファイルがある（相対パス）。
        case mismatched([String])
    }

    /// manifest とファイルを突き合わせる。**何も書かない**。
    public func verify(level: VerificationLevel = .sha256, fileManager: FileManager = .default) throws -> Status {
        let missing = missingRequiredFiles(fileManager: fileManager)
        guard missing.isEmpty else { return .missing(missing) }
        guard fileManager.fileExists(atPath: manifestURL.path) else { return .unmanifested }
        let manifest = try WhisperModelManifest.decode(Data(contentsOf: manifestURL))
        var bad: [String] = []
        for file in manifest.files {
            let url = root.appendingPathComponent(file.path)
            guard let size = Self.fileSize(url, fileManager: fileManager), size == file.size else {
                bad.append(file.path)
                continue
            }
            if level == .sha256, try WhisperModelManifest.sha256Hex(of: url) != file.sha256 {
                bad.append(file.path)
            }
        }
        // manifest の作成後に足されたモデルファイルも食い違いとして扱う（差し替えの検出）
        let listed = Set(manifest.files.map(\.path))
        for path in try contentFiles(fileManager: fileManager) where !listed.contains(path) {
            bad.append(path)
        }
        return bad.isEmpty ? .ready(manifest) : .mismatched(bad.sorted())
    }

    /// 読み込みに必要なファイルのうち無いもの（相対パス）。
    public func missingRequiredFiles(fileManager: FileManager = .default) -> [String] {
        var missing: [String] = []
        for name in Self.requiredModelNames {
            let url = modelFolder.appendingPathComponent("\(name).mlmodelc")
            if !fileManager.fileExists(atPath: url.appendingPathComponent("coremldata.bin").path) {
                missing.append(relativePath(url))
            }
        }
        let tok = tokenizerFolder.appendingPathComponent("tokenizer.json")
        if !fileManager.fileExists(atPath: tok.path) { missing.append(relativePath(tok)) }
        return missing
    }

    // MARK: - manifest

    /// 今あるファイルから manifest を作る（sha256 を計算する。書き込まない）。
    public func buildManifest(createdAt: Date = Date(), fileManager: FileManager = .default) throws -> WhisperModelManifest {
        let files = try contentFiles(fileManager: fileManager).map { path -> WhisperModelManifest.File in
            let url = root.appendingPathComponent(path)
            return .init(path: path, size: Self.fileSize(url, fileManager: fileManager) ?? 0,
                         sha256: try WhisperModelManifest.sha256Hex(of: url))
        }
        return WhisperModelManifest(
            repo: Self.modelRepo, variant: variant,
            revision: downloadedRevision(repoFolder: modelFolder.deletingLastPathComponent(),
                                         relativePrefix: variant + "/") ?? "unknown",
            tokenizerRepo: Self.tokenizerRepo,
            tokenizerRevision: downloadedRevision(repoFolder: tokenizerFolder, relativePrefix: "") ?? "unknown",
            preparedWith: Self.preparedWith,
            createdAt: Date(timeIntervalSince1970: createdAt.timeIntervalSince1970.rounded(.down)),
            files: files
        )
    }

    public func writeManifest(_ manifest: WhisperModelManifest) throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        try manifest.encoded().write(to: manifestURL, options: .atomic)
    }

    /// manifest に載せるファイル（whisperkit ディレクトリからの相対パス、昇順）。
    /// モデルの variant ディレクトリとトークナイザのディレクトリの通常ファイル。Hub の `.cache/` は除く。
    func contentFiles(fileManager: FileManager = .default) throws -> [String] {
        var out: [String] = []
        for folder in [modelFolder, tokenizerFolder] where fileManager.fileExists(atPath: folder.path) {
            guard let e = fileManager.enumerator(at: folder, includingPropertiesForKeys: [.isRegularFileKey],
                                                 options: []) else { continue }
            for case let url as URL in e {
                if url.lastPathComponent == ".cache" { e.skipDescendants(); continue }
                guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
                if url.lastPathComponent == ".DS_Store" { continue }
                out.append(relativePath(url))
            }
        }
        return out.sorted()
    }

    /// Hub がダウンロード時に書く `.cache/huggingface/download/<file>.metadata` の 1 行目（commit）を読む。
    func downloadedRevision(repoFolder: URL, relativePrefix: String) -> String? {
        let dir = repoFolder.appendingPathComponent(".cache/huggingface/download", isDirectory: true)
        guard let e = FileManager.default.enumerator(at: dir, includingPropertiesForKeys: nil) else { return nil }
        // 一時ディレクトリでは /var と /private/var が混ざるので、どちらも実体のパスにしてから比べる
        let base = dir.resolvingSymlinksInPath().path + "/"
        var commits = Set<String>()
        for case let url as URL in e where url.pathExtension == "metadata" {
            let full = url.resolvingSymlinksInPath().path
            guard full.hasPrefix(base) else { continue }
            let rel = String(full.dropFirst(base.count))
            guard rel.hasPrefix(relativePrefix),
                  let first = (try? String(contentsOf: url, encoding: .utf8))?.split(separator: "\n").first
            else { continue }
            commits.insert(String(first).trimmingCharacters(in: .whitespaces))
        }
        // ファイルごとに commit が違う（途中で更新された）ときは決められないので nil
        return commits.count == 1 ? commits.first : nil
    }

    func relativePath(_ url: URL) -> String {
        let base = root.resolvingSymlinksInPath().path
        let path = url.standardizedFileURL.resolvingSymlinksInPath().path
        return path.hasPrefix(base + "/") ? String(path.dropFirst(base.count + 1)) : path
    }

    static func fileSize(_ url: URL, fileManager: FileManager) -> Int64? {
        (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }

    // MARK: - 取得

    /// 進捗の通知（取得中のバイト割合 0–1 と、今の段階）。
    public typealias ProgressHandler = @Sendable (_ stage: String, _ fraction: Double) -> Void

    public enum Outcome: Sendable, Equatable {
        /// 既に揃っていて manifest とも一致した（何もしていない）。
        case alreadyPrepared(WhisperModelManifest)
        /// 取得（または manifest の作成）をした。
        case prepared(WhisperModelManifest)
    }

    /// 揃っていて manifest と一致すれば何もしない。そうでなければ取得し、manifest を書き、検証する。
    /// 食い違うファイルは消してから取り直す（Hub は `.metadata` が一致するとファイルを取り直さないため）。
    public func prepare(progress: ProgressHandler? = nil) async throws -> Outcome {
        switch try verify(level: .sha256) {
        case .ready(let manifest):
            return .alreadyPrepared(manifest)
        case .mismatched(let paths):
            for path in paths { try removeDownloaded(path) }
            try await download(progress: progress)
        case .missing:
            try await download(progress: progress)
        case .unmanifested:
            // ファイルはあるが、取得元が分からない。固定 revision で取り直して（同じなら Hub が省く）から manifest を作る
            try await download(progress: progress)
        }
        progress?("manifest", 0)
        let manifest = try buildManifest()
        try writeManifest(manifest)
        guard case .ready = try verify(level: .size) else {
            throw WhisperModelPreparerError.verificationFailed(manifestURL.path)
        }
        progress?("manifest", 1)
        return .prepared(manifest)
    }

    /// モデル（約 1.5GB）とトークナイザを Hub から取る。既に同じ commit のものがあれば Hub が省く。
    public func download(progress: ProgressHandler? = nil) async throws {
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        let hub = HubApiWrapper(downloadBase: root)
        _ = try await hub.snapshot(
            from: .init(id: Self.modelRepo), revision: modelRevision, matching: ["\(variant)/*"]
        ) { p in progress?("model", p.fractionCompleted) }
        _ = try await hub.snapshot(
            from: .init(id: Self.tokenizerRepo), revision: tokenizerRevision, matching: Self.tokenizerFiles
        ) { p in progress?("tokenizer", p.fractionCompleted) }
        let missing = missingRequiredFiles()
        guard missing.isEmpty else { throw WhisperModelPreparerError.downloadIncomplete(missing) }
    }

    /// 食い違ったファイルと、その Hub の `.metadata` を消す。
    func removeDownloaded(_ path: String) throws {
        let fm = FileManager.default
        let url = root.appendingPathComponent(path)
        if fm.fileExists(atPath: url.path) { try fm.removeItem(at: url) }
        // models/<owner>/<name>/<rest> → models/<owner>/<name>/.cache/huggingface/download/<rest>.metadata
        let parts = path.split(separator: "/", maxSplits: 3).map(String.init)
        if parts.count == 4, parts[0] == "models" {
            let meta = root.appendingPathComponent("models/\(parts[1])/\(parts[2])/.cache/huggingface/download/\(parts[3]).metadata")
            if fm.fileExists(atPath: meta.path) { try fm.removeItem(at: meta) }
        }
    }

    // MARK: - ANE 特殊化

    public struct WarmUpReport: Sendable {
        /// 読み込み（初回は ANE 向けの特殊化を含む）にかかった秒数。
        public var loadSeconds: Double
    }

    /// モデルを一度読み込んで ANE 向けの特殊化を済ませ、すぐ解放する。
    /// 特殊化の結果は OS がキャッシュするので、次からのアプリ側の読み込み（CCSTT.prepare）は数秒で済む。
    public func warmUp() async throws -> WarmUpReport {
        let missing = missingRequiredFiles()
        guard missing.isEmpty else { throw WhisperModelPreparerError.downloadIncomplete(missing) }
        let start = Date()
        let config = WhisperKitConfig(
            model: variant,
            downloadBase: root,
            modelFolder: modelFolder.path,
            tokenizerFolder: root,
            verbose: false,
            logLevel: .error,
            prewarm: true,
            load: true,
            download: false
        )
        let kit = try await WhisperKit(config)
        let seconds = Date().timeIntervalSince(start)
        await kit.unloadModels()
        return WarmUpReport(loadSeconds: seconds)
    }
}

public enum WhisperModelPreparerError: Error, Equatable, CustomStringConvertible {
    /// 取得後も読み込みに要るファイルが無い。
    case downloadIncomplete([String])
    /// manifest を書いた直後の検証に失敗した。
    case verificationFailed(String)

    public var description: String {
        switch self {
        case .downloadIncomplete(let paths): return "取得後もファイルが足りません: \(paths.joined(separator: ", "))"
        case .verificationFailed(let path): return "manifest の検証に失敗しました: \(path)"
        }
    }
}
