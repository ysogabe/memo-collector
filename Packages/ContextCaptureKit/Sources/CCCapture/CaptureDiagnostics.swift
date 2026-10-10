import CCCore
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// 実機確認用の診断（手で実行する。テストからは呼ばない）。結果は JSON 文字列で返し、標準出力にも書く。
/// 手順は `docs/manual-tests/capture.md`。**この関数群はダイアログを出す API を呼ばない**（権限は状態を読むだけ）。
public enum CaptureDiagnostics {
    public struct Options: Sendable {
        /// 診断を始めるまで待つ秒（その間に確認したいアプリを前面にする）。
        public var delaySeconds: Double
        public var capturesScreenshot: Bool
        public var capturesURL: Bool
        public var excludedBundleIDs: Set<String>
        /// スクショを PNG で書き出す先（nil なら書かない）。
        public var screenshotOutputURL: URL?
        /// 標準出力にも書くか。
        public var printsToStdout: Bool

        public init(
            delaySeconds: Double = 3,
            capturesScreenshot: Bool = true,
            capturesURL: Bool = true,
            excludedBundleIDs: Set<String> = [],
            screenshotOutputURL: URL? = nil,
            printsToStdout: Bool = true
        ) {
            self.delaySeconds = delaySeconds
            self.capturesScreenshot = capturesScreenshot
            self.capturesURL = capturesURL
            self.excludedBundleIDs = excludedBundleIDs
            self.screenshotOutputURL = screenshotOutputURL
            self.printsToStdout = printsToStdout
        }
    }

    /// 前面コンテキストを 1 回取り、権限の状態・各項目・所要時間を JSON で返す。
    /// オートメーションは**許可済みのときだけ** URL を取る（ダイアログを出さない）。
    @discardableResult
    public static func runOnce(_ options: Options = Options()) async -> String {
        if options.delaySeconds > 0 {
            try? await Task.sleep(nanoseconds: UInt64(options.delaySeconds * 1_000_000_000))
        }
        let capturer = FrontmostContextCapturer(configuration: CaptureConfiguration(
            excludedBundleIDs: options.excludedBundleIDs,
            capturesURL: options.capturesURL,
            capturesScreenshot: options.capturesScreenshot,
            automationConsent: .onlyIfAlreadyGranted
        ))
        let (ctx, timings) = await capturer.captureWithTimings()

        var out: [String: Any] = [:]
        out["permissions"] = permissionsJSON(frontBundleID: ctx.app?.bundleID)
        out["captured_at"] = CCJSONDate.string(ctx.capturedAt)
        out["app"] = ctx.app.map { ["name": $0.name, "bundle_id": $0.bundleID ?? NSNull()] as [String: Any] } ?? NSNull()
        if let w = ctx.window {
            var wj: [String: Any] = ["title": w.title ?? NSNull()]
            if let f = w.frame { wj["frame"] = [f.minX, f.minY, f.width, f.height] } else { wj["frame"] = NSNull() }
            out["window"] = wj
        } else {
            out["window"] = NSNull()
        }
        out["url"] = ctx.url ?? NSNull()
        if let img = ctx.screenshot {
            var sj: [String: Any] = ["width": img.width, "height": img.height, "scope": timings.screenshotScope ?? NSNull()]
            if let dst = options.screenshotOutputURL {
                sj["saved_to"] = writePNG(img, to: dst) ? dst.path : NSNull()
            }
            out["screenshot"] = sj
        } else {
            out["screenshot"] = NSNull()
        }
        out["screenshot_skip_reason"] = ctx.screenshotSkipReason ?? NSNull()
        out["timings_ms"] = [
            "total": round1(timings.totalMs),
            "window": timings.windowMs.map(round1) ?? NSNull(),
            "url": timings.urlMs.map(round1) ?? NSNull(),
            "screenshot": timings.screenshotMs.map(round1) ?? NSNull(),
            "window_timed_out": timings.windowTimedOut,
            "url_timed_out": timings.urlTimedOut,
        ] as [String: Any]
        return emit(out, print: options.printsToStdout)
    }

    /// 録音の確認: `start()` までの所要時間、`seconds` 秒録音した結果（長さ・ピーク・RMS・WAV の場所）、
    /// その間に流れたレベルの個数を JSON で返す。マイク権限が無ければエラーを JSON に入れて返す（要求はしない）。
    @discardableResult
    public static func runRecordingCheck(seconds: Double = 3, printsToStdout: Bool = true) async -> String {
        let recorder = PushToTalkRecorder()
        var out: [String: Any] = ["microphone": CapturePermissions.status(.microphone).rawValue]
        do {
            let p0 = ProcessInfo.processInfo.systemUptime
            try await recorder.prepare()
            out["prepare_ms"] = round1((ProcessInfo.processInfo.systemUptime - p0) * 1000)
            let levels = await recorder.levels()
            let counter = Task { () -> Int in
                var n = 0
                for await _ in levels { n += 1 }
                return n
            }
            let t0 = ProcessInfo.processInfo.systemUptime
            try await recorder.start()
            out["start_ms"] = round1((ProcessInfo.processInfo.systemUptime - t0) * 1000)
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            let audio = try await recorder.stop()
            out["duration_s"] = round1(audio.duration * 1000) / 1000
            out["sample_count"] = audio.samples16kMono.count
            out["peak"] = audio.samples16kMono.map(abs).max() ?? 0
            out["rms"] = LevelMeter.rms(audio.samples16kMono)
            out["file"] = audio.fileURL?.path ?? NSNull()
            out["level_events"] = await counter.value
        } catch {
            out["error"] = String(describing: error)
        }
        return emit(out, print: printsToStdout)
    }

    /// ホットキーの確認: `seconds` 秒間、押下 / 解放を記録して JSON で返す。
    /// **メインスレッドの run loop が回っている環境（アプリ内）で呼ぶこと。**
    @MainActor
    @discardableResult
    public static func runHotKeyCheck(
        shortcut: HotKeyShortcut = .optionSpace,
        seconds: Double = 10,
        allowEventTapFallback: Bool = true,
        printsToStdout: Bool = true
    ) async -> String {
        let hotKey = GlobalPushToTalkHotKey(shortcut: shortcut)
        var out: [String: Any] = ["shortcut": shortcut.displayString]
        var events: [[String: Any]] = []
        hotKey.onEvent = { e in
            var j: [String: Any] = ["kind": e.kind.rawValue, "uptime": e.uptime]
            if let d = e.pressDuration {
                j["press_duration_s"] = d
                j["short_press"] = e.isShortPress
            }
            events.append(j)
        }
        do {
            let backend = try hotKey.start(allowEventTapFallback: allowEventTapFallback)
            out["backend"] = backend.rawValue
            out["carbon_status"] = Int(hotKey.lastCarbonStatus ?? 0)
            try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
            hotKey.stop()
        } catch {
            out["error"] = String(describing: error)
            out["carbon_status"] = hotKey.lastCarbonStatus.map { Int($0) } ?? NSNull()
        }
        out["events"] = events
        return emit(out, print: printsToStdout)
    }

    // MARK: - 補助

    static func permissionsJSON(frontBundleID: String?) -> [String: Any] {
        var p: [String: Any] = [
            "microphone": CapturePermissions.status(.microphone).rawValue,
            "screen_recording": CapturePermissions.status(.screenRecording).rawValue,
            "accessibility": CapturePermissions.status(.accessibility).rawValue,
        ]
        if let id = frontBundleID, SupportedBrowser.from(bundleID: id) != nil {
            p["automation_front_browser"] = CapturePermissions.automationStatus(bundleID: id).rawValue
        }
        return p
    }

    private static func round1(_ v: Double) -> Double { (v * 10).rounded() / 10 }

    private static func emit(_ object: [String: Any], print: Bool) -> String {
        let data = (try? JSONSerialization.data(withJSONObject: object, options: [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes])) ?? Data("{}".utf8)
        let s = String(decoding: data, as: UTF8.self)
        if print { Swift.print(s) }
        return s
    }

    private static func writePNG(_ image: CGImage, to url: URL) -> Bool {
        guard let dest = CGImageDestinationCreateWithURL(url as CFURL, UTType.png.identifier as CFString, 1, nil) else { return false }
        CGImageDestinationAddImage(dest, image, nil)
        return CGImageDestinationFinalize(dest)
    }
}

/// 診断出力用の日時文字列（ISO 8601、ミリ秒、端末のタイムゾーン）。
enum CCJSONDate {
    static func string(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        f.timeZone = .current
        return f.string(from: d)
    }
}
