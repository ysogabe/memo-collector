// Apple Vision の OCR（VNRecognizeTextRequest）でスクショの文字を読む。
// usage: swift ocr.swift a.png b.png ...  → 1 行 1 JSON {"path","ms","text"}
import AppKit
import Foundation
import Vision

for path in CommandLine.arguments.dropFirst() {
    guard let image = NSImage(contentsOfFile: path),
          let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil) else {
        FileHandle.standardError.write("cannot load \(path)\n".data(using: .utf8)!)
        continue
    }
    let start = Date()
    let request = VNRecognizeTextRequest()
    request.recognitionLevel = .accurate
    request.recognitionLanguages = ["ja-JP", "en-US"]
    request.usesLanguageCorrection = false  // キーやトークンを辞書補正で壊さない
    try VNImageRequestHandler(cgImage: cg).perform([request])
    let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
    let ms = Int(Date().timeIntervalSince(start) * 1000)
    let obj: [String: Any] = ["path": path, "ms": ms, "text": lines.joined(separator: "\n")]
    let data = try JSONSerialization.data(withJSONObject: obj)
    print(String(data: data, encoding: .utf8)!)
}
