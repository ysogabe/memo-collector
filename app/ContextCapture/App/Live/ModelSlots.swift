import CCCore
import CCModels
import CCSTT
import Foundation

// オンボーディングの「モデルの準備」で順に準備する 3 モデル（`ModelPreparationPipeline` の本物の部品）。
// どれも **ファイルは揃っているが manifest が無い（開発用の置き場 `CC_MODELS_DIR=spikes/dev-models` など）ときは取りに行かない**
// （読み取り専用の置き場へ書き込まず、数 GB を取り直さないため）。

/// 文字起こし（Whisper large-v3-turbo / WhisperKit、約 1.5GB）。
///
/// 1. `WhisperModelPreparer.verify(level: .size)` で揃っているかを見る（起動時にも呼ぶので sha256 は読まない）
/// 2. 無い・食い違う → `prepare(progress:)`（Hub から約 1.5GB。sha256 まで検証して manifest を書く）
/// 3. **アプリのプロセス内で** `WhisperKitTranscriber.prepare()`（初回は ANE 特殊化で数十秒〜1 分。キャッシュは実行バイナリ単位）
///
/// `transcriber` は AppCoordinator と同じインスタンス（読み込みは 1 回だけ。読み込み中の呼び出しは同じ読み込みを待つ）。
struct WhisperModelSlot: ModelSlotPreparing {
    let preparer: WhisperModelPreparer
    let transcriber: WhisperKitTranscriber
    let displayName = "文字起こしモデル"
    /// large-v3-turbo の Core ML 版 + トークナイザ（実測 1.5GB）。
    let downloadBytes: Int64 = 1_600_000_000
    let requiredFreeBytes: Int64 = 1_900_000_000
    /// 初回の ANE 特殊化の目安（進捗バーをそれらしく進めるためだけに使う）。
    static let expectedLoadSeconds: Double = 60

    func filesPresent() -> Bool {
        switch try? preparer.verify(level: .size) {
        case .ready?, .unmanifested?: return true
        default: return false
        }
    }

    func isPrepared() async -> Bool {
        guard filesPresent() else { return false }
        return await transcriber.isLoaded
    }

    func prepare(progress: @escaping @Sendable (ModelPreparationProgress.Phase, Double) -> Void) async throws {
        let status = try preparer.verify(level: .size)
        CCLog.models.notice("whisper status: \(String(describing: status), privacy: .public) at \(preparer.root.path, privacy: .public)")
        switch status {
        case .ready, .unmanifested:
            break
        case .missing, .mismatched:
            _ = try await preparer.prepare { stage, fraction in
                // model が大半。tokenizer / manifest（sha256 の計算）は最後の 3%。ダウンロードは全体の 80%。
                let f: Double
                switch stage {
                case "model": f = fraction * 0.97
                case "tokenizer": f = 0.97 + fraction * 0.02
                default: f = 0.99 + fraction * 0.01
                }
                progress(.downloading, f * 0.8)
            }
        }
        try Task.checkCancellation()

        // 読み込み（ANE 特殊化）。進み具合は取れないので、目安の時間に沿って進める。
        let start = Date()
        let ticker = Task {
            while !Task.isCancelled {
                let f = min(0.95, Date().timeIntervalSince(start) / Self.expectedLoadSeconds)
                progress(.optimizing, 0.8 + 0.2 * f)
                try? await Task.sleep(for: .milliseconds(500))
            }
        }
        defer { ticker.cancel() }
        try await transcriber.prepare()
        CCLog.models.notice("whisper loaded in-process in \(Date().timeIntervalSince(start), format: .fixed(precision: 1), privacy: .public)s")
        ticker.cancel()
        _ = await ticker.value  // 最後の進捗が完了の後に来ないように
    }
}

/// 検索（EmbeddingGemma 2 Core ML、取得 約 0.85GB → コンパイル）。ANE の初回特殊化はここではせず、
/// 準備の後に `SearchIndexMaintainer` がバックグラウンドで行う（数分。メニューバーに「検索の準備中」）。
struct EmbeddingModelSlot: ModelSlotPreparing {
    let preparer: EmbeddingModelPreparer
    let displayName = "検索モデル"
    let downloadBytes: Int64 = EmbeddingModelPreparer.pinnedSourceFiles.reduce(0) { $0 + $1.size }
    /// 取得物 + コンパイル済み + 余裕。
    var requiredFreeBytes: Int64 { downloadBytes * 2 + 300_000_000 }

    func filesPresent() -> Bool {
        switch try? preparer.verify(level: .size) {
        case .ready?, .unmanifested?: return true
        default: return false
        }
    }

    func isPrepared() async -> Bool { filesPresent() }

    func prepare(progress: @escaping @Sendable (ModelPreparationProgress.Phase, Double) -> Void) async throws {
        guard !filesPresent() else { return }
        _ = try await preparer.prepare { stage, fraction in
            switch stage {
            case "download": progress(.downloading, fraction * 0.8)
            case "verify": progress(.optimizing, 0.8 + fraction * 0.05)
            case "compile": progress(.optimizing, 0.85 + fraction * 0.13)
            default: progress(.optimizing, 0.98 + fraction * 0.02)
            }
        }
    }
}

/// 意図（d1-3B、HF から約 5.8GB 取得 → Swift で MLX 8bit に変換、約 2.9GB。変換は数分・メモリ約 3GB）。
struct D1ModelSlot: ModelSlotPreparing {
    let preparer: D1ModelPreparer
    let displayName = "意図の推定モデル"
    /// HF の元 checkpoint（model.safetensors 約 5.8GB と tokenizer 類）。
    static let sourceBytes: Int64 = 5_850_000_000
    static let convertedBytes: Int64 = 2_900_000_000
    /// `CCIntent.D1IntentClassifier.load()` が読むファイル（`D1ModelPreparer.requiredFiles` と同じ）。
    static let requiredFiles = D1ModelPreparer.requiredFiles

    /// Python の HF キャッシュに同じ revision があれば取得しない。
    var hasCachedSource: Bool { D1ModelPreparer.pythonHFCacheSnapshot() != nil }
    var downloadBytes: Int64 { hasCachedSource ? 0 : Self.sourceBytes }
    /// 取得物（変換後も `.downloads/` に残る）+ 変換物 + 作業の余裕。
    var requiredFreeBytes: Int64 { downloadBytes + Self.convertedBytes + 500_000_000 }

    /// `D1ModelPreparer.verify(level: .size)`（起動時にも呼ぶので sha256 は読まない）。manifest が無い開発用の置き場
    /// （`.unmanifested`）も揃っているとみなす（変換し直さない）。食い違う（途中で壊れた等）・無いなら準備する。
    func filesPresent() -> Bool {
        switch try? preparer.verify(level: .size) {
        case .ready?, .unmanifested?: return true
        default: return false
        }
    }

    func isPrepared() async -> Bool { filesPresent() }

    func prepare(progress: @escaping @Sendable (ModelPreparationProgress.Phase, Double) -> Void) async throws {
        switch try preparer.verify(level: .size) {
        case .ready, .unmanifested:
            return
        case let .missing(names):
            CCLog.models.notice("d1 missing \(names.joined(separator: ","), privacy: .public) at \(preparer.destination.path, privacy: .public)")
        case let .mismatched(names):
            CCLog.models.notice("d1 mismatched \(names.joined(separator: ","), privacy: .public) at \(preparer.destination.path, privacy: .public)")
        }
        let preparer = preparer
        let source: URL
        if let cached = D1ModelPreparer.pythonHFCacheSnapshot() {
            source = cached
        } else {
            // HubApi は進捗を返さないので、取得先の大きさを見て進める（0–70%）。
            let downloads = preparer.destination.deletingLastPathComponent().appendingPathComponent(".downloads", isDirectory: true)
            let ticker = Task.detached(priority: .utility) {
                while !Task.isCancelled {
                    let f = Double(Self.directorySize(downloads)) / Double(Self.sourceBytes)
                    progress(.downloading, 0.7 * min(f, 1))
                    try? await Task.sleep(for: .seconds(1))
                }
            }
            defer { ticker.cancel() }
            source = try await preparer.download()
        }
        try Task.checkCancellation()
        // 変換は同期で数分かかるので、協調スレッドプールを塞がないよう専用のスレッドで。
        _ = try await withCheckedThrowingContinuation { (c: CheckedContinuation<D1ModelManifest, Error>) in
            Thread.detachNewThread {
                c.resume(with: Result { try preparer.convert(source: source) { f, _ in progress(.optimizing, 0.7 + 0.3 * f) } })
            }
        }
    }

    static func directorySize(_ url: URL) -> Int64 {
        guard let e = FileManager.default.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: Int64 = 0
        for case let u as URL in e {
            total += Int64((try? u.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0)
        }
        return total
    }
}
