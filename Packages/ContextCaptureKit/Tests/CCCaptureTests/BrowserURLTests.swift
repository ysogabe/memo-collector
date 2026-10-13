import XCTest
@testable import CCCapture

/// URL 取得のスクリプト生成とブラウザ判定。AppleScript は**実行しない**（オートメーションのダイアログを出さないため）。
final class BrowserURLTests: XCTestCase {
    func testBrowserDetection() {
        XCTAssertEqual(SupportedBrowser.from(bundleID: "com.apple.Safari"), .safari)
        XCTAssertEqual(SupportedBrowser.from(bundleID: "com.apple.SafariTechnologyPreview"), .safari)
        XCTAssertEqual(SupportedBrowser.from(bundleID: "com.google.Chrome"), .chrome)
        XCTAssertEqual(SupportedBrowser.from(bundleID: "com.google.Chrome.canary"), .chrome)
        XCTAssertEqual(SupportedBrowser.from(bundleID: "company.thebrowser.Browser"), .arc)
        XCTAssertEqual(SupportedBrowser.from(bundleID: "com.microsoft.edgemac"), .edge)
        XCTAssertNil(SupportedBrowser.from(bundleID: "org.mozilla.firefox"))
        XCTAssertNil(SupportedBrowser.from(bundleID: "com.microsoft.VSCode"))
        XCTAssertNil(SupportedBrowser.from(bundleID: nil))
    }

    func testSafariScript() throws {
        let s = try XCTUnwrap(SupportedBrowser.safari.appleScriptSource(bundleID: "com.apple.Safari"))
        XCTAssertTrue(s.contains("tell application id \"com.apple.Safari\""))
        XCTAssertTrue(s.contains("URL of current tab of front window"))
        XCTAssertTrue(s.contains("with timeout of 1 seconds"))
        XCTAssertTrue(s.contains("if (count of windows) is 0 then return \"\""))
        // コンパイルだけはできる構文か（実行はしない）。NSAppleScript の生成は Apple Event を送らない。
        XCTAssertNotNil(NSAppleScript(source: s))
    }

    func testChromiumScripts() throws {
        let cases: [(SupportedBrowser, String)] = [
            (.chrome, "com.google.Chrome"),
            (.arc, "company.thebrowser.Browser"),
            (.edge, "com.microsoft.edgemac"),
        ]
        for (b, id) in cases {
            let s = try XCTUnwrap(b.appleScriptSource(bundleID: id), "\(b)")
            XCTAssertTrue(s.contains("tell application id \"\(id)\""), "\(b)")
            XCTAssertTrue(s.contains("URL of active tab of front window"), "\(b)")
        }
    }

    func testScriptRejectsMismatchedOrUnsafeBundleIDs() {
        XCTAssertNil(SupportedBrowser.safari.appleScriptSource(bundleID: "com.google.Chrome"), "別ブラウザの ID は使わない")
        XCTAssertNil(SupportedBrowser.chrome.appleScriptSource(bundleID: "com.google.Chrome\" to do shell script \"x"))
        XCTAssertFalse(SupportedBrowser.isSafeBundleID("a\"b"))
        XCTAssertFalse(SupportedBrowser.isSafeBundleID(""))
        XCTAssertFalse(SupportedBrowser.isSafeBundleID("com.例え"))
        XCTAssertTrue(SupportedBrowser.isSafeBundleID("com.microsoft.edgemac.Beta"))
        XCTAssertTrue(SupportedBrowser.isSafeBundleID("a_b-c.1"))
    }

    func testResultNormalization() {
        XCTAssertEqual(SupportedBrowser.normalizeResult(" https://example.com/a?b=1 \n"), "https://example.com/a?b=1")
        XCTAssertNil(SupportedBrowser.normalizeResult(""))
        XCTAssertNil(SupportedBrowser.normalizeResult("missing value"))
        XCTAssertNil(SupportedBrowser.normalizeResult(nil))
    }

    func testAutomationStatusMapping() {
        XCTAssertEqual(AutomationPermission.state(from: noErr), .granted)
        XCTAssertEqual(AutomationPermission.state(from: -1743), .denied)
        XCTAssertEqual(AutomationPermission.state(from: -1744), .notDetermined)
        XCTAssertEqual(AutomationPermission.state(from: -600), .notGranted)
    }

    /// 対応外のアプリでは Apple Event を一切送らずに nil。
    func testProviderReturnsNilForNonBrowser() async {
        let p = AppleScriptBrowserURLProvider(policy: .onlyIfAlreadyGranted)
        let url = await p.currentURL(bundleID: "com.apple.Terminal")
        XCTAssertNil(url)
    }
}
