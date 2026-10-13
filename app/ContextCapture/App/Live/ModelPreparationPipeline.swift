import CCCore
import Foundation

/// モデル 1 種の準備（文字起こし・検索・意図）。本物は `ModelSlots.swift`、テストはフェイク。
protocol ModelSlotPreparing: Sendable {
    /// 表示名（例: "文字起こしモデル"）。
    var displayName: String { get }
    /// ダウンロードする大きさの目安（進捗と説明用）。
    var downloadBytes: Int64 { get }
    /// 取得〜変換の間に一時的に要る空き容量（取得物 + 変換物 + 余裕）。ファイルが揃っていれば 0 とみなす。
    var requiredFreeBytes: Int64 { get }
    /// 読み込みに要るファイルが揃っているか（manifest の有無は問わない。開発用の置き場は manifest が無い）。
    func filesPresent() -> Bool
    /// 使える状態か（文字起こしは読み込み済みまで）。
    func isPrepared() async -> Bool
    /// 取得・変換・（必要なら）読み込み。`progress(phase, 0–1)`。
    func prepare(progress: @escaping @Sendable (ModelPreparationProgress.Phase, Double) -> Void) async throws
}

/// 空き容量が足りない。
struct InsufficientDiskSpace: LocalizedError, Equatable {
    var requiredBytes: Int64
    var availableBytes: Int64

    var errorDescription: String? {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return "空き容量が足りません。モデルの準備に \(f.string(fromByteCount: requiredBytes)) の空きが要りますが、"
            + "\(f.string(fromByteCount: availableBytes)) しかありません。あと \(f.string(fromByteCount: requiredBytes - availableBytes)) 空けてから、もう一度始めてください。"
    }
}

/// 3 モデルの準備（オンボーディング）。順序は 文字起こし → 検索 → 意図（d1）。
///
/// - 揃っていないモデルの `requiredFreeBytes` の合計を、始める前に空き容量と比べる。足りなければ何も取らずに
///   `InsufficientDiskSpace`（必要量を表示する）
/// - 進捗はダウンロード量で重み付けして 0–1 に均す（揃っているモデルも小さな重みで数える。文字起こしは読み込みがあるため）
/// - 全部終わったら `onPrepared`（埋め込みの準備とトリアージの再開を始める）。検索モデルの ANE 初回特殊化（数分）は
///   ここでは待たない（バックグラウンドで続き、メニューバーに「検索の準備中」を出す）
struct ModelPreparationPipeline: ModelPreparationProviding {
    let slots: [any ModelSlotPreparing]
    /// モデル置き場の空き容量（bytes）。取れなければ nil（チェックしない）。
    let availableBytes: @Sendable () -> Int64?
    var onPrepared: @Sendable () async -> Void = {}

    /// 揃っていないモデルの準備に要る空き容量。
    func requiredFreeBytes() -> Int64 {
        slots.filter { !$0.filesPresent() }.reduce(0) { $0 + $1.requiredFreeBytes }
    }

    func isPrepared() async -> Bool {
        for s in slots where !(await s.isPrepared()) { return false }
        return true
    }

    func prepare() -> AsyncThrowingStream<ModelPreparationProgress, Error> {
        AsyncThrowingStream { c in
            let task = Task {
                do {
                    try await run(c)
                    c.finish()
                } catch {
                    CCLog.models.error("model preparation failed: \(String(describing: error), privacy: .public)")
                    c.finish(throwing: error)
                }
            }
            c.onTermination = { _ in task.cancel() }
        }
    }

    private func run(_ c: AsyncThrowingStream<ModelPreparationProgress, Error>.Continuation) async throws {
        let present = slots.map { $0.filesPresent() }
        let required = zip(slots, present).filter { !$0.1 }.reduce(Int64(0)) { $0 + $1.0.requiredFreeBytes }
        if required > 0, let available = availableBytes(), available < required {
            CCLog.models.error("insufficient disk: required \(required) available \(available)")
            throw InsufficientDiskSpace(requiredBytes: required, availableBytes: available)
        }
        // 重み: 取るものはダウンロード量、揃っているものは 1%（読み込みだけ）。
        let weights: [Double] = zip(slots, present).map { s, p in p ? 0.01 : max(Double(s.downloadBytes), 1) }
        let totalWeight = max(weights.reduce(0, +), 1)
        let totalBytes = zip(slots, present).filter { !$0.1 }.reduce(Int64(0)) { $0 + $1.0.downloadBytes }
        var before = 0.0
        for (i, slot) in slots.enumerated() {
            try Task.checkCancellation()
            let base = before / totalWeight
            let span = weights[i] / totalWeight
            let name = slot.displayName
            CCLog.models.notice("preparing \(name, privacy: .public) (files present: \(present[i]))")
            c.yield(ModelPreparationProgress(phase: present[i] ? .optimizing : .downloading, fractionCompleted: base,
                                             completedBytes: Int64(Double(totalBytes) * base), totalBytes: totalBytes,
                                             currentItem: name))
            try await slot.prepare { phase, f in
                let overall = base + span * min(max(f, 0), 1)
                c.yield(ModelPreparationProgress(phase: phase == .finished ? .optimizing : phase, fractionCompleted: overall,
                                                 completedBytes: Int64(Double(totalBytes) * overall), totalBytes: totalBytes,
                                                 currentItem: name))
            }
            before += weights[i]
        }
        try Task.checkCancellation()
        await onPrepared()
        c.yield(ModelPreparationProgress(phase: .finished, fractionCompleted: 1, completedBytes: totalBytes, totalBytes: totalBytes))
    }

    /// `url`（無ければ存在する親）を含むボリュームの空き容量（重要な用途向け。macOS が消せるキャッシュも含む）。
    static func availableCapacity(at url: URL) -> Int64? {
        var u = url
        while !FileManager.default.fileExists(atPath: u.path), u.pathComponents.count > 1 {
            u = u.deletingLastPathComponent()
        }
        let values = try? u.resourceValues(forKeys: [.volumeAvailableCapacityForImportantUsageKey])
        return values?.volumeAvailableCapacityForImportantUsage
    }
}
