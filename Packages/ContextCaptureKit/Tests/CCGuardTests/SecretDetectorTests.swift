import CCCore
import CoreGraphics
import XCTest
@testable import CCGuard

/// Vision を通さない正規表現と見出し・値の対応のテスト（座標は左上原点の正規化値）。
final class SecretDetectorTests: XCTestCase {
    let detector = SecretDetector()

    private func line(_ text: String, y: CGFloat, x: CGFloat = 0.1, w: CGFloat = 0.3, h: CGFloat = 0.02) -> OCRLine {
        OCRLine(text: text, bbox: CGRect(x: x, y: y, width: w, height: h))
    }

    func testMaskedPasswordBelowLabelIsNotDetected() {
        for masked in ["●●●●●●●●●●", "••••••••", "********", "・・・・・・"] {
            let found = detector.detect(lines: [line("パスワード", y: 0.2), line(masked, y: 0.222)])
            XCTAssertEqual(found, [], masked)
        }
    }

    func testVisiblePasswordBelowLabelIsDetectedAtValue() {
        let found = detector.detect(lines: [line("Password", y: 0.2), line("hunter2-Correct", y: 0.222)])
        XCTAssertEqual(found.map(\.kind), ["password_field"])
        XCTAssertEqual(found.first?.bbox.minY ?? 0, 0.222, accuracy: 1e-6)
    }

    func testPasswordOnSameLineAfterDelimiter() {
        let found = detector.detect(lines: [line("DB_PASSWORD=s3cr3t-pass", y: 0.1)])
        XCTAssertEqual(found.map(\.kind), ["password_field"])
        let empty = detector.detect(lines: [line("Password:", y: 0.1)])
        XCTAssertEqual(empty, [])
        let maskedInline = detector.detect(lines: [line("パスワード：●●●●●●●●", y: 0.1)])
        XCTAssertEqual(maskedInline, [])
    }

    func testPasswordMentionInSentenceIsIgnored() {
        let lines = [
            line("Forgot your password?", y: 0.1),
            line("Enter your password to continue", y: 0.2),
            line("パスワードを忘れた場合はこちら", y: 0.3),
            line("Please reset the password used by the deploy pipeline every 90 days", y: 0.4),
        ]
        XCTAssertEqual(detector.detect(lines: lines), [])
    }

    func testLabelWithoutValueBelowIsIgnored() {
        // 値の行が遠い・横にずれている。
        let found = detector.detect(lines: [
            line("Secret access key", y: 0.2),
            line("wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", y: 0.5),
            line("wJalrXUtnFEMI/K7MDENG/bPxRfiCYEXAMPLEKEY", y: 0.222, x: 0.7),
        ])
        XCTAssertEqual(found, [])
    }

    func testValuePatternsAndCaseInsensitivePrefixes() {
        let cases: [(String, String)] = [
            ("OPENAI_API_KEY=SK-proj-FAKEa1B2c3D4e5F6g7H8i9J0kLmNo", "openai_key"),
            ("sk-ant-api03-FAKExYz987654321AbCdEf", "anthropic_key"),
            ("STRIPE=SK_Live_FAKE51Hc2kLmN0pQrSt", "stripe_key"),
            ("AKIAFAKE7Q3EXAMPLE2X", "aws_access_key"),
            ("token ghp_FAKE0123456789abcdefghijABCDEFGHIJ", "github_token"),
            ("xoxb-0000000000-FAKEFAKEFAKE", "slack_token"),
            ("key=AIzaFAKE0123456789abcdefghijklmnopqrstu", "google_api_key"),
            ("-----BEGIN OPENSSH PRIVATE KEY-----", "private_key"),
            ("postgres://mach: Pg-Dev-Pass-2026!@localhost:5432/mach", "dsn_password"),
            ("MY_SERVICE_SECRET=Zx81kd02mfLq93nVb7", "secret_assignment"),
        ]
        for (text, kind) in cases {
            XCTAssertEqual(detector.detect(lines: [line(text, y: 0.1)]).map(\.kind), [kind], text)
        }
    }

    func testNonSecretsAreIgnored() {
        let texts = [
            "HERMES_ENDPOINT=http://127.0.0.1:8787",
            "max_tokens: 4096",
            "const timeout: number = cfg.timeout ?? 30",
            "commit 3f1c2a9d8e7b6a5f4e3d2c1b0a9f8e7d6c5b4a39",
            "https://github.com/opendots/opendots/issues/128",
            "TOKEN_COUNT=abcdefghijklmnopqrstuvwxyz",
        ]
        for t in texts {
            XCTAssertEqual(detector.detect(lines: [line(t, y: 0.1)]), [], t)
        }
    }

    func testSameRangeIsNotReportedTwice() {
        // STRIPE_SECRET_KEY は stripe_key と secret_assignment の両方に当たるが 1 件にする。
        let found = detector.detect(lines: [line("STRIPE_SECRET_KEY=sk_live_FAKE51Hc2kLmN0pQrStUv", y: 0.1)])
        XCTAssertEqual(found.map(\.kind), ["stripe_key"])
    }

    func testVisionRectIsFlippedToTopLeft() {
        let r = VisionSecretScanner.topLeft(CGRect(x: 0.1, y: 0.7, width: 0.2, height: 0.1))
        XCTAssertEqual(r.minY, 0.2, accuracy: 1e-9)
        XCTAssertEqual(r.minX, 0.1, accuracy: 1e-9)
        XCTAssertEqual(r.height, 0.1, accuracy: 1e-9)
    }
}
