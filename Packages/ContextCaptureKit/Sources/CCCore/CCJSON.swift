import Foundation

/// ContextRecord 等を JSON にするときの共通エンコーダ／デコーダ。
/// 日時は ISO 8601（`2026-10-08T23:15:32+09:00`）。エンコードは指定タイムゾーンのオフセット付きで、
/// 小数秒があるときだけミリ秒まで書く。デコードは小数秒あり／なし・`Z`／オフセットのどれも受ける。
public enum CCJSON {
    /// 共通エンコーダ。`timeZone` は書き出すオフセット（既定は端末のタイムゾーン）。キーは並べ替えて出す。
    public static func encoder(timeZone: TimeZone = .current) -> JSONEncoder {
        let e = JSONEncoder()
        e.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        e.dateEncodingStrategy = .custom { date, encoder in
            var c = encoder.singleValueContainer()
            try c.encode(formatDate(date, timeZone: timeZone))
        }
        return e
    }

    /// 共通デコーダ。
    public static func decoder() -> JSONDecoder {
        let d = JSONDecoder()
        d.dateDecodingStrategy = .custom { decoder in
            let c = try decoder.singleValueContainer()
            let s = try c.decode(String.self)
            guard let date = parseDate(s) else {
                throw DecodingError.dataCorruptedError(in: c, debugDescription: "ISO 8601 の日時ではない: \(s)")
            }
            return date
        }
        return d
    }

    /// ISO 8601 文字列にする（小数秒が 0 なら秒まで）。
    public static func formatDate(_ date: Date, timeZone: TimeZone = .current) -> String {
        let f = ISO8601DateFormatter()
        f.timeZone = timeZone
        let hasFraction = date.timeIntervalSince1970.truncatingRemainder(dividingBy: 1) != 0
        f.formatOptions = hasFraction ? [.withInternetDateTime, .withFractionalSeconds] : [.withInternetDateTime]
        return f.string(from: date)
    }

    /// ISO 8601 文字列を読む（小数秒あり／なし）。読めなければ nil。
    public static func parseDate(_ string: String) -> Date? {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let d = f.date(from: string) { return d }
        f.formatOptions = [.withInternetDateTime]
        return f.date(from: string)
    }
}
