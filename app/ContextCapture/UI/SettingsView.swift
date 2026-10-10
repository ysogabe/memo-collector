import AppKit
import Observation
import SwiftUI
import UniformTypeIdentifiers

@Observable
@MainActor
final class SettingsViewModel {
    private let store: any SettingsStore
    private(set) var settings: AppSettings
    /// 固有名詞の辞書（1 行 1 語）の編集中の文字。
    var vocabularyText: String {
        didSet { update { $0.vocabulary = Self.parseVocabulary(vocabularyText) } }
    }
    private(set) var isRecordingHotkey = false
    private(set) var hotkeyMessage: String?
    /// 画像トークン数を変えたか（索引の作り直しを知らせる）。
    private(set) var tokenBudgetChanged = false
    private let initialTokenBudget: Int
    @ObservationIgnored private var monitor: Any?

    init(store: any SettingsStore) {
        self.store = store
        let s = store.load()
        settings = s
        vocabularyText = s.vocabulary.joined(separator: "\n")
        initialTokenBudget = s.imageTokenBudget
    }

    func update(_ mutate: (inout AppSettings) -> Void) {
        var s = settings
        mutate(&s)
        guard s != settings else { return }
        settings = s
        store.save(s)
        tokenBudgetChanged = s.imageTokenBudget != initialTokenBudget
    }

    static func parseVocabulary(_ text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    // MARK: ホットキーの記録

    func startRecordingHotkey() {
        guard !isRecordingHotkey else { return }
        isRecordingHotkey = true
        hotkeyMessage = nil
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            MainActor.assumeIsolated { self?.handleKey(event) }
            return nil
        }
    }

    func stopRecordingHotkey() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        isRecordingHotkey = false
    }

    private func handleKey(_ event: NSEvent) {
        let mods = event.modifierFlags.intersection([.command, .option, .control, .shift])
        if event.keyCode == 53 && mods.isEmpty {  // Esc
            stopRecordingHotkey()
            return
        }
        let isFunctionKey = (96...122).contains(event.keyCode)
        guard !mods.isEmpty || isFunctionKey else {
            hotkeyMessage = "⌥ や ⌃ などの修飾キーと一緒に押してください。"
            return
        }
        let combo = HotkeyCombo(keyCode: event.keyCode, modifiers: mods.rawValue)
        update { $0.hotkey = combo }
        hotkeyMessage = nil
        stopRecordingHotkey()
    }

    func resetHotkey() {
        update { $0.hotkey = .default }
    }

    // MARK: 除外アプリ

    func addExcludedApp() {
        let panel = NSOpenPanel()
        panel.title = "スクショを撮らないアプリを選ぶ"
        panel.prompt = "追加する"
        panel.allowedContentTypes = [.application]
        panel.allowsMultipleSelection = true
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK else { return }
        var apps = settings.excludedApps
        for url in panel.urls {
            guard let bundle = Bundle(url: url), let id = bundle.bundleIdentifier,
                  !apps.contains(where: { $0.bundleID == id }) else { continue }
            let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
            apps.append(ExcludedApp(bundleID: id, name: name))
        }
        update { $0.excludedApps = apps }
    }

    func removeExcludedApp(_ app: ExcludedApp) {
        update { $0.excludedApps.removeAll { $0.bundleID == app.bundleID } }
    }
}

/// 設定（F-02 のキー変更, F-05 の語彙, F-13, 保持期間, 検索の画像トークン数）。
struct SettingsView: View {
    @Bindable var vm: SettingsViewModel

    var body: some View {
        Form {
            hotkeySection
            excludedSection
            vocabularySection
            retentionSection
            searchSection
        }
        .formStyle(.grouped)
        .frame(width: 560)
        .frame(minHeight: 560)
        .onDisappear { vm.stopRecordingHotkey() }
    }

    private var hotkeySection: some View {
        Section {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text("録音のキー")
                    Text("押している間だけ録音し、離すと保存します。")
                        .font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                Text(vm.isRecordingHotkey ? "新しい組み合わせを押す…" : vm.settings.hotkey.display)
                    .font(.system(size: 13, weight: .medium, design: .rounded))
                    .padding(.horizontal, 10).padding(.vertical, 4)
                    .background(RoundedRectangle(cornerRadius: 6).fill(Color.primary.opacity(0.06)))
                    .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(vm.isRecordingHotkey ? Color.capture : Color.primary.opacity(0.15)))
                    .accessibilityLabel(vm.isRecordingHotkey ? "新しい組み合わせを待っています" : "現在のキー \(vm.settings.hotkey.display)")
                if vm.isRecordingHotkey {
                    Button("やめる") { vm.stopRecordingHotkey() }
                } else {
                    Button("キーを変更") { vm.startRecordingHotkey() }
                }
            }
            if vm.isRecordingHotkey || vm.hotkeyMessage != nil {
                Text(vm.hotkeyMessage ?? "使いたい組み合わせを押してください。Esc でやめます。")
                    .font(.caption)
                    .foregroundStyle(vm.hotkeyMessage == nil ? Color.secondary : Color.warnText)
            }
            if vm.settings.hotkey != .default && !vm.isRecordingHotkey {
                Button("\(HotkeyCombo.default.display) に戻す") { vm.resetHotkey() }
            }
        } header: {
            Text("キー")
        }
    }

    private var excludedSection: some View {
        Section {
            ForEach(vm.settings.excludedApps) { app in
                HStack(spacing: 8) {
                    AppIconView(bundleID: app.bundleID, size: 18)
                    Text(app.name)
                    Spacer()
                    Button {
                        vm.removeExcludedApp(app)
                    } label: {
                        Image(systemName: "minus.circle")
                    }
                    .buttonStyle(.borderless)
                    .accessibilityLabel("\(app.name) を除外から外す")
                }
            }
            Button("アプリを追加…") { vm.addExcludedApp() }
        } header: {
            Text("スクショを撮らないアプリ")
        } footer: {
            Text("ここにあるアプリが前面のときはスクショを撮りません。注釈とアプリ名は記録します。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var vocabularySection: some View {
        Section {
            TextEditor(text: $vm.vocabularyText)
                .font(.system(size: 13))
                .frame(height: 88)
                .scrollContentBackground(.hidden)
                .accessibilityLabel("固有名詞の辞書")
        } header: {
            Text("固有名詞の辞書")
        } footer: {
            Text("1 行に 1 語。製品名や社内用語など、聞き間違えやすい言葉を書いておくと文字起こしで優先します。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var retentionSection: some View {
        Section {
            Stepper(value: Binding(get: { vm.settings.audioRetentionDays },
                                   set: { v in vm.update { $0.audioRetentionDays = v } }),
                    in: AppSettings.audioRetentionRange) {
                LabeledContent("音声を残す日数", value: "\(vm.settings.audioRetentionDays) 日")
            }
            Picker("スクショを残す期間", selection: Binding(
                get: { vm.settings.screenshotRetentionDays == nil },
                set: { forever in vm.update { $0.screenshotRetentionDays = forever ? nil : 90 } }
            )) {
                Text("無期限").tag(true)
                Text("日数を決める").tag(false)
            }
            if let days = vm.settings.screenshotRetentionDays {
                Stepper(value: Binding(get: { days }, set: { v in vm.update { $0.screenshotRetentionDays = v } }),
                        in: AppSettings.screenshotRetentionRange, step: 30) {
                    LabeledContent("スクショを残す日数", value: "\(days) 日")
                }
            }
        } header: {
            Text("保持期間")
        } footer: {
            Text("期間を過ぎた音声は削除し、文字起こしは残します。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }

    private var searchSection: some View {
        Section {
            Picker("画像トークン数", selection: Binding(
                get: { vm.settings.imageTokenBudget },
                set: { v in vm.update { $0.imageTokenBudget = v } }
            )) {
                ForEach(AppSettings.imageTokenBudgetChoices, id: \.self) { n in
                    Text(n == 280 ? "\(n)（既定）" : "\(n)").tag(n)
                }
            }
            .pickerStyle(.segmented)
            if vm.tokenBudgetChanged {
                Label("検索の索引を作り直します。終わるまで、見た目での検索は古い索引で動きます。", systemImage: "arrow.triangle.2.circlepath")
                    .font(.caption)
                    .foregroundStyle(Color.warnText)
            }
        } header: {
            Text("検索")
        } footer: {
            Text("多いほどスクショの見た目で探すときの精度が上がり、1 件の索引づくりに時間がかかります（280 で約 1 秒、70 で約 0.2 秒）。変更すると検索の索引を作り直します。")
                .font(.caption).foregroundStyle(.secondary)
        }
    }
}
