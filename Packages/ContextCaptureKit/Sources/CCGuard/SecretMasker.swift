import CCCore
import CoreGraphics
import Foundation

/// 検出箇所を塗りつぶしたマスク画像を作る（純粋関数。ファイルにもストアにも触らない）。
///
/// bbox は正規化・左上原点（`SecretFinding` の約束）。CGContext は左下原点なので描画時に上下を反転する。
/// OCR の bbox は文字にぴったり沿うため、`padding` で上下左右に余白を足してから塗る（アセンダ・ディセンダの欠けや、
/// 範囲 bbox が数ピクセルずれる分を吸収する）。
public enum SecretMasker {
    /// 余白（bbox の高さに対する割合）。行の高さの 1/3 程度あれば上下のはみ出しを隠せる。
    public static let defaultPaddingRatio: CGFloat = 0.35
    /// 余白の基準にする高さの上限（画像の高さに対する割合）。複数行のブロック（PEM 鍵）は bbox が高いので、
    /// そのまま割合を掛けると余白が隣の行まで広がる。1 行分の高さ程度で頭打ちにする。
    public static let maxPaddingBaseRatio: CGFloat = 0.04
    /// 余白の下限（ピクセル）。
    public static let minimumPaddingPixels: CGFloat = 4
    /// 塗りの色（不透明の黒）。
    public static let fillColor = CGColor(red: 0, green: 0, blue: 0, alpha: 1)

    /// findings の領域を塗りつぶした画像を返す。findings が空なら元画像の複製を返す。描画に失敗したら nil。
    public static func mask(
        image: CGImage,
        findings: [SecretFinding],
        paddingRatio: CGFloat = defaultPaddingRatio
    ) -> CGImage? {
        let width = image.width
        let height = image.height
        guard let ctx = CGContext(
            data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
            space: CGColorSpace(name: CGColorSpace.sRGB)!,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
        ) else { return nil }
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        ctx.draw(image, in: bounds)
        ctx.setFillColor(fillColor)
        for rect in pixelRects(findings: findings, width: width, height: height, paddingRatio: paddingRatio) {
            // pixelRects は左上原点。CGContext は左下原点なので反転する。
            let flipped = CGRect(x: rect.minX, y: CGFloat(height) - rect.maxY, width: rect.width, height: rect.height)
            ctx.fill(flipped)
        }
        return ctx.makeImage()
    }

    /// 塗る矩形（ピクセル、**左上原点**、余白込み、画像内に切り詰め済み）。テスト・UI のハイライト用。
    public static func pixelRects(
        findings: [SecretFinding],
        width: Int,
        height: Int,
        paddingRatio: CGFloat = defaultPaddingRatio
    ) -> [CGRect] {
        let w = CGFloat(width), h = CGFloat(height)
        let bounds = CGRect(x: 0, y: 0, width: w, height: h)
        return findings.compactMap { f in
            let r = CGRect(x: f.bbox.minX * w, y: f.bbox.minY * h, width: f.bbox.width * w, height: f.bbox.height * h)
            let pad = max(minimumPaddingPixels, min(r.height, h * maxPaddingBaseRatio) * paddingRatio)
            let padded = r.insetBy(dx: -pad, dy: -pad).intersection(bounds)
            return padded.isNull || padded.isEmpty ? nil : padded.integral
        }
    }
}
