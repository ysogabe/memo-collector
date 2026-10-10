import CCCore
import CCGuard
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 「要確認」の記録に対するユーザーの判断（F-10）の本物。
///
/// - `markReviewed`: 要確認 → `clear`（既に clear なら何もしない）。それ以外の状態（pending / masked）は変えない
/// - `useMaskedImage`: 元のスクショの検出箇所を `SecretMasker.mask` で塗り、HEIC で `maskedScreenshot`
///   （`<id>-masked.heic`）に書いてから、`maskedScreenshotPath` と `guard.status = masked` を設定する
/// - どちらも `modify`（トランザクション内の read-modify-write）で最新を読み直して書く。マスクを作る間にスクショや検出結果が
///   変わっていたら書かずに失敗させる（別の画像のマスクを「渡せる」にしない）
/// - ⚠️ 検出文字列・OCR 結果はログに出さない（このクラスは bbox しか扱わない）
struct LiveGuardReviewer: GuardReviewing {
    typealias Modify = @Sendable (_ id: String, _ transform: @escaping @Sendable (inout ContextRecord) throws -> Void) async throws -> ContextRecord

    let store: any RecordStore
    let modify: Modify
    /// マスク画像の形式（HEIC。書けなければ PNG）。
    var formats: [ScreenshotEncoder.Format] = [
        ScreenshotEncoder.Format(type: .heic, fileExtension: "heic"),
        ScreenshotEncoder.Format(type: .png, fileExtension: "png"),
    ]

    enum ReviewError: Error, Equatable {
        case notFound
        /// 要確認ではない（ガード処理中・マスク済みなど）。
        case notNeedingReview(GuardStatus)
        case noScreenshot
        case unreadableScreenshot
        case maskFailed
        /// マスクを作っている間にスクショか検出結果が変わった。
        case changedDuringMasking
    }

    func markReviewed(recordID: String) async throws -> ContextRecord {
        try await modify(recordID) { r in
            switch r.guardInfo.status {
            case .needsReview: r.guardInfo.status = .clear
            case .clear: break
            case let other: throw ReviewError.notNeedingReview(other)
            }
        }
    }

    func useMaskedImage(recordID: String) async throws -> ContextRecord {
        guard let r = try await store.get(id: recordID) else { throw ReviewError.notFound }
        guard r.guardInfo.status == .needsReview else { throw ReviewError.notNeedingReview(r.guardInfo.status) }
        guard let shot = r.screenshotPath else { throw ReviewError.noScreenshot }
        let findings = r.guardInfo.findings

        let url = try await store.attachmentURL(for: shot)
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(src, 0, nil) else { throw ReviewError.unreadableScreenshot }
        guard let masked = SecretMasker.mask(image: image, findings: findings),
              let encoded = ScreenshotEncoder.encode(masked, formats: formats) else { throw ReviewError.maskFailed }
        let path = try await store.writeAttachment(encoded.data, id: r.id, kind: .maskedScreenshot,
                                                   ext: encoded.fileExtension, capturedAt: r.capturedAt)
        do {
            return try await modify(recordID) { latest in
                guard latest.screenshotPath == shot, latest.guardInfo.findings == findings,
                      latest.guardInfo.status == .needsReview else { throw ReviewError.changedDuringMasking }
                latest.maskedScreenshotPath = path
                latest.guardInfo.status = .masked
            }
        } catch {
            // 書いたマスク画像を、どの記録も指していなければ消す（前からこのパスを指していたなら残す）。
            if r.maskedScreenshotPath != path, let u = try? await store.attachmentURL(for: path) {
                try? FileManager.default.removeItem(at: u)
            }
            throw error
        }
    }
}
