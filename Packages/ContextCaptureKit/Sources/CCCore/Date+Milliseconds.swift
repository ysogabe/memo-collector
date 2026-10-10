import Foundation

extension Date {
    /// ミリ秒に丸める（四捨五入）。
    ///
    /// CCJSON（`CCJSON.encoder` の日時）と CCStore（SQLite の `captured_at` 列）はミリ秒精度で保存するので、
    /// 丸めていない `Date()` をそのまま `ContextRecord` に入れると、保存して読み直した値と `==` にならない。
    /// **方針**: 永続化される日時（`ContextRecord.capturedAt`・`Note.at`・`Handoff.at` など）は、
    /// 値を**作る側**（キャプチャ・追記・受け渡しの生成箇所）でこれを通してから入れる。
    /// 読み込み側・比較側では丸めない（保存済みの値は既にミリ秒精度）。
    public var roundedToMilliseconds: Date {
        Date(timeIntervalSince1970: (timeIntervalSince1970 * 1000).rounded() / 1000)
    }
}
