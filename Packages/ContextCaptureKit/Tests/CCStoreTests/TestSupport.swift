import CCCore
import Foundation
import XCTest
@testable import CCStore

/// 一時データルートを作り、テスト終了時に消す。
final class TempDataRoot {
    let url: URL
    let paths: CCPaths

    init() throws {
        url = FileManager.default.temporaryDirectory
            .appendingPathComponent("CCStoreTests-\(UUID().uuidString)", isDirectory: true)
        paths = CCPaths(dataRoot: url, modelsRoot: url.appendingPathComponent("Models", isDirectory: true))
        try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    }

    func makeStore() throws -> SQLiteRecordStore {
        try SQLiteRecordStore(paths: paths, timeZone: TimeZone(identifier: "Asia/Tokyo")!)
    }

    deinit { try? FileManager.default.removeItem(at: url) }
}

/// CCJSON はミリ秒までしか持たないので、往復比較するテストの日時はミリ秒に丸める。
func ms(_ t: TimeInterval) -> Date {
    Date(timeIntervalSince1970: (t * 1000).rounded() / 1000)
}

let baseTime: TimeInterval = 1_791_468_000  // 2026-10-08T23:00:00+09:00

func makeRecord(
    id: String = ULID.generate().string,
    at offset: TimeInterval = 0,
    status: RecordStatus = .inbox,
    intent: Intent? = nil,
    triaged: Bool = false,
    guardStatus: GuardStatus = .pending,
    text: String = "メモ",
    bundleID: String? = "com.example.app"
) -> ContextRecord {
    ContextRecord(
        id: id,
        capturedAt: ms(baseTime + offset),
        app: AppInfo(name: "Example", bundleID: bundleID),
        annotation: Annotation(text: text, sttEngine: "test"),
        triage: (triaged || intent != nil)
            ? TriageResult(intent: intent, intentConfidence: intent == nil ? 0.4 : 0.9, mentionsDatetime: false, model: "test")
            : nil,
        guardInfo: GuardInfo(status: guardStatus),
        status: status
    )
}

/// i 番目の基底方向を少し混ぜた正規化ベクトル。
func unitVector(_ components: [Int: Float], dim: Int = 256) -> [Float] {
    var v = [Float](repeating: 0, count: dim)
    for (i, x) in components { v[i] = x }
    let norm = sqrt(v.reduce(0) { $0 + $1 * $1 })
    return v.map { $0 / norm }
}
