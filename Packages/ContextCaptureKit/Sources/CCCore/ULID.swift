import Foundation

/// ULID（26 文字の Crockford Base32。先頭 10 文字がミリ秒時刻、残り 16 文字が 80bit 乱数）。
/// `generate()` はプロセス内で単調増加（同じミリ秒内では乱数部を +1）するので、文字列の辞書順 = 生成順。
public struct ULID: Hashable, Comparable, Sendable, Codable, CustomStringConvertible {
    /// 大文字 26 文字の表現。レコード id にはこれを使う。
    public let string: String

    static let alphabet = Array("0123456789ABCDEFGHJKMNPQRSTVWXYZ")

    /// 文字列から作る。形式が正しくなければ nil（小文字は大文字に揃える）。
    public init?(string: String) {
        let upper = string.uppercased()
        guard ULID.isValid(upper) else { return nil }
        self.string = upper
    }

    init(timeMs: UInt64, randomHi: UInt16, randomLo: UInt64) {
        // 128bit = time(48) | random(80)。hi は上位 64bit、lo は下位 64bit。
        let hi = (timeMs << 16) | UInt64(randomHi)
        let lo = randomLo
        var chars: [Character] = []
        chars.reserveCapacity(26)
        for i in 0..<26 {
            let shift = 125 - 5 * i
            let v: UInt64
            if shift >= 64 {
                v = (hi >> UInt64(shift - 64)) & 31
            } else if shift + 5 <= 64 {
                v = (lo >> UInt64(shift)) & 31
            } else {
                v = ((lo >> UInt64(shift)) | (hi << UInt64(64 - shift))) & 31
            }
            chars.append(ULID.alphabet[Int(v)])
        }
        string = String(chars)
    }

    /// 新しい ULID を共有ジェネレータで生成する（スレッドセーフ・単調）。
    public static func generate(now: Date = Date()) -> ULID {
        ULIDGenerator.shared.next(now: now)
    }

    /// 26 文字・Crockford Base32（I L O U を含まない）・先頭が 0〜7 なら true。大文字のみ受け付ける。
    public static func isValid(_ s: String) -> Bool {
        guard s.count == 26, let first = s.first, ("0"..."7").contains(first) else { return false }
        return s.allSatisfy { alphabet.contains($0) }
    }

    /// 埋め込まれた時刻（ミリ秒精度）。
    public var timestamp: Date {
        var ms: UInt64 = 0
        for ch in string.prefix(10) {
            ms = ms << 5 | UInt64(ULID.alphabet.firstIndex(of: ch)!)
        }
        return Date(timeIntervalSince1970: Double(ms) / 1000)
    }

    public var description: String { string }

    public static func < (lhs: ULID, rhs: ULID) -> Bool { lhs.string < rhs.string }

    public init(from decoder: Decoder) throws {
        let c = try decoder.singleValueContainer()
        let s = try c.decode(String.self)
        guard let u = ULID(string: s) else {
            throw DecodingError.dataCorruptedError(in: c, debugDescription: "ULID ではない: \(s)")
        }
        self = u
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(string)
    }
}

/// 単調な ULID を作るジェネレータ。時計が戻っても直前の値より大きい ULID を返す。
public final class ULIDGenerator: @unchecked Sendable {
    /// `ULID.generate()` が使う共有インスタンス。
    public static let shared = ULIDGenerator()

    private let lock = NSLock()
    private var lastMs: UInt64 = 0
    private var lastHi: UInt16 = 0
    private var lastLo: UInt64 = 0

    public init() {}

    /// 次の ULID。同じ（または過去の）ミリ秒なら直前の乱数部 +1、それ以外は新しい乱数。
    public func next(now: Date = Date()) -> ULID {
        let nowMs = UInt64(max(0, (now.timeIntervalSince1970 * 1000).rounded(.down)))
        lock.lock()
        defer { lock.unlock() }
        if nowMs > lastMs {
            var rng = SystemRandomNumberGenerator()
            lastMs = nowMs
            lastHi = UInt16.random(in: .min ... .max, using: &rng)
            lastLo = UInt64.random(in: .min ... .max, using: &rng)
        } else {
            let (lo, overflow) = lastLo.addingReportingOverflow(1)
            lastLo = lo
            if overflow {
                let (hi, overflowHi) = lastHi.addingReportingOverflow(1)
                lastHi = hi
                if overflowHi { lastMs += 1 }  // 80bit を使い切ったら時刻を 1ms 進める
            }
        }
        return ULID(timeMs: lastMs, randomHi: lastHi, randomLo: lastLo)
    }
}
