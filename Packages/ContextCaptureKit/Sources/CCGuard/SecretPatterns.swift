import Foundation

/// 秘密情報の検出パターン 1 種。
///
/// - `.value`: 秘密そのものの形（API キーなど）に一致させる。一致範囲（名前付きグループ `v` があればその範囲）を秘密とみなす。
/// - `.label`: 「パスワード」「Secret access key」のような**見出し**に一致させる。秘密は見出しの右（`:` の後）か
///   すぐ下の行にあるので、`SecretDetector` がそちらを探して値の位置を秘密とみなす。値が伏せ字（●●●）や空なら検出しない。
public struct SecretPattern: Sendable {
    public enum Mode: Sendable, Equatable {
        case value
        case label
        /// 複数行のブロックの見出し（PEM の `-----BEGIN … PRIVATE KEY-----`）。`SecretDetector` が対応する END 行まで
        /// （END が画面外なら、縦に連続する base64 らしい行の塊の終わりまで）を 1 件の秘密として覆う。
        case blockStart
    }

    /// `SecretFinding.kind` に入る名前（PoC `exp05_baselines.py` の `SECRET_PATTERNS` のキーを踏襲）。
    public let kind: String
    public let mode: Mode
    public let regex: NSRegularExpression

    public init(kind: String, mode: Mode, pattern: String) {
        self.kind = kind
        self.mode = mode
        // パターンは定数なので失敗はプログラムの誤り。
        self.regex = try! NSRegularExpression(pattern: pattern)
    }
}

extension SecretPattern {
    /// 既定のパターン集合。**評価順に意味がある**（同じ行の同じ範囲は先に一致したものが取る）。
    ///
    /// PoC（`poc/scripts/exp05_baselines.py`）の 8 種からの調整と理由:
    /// - `sk-` / `sk_` 系を大文字小文字無視にした。Vision OCR（言語補正なし）が s07 の `sk-proj-…` を `SK-proj-…`、
    ///   `sk_live_…` を `SK_Live_…` と読んだため、PoC の case-sensitive なパターンではその 2 行を取り逃がしていた
    ///   （PoC は同じ画面の `sk-ant-…` 行で openai_key が当たっていたので画面単位では見逃しに見えなかった）。
    /// - `openai_key` は `sk-ant-` を除外した（anthropic_key と同じ行を奪い合わないように）。
    /// - `dsn_password` は `:` の後の空白を許した（OCR が `mach: Pg-…` と空白を挟んだ）。値（パスワード部）だけを秘密範囲にする。
    /// - `aws_secret_label` / `password_field` は見出しパターンにした（`.label`）。PoC は見出しの行だけを当てていたため、
    ///   マスクすると見出しが消えて値（すぐ下の行）が残っていた。値の行を探し、値が伏せ字（●●●）なら検出しない。
    ///   `1Password` のような製品名に当てないよう、見出しの直前が英数字なら見出しとみなさない（s13 のサイドバー）。
    ///   見出しが文中に現れるだけの行（例: s08 の「the secret access key can be viewed…」）は、`:` が続かず見出しだけの行でもないので当てない。
    /// - `github_token` に fine-grained PAT（`github_pat_`）を足した。
    /// - 追加: `slack_token`、`google_api_key`、`private_key`（PEM の見出し）、`secret_assignment`（`FOO_SECRET=…` / `api_key: …` の
    ///   形の代入で、値が 16 文字以上かつ英字と数字を両方含むもの）。.env や設定ファイルの未知の形式のキーを拾うため。
    ///   値の条件で `max_tokens: 4096` のような設定値は当たらない。
    /// - 値パターンは「キーらしい文字が規定長続く」ことで当て、**秘密範囲は次の空白まで伸ばす**（末尾の `\S*`）。
    ///   OCR が値の途中に記号を混ぜたり、値に想定外の文字（`!` など）が含まれたりしたときに、残りが塗り残されないように
    ///   するため（マスク漏れ対策）。開始側の条件は変えないので誤検知は増えない（例: `accessToken = getToken(cfg.k1)` は
    ///   `getToken` が 16 文字に満たず当たらない）。
    /// - `private_key` は見出し行だけでなく鍵本体までを覆う（`.blockStart`）。前後の `-----` は条件にしない
    ///   （Vision が `-----BEGIN` を `-BEGIN`、`-----END` を `---END` と読んで本数が揃わないため。描画した PEM で確認）。
    public static let defaults: [SecretPattern] = [
        SecretPattern(kind: "anthropic_key", mode: .value, pattern: #"(?i)sk-ant-[A-Za-z0-9_\-]{20,}\S*"#),
        SecretPattern(kind: "openai_key", mode: .value, pattern: #"(?i)sk-(?!ant-)(?:proj-)?[A-Za-z0-9_\-]{20,}\S*"#),
        SecretPattern(kind: "stripe_key", mode: .value, pattern: #"(?i)[sr]k_(?:live|test)_[A-Za-z0-9]{16,}\S*"#),
        SecretPattern(kind: "aws_access_key", mode: .value, pattern: #"(?<![A-Z0-9])(?:AKIA|ASIA)[0-9A-Z]{16}(?![A-Z0-9])"#),
        SecretPattern(kind: "github_token", mode: .value, pattern: #"(?i)(?:gh[pousr]_[A-Za-z0-9]{30,}|github_pat_[A-Za-z0-9_]{40,})\S*"#),
        SecretPattern(kind: "slack_token", mode: .value, pattern: #"xox[abprs]-[A-Za-z0-9\-]{10,}\S*"#),
        SecretPattern(kind: "google_api_key", mode: .value, pattern: #"AIza[0-9A-Za-z_\-]{35}\S*"#),
        SecretPattern(kind: "private_key", mode: .blockStart, pattern: #"BEGIN [A-Z ]*PRIVATE KEY"#),
        SecretPattern(kind: "dsn_password", mode: .value, pattern: #"[A-Za-z][A-Za-z0-9+.\-]*://[^:\s/@]+:\s?(?<v>[^@\s]+)@"#),
        SecretPattern(
            kind: "secret_assignment", mode: .value,
            pattern: #"(?i)\b[A-Z0-9_]*(?:SECRET|TOKEN|API_?KEY|ACCESS_?KEY|PRIVATE_?KEY)[A-Z0-9_]*\s*[=:：]\s*["']?(?<v>(?=[A-Za-z0-9/+_\-.]*[0-9])(?=[A-Za-z0-9/+_\-.]*[A-Za-z])[A-Za-z0-9/+_\-.]{16,}\S*)"#
        ),
        SecretPattern(kind: "aws_secret_label", mode: .label, pattern: #"(?i)(?:aws[ _]?)?secret[ _]?access[ _]?key(?:[ _]?id)?"#),
        SecretPattern(
            kind: "password_field", mode: .label,
            pattern: #"(?i)(?<![A-Za-z0-9])(?:password|passwd|passphrase|passcode|パスワード|暗証番号)"#
        ),
    ]
}
