import CoreGraphics
import Foundation
import ImageIO
import XCTest

enum GuardFixtures {
    /// リポジトリ直下の `poc/fixtures/screens/`（Package.swift に resources を足さずに #filePath から辿る）。
    static let screensDir: URL = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent() // CCGuardTests
        .deletingLastPathComponent() // Tests
        .deletingLastPathComponent() // ContextCaptureKit
        .deletingLastPathComponent() // Packages
        .deletingLastPathComponent() // repo root
        .appendingPathComponent("poc/fixtures/screens", isDirectory: true)

    static let screenIDs = (1...14).map { String(format: "s%02d", $0) }
    /// `poc/fixtures/dataset.json` の contains_secret が true の画面。
    static let secretScreens: Set<String> = ["s07", "s08", "s11", "s13"]

    static func image(_ id: String) throws -> CGImage {
        let url = screensDir.appendingPathComponent("\(id).png")
        guard let src = CGImageSourceCreateWithURL(url as CFURL, nil),
              let img = CGImageSourceCreateImageAtIndex(src, 0, nil) else {
            throw XCTSkip("fixture が読めない: \(url.path)")
        }
        return img
    }

    /// RGBA8 のビットマップ（先頭行が画像の上端）。
    static func rgba(_ image: CGImage) -> [UInt8] {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        return buf
    }

    /// RGBA8 に描き直して (x, y)（ピクセル、左上原点）の色を返す。
    static func pixel(_ image: CGImage, x: Int, y: Int) -> (r: UInt8, g: UInt8, b: UInt8) {
        let w = image.width, h = image.height
        var buf = [UInt8](repeating: 0, count: w * h * 4)
        let ctx = CGContext(data: &buf, width: w, height: h, bitsPerComponent: 8, bytesPerRow: w * 4,
                            space: CGColorSpace(name: CGColorSpace.sRGB)!,
                            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
        ctx.draw(image, in: CGRect(x: 0, y: 0, width: w, height: h))
        // CGContext のビットマップメモリは先頭行が画像の上端。
        let i = (y * w + x) * 4
        return (buf[i], buf[i + 1], buf[i + 2])
    }
}
