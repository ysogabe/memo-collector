import AppKit
import Foundation

/// アプリの設定（F-02 のキー、F-05 の語彙、F-13 の除外、保持期間、検索の画像トークン数）。
struct AppSettings: Codable, Equatable, Sendable {
    var hotkey: HotkeyCombo = .default
    /// 前面にあるときスクショを撮らないアプリ（F-13）。
    var excludedApps: [ExcludedApp] = ExcludedApp.defaults
    /// 固有名詞の辞書（STT のカスタム語彙）。1 要素 1 語。
    var vocabulary: [String] = []
    /// 音声を残す日数（既定 7）。過ぎたら音声だけ消し、文字起こしは残す。
    var audioRetentionDays: Int = 7
    /// スクショを残す日数。nil は無期限。
    var screenshotRetentionDays: Int? = nil
    /// 検索の索引に使う画像トークン数（70 / 140 / 280）。変えたら索引の作り直しが要る。
    var imageTokenBudget: Int = 280
    /// オンボーディングを最後まで終えたか。
    var onboardingCompleted: Bool = false

    static let imageTokenBudgetChoices = [70, 140, 280]
    static let audioRetentionRange = 1...90
    static let screenshotRetentionRange = 1...3650

    init() {}

    // 項目を足しても古い保存値を読めるよう、欠けたキーは既定値で埋める。
    init(from decoder: Decoder) throws {
        let d = AppSettings()
        let c = try decoder.container(keyedBy: CodingKeys.self)
        hotkey = try c.decodeIfPresent(HotkeyCombo.self, forKey: .hotkey) ?? d.hotkey
        excludedApps = try c.decodeIfPresent([ExcludedApp].self, forKey: .excludedApps) ?? d.excludedApps
        vocabulary = try c.decodeIfPresent([String].self, forKey: .vocabulary) ?? d.vocabulary
        audioRetentionDays = try c.decodeIfPresent(Int.self, forKey: .audioRetentionDays) ?? d.audioRetentionDays
        screenshotRetentionDays = try c.decodeIfPresent(Int.self, forKey: .screenshotRetentionDays)
        imageTokenBudget = try c.decodeIfPresent(Int.self, forKey: .imageTokenBudget) ?? d.imageTokenBudget
        onboardingCompleted = try c.decodeIfPresent(Bool.self, forKey: .onboardingCompleted) ?? d.onboardingCompleted
    }
}

/// 除外アプリ 1 件。
struct ExcludedApp: Codable, Equatable, Hashable, Sendable, Identifiable {
    var bundleID: String
    var name: String
    var id: String { bundleID }

    static let defaults = [
        ExcludedApp(bundleID: "com.1password.1password", name: "1Password"),
        ExcludedApp(bundleID: "com.apple.keychainaccess", name: "キーチェーンアクセス"),
    ]
}

/// グローバルホットキーの組み合わせ。記録して保存するだけで、登録は CCCapture（wiring）が行う。
struct HotkeyCombo: Codable, Equatable, Hashable, Sendable {
    /// 仮想キーコード（kVK_*）。
    var keyCode: UInt16
    /// `NSEvent.ModifierFlags` の rawValue（command / option / control / shift だけ）。
    var modifiers: UInt

    /// 既定は ⌥Space。
    static let `default` = HotkeyCombo(keyCode: 49, modifiers: NSEvent.ModifierFlags.option.rawValue)

    var modifierFlags: NSEvent.ModifierFlags { NSEvent.ModifierFlags(rawValue: modifiers) }

    /// 表示用（例: "⌥Space"、"⌃⇧K"）。
    var display: String {
        var s = ""
        let f = modifierFlags
        if f.contains(.control) { s += "⌃" }
        if f.contains(.option) { s += "⌥" }
        if f.contains(.shift) { s += "⇧" }
        if f.contains(.command) { s += "⌘" }
        return s + KeyCodeNames.name(for: keyCode)
    }
}

/// 仮想キーコード → 表示名。
enum KeyCodeNames {
    static func name(for keyCode: UInt16) -> String {
        if let special = special[keyCode] { return special }
        if let letter = letters[keyCode] { return letter }
        return "Key\(keyCode)"
    }

    private static let special: [UInt16: String] = [
        49: "Space", 36: "↩", 48: "⇥", 51: "⌫", 53: "⎋", 117: "⌦",
        123: "←", 124: "→", 125: "↓", 126: "↑",
        122: "F1", 120: "F2", 99: "F3", 118: "F4", 96: "F5", 97: "F6",
        98: "F7", 100: "F8", 101: "F9", 109: "F10", 103: "F11", 111: "F12",
    ]

    private static let letters: [UInt16: String] = [
        0: "A", 11: "B", 8: "C", 2: "D", 14: "E", 3: "F", 5: "G", 4: "H", 34: "I", 38: "J",
        40: "K", 37: "L", 46: "M", 45: "N", 31: "O", 35: "P", 12: "Q", 15: "R", 1: "S", 17: "T",
        32: "U", 9: "V", 13: "W", 7: "X", 16: "Y", 6: "Z",
        29: "0", 18: "1", 19: "2", 20: "3", 21: "4", 23: "5", 22: "6", 26: "7", 28: "8", 25: "9",
        50: "`", 27: "-", 24: "=", 33: "[", 30: "]", 42: "\\", 41: ";", 39: "'", 43: ",", 47: ".", 44: "/",
    ]
}

/// UserDefaults に JSON 1 本で保存する実装（本番用）。
final class UserDefaultsSettingsStore: SettingsStore, @unchecked Sendable {
    // UserDefaults はスレッドセーフ。
    private let defaults: UserDefaults
    private let key: String

    init(defaults: UserDefaults = .standard, key: String = "ContextCapture.settings.v1") {
        self.defaults = defaults
        self.key = key
    }

    func load() -> AppSettings {
        guard let data = defaults.data(forKey: key),
              let settings = try? JSONDecoder().decode(AppSettings.self, from: data)
        else { return AppSettings() }
        return settings
    }

    func save(_ settings: AppSettings) {
        guard let data = try? JSONEncoder().encode(settings) else { return }
        defaults.set(data, forKey: key)
        DispatchQueue.main.async {
            NotificationCenter.default.post(name: SettingsChange.didChangeNotification, object: nil)
        }
    }
}
