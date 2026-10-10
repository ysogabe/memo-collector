import CCCore
import ImageIO
import XCTest

final class LatencySamplesTests: XCTestCase {
    func testPercentilesUseNearestRank() {
        var s = LatencySamples(capacity: 20)
        XCTAssertNil(s.p50)
        for v in 1...10 { s.append(Double(v * 10)) }
        XCTAssertEqual(s.p50, 50)
        XCTAssertEqual(s.p90, 90)
        s.append(1000)
        XCTAssertEqual(s.p90, 100)
    }

    func testKeepsOnlyRecentValues() {
        var s = LatencySamples(capacity: 20)
        for v in 1...25 { s.append(Double(v)) }
        XCTAssertEqual(s.count, 20)
        XCTAssertEqual(s.values.first, 6)
        XCTAssertEqual(s.values.last, 25)
    }
}

final class ScreenshotEncoderTests: XCTestCase {
    func testEncodesWithFirstWritableFormat() throws {
        let format = try XCTUnwrap(ScreenshotEncoder.chosenFormat)
        // macOS の ImageIO は WebP を書けない（読めるだけ）ので HEIC になる。書けるようになったら WebP が選ばれる。
        XCTAssertTrue(["webp", "heic"].contains(format.fileExtension), format.fileExtension)
        let encoded = try XCTUnwrap(ScreenshotEncoder.encode(TestImages.solid(width: 320, height: 200)))
        XCTAssertEqual(encoded.fileExtension, format.fileExtension)
        let src = try XCTUnwrap(CGImageSourceCreateWithData(encoded.data as CFData, nil))
        let decoded = try XCTUnwrap(CGImageSourceCreateImageAtIndex(src, 0, nil))
        XCTAssertEqual(decoded.width, 320)
        XCTAssertEqual(decoded.height, 200)
    }

    func testFallsBackToNextFormat() throws {
        let bogus = ScreenshotEncoder.Format(type: .init(exportedAs: "dev.ysogabe.not-an-image"), fileExtension: "xx")
        let encoded = try XCTUnwrap(ScreenshotEncoder.encode(TestImages.solid(), formats: [bogus, .init(type: .png, fileExtension: "png")]))
        XCTAssertEqual(encoded.fileExtension, "png")
    }
}

final class AudioFileIOTests: XCTestCase {
    func testWAVRoundTrip() throws {
        let samples = (0..<1600).map { Float(sin(Double($0) * 0.1)) * 0.5 }
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("cc-roundtrip-\(UUID().uuidString).wav")
        defer { try? FileManager.default.removeItem(at: url) }
        try AudioFileIO.wavData(samples: samples).write(to: url)
        let back = try AudioFileIO.readMono16k(url: url)
        XCTAssertEqual(back.count, samples.count)
        for (a, b) in zip(samples, back) { XCTAssertEqual(a, b, accuracy: 1.0 / 16_000) }
    }
}

final class SubstringSearchServiceTests: XCTestCase {
    func testMatchesAnnotationTitleAndURLCaseInsensitively() async throws {
        let store = TestStore()
        defer { try? FileManager.default.removeItem(at: store.root) }
        let now = Date()
        let a = ContextRecord(capturedAt: now, app: AppInfo(name: "Safari", bundleID: nil),
                              window: WindowInfo(title: "WhisperKit README", frame: nil),
                              annotation: Annotation(text: "あとで読む", sttEngine: nil))
        let b = ContextRecord(capturedAt: now.addingTimeInterval(-10), app: AppInfo(name: "Chrome", bundleID: nil),
                              url: "https://github.com/x/hermes",
                              annotation: Annotation(text: "Hermesのアダプタに使えそう", sttEngine: nil))
        let c = ContextRecord(capturedAt: now.addingTimeInterval(-20), app: AppInfo(name: "Terminal", bundleID: nil),
                              annotation: Annotation(text: "ＨＥＲＭＥＳ の設定", sttEngine: nil))
        for r in [a, b, c] { try await store.insert(r) }
        let search = SubstringSearchService(store: store)

        let hermes = try await search.search("hermes", limit: 10).map(\.record.id)
        XCTAssertEqual(Set(hermes), [b.id, c.id], "全角・大文字小文字を無視")
        let whisper = try await search.search("whisperkit", limit: 10).map(\.record.id)
        XCTAssertEqual(whisper, [a.id])
        let both = try await search.search("hermes アダプタ", limit: 10).map(\.record.id)
        XCTAssertEqual(both, [b.id], "語はすべて含む")
        let blank = try await search.search("  ", limit: 10)
        XCTAssertTrue(blank.isEmpty)
        let limited = try await search.search("hermes", limit: 1)
        XCTAssertEqual(limited.count, 1)
    }
}
