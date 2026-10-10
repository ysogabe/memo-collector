import CCCore
@preconcurrency import CoreML
import Foundation

/// EmbeddingGemma 2 の Core ML 版（`FluidInference/embeddinggemma-2-coreml`、revision 固定）を
/// `<models>/embeddinggemma-2/` に用意する（`cc-models prepare embedding`）。
///
/// 1. HF から固定 revision で必要なファイルだけ取る（テキスト・画像の `.mlpackage`、トークン表、位置表、トークナイザ。音声は取らない）
/// 2. 全ファイルを**固定の sha256**（HF の LFS oid と一致を確認済み）と照合する
/// 3. `.mlpackage` を `MLModel.compileModel` で `.mlmodelc` にし、`.mlpackage` は置かない（置くとディスクが 2 倍）
/// 4. LICENSE（Apache-2.0 全文）・NOTICE.txt（Google の元モデルと FluidInference の変換の帰属）・元の README を同梱
/// 5. manifest.json（repo・revision・元ファイルと置いたファイルの sha256・作成日時・手順の版）を書く
///
/// 作業ディレクトリ `.<名前>.partial-<uuid>` で作ってから置き換えるので、途中で落ちても既存のモデルは壊れない。
/// 既に揃っていて manifest と一致すれば検証だけで終わる。
///
/// **ANE 向けの温めはしない**: ANE のコンパイル結果のキャッシュは実行バイナリ単位で、`cc-models` で温めても
/// アプリでは効かない（docs/research/fluid-inference.md §3.3）。アプリ本体で `CoreMLEmbedder.prepare()` を呼ぶこと。
public struct EmbeddingModelPreparer: Sendable {
    public static let repoId = "FluidInference/embeddinggemma-2-coreml"
    public static let revision = "3f978ddf92cac9aa07eb2dcf6eb36cf450f3dba4"
    public static let baseModel = "google/embeddinggemma-2"
    /// 手順の版。手順を変えたら上げる。
    public static let preparationVersion = "embeddinggemma-2-coreml/1"
    public static let preparedWith = "cc-models EmbeddingModelPreparer"

    /// 元ファイル（HF のパス・大きさ・sha256）。revision 3f978dd の値（HF API の LFS oid / 取得物の実測で確認）。
    public struct SourceFile: Sendable, Equatable {
        public var path: String
        public var size: Int64
        public var sha256: String

        public init(path: String, size: Int64, sha256: String) {
            self.path = path
            self.size = size
            self.sha256 = sha256
        }
    }

    public static let pinnedSourceFiles: [SourceFile] = [
        .init(path: "config.json", size: 2845, sha256: "30668aba89f54a200a3fa38913f21e2a2f18aba7215de67c1806542a75b9629b"),
        .init(path: "README.md", size: 7927, sha256: "aa45f21a729232536235726eda97ea074e8383ea5c049c64444be3a91189dc6e"),
        .init(path: "tokenizer.json", size: 32_170_510, sha256: "4d777ef5bdc1aa36227abdfb77c3e49e7b9c892d16e1b6bda41c393504828be4"),
        .init(path: "embeddings.bf16", size: 268_435_456, sha256: "56ebbdbfd706c827f3fae1d97aa39135c7ddc0f1e6d9b12f8565f84bbfbda877"),
        .init(path: "position_embeddings.f16", size: 3_145_728, sha256: "17de9480acc23638c0634a97ed89e51ed664433256d7d6f109587dcd91c79124"),
        .init(path: "EmbeddingGemma2Text.mlpackage/Manifest.json", size: 617,
              sha256: "83eace80b69b46f8415af620ba1b40d7c490d00f7c00ba9dedd2e29da6e9ac19"),
        .init(path: "EmbeddingGemma2Text.mlpackage/Data/com.apple.CoreML/model.mlmodel", size: 7_323_423,
              sha256: "0df9aca02807cf490db6d4f1c68607a8c7f486ad23b376d1968fd3be5eb14677"),
        .init(path: "EmbeddingGemma2Text.mlpackage/Data/com.apple.CoreML/weights/weight.bin", size: 276_815_424,
              sha256: "75b97ab036ca87eae60560c4034a63d604201498dc4b6f6971dd0b1e4558d61f"),
        .init(path: "EmbeddingGemma2Vision.mlpackage/Manifest.json", size: 617,
              sha256: "376afe7b51608637312cd15a0a89b1d7863f9779502aaf5f12fa6b14c4272d8d"),
        .init(path: "EmbeddingGemma2Vision.mlpackage/Data/com.apple.CoreML/model.mlmodel", size: 2_053_174,
              sha256: "0085b5e04a13d000fe5969adeaa13d897f5a3cb7be60c76c8685c023747f89ef"),
        .init(path: "EmbeddingGemma2Vision.mlpackage/Data/com.apple.CoreML/weights/weight.bin", size: 304_078_400,
              sha256: "5b5b6dd8d80aa438bf91ba143fbe90d56a2e25bfcf685a56b990aad71cf75232"),
    ]

    /// コンパイルするパッケージ（拡張子なし）。
    public static let packages = ["EmbeddingGemma2Text", "EmbeddingGemma2Vision"]
    /// そのまま置くファイル。
    public static let copiedFiles = ["config.json", "README.md", "tokenizer.json", "embeddings.bf16", "position_embeddings.f16"]
    /// 読み込みに要るもの（CCEmbedding の `EmbeddingModelFiles` と同じ）。
    public static let requiredFiles = ["EmbeddingGemma2Text.mlmodelc", "EmbeddingGemma2Vision.mlmodelc", "embeddings.bf16",
                                       "position_embeddings.f16", "tokenizer.json"]

    /// `<models>/embeddinggemma-2/`。
    public var destination: URL
    /// 照合する元ファイル（テストで差し替えるときだけ変える）。
    public var sourceFiles: [SourceFile] = Self.pinnedSourceFiles
    /// 取得元（`<base>/<path>`）。
    public var baseURL = URL(string: "https://huggingface.co/\(Self.repoId)/resolve/\(Self.revision)/")!

    public init(destination: URL) {
        self.destination = destination.standardizedFileURL
    }

    public init(paths: CCPaths = .resolve()) {
        self.init(destination: paths.modelDirectory(.embedding))
    }

    public var manifestURL: URL { destination.appendingPathComponent(CCPaths.manifestFileName) }
    /// 取得物の一時置き場（`<models>/.downloads/embeddinggemma-2-coreml@3f978dd/`。成功したら消す）。
    public var downloadDirectory: URL {
        destination.deletingLastPathComponent()
            .appendingPathComponent(".downloads/embeddinggemma-2-coreml@\(Self.revision.prefix(7))", isDirectory: true)
    }

    // MARK: - 検証（書き込まない）

    public enum VerificationLevel: Sendable {
        /// 大きさだけ（数ミリ秒。アプリ起動時向け）。
        case size
        /// sha256 まで（0.9GB を読むので数秒）。
        case sha256
    }

    public enum Status: Sendable, Equatable {
        /// manifest があり、全ファイルが一致。
        case ready(EmbeddingModelManifest)
        /// 読み込みに要るファイルが無い。
        case missing([String])
        /// ファイルはあるが manifest が無い（スパイクの置き場など）。
        case unmanifested
        /// manifest と食い違う（相対パス。revision 違いは `manifest.json`）。
        case mismatched([String])
    }

    public func verify(level: VerificationLevel = .sha256, fileManager: FileManager = .default) throws -> Status {
        let missing = Self.requiredFiles.filter { !fileManager.fileExists(atPath: destination.appendingPathComponent($0).path) }
        guard missing.isEmpty else { return .missing(missing) }
        guard fileManager.fileExists(atPath: manifestURL.path) else { return .unmanifested }
        let manifest = try EmbeddingModelManifest.decode(Data(contentsOf: manifestURL))
        var bad: [String] = []
        if manifest.revision != Self.revision || manifest.repo != Self.repoId { bad.append(CCPaths.manifestFileName) }
        for file in manifest.files {
            let url = destination.appendingPathComponent(file.path)
            guard let size = Self.fileSize(url, fileManager: fileManager), size == file.size else {
                bad.append(file.path)
                continue
            }
            if level == .sha256, try D1ModelPreparer.sha256(of: url) != file.sha256 { bad.append(file.path) }
        }
        let listed = Set(manifest.files.map(\.path))
        for path in try Self.listFiles(in: destination, fileManager: fileManager) where !listed.contains(path) {
            bad.append(path)
        }
        return bad.isEmpty ? .ready(manifest) : .mismatched(bad.sorted())
    }

    // MARK: - 準備

    public enum Outcome: Sendable, Equatable {
        /// 既に揃っていて manifest とも一致した（何もしていない）。
        case alreadyPrepared(EmbeddingModelManifest)
        /// 取得（またはコピー）・検証・コンパイルをした。
        case prepared(EmbeddingModelManifest)
    }

    /// 段階と、その段階の進み具合（0–1）。
    public typealias ProgressHandler = @Sendable (_ stage: String, _ fraction: Double) -> Void

    /// 揃っていれば検証だけ。そうでなければ取得 → sha256 照合 → コンパイル → 置き換え。
    /// `source` を渡すと HF の代わりにそのディレクトリ（HF リポジトリと同じ構成）から取る（照合は同じ）。
    public func prepare(source: URL? = nil, force: Bool = false, progress: ProgressHandler? = nil) async throws -> Outcome {
        if !force, case .ready(let m) = try verify(level: .sha256) { return .alreadyPrepared(m) }
        let fm = FileManager.default
        let staging: URL
        if let source {
            staging = source.standardizedFileURL
        } else {
            staging = downloadDirectory
            try await download(into: staging, progress: progress)
        }
        // ---- 照合
        var sources: [EmbeddingModelManifest.File] = []
        for (i, f) in sourceFiles.enumerated() {
            progress?("verify", Double(i) / Double(sourceFiles.count))
            let url = staging.appendingPathComponent(f.path)
            guard fm.fileExists(atPath: url.path) else { throw EmbeddingPrepareError.missingSourceFile(f.path) }
            let sha = try D1ModelPreparer.sha256(of: url)
            guard sha == f.sha256 else { throw EmbeddingPrepareError.checksumMismatch(path: f.path, expected: f.sha256, actual: sha) }
            sources.append(.init(path: f.path, size: Self.fileSize(url, fileManager: fm) ?? -1, sha256: sha))
        }
        progress?("verify", 1)

        let work = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).partial-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        var succeeded = false
        defer { if !succeeded { try? fm.removeItem(at: work) } }

        // ---- コピーとコンパイル
        for name in Self.copiedFiles {
            try fm.copyItem(at: staging.appendingPathComponent(name).resolvingSymlinksInPath(), to: work.appendingPathComponent(name))
        }
        for (i, name) in Self.packages.enumerated() {
            progress?("compile", Double(i) / Double(Self.packages.count))
            let compiled = try await MLModel.compileModel(at: staging.appendingPathComponent("\(name).mlpackage"))
            // compileModel の出力は一時ディレクトリ（プロセス終了で消える）なので、すぐ移す
            try fm.moveItem(at: compiled, to: work.appendingPathComponent("\(name).mlmodelc"))
        }
        progress?("compile", 1)
        try (EmbeddingModelLicense.apache2 + "\n").write(to: work.appendingPathComponent("LICENSE"), atomically: true, encoding: .utf8)
        try Self.notice.write(to: work.appendingPathComponent("NOTICE.txt"), atomically: true, encoding: .utf8)

        // ---- manifest
        progress?("manifest", 0)
        let files = try Self.listFiles(in: work, fileManager: fm).map { path -> EmbeddingModelManifest.File in
            let url = work.appendingPathComponent(path)
            return .init(path: path, size: Self.fileSize(url, fileManager: fm) ?? -1, sha256: try D1ModelPreparer.sha256(of: url))
        }
        let manifest = EmbeddingModelManifest(
            formatVersion: EmbeddingModelManifest.currentFormatVersion, repo: Self.repoId, revision: Self.revision,
            baseModel: Self.baseModel, license: "Apache-2.0", preparationVersion: Self.preparationVersion,
            preparedWith: Self.preparedWith, compiledOn: ProcessInfo.processInfo.operatingSystemVersionString,
            createdAt: Date(timeIntervalSince1970: Date().timeIntervalSince1970.rounded(.down)),
            sourceFiles: sources, files: files)
        try manifest.encoded().write(to: work.appendingPathComponent(CCPaths.manifestFileName))

        // ---- 置き換え
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: work)
        } else {
            try fm.moveItem(at: work, to: destination)
        }
        succeeded = true
        if source == nil { try? fm.removeItem(at: staging) }
        guard case .ready(let written) = try verify(level: .size) else {
            throw EmbeddingPrepareError.verificationFailed(manifestURL.path)
        }
        progress?("manifest", 1)
        return .prepared(written)
    }

    /// 元ファイルを `directory` へ取る。既に sha256 が合うものは取り直さない。
    public func download(into directory: URL, progress: ProgressHandler? = nil) async throws {
        let fm = FileManager.default
        let total = Double(sourceFiles.reduce(0) { $0 + $1.size })
        var done = 0.0
        for f in sourceFiles {
            let dest = directory.appendingPathComponent(f.path)
            try fm.createDirectory(at: dest.deletingLastPathComponent(), withIntermediateDirectories: true)
            if fm.fileExists(atPath: dest.path) {
                if Self.fileSize(dest, fileManager: fm) == f.size, try D1ModelPreparer.sha256(of: dest) == f.sha256 {
                    done += Double(f.size)
                    continue
                }
                try fm.removeItem(at: dest)
            }
            let url = baseURL.appendingPathComponent(f.path)
            let (tmp, response) = try await URLSession.shared.download(from: url)
            if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                try? fm.removeItem(at: tmp)
                throw EmbeddingPrepareError.downloadFailed(path: f.path, status: http.statusCode)
            }
            try fm.moveItem(at: tmp, to: dest)
            done += Double(f.size)
            progress?("download", total > 0 ? done / total : 1)
        }
    }

    // MARK: - 下請け

    static let notice = """
        This directory contains EmbeddingGemma 2 converted to Core ML.

        - Original model: google/embeddinggemma-2 by Google, licensed under the Apache License 2.0.
        - Core ML conversion: FluidInference/embeddinggemma-2-coreml (https://huggingface.co/FluidInference/embeddinggemma-2-coreml),
          revision \(revision), licensed under the Apache License 2.0 (see LICENSE and README.md).

        Modifications made by Context Capture's model preparer (\(preparationVersion)):
        - Only the text and vision encoders are kept; the audio encoder is not downloaded.
        - EmbeddingGemma2Text.mlpackage and EmbeddingGemma2Vision.mlpackage are compiled to .mlmodelc with Core ML
          (MLModel.compileModel); the .mlpackage files are not kept. Weights are unchanged.

        """

    /// ディレクトリ内の通常ファイル（相対パス、昇順。manifest.json と .DS_Store は除く）。
    static func listFiles(in root: URL, fileManager: FileManager) throws -> [String] {
        let base = root.resolvingSymlinksInPath().path + "/"
        guard let e = fileManager.enumerator(at: root, includingPropertiesForKeys: [.isRegularFileKey]) else { return [] }
        var out: [String] = []
        for case let url as URL in e {
            guard (try url.resourceValues(forKeys: [.isRegularFileKey])).isRegularFile == true else { continue }
            let full = url.resolvingSymlinksInPath().path
            guard full.hasPrefix(base) else { continue }
            let rel = String(full.dropFirst(base.count))
            if rel == CCPaths.manifestFileName || url.lastPathComponent == ".DS_Store" { continue }
            out.append(rel)
        }
        return out.sorted()
    }

    static func fileSize(_ url: URL, fileManager: FileManager) -> Int64? {
        (try? fileManager.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.int64Value
    }
}

public enum EmbeddingPrepareError: Error, Equatable, CustomStringConvertible {
    case missingSourceFile(String)
    case checksumMismatch(path: String, expected: String, actual: String)
    case downloadFailed(path: String, status: Int)
    case verificationFailed(String)

    public var description: String {
        switch self {
        case let .missingSourceFile(p): return "元ファイルがありません: \(p)"
        case let .checksumMismatch(p, e, a): return "sha256 が一致しません: \(p)（期待 \(e)、実際 \(a)）"
        case let .downloadFailed(p, s): return "取得に失敗しました: \(p)（HTTP \(s)）"
        case let .verificationFailed(p): return "manifest の検証に失敗しました: \(p)"
        }
    }
}
