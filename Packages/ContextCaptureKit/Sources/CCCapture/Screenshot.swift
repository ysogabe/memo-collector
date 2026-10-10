import CCCore
import CoreGraphics
import Foundation
import ScreenCaptureKit

/// SCWindow 照合の入力（SCWindow + CGWindowList の z 順を混ぜたもの。テストではフェイクを並べる）。
public struct WindowCandidate: Sendable, Equatable {
    public var windowID: CGWindowID
    public var pid: pid_t
    public var title: String?
    /// CG グローバル座標（左上原点・ポイント）。
    public var frame: CGRect
    /// ウインドウレイヤ（通常ウインドウは 0）。
    public var layer: Int
    public var isOnScreen: Bool
    /// 前面からの順位（0 が最前面）。分からなければ nil（最後尾扱い）。
    public var zIndex: Int?

    public init(windowID: CGWindowID, pid: pid_t, title: String?, frame: CGRect, layer: Int = 0, isOnScreen: Bool = true, zIndex: Int? = nil) {
        self.windowID = windowID
        self.pid = pid
        self.title = title
        self.frame = frame
        self.layer = layer
        self.isOnScreen = isOnScreen
        self.zIndex = zIndex
    }
}

/// フォーカス中ウインドウ（AX の pid・frame・タイトル）に当たる SCWindow を選ぶ。
public enum WindowMatcher {
    /// frame の一致とみなす誤差（ポイント）。
    public static let frameTolerance: CGFloat = 2

    /// 優先順: (1) pid 一致 + frame 一致（同点はタイトル一致 → 前面順）、(2) pid 一致 + タイトル一致（前面順）、
    /// (3) pid の最前面の通常ウインドウ。どれも無ければ nil。
    public static func bestMatch(
        candidates: [WindowCandidate],
        pid: pid_t,
        axFrame: CGRect?,
        axTitle: String?
    ) -> WindowCandidate? {
        let pool = candidates.filter { c in
            c.pid == pid && c.layer == 0 && c.frame.width > 1 && c.frame.height > 1
        }
        guard !pool.isEmpty else { return nil }
        let title = axTitle.flatMap { $0.isEmpty ? nil : $0 }

        func byZ(_ a: WindowCandidate, _ b: WindowCandidate) -> Bool {
            if a.isOnScreen != b.isOnScreen { return a.isOnScreen }
            return (a.zIndex ?? Int.max) < (b.zIndex ?? Int.max)
        }

        if let axFrame {
            let framed = pool.filter { framesMatch($0.frame, axFrame) }
            if !framed.isEmpty {
                if let title, let t = framed.filter({ $0.title == title }).sorted(by: byZ).first { return t }
                return framed.sorted(by: byZ).first
            }
        }
        if let title, let t = pool.filter({ $0.title == title }).sorted(by: byZ).first {
            return t
        }
        return pool.filter(\.isOnScreen).sorted(by: byZ).first
    }

    static func framesMatch(_ a: CGRect, _ b: CGRect, tolerance: CGFloat = frameTolerance) -> Bool {
        abs(a.minX - b.minX) <= tolerance && abs(a.minY - b.minY) <= tolerance
            && abs(a.width - b.width) <= tolerance && abs(a.height - b.height) <= tolerance
    }

    /// 窓の中心を含むディスプレイ。無ければ nil（呼び出し側で主ディスプレイにする）。
    static func displayIndex(containing frame: CGRect?, displays: [CGRect]) -> Int? {
        guard let frame else { return nil }
        let center = CGPoint(x: frame.midX, y: frame.midY)
        return displays.firstIndex { $0.contains(center) }
    }
}

/// スクショの結果。
struct ScreenshotOutcome: @unchecked Sendable {
    // CGImage は不変なので複数スレッドから読んでよい。
    var image: CGImage?
    var skipReason: String?
    /// 照合できた SCWindow のタイトルと frame（AX が取れないときの補完に使う）。
    var matchedWindow: WindowInfo?
    /// "window" / "display"（診断用）。
    var scope: String?

    static func skipped(_ reason: String) -> ScreenshotOutcome {
        ScreenshotOutcome(image: nil, skipReason: reason, matchedWindow: nil, scope: nil)
    }
}

protocol ScreenshotTaking: Sendable {
    /// `window` は AX の結果を待つクロージャ（SCShareableContent の取得と並行に走らせるため）。
    /// 権限の確認は呼び出し側が済ませている前提。失敗しても throw しない。
    func capture(pid: pid_t?, window: @escaping @Sendable () async -> WindowInfo?) async -> ScreenshotOutcome
}

/// ScreenCaptureKit で 1 枚だけ撮る。**画面収録の権限が無いときに呼ぶとダイアログが出うる**ので、
/// 呼び出し側（FrontmostContextCapturer）が `CGPreflightScreenCaptureAccess()` で必ず先に確かめる。
struct SCKScreenshotTaker: ScreenshotTaking {
    /// 画面全体へのフォールバックで写さない自アプリ（HUD 等）のバンドル ID。
    var ownBundleID: String? = Bundle.main.bundleIdentifier

    func capture(pid: pid_t?, window: @escaping @Sendable () async -> WindowInfo?) async -> ScreenshotOutcome {
        async let contentResult: UncheckedBox<SCShareableContent?> = {
            UncheckedBox(try? await SCShareableContent.excludingDesktopWindows(true, onScreenWindowsOnly: true))
        }()
        let axWindow = await window()
        guard let content = await contentResult.value else {
            return .skipped(ScreenshotSkipReason.captureFailed)
        }

        var matched: SCWindow?
        if let pid {
            let z = Self.zOrder()
            let candidates = content.windows.map { w in
                WindowCandidate(
                    windowID: w.windowID,
                    pid: w.owningApplication?.processID ?? -1,
                    title: w.title,
                    frame: w.frame,
                    layer: w.windowLayer,
                    isOnScreen: w.isOnScreen,
                    zIndex: z[w.windowID]
                )
            }
            if let best = WindowMatcher.bestMatch(candidates: candidates, pid: pid, axFrame: axWindow?.frame, axTitle: axWindow?.title) {
                matched = content.windows.first { $0.windowID == best.windowID }
            }
        }

        if let w = matched, let image = await Self.captureWindow(w) {
            let info = WindowInfo(title: w.title.flatMap { $0.isEmpty ? nil : $0 }, frame: w.frame)
            return ScreenshotOutcome(image: image, skipReason: nil, matchedWindow: info, scope: "window")
        }
        // 画面全体へのフォールバック（窓のあるディスプレイ、無ければ主ディスプレイ）。
        let displays = content.displays
        let idx = WindowMatcher.displayIndex(containing: matched?.frame ?? axWindow?.frame, displays: displays.map(\.frame))
        let display = idx.map { displays[$0] }
            ?? displays.first { $0.displayID == CGMainDisplayID() }
            ?? displays.first
        guard let display else { return .skipped(ScreenshotSkipReason.captureFailed) }
        let own = content.applications.filter { app in ownBundleID != nil && app.bundleIdentifier == ownBundleID }
        if let image = await Self.captureDisplay(display, excluding: own) {
            let info = matched.map { WindowInfo(title: $0.title, frame: $0.frame) }
            return ScreenshotOutcome(image: image, skipReason: nil, matchedWindow: info, scope: "display")
        }
        return .skipped(ScreenshotSkipReason.captureFailed)
    }

    /// CGWindowList（前面から順）での順位。windowNumber・pid・layer は権限なしで読める。
    static func zOrder() -> [CGWindowID: Int] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID) as? [[String: Any]] else {
            return [:]
        }
        var result: [CGWindowID: Int] = [:]
        for (i, info) in list.enumerated() {
            if let n = info[kCGWindowNumber as String] as? Int {
                result[CGWindowID(n)] = i
            }
        }
        return result
    }

    /// 隠れていても窓そのものを撮る（desktopIndependentWindow）。Retina の実解像度。
    static func captureWindow(_ window: SCWindow) async -> CGImage? {
        let filter = SCContentFilter(desktopIndependentWindow: window)
        let config = SCStreamConfiguration()
        let rect = filter.contentRect.isEmpty ? window.frame : filter.contentRect
        let scale = CGFloat(max(1, filter.pointPixelScale))
        config.width = max(1, Int((rect.width * scale).rounded()))
        config.height = max(1, Int((rect.height * scale).rounded()))
        config.captureResolution = .best
        config.showsCursor = false
        config.ignoreShadowsSingleWindow = true
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }

    static func captureDisplay(_ display: SCDisplay, excluding apps: [SCRunningApplication]) async -> CGImage? {
        let filter = SCContentFilter(display: display, excludingApplications: apps, exceptingWindows: [])
        let config = SCStreamConfiguration()
        let scale = CGFloat(max(1, filter.pointPixelScale))
        config.width = max(1, Int((CGFloat(display.width) * scale).rounded()))
        config.height = max(1, Int((CGFloat(display.height) * scale).rounded()))
        config.captureResolution = .best
        config.showsCursor = false
        return try? await SCScreenshotManager.captureImage(contentFilter: filter, configuration: config)
    }
}
