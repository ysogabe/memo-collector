import CCCore
import CryptoKit
import Foundation
import Hub
import MLX

/// d1-3B（LiquidAI/d1-3B, revision 051bcc4 固定）から、CCIntent が読む MLX 8bit の言語モデル部を作る。
/// Python を使わず MLX Swift だけで、スパイクの `d1_extract_text.py` + `mlx_lm convert -q --q-bits 8 --q-group-size 64`
/// + `d1_patch_config.py` と同じ物を作る:
///
/// 1. 言語モデル部の重みだけを残し `model.language_model.X → model.X` に改名（視覚塔・projector は捨てる）
/// 2. 因果 conv の重みを MLX の形（[C, K, 1]）へ転置（mlx-lm / mlx-swift-lm の `sanitize` と同じ条件）
/// 3. 2 次元の `.weight`（Linear と Embedding）を affine 8bit・group size 64 で量子化（`.scales` / `.biases` を足す）
/// 4. config を `text_config` から作り、`model_type=lfm2`・`tie_word_embeddings=true`・`block_ff_dim`・`quantization` を足す
/// 5. tokenizer 類と d1 の `LICENSE` をコピーし、改変告知 `NOTICE-MODIFIED.txt` と `manifest.json` を置く
///
/// 出力は `<destination>.partial-<uuid>` に作ってから置き換えるので、途中で落ちても既存のモデルは壊れない。
public struct D1ModelPreparer: Sendable {
    public static let repoId = "LiquidAI/d1-3B"
    public static let revision = "051bcc464b01b9f92942b364d9586b0ef5912432"
    /// 元 checkpoint（model.safetensors）の sha256（HF の LFS oid）。取得物の検証に使う。
    public static let sourceWeightsSHA256 = "50e03317847caf6df9a9aee27ed40f20554a86a21e60d1d47ba41a422b546c0c"
    /// 変換手順の版。手順を変えたら上げる（manifest に残り、古い変換物を見分けられる）。
    public static let conversionVersion = "d1-text-mlx-q8/1"
    /// HF から取る元ファイル（.py のリモートコードは取らない）。
    public static let sourceFiles = ["config.json", "model.safetensors", "tokenizer.json", "tokenizer_config.json",
                                     "chat_template.jinja", "LICENSE"]
    /// 変換物にそのままコピーするファイル。
    static let copiedFiles = ["tokenizer.json", "tokenizer_config.json", "chat_template.jinja", "LICENSE"]
    static let languageModelPrefix = "model.language_model."

    public var destination: URL
    public var groupSize: Int = 64
    public var bits: Int = 8
    /// 元 checkpoint の sha256 を確かめるか（テストで別の checkpoint を使うときだけ false）。
    public var verifySourceChecksum: Bool = true
    /// `prepare` が HF から取得した元モデル（`<destination の親>/.downloads/`、約 5.8GB）を変換の成功後に消すか。
    /// 既定は消す。`source` を渡したとき・Python の HF キャッシュを使ったときは、取得していないので何も消さない。
    public var removeDownloadsAfterConversion: Bool = true

    public init(destination: URL = CCPaths.resolve().modelDirectory(.d1)) {
        self.destination = destination
    }

    /// 進捗（0–1 と説明）。
    public typealias Progress = @Sendable (Double, String) -> Void

    /// 元モデルを用意して変換する。`source` を渡せばそのディレクトリ（HF snapshot と同じ構成）を使い、
    /// nil なら Python の HF キャッシュに同じ revision があればそれを、無ければ HF から取得する。
    /// HF から取得した場合は、変換の成功後に取得物を消す（`removeDownloadsAfterConversion`）。失敗したときは残す（再実行で取り直さない）。
    @discardableResult
    public func prepare(source: URL? = nil, progress: Progress = { _, _ in }) async throws -> D1ModelManifest {
        let src: URL
        var downloaded = false
        if let source {
            src = source
        } else if let cached = Self.pythonHFCacheSnapshot() {
            src = cached
        } else {
            progress(0, "downloading \(Self.repoId)@\(Self.revision.prefix(7))")
            src = try await download()
            downloaded = true
        }
        let manifest = try convert(source: src, progress: progress)
        if downloaded, removeDownloadsAfterConversion { removeDownloads() }
        return manifest
    }

    /// HF からの取得先（`<destination の親>/.downloads/`）。embedding の取得物と共有する。
    public var downloadsDirectory: URL {
        destination.deletingLastPathComponent().appendingPathComponent(".downloads", isDirectory: true)
    }

    /// `download()` の取得物（`.downloads/models/LiquidAI/d1-3B/`）を消し、空になった親ディレクトリも
    /// `.downloads` まで消す（他のモデルの取得物があれば残す）。失敗しても throw しない（変換物は既に置けている）。
    public func removeDownloads() {
        let fm = FileManager.default
        let base = downloadsDirectory.standardizedFileURL
        var dir = base.appendingPathComponent("models/\(Self.repoId)", isDirectory: true)
        try? fm.removeItem(at: dir)
        dir = dir.deletingLastPathComponent()
        while dir.path.hasPrefix(base.path) {
            guard (try? fm.contentsOfDirectory(atPath: dir.path))?.isEmpty == true else { break }
            try? fm.removeItem(at: dir)
            if dir.path == base.path { break }
            dir = dir.deletingLastPathComponent()
        }
    }

    /// Python の HF キャッシュ（`HF_HUB_CACHE` / `HF_HOME/hub` / `~/.cache/huggingface/hub`）にある同 revision の snapshot。
    public static func pythonHFCacheSnapshot(environment: [String: String] = ProcessInfo.processInfo.environment) -> URL? {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var roots: [URL] = []
        if let c = environment["HF_HUB_CACHE"], !c.isEmpty { roots.append(URL(fileURLWithPath: (c as NSString).expandingTildeInPath)) }
        if let h = environment["HF_HOME"], !h.isEmpty {
            roots.append(URL(fileURLWithPath: (h as NSString).expandingTildeInPath).appendingPathComponent("hub"))
        }
        roots.append(home.appendingPathComponent(".cache/huggingface/hub"))
        for root in roots {
            let snap = root.appendingPathComponent("models--LiquidAI--d1-3B/snapshots/\(revision)")
            if sourceFiles.allSatisfy({ FileManager.default.fileExists(atPath: snap.appendingPathComponent($0).path) }) {
                return snap
            }
        }
        return nil
    }

    /// HF から revision 固定で取得する（`<destination の親>/.downloads/` 配下）。
    public func download(files: [String] = D1ModelPreparer.sourceFiles) async throws -> URL {
        let hub = HubApi(downloadBase: downloadsDirectory)
        return try await hub.snapshot(from: HubApi.Repo(id: Self.repoId), revision: Self.revision, matching: files)
    }

    /// 変換する（数分・メモリ数 GB）。成功したら `destination` を置き換える。
    @discardableResult
    public func convert(source: URL, progress: Progress = { _, _ in }) throws -> D1ModelManifest {
        let fm = FileManager.default
        for name in ["config.json", "model.safetensors", "tokenizer.json", "LICENSE"]
        where !fm.fileExists(atPath: source.appendingPathComponent(name).path) {
            throw D1PrepareError.missingSourceFile(name)
        }
        let srcWeights = source.appendingPathComponent("model.safetensors")
        progress(0.02, "checking source checksum")
        let srcSHA = try Self.sha256(of: srcWeights)
        if verifySourceChecksum, srcSHA != Self.sourceWeightsSHA256 {
            throw D1PrepareError.sourceChecksumMismatch(expected: Self.sourceWeightsSHA256, actual: srcSHA)
        }

        let work = destination.deletingLastPathComponent()
            .appendingPathComponent(".\(destination.lastPathComponent).partial-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: work, withIntermediateDirectories: true)
        var succeeded = false
        defer { if !succeeded { try? fm.removeItem(at: work) } }

        // ---- config
        let config = try Self.makeConfig(sourceConfig: Data(contentsOf: source.appendingPathComponent("config.json")),
                                         groupSize: groupSize, bits: bits)
        try config.write(to: work.appendingPathComponent("config.json"))

        // ---- weights
        progress(0.1, "extracting and quantizing")
        let out = try Self.convertWeights(url: srcWeights, groupSize: groupSize, bits: bits) { f in
            progress(0.1 + 0.75 * f, "quantizing")
        }
        progress(0.86, "saving model.safetensors")
        try save(arrays: out, metadata: ["format": "mlx"], url: work.appendingPathComponent("model.safetensors"))
        let tensorCount = out.count
        Memory.clearCache()

        // ---- tokenizer / license / notice
        for name in Self.copiedFiles where fm.fileExists(atPath: source.appendingPathComponent(name).path) {
            // HF キャッシュの snapshot はシンボリックリンクなので、実体をコピーする
            let data = try Data(contentsOf: source.appendingPathComponent(name).resolvingSymlinksInPath())
            try data.write(to: work.appendingPathComponent(name))
        }
        try Self.notice(groupSize: groupSize, bits: bits).write(to: work.appendingPathComponent("NOTICE-MODIFIED.txt"),
                                                                atomically: true, encoding: .utf8)

        // ---- manifest
        progress(0.92, "writing manifest")
        var files: [String: D1ModelManifest.FileEntry] = [:]
        for name in try fm.contentsOfDirectory(atPath: work.path).sorted() {
            let url = work.appendingPathComponent(name)
            let size = (try fm.attributesOfItem(atPath: url.path)[.size] as? NSNumber)?.intValue ?? -1
            files[name] = .init(sha256: try Self.sha256(of: url), bytes: size)
        }
        let manifest = D1ModelManifest(
            repo: Self.repoId, revision: Self.revision, conversionVersion: Self.conversionVersion,
            createdAt: ISO8601DateFormatter().string(from: Date()),
            source: ["model.safetensors": srcSHA],
            quantization: .init(bits: bits, groupSize: groupSize, mode: "affine"),
            tensorCount: tensorCount, files: files)
        try D1ModelManifest.encoder().encode(manifest).write(to: work.appendingPathComponent(CCPaths.manifestFileName))

        // ---- 置き換え
        try fm.createDirectory(at: destination.deletingLastPathComponent(), withIntermediateDirectories: true)
        if fm.fileExists(atPath: destination.path) {
            _ = try fm.replaceItemAt(destination, withItemAt: work)
        } else {
            try fm.moveItem(at: work, to: destination)
        }
        succeeded = true
        progress(1, "done")
        return manifest
    }

    /// 言語モデル部の抽出・改名・conv 転置・量子化。
    static func convertWeights(url: URL, groupSize: Int, bits: Int, progress: (Double) -> Void = { _ in }) throws -> [String: MLXArray] {
        // 解放したバッファを MLX のキャッシュに溜めない（溜めると変換中のフットプリントが元重みの数倍に膨らむ）
        let oldCacheLimit = Memory.cacheLimit
        Memory.cacheLimit = 64 << 20
        defer {
            Memory.cacheLimit = oldCacheLimit
            Memory.clearCache()
        }
        var src = try loadArrays(url: url)
        let keys = src.keys.filter { $0.hasPrefix(languageModelPrefix) }.sorted()
        guard !keys.isEmpty else { throw D1PrepareError.noLanguageModelWeights }
        var out: [String: MLXArray] = [:]
        for (i, key) in keys.enumerated() {
            guard var t = src.removeValue(forKey: key) else { continue }
            let name = "model." + key.dropFirst(languageModelPrefix.count)
            // mlx-lm / mlx-swift-lm の LFM2.sanitize: PyTorch の [C, 1, K] → MLX の [C, K, 1]
            if name.contains("conv.weight"), t.ndim == 3, t.dim(-1) > t.dim(1) {
                t = t.transposed(0, 2, 1)
            }
            if name.hasSuffix(".weight"), t.ndim == 2, t.dim(-1) % groupSize == 0 {
                let base = String(name.dropLast(".weight".count))
                let (wq, scales, biases) = quantized(t, groupSize: groupSize, bits: bits, mode: .affine)
                guard let biases else { throw D1PrepareError.quantizationFailed(name) }
                eval(wq, scales, biases)
                out[name] = wq
                out[base + ".scales"] = scales
                out[base + ".biases"] = biases
            } else {
                // 転置した conv は連続配置にしてから保存する（safetensors は行優先の連続領域を書く）
                let c = t.contiguous()
                eval(c)
                out[name] = c
            }
            progress(Double(i + 1) / Double(keys.count))
        }
        src.removeAll()
        return out
    }

    /// 元 config の text_config から MLX 用 config を作る。
    static func makeConfig(sourceConfig: Data, groupSize: Int, bits: Int) throws -> Data {
        guard let root = try JSONSerialization.jsonObject(with: sourceConfig) as? [String: Any],
              var tc = root["text_config"] as? [String: Any]
        else { throw D1PrepareError.invalidSourceConfig }
        guard let ff = tc["intermediate_size"] as? Int else { throw D1PrepareError.invalidSourceConfig }
        tc["model_type"] = "lfm2"
        tc["architectures"] = ["Lfm2ForCausalLM"]
        tc["tie_word_embeddings"] = true
        // mlx-swift-lm 3.32.3 の LFM2Configuration は intermediate_size を読まず block_ff_dim を要求する
        tc["block_ff_dim"] = ff
        let q: [String: Any] = ["group_size": groupSize, "bits": bits, "mode": "affine"]
        tc["quantization"] = q
        tc["quantization_config"] = q
        return try JSONSerialization.data(withJSONObject: tc, options: [.prettyPrinted, .sortedKeys])
    }

    static func notice(groupSize: Int, bits: Int) -> String {
        """
        This directory contains a modified version of LiquidAI/d1-3B (revision \(revision)),
        licensed under the LFM Open License v1.0 (see LICENSE).

        Modifications made by Context Capture's model preparer (\(conversionVersion)):
        - Only the language model weights are kept; the vision tower and multi-modal projector are removed.
        - Tensors are renamed model.language_model.* -> model.*; causal conv weights are transposed to the MLX layout.
        - Linear and embedding weights are quantized to \(bits)-bit (affine, group size \(groupSize)) with MLX.
        - config.json is derived from text_config (model_type=lfm2, block_ff_dim and quantization added).

        """
    }

    /// ファイルの sha256（16 進小文字）。シンボリックリンクは辿る。
    public static func sha256(of url: URL) throws -> String {
        let h = try FileHandle(forReadingFrom: url.resolvingSymlinksInPath())
        defer { try? h.close() }
        var hasher = SHA256()
        // read(upToCount:) の Data は autorelease されるので、1 チャンクごとにプールを抜ける（抜けないとファイル全体が溜まる）
        while try autoreleasepool(invoking: {
            guard let chunk = try h.read(upToCount: 16 << 20), !chunk.isEmpty else { return false }
            hasher.update(data: chunk)
            return true
        }) {}
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    /// 変換物を manifest の sha256 と突き合わせる。一致しないファイル名を返す（空なら健全）。
    public static func verify(directory: URL) throws -> [String] {
        let data = try Data(contentsOf: directory.appendingPathComponent(CCPaths.manifestFileName))
        let m = try JSONDecoder().decode(D1ModelManifest.self, from: data)
        var bad: [String] = []
        for (name, entry) in m.files.sorted(by: { $0.key < $1.key }) {
            let url = directory.appendingPathComponent(name)
            guard FileManager.default.fileExists(atPath: url.path) else { bad.append(name); continue }
            if try sha256(of: url) != entry.sha256 { bad.append(name) }
        }
        return bad
    }
}

// `D1ModelManifest` は CCCore（ModelManifest.swift）へ移した。下の型エイリアスで `CCModels.D1ModelManifest` も使える。
public typealias D1ModelManifest = CCCore.D1ModelManifest

public enum D1PrepareError: Error, CustomStringConvertible {
    case missingSourceFile(String)
    case sourceChecksumMismatch(expected: String, actual: String)
    case invalidSourceConfig
    case noLanguageModelWeights
    case quantizationFailed(String)

    public var description: String {
        switch self {
        case let .missingSourceFile(n): return "元モデルのファイルが無い: \(n)"
        case let .sourceChecksumMismatch(e, a): return "元モデルの sha256 が違う（期待 \(e)、実際 \(a)）"
        case .invalidSourceConfig: return "元モデルの config.json に text_config / intermediate_size が無い"
        case .noLanguageModelWeights: return "model.language_model.* の重みが無い"
        case let .quantizationFailed(n): return "量子化に失敗: \(n)"
        }
    }
}
