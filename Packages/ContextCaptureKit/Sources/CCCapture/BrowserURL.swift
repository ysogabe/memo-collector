import Foundation

/// URL を取りにいくブラウザ（F-04: Safari / Chrome / Arc / Edge）。
public enum SupportedBrowser: String, CaseIterable, Sendable {
    case safari
    case chrome
    case arc
    case edge

    /// このブラウザとして扱うバンドル ID（ベータ・開発版を含む）。
    public var bundleIDs: [String] {
        switch self {
        case .safari:
            return ["com.apple.Safari", "com.apple.SafariTechnologyPreview"]
        case .chrome:
            return ["com.google.Chrome", "com.google.Chrome.beta", "com.google.Chrome.dev", "com.google.Chrome.canary"]
        case .arc:
            return ["company.thebrowser.Browser"]
        case .edge:
            return ["com.microsoft.edgemac", "com.microsoft.edgemac.Beta", "com.microsoft.edgemac.Dev", "com.microsoft.edgemac.Canary"]
        }
    }

    /// バンドル ID から判定する。対象外なら nil。
    public static func from(bundleID: String?) -> SupportedBrowser? {
        guard let bundleID else { return nil }
        return allCases.first { $0.bundleIDs.contains(bundleID) }
    }

    /// 前面ウインドウのタブの URL を返す AppleScript。ウインドウが無ければ空文字列を返す。
    /// `with timeout` はスクリプト内の Apple Event の上限（秒単位）。呼び出し側はさらに短い期限で見捨てる。
    func appleScriptSource(bundleID: String, timeoutSeconds: Int = 1) -> String? {
        guard Self.isSafeBundleID(bundleID), bundleIDs.contains(bundleID) else { return nil }
        let tabExpr: String
        switch self {
        case .safari: tabExpr = "current tab of front window"
        case .chrome, .arc, .edge: tabExpr = "active tab of front window"
        }
        return """
        with timeout of \(max(1, timeoutSeconds)) seconds
            tell application id "\(bundleID)"
                if (count of windows) is 0 then return ""
                return URL of \(tabExpr)
            end tell
        end timeout
        """
    }

    /// AppleScript の文字列リテラルに埋め込んでよい文字だけか（英数字・`.`・`-`・`_`）。
    static func isSafeBundleID(_ s: String) -> Bool {
        !s.isEmpty && s.unicodeScalars.allSatisfy { c in
            CharacterSet.alphanumerics.contains(c) && c.isASCII || c == "." || c == "-" || c == "_"
        }
    }

    /// スクリプトの戻り値を URL 文字列として採るか（空・"missing value" は捨てる）。
    static func normalizeResult(_ s: String?) -> String? {
        guard let t = s?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty, t != "missing value" else { return nil }
        return t
    }
}

/// オートメーション（Apple Events）の許可をどう扱うか。
public enum AutomationConsentPolicy: String, Sendable {
    /// 未確認なら初回の取得時に OS が許可ダイアログを出す（アプリ本体の既定）。その回の URL は取れないことが多い。
    case askOnFirstUse
    /// 既に許可済みのときだけ取りにいく（ダイアログを出さない。テスト・診断用）。
    case onlyIfAlreadyGranted
}

/// 前面ブラウザの URL を取る。
protocol BrowserURLProviding: Sendable {
    /// 取れなければ nil。期限は呼び出し側が `Deadline.race` で付ける。
    func currentURL(bundleID: String) async -> String?
}

/// NSAppleScript による URL 取得。NSAppleScript はスレッド安全ではないので、専用の直列キュー 1 本でだけ実行する。
/// 前回のスクリプトがまだ戻っていない（ブラウザが固まっている）ときは待たずに nil を返す。
final class AppleScriptBrowserURLProvider: BrowserURLProviding, @unchecked Sendable {
    private let queue = DispatchQueue(label: "CCCapture.AppleScript", qos: .userInitiated)
    private let busy = Locked(false)
    /// queue 上でだけ触る。
    private var compiled: [String: NSAppleScript] = [:]
    let policy: AutomationConsentPolicy

    init(policy: AutomationConsentPolicy) {
        self.policy = policy
    }

    func currentURL(bundleID: String) async -> String? {
        guard let browser = SupportedBrowser.from(bundleID: bundleID),
              let source = browser.appleScriptSource(bundleID: bundleID)
        else { return nil }
        let acquired = busy.withLock { b -> Bool in
            if b { return false }
            b = true
            return true
        }
        guard acquired else { return nil }
        let policy = self.policy
        return await runBlocking(on: queue) { [self] in
            defer { busy.withLock { $0 = false } }
            let permission = AutomationPermission.check(bundleID: bundleID, askUserIfNeeded: false)
            switch (policy, permission) {
            case (_, .denied), (.onlyIfAlreadyGranted, .notDetermined), (.onlyIfAlreadyGranted, .notGranted):
                return nil
            default:
                break
            }
            return execute(source: source, key: bundleID)
        }
    }

    /// queue 上で呼ぶ。
    private func execute(source: String, key: String) -> String? {
        let script: NSAppleScript
        if let s = compiled[key] {
            script = s
        } else {
            guard let s = NSAppleScript(source: source) else { return nil }
            var compileError: NSDictionary?
            guard s.compileAndReturnError(&compileError) else { return nil }
            compiled[key] = s
            script = s
        }
        var error: NSDictionary?
        let result = script.executeAndReturnError(&error)
        guard error == nil else { return nil }
        return SupportedBrowser.normalizeResult(result.stringValue)
    }
}

/// オートメーション権限の確認（`AEDeterminePermissionToAutomateTarget`）。
enum AutomationPermission {
    /// `askUserIfNeeded` が true のときは OS のダイアログが出て、応答までブロックする。メインスレッドで呼ばないこと。
    static func check(bundleID: String, askUserIfNeeded: Bool) -> PermissionState {
        let target = NSAppleEventDescriptor(bundleIdentifier: bundleID)
        guard let desc = target.aeDesc else { return .notGranted }
        // 'core' / 'getd'（データの取得）で問い合わせる。
        let status = AEDeterminePermissionToAutomateTarget(desc, AEEventClass(kAECoreSuite), AEEventID(kAEGetData), askUserIfNeeded)
        return state(from: status)
    }

    /// OSStatus → 状態（純粋関数）。
    static func state(from status: OSStatus) -> PermissionState {
        switch status {
        case noErr: return .granted
        case OSStatus(errAEEventNotPermitted): return .denied  // -1743
        case OSStatus(errAEEventWouldRequireUserConsent): return .notDetermined  // -1744
        default: return .notGranted  // procNotFound(-600) など。対象が起動していない
        }
    }
}
