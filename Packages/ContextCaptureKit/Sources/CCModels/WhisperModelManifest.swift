import CCCore
import CryptoKit
import Foundation

// `WhisperModelManifest` は CCCore（ModelManifest.swift）へ移した。下の型エイリアスで `CCModels.WhisperModelManifest` も使える。
public typealias WhisperModelManifest = CCCore.WhisperModelManifest

extension WhisperModelManifest {
    /// ファイルの SHA-256（16 進小文字）。大きいファイルを 8MB ずつ読む。
    public static func sha256Hex(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while true {
            let chunk = try autoreleasepool { try handle.read(upToCount: 8 << 20) }
            guard let chunk, !chunk.isEmpty else { break }
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }
}
