import CCCore
import CCStore
import CoreGraphics
import Foundation
import ImageIO
import MCP
import UniformTypeIdentifiers
import XCTest
@testable import CCMCP

/// 一時ディレクトリの本物の SQLiteRecordStore。
final class TempStore {
    let root: URL
    let paths: CCPaths
    let store: SQLiteRecordStore

    init() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("ccmcp-tests-\(UUID().uuidString)", isDirectory: true)
        paths = CCPaths(dataRoot: root.appendingPathComponent("data", isDirectory: true),
                        modelsRoot: root.appendingPathComponent("models", isDirectory: true))
        store = try SQLiteRecordStore(paths: paths, timeZone: TimeZone(identifier: "Asia/Tokyo")!)
    }

    deinit { try? FileManager.default.removeItem(at: root) }
}

/// 単語ごとに決まった軸を立てるフェイク埋め込み（"alpha" → e0, "beta" → e1 …）。
struct FakeEmbedder: Embedder {
    var dimension: Int = 256
    var fail = false
    static let vocabulary = ["alpha", "beta", "gamma", "delta"]

    func vector(for text: String) -> [Float] {
        var v = [Float](repeating: 0, count: dimension)
        for (i, w) in Self.vocabulary.enumerated() where text.lowercased().contains(w) { v[i] = 1 }
        if v.allSatisfy({ $0 == 0 }) { v[dimension - 1] = 1 }
        let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
        return v.map { $0 / norm }
    }

    func embedQuery(_ text: String) async throws -> [Float] {
        if fail { throw NSError(domain: "fake", code: 1) }
        return vector(for: text)
    }

    func embedDocument(text: String, title: String?, image: CGImage?) async throws -> [Float] {
        vector(for: text)
    }
}

enum Fixtures {
    static let tokyo = TimeZone(identifier: "Asia/Tokyo")!

    static func record(
        _ text: String,
        at capturedAt: Date = Date(timeIntervalSince1970: 1_791_500_000),
        title: String? = "adapter.ts — mach-runtime",
        url: String? = nil,
        intent: Intent? = .code,
        confidence: Double = 0.9,
        triaged: Bool = true,
        guardStatus: GuardStatus = .clear,
        status: RecordStatus = .inbox
    ) -> ContextRecord {
        ContextRecord(
            id: ULID.generate(now: capturedAt).string,
            capturedAt: capturedAt,
            app: AppInfo(name: "Visual Studio Code", bundleID: "com.microsoft.VSCode"),
            window: WindowInfo(title: title, frame: nil),
            url: url,
            annotation: Annotation(text: text, sttEngine: "whisper-large-v3-turbo"),
            triage: triaged
                ? TriageResult(intent: intent, intentConfidence: confidence, mentionsDatetime: false, model: "test")
                : nil,
            guardInfo: GuardInfo(status: guardStatus,
                                 findings: guardStatus == .clear || guardStatus == .pending ? [] : [SecretFinding(kind: "github_token", bbox: CGRect(x: 0.1, y: 0.1, width: 0.2, height: 0.05))]),
            status: status
        )
    }

    /// 単色の画像を指定形式でエンコードする。
    static func imageData(width: Int = 64, height: Int = 48, type: UTType = .png, noise: Bool = false) -> Data {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.2, green: 0.4, blue: 0.8, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if noise, let buf = ctx.data?.assumingMemoryBound(to: UInt8.self) {
            var rng = SystemRandomNumberGenerator()
            for i in 0..<(ctx.bytesPerRow * height) { buf[i] = UInt8.random(in: 0...255, using: &rng) | (i % 4 == 3 ? 255 : 0) }
        }
        let image = ctx.makeImage()!
        let out = NSMutableData()
        let dest = CGImageDestinationCreateWithData(out as CFMutableData, type.identifier as CFString, 1, nil)!
        CGImageDestinationAddImage(dest, image, nil)
        precondition(CGImageDestinationFinalize(dest))
        return out as Data
    }
}

/// アプリの `ScreenshotEncoder`（app/ContextCapture/App/Live/ScreenshotEncoder.swift）と同じ設定の HEIC。
/// 本番のスクショ・マスク版は macOS 27 では HEIC（WebP は書けない）で保存される。
enum HEICFixtures {
    /// `ScreenshotEncoder.quality` と同じ。
    static let quality: Double = 0.85

    /// 明るい灰色の背景に、左から `blackFraction` の幅を黒で塗った画像（マスク版の黒塗りの代わり）。
    static func image(width: Int, height: Int, blackFraction: Double = 0) -> CGImage {
        let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.setFillColor(CGColor(red: 0.9, green: 0.9, blue: 0.9, alpha: 1))
        ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
        if blackFraction > 0 {
            ctx.setFillColor(CGColor(red: 0, green: 0, blue: 0, alpha: 1))
            ctx.fill(CGRect(x: 0, y: 0, width: Double(width) * blackFraction, height: Double(height)))
        }
        return ctx.makeImage()!
    }

    static func encode(_ image: CGImage) throws -> Data {
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.heic.identifier as CFString, 1, nil) else {
            throw XCTSkip("この OS の ImageIO は HEIC を書けない")
        }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { throw XCTSkip("HEIC のエンコードに失敗") }
        return out as Data
    }

    /// 画像を RGBA8 に描き、列 `x`・行 `y`（上から）の画素の明るさ（RGB の平均、0〜255）を返す。
    static func brightness(of image: CGImage, x: Int, y: Int) -> Double {
        let w = image.width, h = image.height
        let ctx = CGContext(data: nil, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        let buf = ctx.data!.assumingMemoryBound(to: UInt8.self)
        let i = y * w * 4 + x * 4
        return (Double(buf[i]) + Double(buf[i + 1]) + Double(buf[i + 2])) / 3
    }
}

extension CallTool.Result {
    var texts: [String] {
        content.compactMap { if case let .text(text, _, _) = $0 { return text } else { return nil } }
    }

    var images: [(data: String, mimeType: String)] {
        content.compactMap { if case let .image(data, mime, _, _) = $0 { return (data, mime) } else { return nil } }
    }

    /// 最初のテキストを JSON オブジェクトとして読む。
    func json(file: StaticString = #filePath, line: UInt = #line) throws -> [String: Any] {
        let text = try XCTUnwrap(texts.first, file: file, line: line)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any], file: file, line: line)
    }
}

/// `MCPError.invalidParams` で投げられることを確かめる。
func assertInvalidParams(
    _ body: @autoclosure () async throws -> CallTool.Result,
    _ contains: String? = nil,
    file: StaticString = #filePath, line: UInt = #line
) async {
    do {
        _ = try await body()
        XCTFail("invalidParams が投げられなかった", file: file, line: line)
    } catch let MCPError.invalidParams(message) {
        if let contains { XCTAssertTrue(message?.contains(contains) == true, "\(message ?? "nil")", file: file, line: line) }
    } catch {
        XCTFail("想定外のエラー: \(error)", file: file, line: line)
    }
}
