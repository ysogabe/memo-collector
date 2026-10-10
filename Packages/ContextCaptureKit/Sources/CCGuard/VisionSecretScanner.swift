import CCCore
import CoreGraphics
import Foundation
import Vision

/// Apple Vision OCR + 正規表現で秘密情報を検出する（PRD F-10、PoC Q3）。
///
/// - OCR の設定は PoC（`poc/scripts/ocr.swift`）と同じ: `.accurate`、`["ja-JP", "en-US"]`、言語補正なし
///   （辞書補正でキーやトークンを壊さないため）。
/// - 返す bbox は正規化・**左上原点**。Vision の boundingBox は左下原点なので上下を反転して入れる。
/// - 一致した文字範囲の bbox が取れればそれを、取れなければ行（observation）全体を返す。
/// - ⚠️ OCR 結果や検出文字列はログに出さない・保存しない（秘密そのものを残さない）。
public struct VisionSecretScanner: SecretScanning {
    public let detector: SecretDetector
    public let recognitionLanguages: [String]

    public init(detector: SecretDetector = SecretDetector(), recognitionLanguages: [String] = ["ja-JP", "en-US"]) {
        self.detector = detector
        self.recognitionLanguages = recognitionLanguages
    }

    public func scan(image: CGImage) async throws -> [SecretFinding] {
        let lines = try recognize(image: image)
        return detector.detect(lines: lines)
    }

    /// OCR して行（左上原点）にする。テスト・診断用に公開（結果は秘密を含みうるので扱いに注意）。
    public func recognize(image: CGImage) throws -> [OCRLine] {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.recognitionLanguages = recognitionLanguages
        request.usesLanguageCorrection = false
        try VNImageRequestHandler(cgImage: image, options: [:]).perform([request])
        return (request.results ?? []).compactMap { observation -> OCRLine? in
            guard let candidate = observation.topCandidates(1).first else { return nil }
            return OCRLine(
                text: candidate.string,
                bbox: Self.topLeft(observation.boundingBox),
                boxForRange: { range in
                    guard let box = try? candidate.boundingBox(for: range)?.boundingBox else { return nil }
                    return Self.topLeft(box)
                }
            )
        }
    }

    /// Vision の正規化矩形（左下原点）を左上原点にする。0–1 に収める。
    static func topLeft(_ r: CGRect) -> CGRect {
        let flipped = CGRect(x: r.minX, y: 1 - r.maxY, width: r.width, height: r.height)
        return flipped.intersection(CGRect(x: 0, y: 0, width: 1, height: 1))
    }
}
