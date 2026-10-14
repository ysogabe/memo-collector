import CCCore
import CryptoKit
import Foundation
import Vision
import XCTest
@testable import CCGuard

/// Opt-in diagnostics are restricted to the 14 authored fixtures and never include OCR text.
final class OCRFixtureDiagnosticsTests: XCTestCase {
    func testExportFixtureDiagnostics() throws {
        guard let output = ProcessInfo.processInfo.environment["CC_OCR_REPORT_OUT"] else { throw XCTSkip("opt-in fixture OCR diagnostics") }
        let scanner = VisionSecretScanner()
        func digest(_ data: Data) -> String { SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined() }
        func box(_ rect: CGRect) -> [Double] { [rect.minX, rect.minY, rect.width, rect.height].map(Double.init) }
        var rows: [[String: Any]] = []
        for id in GuardFixtures.screenIDs {
            let image = try GuardFixtures.image(id)
            let lines = try scanner.recognize(image: image)
            let findings = scanner.detector.detect(lines: lines)
            let bytes = try Data(contentsOf: GuardFixtures.screensDir.appendingPathComponent(id + ".png"))
            rows.append(["id": id, "imageSHA256": digest(bytes),
                "ocrLines": lines.map { ["textSHA256": digest(Data($0.text.utf8)), "bbox": box($0.bbox)] as [String: Any] },
                "findings": findings.map { ["kind": $0.kind, "bbox": box($0.bbox)] as [String: Any] }])
        }
        let result: [String: Any] = ["schema": "cc-fixture-ocr/1", "os": ProcessInfo.processInfo.operatingSystemVersionString,
            "visionRequestRevision": VNRecognizeTextRequest.defaultRevision, "languages": scanner.recognitionLanguages,
            "scope": "authored fixtures only; OCR text is not exported", "screens": rows]
        try JSONSerialization.data(withJSONObject: result, options: [.prettyPrinted, .sortedKeys])
            .write(to: URL(fileURLWithPath: output), options: .atomic)
        XCTAssertEqual(rows.count, 14)
    }
}
