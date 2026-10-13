import Foundation

/// `CaptureContext.screenshotSkipReason` に入る固定文字列（ログと UI 表示用）。
public enum ScreenshotSkipReason {
    /// 除外アプリ（F-13）が前面だった。
    public static let excludedApp = "excluded_app"
    /// 画面収録の権限が無い。
    public static let permissionDenied = "permission_denied"
    /// ScreenCaptureKit がウインドウも画面全体も撮れなかった。
    public static let captureFailed = "capture_failed"
    /// 全体のタイムアウト（既定 1.5 秒）までに撮れなかった。
    public static let timeout = "timeout"
    /// 設定でスクショ取得を切っている（診断用）。
    public static let disabled = "disabled"
}

/// 競争の結果。`timedOut` は「期限までに operation が終わらなかった」。
enum RaceResult<T> {
    case value(T)
    case timedOut

    var value: T? {
        if case let .value(v) = self { return v }
        return nil
    }
}

extension RaceResult: Sendable where T: Sendable {}

/// continuation を 1 回だけ resume する（2 回目以降は無視）。
final class ResumeOnce<T>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Never>?

    init(_ continuation: CheckedContinuation<T, Never>) {
        self.continuation = continuation
    }

    func resume(_ value: T) {
        lock.lock()
        let c = continuation
        continuation = nil
        lock.unlock()
        c?.resume(returning: value)
    }
}

/// タイムアウトの合成。TaskGroup は子の終了を待つため、止まらない処理（AX・AppleScript・SCK）を
/// 期限で見捨てられない。ここでは先に終わった方を採り、負けた operation は放置する（キャンセル要求だけ送る）。
enum Deadline {
    static func race<T>(
        timeout: TimeInterval,
        _ operation: @escaping @Sendable () async -> T
    ) async -> RaceResult<T> {
        guard timeout > 0 else { return .timedOut }
        return await withCheckedContinuation { (cont: CheckedContinuation<RaceResult<T>, Never>) in
            let once = ResumeOnce(cont)
            let task = Task {
                let v = await operation()
                once.resume(.value(v))
            }
            DispatchQueue.global(qos: .userInitiated).asyncAfter(deadline: .now() + timeout) {
                once.resume(.timedOut)
                task.cancel()
            }
        }
    }

    /// 期限までの残り秒（負なら 0）。
    static func remaining(until deadline: TimeInterval, now: TimeInterval = ProcessInfo.processInfo.systemUptime) -> TimeInterval {
        max(0, deadline - now)
    }
}

/// ブロックする処理を協調スレッドプールの外（専用キュー）で走らせる。
func runBlocking<T>(on queue: DispatchQueue, _ body: @escaping @Sendable () -> T) async -> T {
    await withCheckedContinuation { (cont: CheckedContinuation<T, Never>) in
        queue.async {
            let box = UncheckedBox(body())
            cont.resume(returning: box.value)
        }
    }
}

/// Sendable でない値（CGImage・AXUIElement 等の不変 / スレッド安全なもの）を境界越しに運ぶ箱。
struct UncheckedBox<T>: @unchecked Sendable {
    var value: T
    init(_ value: T) { self.value = value }
}

/// ロックで守る値。
final class Locked<Value>: @unchecked Sendable {
    private let lock = NSLock()
    private var value: Value

    init(_ value: Value) { self.value = value }

    func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
        lock.lock()
        defer { lock.unlock() }
        return try body(&value)
    }

    var current: Value { withLock { $0 } }
}

extension Date {
    // ミリ秒への丸め（`roundedToMilliseconds`）は CCCore の public 拡張を使う。

    /// システム起動からの秒（`ProcessInfo.systemUptime` と同じ時計）を Date にする。
    static func fromUptime(_ uptime: TimeInterval, now: Date = Date(), nowUptime: TimeInterval = ProcessInfo.processInfo.systemUptime) -> Date {
        now.addingTimeInterval(uptime - nowUptime)
    }
}
