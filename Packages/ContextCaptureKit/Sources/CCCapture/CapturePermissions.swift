import AVFoundation
import AppKit
import ApplicationServices
import CoreGraphics
import Foundation

/// キャプチャで使う権限（PRD §8.2）。
public enum CapturePermission: String, CaseIterable, Sendable {
    case microphone
    case screenRecording
    case accessibility
    /// ブラウザごとのオートメーション（URL 取得）。状態はバンドル ID ごとに `CapturePermissions.automationStatus(bundleID:)` で見る。
    case automation
}

/// 権限の状態。
public enum PermissionState: String, Sendable, Codable {
    case granted
    case denied
    /// まだ尋ねていない（マイク・オートメーションのみ判別できる）。
    case notDetermined
    /// 許可されていない（OS が「拒否」と「未確認」を区別して返さない画面収録・アクセシビリティ、または対象アプリが起動していない）。
    case notGranted
}

/// 権限の状態取得・要求・システム設定を開く。UI（オンボーディング）から使う。
///
/// - `status` / `automationStatus` は**ダイアログを出さない**。
/// - `request*` は**OS のダイアログを出す**。ユーザー操作（ボタン）を起点にだけ呼ぶこと。
/// - 画面収録は許可後にアプリの再起動が要る（`CGPreflightScreenCaptureAccess` の結果はプロセス内でキャッシュされる）。
public enum CapturePermissions {
    // MARK: 状態（ダイアログなし）

    public static func status(_ permission: CapturePermission) -> PermissionState {
        switch permission {
        case .microphone:
            return microphoneState(from: AVCaptureDevice.authorizationStatus(for: .audio))
        case .screenRecording:
            // `.denied` は返さない（返せない）。公開 API の `CGPreflightScreenCaptureAccess` は Bool だけで、
            // 「拒否した」と「まだ尋ねていない」を区別しない（TCC の状態を直接読むのは非公開 API なので使わない）。
            // 許可していなければ常に `.notGranted`。UI は「システム設定で許可 → アプリを再起動」を案内すること
            // （許可直後もこのプロセスでは false のまま。結果がプロセス内でキャッシュされるため）。
            return CGPreflightScreenCaptureAccess() ? .granted : .notGranted
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .notGranted
        case .automation:
            // ブラウザごとに違う。起動中の対応ブラウザのうち 1 つでも許可済みなら granted。
            let states = runningBrowserBundleIDs().map { automationStatus(bundleID: $0) }
            if states.contains(.granted) { return .granted }
            if states.contains(.denied) { return .denied }
            if states.contains(.notDetermined) { return .notDetermined }
            return .notGranted
        }
    }

    /// ブラウザ 1 つのオートメーション状態（ダイアログなし）。ブラウザが起動していなければ `.notGranted`。
    public static func automationStatus(bundleID: String) -> PermissionState {
        AutomationPermission.check(bundleID: bundleID, askUserIfNeeded: false)
    }

    /// 起動中の対応ブラウザのバンドル ID。
    public static func runningBrowserBundleIDs() -> [String] {
        let all = Set(SupportedBrowser.allCases.flatMap(\.bundleIDs))
        return NSWorkspace.shared.runningApplications.compactMap(\.bundleIdentifier).filter { all.contains($0) }
    }

    // MARK: 要求（ダイアログが出る）

    /// マイク権限を要求する（未確認のときだけダイアログ）。結果が許可なら true。
    public static func requestMicrophone() async -> Bool {
        await AVCaptureDevice.requestAccess(for: .audio)
    }

    /// 画面収録の許可を要求する（初回はダイアログ、以降はシステム設定へ誘導される）。反映にはアプリの再起動が要る。
    @discardableResult
    public static func requestScreenRecording() -> Bool {
        CGRequestScreenCaptureAccess()
    }

    /// アクセシビリティの許可を求めるダイアログ（システム設定へ誘導）を出す。現在の状態を返す。
    @discardableResult
    public static func requestAccessibility() -> Bool {
        let key = "AXTrustedCheckOptionPrompt" as CFString  // kAXTrustedCheckOptionPrompt
        return AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
    }

    /// ブラウザ 1 つのオートメーション許可を要求する（未確認ならダイアログ。ブラウザが起動している必要がある）。
    public static func requestAutomation(bundleID: String) async -> PermissionState {
        await withCheckedContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                cont.resume(returning: AutomationPermission.check(bundleID: bundleID, askUserIfNeeded: true))
            }
        }
    }

    // MARK: システム設定

    /// システム設定の該当ペインを開く URL。
    public static func settingsURL(for permission: CapturePermission) -> URL {
        let anchor: String
        switch permission {
        case .microphone: anchor = "Privacy_Microphone"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .automation: anchor = "Privacy_Automation"
        }
        return URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)")!
    }

    /// システム設定の該当ペインを開く。
    @MainActor
    @discardableResult
    public static func openSettings(for permission: CapturePermission) -> Bool {
        NSWorkspace.shared.open(settingsURL(for: permission))
    }

    // MARK: 純粋関数（テスト用）

    static func microphoneState(from status: AVAuthorizationStatus) -> PermissionState {
        switch status {
        case .authorized: return .granted
        case .denied, .restricted: return .denied
        case .notDetermined: return .notDetermined
        @unknown default: return .notGranted
        }
    }
}

/// キャプチャ中に参照する権限（テストで差し替える）。
protocol CapturePermissionChecking: Sendable {
    var screenCaptureGranted: Bool { get }
    var accessibilityTrusted: Bool { get }
}

struct SystemCapturePermissionChecker: CapturePermissionChecking {
    var screenCaptureGranted: Bool { CGPreflightScreenCaptureAccess() }
    var accessibilityTrusted: Bool { AXIsProcessTrusted() }
}
