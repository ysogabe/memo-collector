import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// スクショを保存用にエンコードした結果。
struct EncodedImage: Sendable, Equatable {
    var data: Data
    /// 拡張子（"webp" / "heic" / "png"）。
    var fileExtension: String
}

/// スクショのエンコード（PRD F-03 は WebP）。
///
/// ImageIO（`CGImageDestination`）で書ける形式を WebP → HEIC → PNG の順に選ぶ。
/// 2026-10 時点の macOS 27 では `CGImageDestinationCopyTypeIdentifiers()` に `org.webmproject.webp` が無く
/// （WebP は読めるが書けない）、HEIC になる。HEIC は WebP と同程度に小さく、ハードウェアエンコーダで速い。
/// 品質 0.85 は Wave 3 の OCR（秘密情報ガード）で小さな文字が潰れないよう高めにしてある。
enum ScreenshotEncoder {
    struct Format: Sendable, Equatable {
        var type: UTType
        var fileExtension: String
    }

    static let preferred: [Format] = [
        Format(type: .webP, fileExtension: "webp"),
        Format(type: .heic, fileExtension: "heic"),
        Format(type: .png, fileExtension: "png"),
    ]

    static let quality: Double = 0.85

    /// この OS の ImageIO が書ける形式（優先順）。
    static let writableFormats: [Format] = {
        let ids = Set((CGImageDestinationCopyTypeIdentifiers() as? [String]) ?? [])
        return preferred.filter { ids.contains($0.type.identifier) }
    }()

    /// 採用される形式（ログ・報告用）。
    static var chosenFormat: Format? { writableFormats.first }

    /// 書ける形式で順に試し、最初に成功したものを返す。どれも失敗したら nil（スクショなしで保存を続ける）。
    static func encode(_ image: CGImage, formats: [Format] = writableFormats) -> EncodedImage? {
        for f in formats {
            if let data = encode(image, as: f) {
                return EncodedImage(data: data, fileExtension: f.fileExtension)
            }
        }
        return nil
    }

    static func encode(_ image: CGImage, as format: Format) -> Data? {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, format.type.identifier as CFString, 1, nil) else {
            return nil
        }
        var props: [CFString: Any] = [:]
        if format.type != .png {
            props[kCGImageDestinationLossyCompressionQuality] = quality
        }
        CGImageDestinationAddImage(dest, image, props as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
