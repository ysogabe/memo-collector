import CCCore
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 外部へ渡す画像を読む。データルート外のファイルは読まない（パストラバーサル・シンボリックリンク対策）。
public struct MCPImageLoader: Sendable {
    /// 読み込んだ画像（base64 にする前のバイト列と MIME タイプ）。
    public struct LoadedImage: Sendable, Equatable {
        public var data: Data
        public var mimeType: String
        /// 縮小・変換したなら true。
        public var resized: Bool
    }

    public enum LoadError: Error, Equatable, Sendable {
        /// 相対パスが不正（絶対パス・`..`・データルート外を指すシンボリックリンク等）。
        case outsideDataRoot
        /// ファイルが無い・通常ファイルではない。
        case notFound
        /// 画像として読めない。
        case unreadable
    }

    /// これを超えるファイルは縮小してから返す（MCP の 1 メッセージを数 MB に抑えるため）。
    public var maxBytes: Int
    /// 縮小時の長辺の上限（px）。
    public var maxPixelSize: Int
    /// 長辺がこれを超える画像はサイズに関係なく縮小する。
    public var maxSourcePixelSize: Int

    public init(maxBytes: Int = 5 * 1024 * 1024, maxPixelSize: Int = 2048, maxSourcePixelSize: Int = 8000) {
        self.maxBytes = maxBytes
        self.maxPixelSize = maxPixelSize
        self.maxSourcePixelSize = maxSourcePixelSize
    }

    /// そのまま返せる画像形式（拡張子 → MIME）。これ以外は PNG / JPEG に変換して返す。
    static let passthroughMIMETypes: [String: String] = [
        "png": "image/png",
        "jpg": "image/jpeg",
        "jpeg": "image/jpeg",
        "gif": "image/gif",
        "webp": "image/webp",
    ]

    /// データルートからの相対パスを、データルート内の実在する通常ファイルの URL にする。
    /// 検査は `CCPaths.resolveRegularFileInsideDataRoot` に任せ、エラーをこの型の `LoadError` に読み替える。
    public static func resolveInsideDataRoot(_ relativePath: String, paths: CCPaths) throws -> URL {
        do {
            return try paths.resolveRegularFileInsideDataRoot(relativePath)
        } catch CCPathError.notRegularFile {
            throw LoadError.notFound
        } catch {
            throw LoadError.outsideDataRoot
        }
    }

    /// 相対パスの画像を読む。大きすぎる・そのまま渡せない形式なら縮小・変換する。
    public func load(relativePath: String, paths: CCPaths) throws -> LoadedImage {
        let url = try Self.resolveInsideDataRoot(relativePath, paths: paths)
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { throw LoadError.unreadable }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              CGImageSourceGetCount(source) > 0
        else { throw LoadError.unreadable }

        let ext = url.pathExtension.lowercased()
        let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        let width = props?[kCGImagePropertyPixelWidth] as? Int ?? 0
        let height = props?[kCGImagePropertyPixelHeight] as? Int ?? 0
        let longEdge = max(width, height)

        if let mime = Self.passthroughMIMETypes[ext], data.count <= maxBytes, longEdge <= maxSourcePixelSize {
            return LoadedImage(data: data, mimeType: mime, resized: false)
        }

        // 縮小・変換。長辺を段階的に下げて maxBytes に収まるまで JPEG で書き出す。
        var edge = min(maxPixelSize, longEdge > 0 ? longEdge : maxPixelSize)
        while edge >= 256 {
            if let out = Self.encodeJPEG(source: source, maxPixelSize: edge, quality: 0.8), out.count <= maxBytes {
                return LoadedImage(data: out, mimeType: "image/jpeg", resized: true)
            }
            edge = edge * 3 / 4
        }
        throw LoadError.unreadable
    }

    static func encodeJPEG(source: CGImageSource, maxPixelSize: Int, quality: Double) -> Data? {
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceThumbnailMaxPixelSize: maxPixelSize,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        let out = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(out as CFMutableData, UTType.jpeg.identifier as CFString, 1, nil)
        else { return nil }
        CGImageDestinationAddImage(dest, image, [kCGImageDestinationLossyCompressionQuality: quality] as CFDictionary)
        guard CGImageDestinationFinalize(dest) else { return nil }
        return out as Data
    }
}
