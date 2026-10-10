import CCCore
import CoreGraphics
import Foundation

/// 前面コンテキスト取得の設定。
public struct CaptureConfiguration: Sendable, Equatable {
    /// スクショを撮らないアプリ（F-13）。
    public var excludedBundleIDs: Set<String>
    /// 全体の期限（秒）。超えた項目は諦める。
    public var overallTimeout: TimeInterval
    /// URL 取得の期限（秒）。全体の期限とどちらか短い方。
    public var urlTimeout: TimeInterval
    /// URL を取りにいくか。
    public var capturesURL: Bool
    /// スクショを撮るか（診断で切り分けるとき用。アプリでは true）。
    public var capturesScreenshot: Bool
    /// オートメーション許可の扱い。アプリは `.askOnFirstUse`、テスト・診断は `.onlyIfAlreadyGranted`。
    public var automationConsent: AutomationConsentPolicy

    public init(
        excludedBundleIDs: Set<String> = [],
        overallTimeout: TimeInterval = 1.5,
        urlTimeout: TimeInterval = 0.3,
        capturesURL: Bool = true,
        capturesScreenshot: Bool = true,
        automationConsent: AutomationConsentPolicy = .askOnFirstUse
    ) {
        self.excludedBundleIDs = excludedBundleIDs
        self.overallTimeout = overallTimeout
        self.urlTimeout = urlTimeout
        self.capturesURL = capturesURL
        self.capturesScreenshot = capturesScreenshot
        self.automationConsent = automationConsent
    }
}

/// 各項目の所要時間（ミリ秒、診断用。`CaptureContext.extra` には入れない）。
struct CaptureTimings: Sendable, Equatable {
    var totalMs: Double = 0
    var windowMs: Double?
    var urlMs: Double?
    var screenshotMs: Double?
    var windowTimedOut = false
    var urlTimedOut = false
    var screenshotScope: String?
}

/// ホットキー押下の瞬間に呼ぶ前面コンテキスト取得（F-03, F-04, F-13）。
///
/// - **throw しない・落ちない**。権限が無い・時間切れの項目は nil（スクショは `screenshotSkipReason` に理由）。
/// - アプリ名とバンドル ID は即時（NSWorkspace）。ウインドウ（AX）・URL（AppleScript）・スクショ（ScreenCaptureKit）は並行に走らせ、
///   全体の期限（既定 1.5 秒）、URL は 0.3 秒で見捨てる。
/// - 押下時点の窓を撮るため、STT や保存より先に呼ぶこと。
public final class FrontmostContextCapturer: ContextCapturing, @unchecked Sendable {
    struct Dependencies: Sendable {
        var frontmost: any FrontmostAppProviding
        var windowReader: any FocusedWindowReading
        var urlProvider: any BrowserURLProviding
        var screenshotter: any ScreenshotTaking
        var permissions: any CapturePermissionChecking
    }

    private let state: Locked<CaptureConfiguration>
    private let deps: Dependencies

    /// 実環境用。
    public convenience init(configuration: CaptureConfiguration = CaptureConfiguration()) {
        self.init(configuration: configuration, dependencies: Dependencies(
            frontmost: WorkspaceFrontmostAppProvider(),
            windowReader: AXFocusedWindowReader(),
            urlProvider: AppleScriptBrowserURLProvider(policy: configuration.automationConsent),
            screenshotter: SCKScreenshotTaker(),
            permissions: SystemCapturePermissionChecker()
        ))
    }

    init(configuration: CaptureConfiguration, dependencies: Dependencies) {
        state = Locked(configuration)
        deps = dependencies
    }

    /// 設定（除外アプリ等）。設定画面から差し替えてよい（スレッド安全）。
    /// `automationConsent` の変更は生成時の値から変わらない（URL 取得器が生成時に決まるため）。
    public var configuration: CaptureConfiguration {
        get { state.current }
        set { state.withLock { $0 = newValue } }
    }

    public func captureFrontmost() async -> CaptureContext {
        await captureWithTimings().0
    }

    func captureWithTimings() async -> (CaptureContext, CaptureTimings) {
        let config = configuration
        let start = ProcessInfo.processInfo.systemUptime
        let deadline = start + config.overallTimeout
        var timings = CaptureTimings()
        var context = CaptureContext(capturedAt: Date().roundedToMilliseconds)

        let front = deps.frontmost.frontmostApp()
        if let front {
            context.app = AppInfo(name: front.name, bundleID: front.bundleID)
        }
        let pid = front?.pid
        let accessibility = deps.permissions.accessibilityTrusted

        // ウインドウ（AX）。スクショの照合にも使うので Task にして共有する。
        let reader = deps.windowReader
        let windowTask = Task<(RaceResult<WindowInfo?>, Double)?, Never> {
            guard let pid, accessibility else { return nil }
            let t0 = ProcessInfo.processInfo.systemUptime
            let r = await Deadline.race(timeout: Deadline.remaining(until: deadline)) {
                await reader.focusedWindow(pid: pid)
            }
            return (r, (ProcessInfo.processInfo.systemUptime - t0) * 1000)
        }

        // URL（対応ブラウザのときだけ）。
        let urlProvider = deps.urlProvider
        let browserBundleID = config.capturesURL ? front?.bundleID.flatMap { SupportedBrowser.from(bundleID: $0) != nil ? $0 : nil } : nil
        let urlTask = Task<(RaceResult<String?>, Double)?, Never> {
            guard let bundleID = browserBundleID else { return nil }
            let t0 = ProcessInfo.processInfo.systemUptime
            let limit = min(config.urlTimeout, Deadline.remaining(until: deadline))
            let r = await Deadline.race(timeout: limit) { await urlProvider.currentURL(bundleID: bundleID) }
            return (r, (ProcessInfo.processInfo.systemUptime - t0) * 1000)
        }

        // スクショ。除外アプリと権限は ScreenCaptureKit に触る前に判定する。
        var screenshot: ScreenshotOutcome
        if let bundleID = front?.bundleID, config.excludedBundleIDs.contains(bundleID) {
            screenshot = .skipped(ScreenshotSkipReason.excludedApp)
        } else if !config.capturesScreenshot {
            screenshot = .skipped(ScreenshotSkipReason.disabled)
        } else if !deps.permissions.screenCaptureGranted {
            screenshot = .skipped(ScreenshotSkipReason.permissionDenied)
        } else {
            let shooter = deps.screenshotter
            let t0 = ProcessInfo.processInfo.systemUptime
            let r = await Deadline.race(timeout: Deadline.remaining(until: deadline)) {
                await shooter.capture(pid: pid) { await windowTask.value?.0.value ?? nil }
            }
            timings.screenshotMs = (ProcessInfo.processInfo.systemUptime - t0) * 1000
            switch r {
            case let .value(outcome): screenshot = outcome
            case .timedOut: screenshot = .skipped(ScreenshotSkipReason.timeout)
            }
        }
        // 撮れていないのに理由が空、という状態を作らない。
        if screenshot.image == nil, screenshot.skipReason == nil {
            screenshot.skipReason = ScreenshotSkipReason.captureFailed
        }
        context.screenshot = screenshot.image
        context.screenshotSkipReason = screenshot.image == nil ? screenshot.skipReason : nil
        timings.screenshotScope = screenshot.scope

        if case let (r, ms)? = await windowTask.value {
            timings.windowMs = ms
            switch r {
            case let .value(w): context.window = w
            case .timedOut: timings.windowTimedOut = true
            }
        }
        // AX が取れなかったら、照合できた SCWindow のタイトルと frame で補う。
        if context.window == nil, let w = screenshot.matchedWindow {
            context.window = w
        } else if var w = context.window, (w.title ?? "").isEmpty, let t = screenshot.matchedWindow?.title, !t.isEmpty {
            w.title = t
            context.window = w
        }

        if case let (r, ms)? = await urlTask.value {
            timings.urlMs = ms
            switch r {
            case let .value(u): context.url = u
            case .timedOut: timings.urlTimedOut = true
            }
        }

        timings.totalMs = (ProcessInfo.processInfo.systemUptime - start) * 1000
        return (context, timings)
    }
}
