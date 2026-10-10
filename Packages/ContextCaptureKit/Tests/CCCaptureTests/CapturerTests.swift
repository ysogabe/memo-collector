import ApplicationServices
import CCCore
import CoreGraphics
import ScreenCaptureKit
import XCTest
@testable import CCCapture

// MARK: - フェイク

struct FakeFrontmost: FrontmostAppProviding {
    var app: FrontmostApp?
    func frontmostApp() -> FrontmostApp? { app }
}

struct FakeWindowReader: FocusedWindowReading {
    var window: WindowInfo?
    var delay: TimeInterval = 0
    func focusedWindow(pid: pid_t) async -> WindowInfo? {
        if delay > 0 { blockingSleep(delay) }
        return window
    }
}

struct FakeURLProvider: BrowserURLProviding {
    var url: String?
    var delay: TimeInterval = 0
    let calls = Locked(0)
    func currentURL(bundleID: String) async -> String? {
        calls.withLock { $0 += 1 }
        if delay > 0 { blockingSleep(delay) }
        return url
    }
}

struct FakeScreenshotter: ScreenshotTaking {
    var outcome: ScreenshotOutcome
    var delay: TimeInterval = 0
    let calls = Locked(0)
    let receivedWindow = Locked<WindowInfo?>(nil)
    func capture(pid: pid_t?, window: @escaping @Sendable () async -> WindowInfo?) async -> ScreenshotOutcome {
        calls.withLock { $0 += 1 }
        let w = await window()
        receivedWindow.withLock { $0 = w }
        if delay > 0 { blockingSleep(delay) }
        return outcome
    }
}

struct FakePermissions: CapturePermissionChecking {
    var screenCaptureGranted: Bool
    var accessibilityTrusted: Bool
}

/// 止まらない処理（AX・AppleScript の固まり）を真似る。協調スレッドを塞がないよう別スレッドで寝る。
func blockingSleep(_ seconds: TimeInterval) {
    let sem = DispatchSemaphore(value: 0)
    DispatchQueue.global().asyncAfter(deadline: .now() + seconds) { sem.signal() }
    // ここは専用スレッドではないが、テストでは数本しか同時に走らないので許容する。
    sem.wait()
}

func makeImage(width: Int = 8, height: Int = 6) -> CGImage {
    let ctx = CGContext(data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                        space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.setFillColor(CGColor(red: 1, green: 0, blue: 0, alpha: 1))
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    return ctx.makeImage()!
}

// MARK: - テスト

final class CapturerTests: XCTestCase {
    private let safari = FrontmostApp(name: "Safari", bundleID: "com.apple.Safari", pid: 501)
    private let code = FrontmostApp(name: "Code", bundleID: "com.microsoft.VSCode", pid: 777)
    private let window = WindowInfo(title: "Issue #128", frame: CGRect(x: 10, y: 20, width: 800, height: 600))

    private func capturer(
        app: FrontmostApp?,
        window: FakeWindowReader = FakeWindowReader(window: nil),
        url: FakeURLProvider = FakeURLProvider(url: nil),
        shot: FakeScreenshotter = FakeScreenshotter(outcome: .skipped(ScreenshotSkipReason.captureFailed)),
        permissions: FakePermissions = FakePermissions(screenCaptureGranted: true, accessibilityTrusted: true),
        config: CaptureConfiguration = CaptureConfiguration(automationConsent: .onlyIfAlreadyGranted)
    ) -> FrontmostContextCapturer {
        FrontmostContextCapturer(configuration: config, dependencies: .init(
            frontmost: FakeFrontmost(app: app), windowReader: window, urlProvider: url, screenshotter: shot, permissions: permissions
        ))
    }

    func testHappyPathFillsEverything() async {
        let shot = FakeScreenshotter(outcome: ScreenshotOutcome(image: makeImage(), skipReason: nil, matchedWindow: nil, scope: "window"))
        let c = capturer(app: safari, window: FakeWindowReader(window: window), url: FakeURLProvider(url: "https://github.com/x/y/issues/128"), shot: shot)
        let ctx = await c.captureFrontmost()
        XCTAssertEqual(ctx.app, AppInfo(name: "Safari", bundleID: "com.apple.Safari"))
        XCTAssertEqual(ctx.window, window)
        XCTAssertEqual(ctx.url, "https://github.com/x/y/issues/128")
        XCTAssertNotNil(ctx.screenshot)
        XCTAssertNil(ctx.screenshotSkipReason)
        XCTAssertTrue(ctx.extra.isEmpty, "所要時間などを extra に入れない")
        XCTAssertEqual(shot.receivedWindow.current, window, "スクショの照合に AX の結果が渡る")
        let ms = ctx.capturedAt.timeIntervalSince1970 * 1000
        XCTAssertEqual(ms, ms.rounded(), accuracy: 1e-3, "capturedAt はミリ秒に丸める")
    }

    func testExcludedAppSkipsScreenshotWithoutCallingScreenCapture() async {
        let shot = FakeScreenshotter(outcome: ScreenshotOutcome(image: makeImage(), skipReason: nil, matchedWindow: nil, scope: "window"))
        let c = capturer(app: code, window: FakeWindowReader(window: window), shot: shot,
                         config: CaptureConfiguration(excludedBundleIDs: ["com.microsoft.VSCode"], automationConsent: .onlyIfAlreadyGranted))
        let ctx = await c.captureFrontmost()
        XCTAssertNil(ctx.screenshot)
        XCTAssertEqual(ctx.screenshotSkipReason, "excluded_app")
        XCTAssertEqual(shot.calls.current, 0)
        XCTAssertEqual(ctx.window, window, "除外はスクショだけ（F-13）")
        XCTAssertEqual(ctx.app?.bundleID, "com.microsoft.VSCode")
    }

    func testExclusionListCanBeChangedAtRuntime() async {
        let shot = FakeScreenshotter(outcome: ScreenshotOutcome(image: makeImage(), skipReason: nil, matchedWindow: nil, scope: "window"))
        let c = capturer(app: code, shot: shot)
        var ctx = await c.captureFrontmost()
        XCTAssertNotNil(ctx.screenshot)
        c.configuration.excludedBundleIDs = ["com.microsoft.VSCode"]
        ctx = await c.captureFrontmost()
        XCTAssertEqual(ctx.screenshotSkipReason, "excluded_app")
    }

    func testNoPermissionsGivesNilItemsWithoutThrowing() async {
        let shot = FakeScreenshotter(outcome: ScreenshotOutcome(image: makeImage(), skipReason: nil, matchedWindow: nil, scope: "window"))
        let reader = FakeWindowReader(window: window)
        let c = capturer(app: code, window: reader, shot: shot, permissions: FakePermissions(screenCaptureGranted: false, accessibilityTrusted: false))
        let ctx = await c.captureFrontmost()
        XCTAssertEqual(ctx.app?.name, "Code", "アプリ名・バンドル ID は権限なしで取れる")
        XCTAssertNil(ctx.window, "アクセシビリティが無ければ AX を読まない")
        XCTAssertNil(ctx.url)
        XCTAssertNil(ctx.screenshot)
        XCTAssertEqual(ctx.screenshotSkipReason, "permission_denied")
        XCTAssertEqual(shot.calls.current, 0, "権限が無いと ScreenCaptureKit に触らない（ダイアログを出さない）")
    }

    func testNoFrontmostApp() async {
        let c = capturer(app: nil, permissions: FakePermissions(screenCaptureGranted: false, accessibilityTrusted: true))
        let ctx = await c.captureFrontmost()
        XCTAssertNil(ctx.app)
        XCTAssertNil(ctx.window)
        XCTAssertEqual(ctx.screenshotSkipReason, "permission_denied")
    }

    func testURLOnlyForBrowsers() async {
        let url = FakeURLProvider(url: "https://example.com")
        let ctx = await capturer(app: code, url: url).captureFrontmost()
        XCTAssertNil(ctx.url)
        XCTAssertEqual(url.calls.current, 0, "ブラウザ以外では Apple Event を送らない")

        let off = FakeURLProvider(url: "https://example.com")
        let ctx2 = await capturer(app: safari, url: off, config: CaptureConfiguration(capturesURL: false, automationConsent: .onlyIfAlreadyGranted)).captureFrontmost()
        XCTAssertNil(ctx2.url)
        XCTAssertEqual(off.calls.current, 0)
    }

    func testURLTimeoutDoesNotDelayCapture() async {
        let slowURL = FakeURLProvider(url: "https://late.example", delay: 2.0)
        let shot = FakeScreenshotter(outcome: ScreenshotOutcome(image: makeImage(), skipReason: nil, matchedWindow: nil, scope: "window"))
        let c = capturer(app: safari, window: FakeWindowReader(window: window), url: slowURL, shot: shot)
        let t0 = Date()
        let (ctx, timings) = await c.captureWithTimings()
        let elapsed = Date().timeIntervalSince(t0)
        XCTAssertNil(ctx.url, "300ms を超えた URL は諦める")
        XCTAssertTrue(timings.urlTimedOut)
        XCTAssertNotNil(ctx.screenshot)
        XCTAssertEqual(ctx.window, window)
        XCTAssertLessThan(elapsed, 1.0, "URL 待ちで全体が遅れない（実測 \(elapsed)s）")
    }

    func testOverallTimeoutAbandonsHungProviders() async {
        let hungWindow = FakeWindowReader(window: window, delay: 3.0)
        let hungShot = FakeScreenshotter(outcome: ScreenshotOutcome(image: makeImage(), skipReason: nil, matchedWindow: nil, scope: "window"), delay: 3.0)
        let c = capturer(app: code, window: hungWindow, shot: hungShot,
                         config: CaptureConfiguration(overallTimeout: 0.4, automationConsent: .onlyIfAlreadyGranted))
        let t0 = Date()
        let (ctx, timings) = await c.captureWithTimings()
        let elapsed = Date().timeIntervalSince(t0)
        XCTAssertLessThan(elapsed, 1.0, "全体の期限 0.4s で戻る（実測 \(elapsed)s）")
        XCTAssertNil(ctx.window)
        XCTAssertTrue(timings.windowTimedOut)
        XCTAssertNil(ctx.screenshot)
        XCTAssertEqual(ctx.screenshotSkipReason, "timeout")
        XCTAssertEqual(ctx.app?.name, "Code")
    }

    func testScreenshotFailureAlwaysHasReason() async {
        let shot = FakeScreenshotter(outcome: ScreenshotOutcome(image: nil, skipReason: nil, matchedWindow: nil, scope: nil))
        let ctx = await capturer(app: code, shot: shot).captureFrontmost()
        XCTAssertNil(ctx.screenshot)
        XCTAssertEqual(ctx.screenshotSkipReason, "capture_failed")
    }

    func testMatchedWindowFillsMissingAXInfo() async {
        let matched = WindowInfo(title: "zsh — 80×24", frame: CGRect(x: 0, y: 0, width: 640, height: 480))
        let shot = FakeScreenshotter(outcome: ScreenshotOutcome(image: makeImage(), skipReason: nil, matchedWindow: matched, scope: "window"))
        // AX 権限なし → SCWindow のタイトルで補う
        let ctx = await capturer(app: code, shot: shot, permissions: FakePermissions(screenCaptureGranted: true, accessibilityTrusted: false)).captureFrontmost()
        XCTAssertEqual(ctx.window, matched)

        // AX はあるがタイトルが空 → タイトルだけ補う
        let axNoTitle = WindowInfo(title: nil, frame: CGRect(x: 1, y: 2, width: 3, height: 4))
        let ctx2 = await capturer(app: code, window: FakeWindowReader(window: axNoTitle), shot: shot).captureFrontmost()
        XCTAssertEqual(ctx2.window?.title, "zsh — 80×24")
        XCTAssertEqual(ctx2.window?.frame, axNoTitle.frame)
    }

    func testDeadlineRace() async {
        let fast = await Deadline.race(timeout: 1) { 42 }
        XCTAssertEqual(fast.value, 42)
        let t0 = Date()
        let slow = await Deadline.race(timeout: 0.1) { () -> Int in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            return 1
        }
        XCTAssertNil(slow.value)
        XCTAssertLessThan(Date().timeIntervalSince(t0), 1.0)
        let zero = await Deadline.race(timeout: 0) { 1 }
        XCTAssertNil(zero.value)
        XCTAssertEqual(Deadline.remaining(until: 10, now: 12), 0)
        XCTAssertEqual(Deadline.remaining(until: 10, now: 9.5), 0.5)
    }

    /// 実環境の既定構成で、throw せず・落ちず・期限内に戻ること。
    /// 画面収録の権限がこのプロセスにある場合は、利用者の画面を撮らないようスクショを切る（ダイアログも出さない）。
    func testRealCapturerDoesNotThrowWithoutPermissions() async {
        let screenGranted = CGPreflightScreenCaptureAccess()
        let config = CaptureConfiguration(capturesScreenshot: !screenGranted ? true : false, automationConsent: .onlyIfAlreadyGranted)
        let c = FrontmostContextCapturer(configuration: config)
        let t0 = Date()
        let ctx = await c.captureFrontmost()
        XCTAssertLessThan(Date().timeIntervalSince(t0), 2.5)
        XCTAssertNil(ctx.screenshot)
        XCTAssertEqual(ctx.screenshotSkipReason, screenGranted ? "disabled" : "permission_denied")
        if !AXIsProcessTrusted() {
            XCTAssertNil(ctx.window, "アクセシビリティが無ければウインドウは nil")
        }
    }
}
