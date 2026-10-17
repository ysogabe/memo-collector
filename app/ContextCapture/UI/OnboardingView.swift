import Observation
import SwiftUI

@Observable
@MainActor
final class OnboardingViewModel {
    enum Step: Int, CaseIterable {
        case welcome, permissions, models, ready
    }

    enum ModelState: Equatable {
        case notStarted
        case running(ModelPreparationProgress)
        case finished
        case failed(String)
    }

    private let permissions: any PermissionsProviding
    private let models: any ModelPreparationProviding
    private let onFinish: @MainActor () -> Void

    var step: Step = .welcome
    private(set) var states: [PermissionKind: PermissionState] = [:]
    var modelState: ModelState = .notStarted
    @ObservationIgnored private var prepareTask: Task<Void, Never>?

    init(permissions: any PermissionsProviding, models: any ModelPreparationProviding,
         onFinish: @escaping @MainActor () -> Void) {
        self.permissions = permissions
        self.models = models
        self.onFinish = onFinish
    }

    func load() async {
        await refreshPermissions()
        if await models.isPrepared() { modelState = .finished }
    }

    func refreshPermissions() async {
        for k in PermissionKind.allCases {
            states[k] = await permissions.state(of: k)
        }
    }

    func openSettings(_ kind: PermissionKind) async {
        if states[kind] == .notDetermined && kind != .automation {
            // まだ一度も聞いていなければ、まずシステムのダイアログを出す。
            await permissions.request(kind)
        } else {
            await permissions.openSystemSettings(for: kind)
        }
        await refreshPermissions()
    }

    func startModelPreparation() {
        prepareTask?.cancel()
        modelState = .running(ModelPreparationProgress(phase: .downloading, fractionCompleted: 0, completedBytes: 0, totalBytes: 0))
        let stream = models.prepare()
        prepareTask = Task { [weak self] in
            do {
                for try await p in stream {
                    guard let self else { return }
                    self.modelState = p.phase == .finished ? .finished : .running(p)
                }
            } catch let error as InsufficientDiskSpace {
                self?.modelState = .failed(error.errorDescription ?? "空き容量が足りません。")
            } catch {
                self?.modelState = .failed("準備できませんでした。ネットワークにつながっているか確かめて、もう一度始めてください。")
            }
        }
    }

    var canGoNext: Bool {
        switch step {
        case .welcome: return true
        // マイクが無いと使えない（PRD §8.2）。他は許可しなくても進める。
        case .permissions: return states[.microphone] == .granted
        case .models: return modelState == .finished
        case .ready: return true
        }
    }

    func next() {
        if step == .ready {
            onFinish()
            return
        }
        step = Step(rawValue: step.rawValue + 1) ?? .ready
    }

    func back() {
        step = Step(rawValue: max(0, step.rawValue - 1)) ?? .welcome
    }
}

/// 初回起動時の説明（権限 4 種とモデルの準備）。
struct OnboardingView: View {
    @Bindable var vm: OnboardingViewModel
    let hotkey: String
    /// ホットキーを登録できないときの説明（本番の配線から。スナップショットでは nil）。
    var hotKeyIssue: () -> HotKeyIssue? = { nil }

    var body: some View {
        VStack(spacing: 0) {
            Group {
                switch vm.step {
                case .welcome: welcome
                case .permissions: permissions
                case .models: models
                case .ready: ready
                }
            }
            .padding(.horizontal, 32)
            .padding(.top, 28)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
        }
        .frame(width: 640, height: 600)
        .task { await vm.load() }
    }

    // MARK: ようこそ

    private var welcome: some View {
        VStack(alignment: .leading, spacing: 18) {
            Image(systemName: "camera.viewfinder")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color.capture)
            Text("見ている画面に、声でメモを貼る。")
                .font(.system(size: 24, weight: .bold))
            Text("\(hotkey) を押して、ひと言話して、離すだけ。いま開いているウインドウのスクショ、アプリ名、URL、あなたの一言が 1 件の記録になって Mac の中に残ります。")
                .font(.system(size: 14))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                stepRow("1", "押す", "そのときの画面とアプリ情報を記録し、録音を始めます。")
                stepRow("2", "話す", "思ったことをそのまま。「あとで」「これ」で通じます。")
                stepRow("3", "離す", "約 1.5 秒で文字起こしして保存。5 秒以内なら取り消せます。")
            }
            .padding(.top, 6)
            Text("使い始める前に、権限の許可とモデルの準備をします。")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    private func stepRow(_ n: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 12) {
            Text(n)
                .font(.system(size: 12, weight: .bold, design: .monospaced))
                .foregroundStyle(Color.capture)
                .frame(width: 22, height: 22)
                .background(Circle().fill(Color.captureSoft))
            Text(title).font(.system(size: 14, weight: .semibold)).frame(width: 36, alignment: .leading)
            Text(detail).font(.system(size: 13)).foregroundStyle(.secondary)
        }
    }

    // MARK: 権限

    private var permissions: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("使う権限と理由").font(.system(size: 20, weight: .bold))
            Text("許可しなくても、マイク以外は記録を続けます。あとからシステム設定でいつでも変えられます。")
                .font(.system(size: 13)).foregroundStyle(.secondary)
            VStack(spacing: 0) {
                ForEach(PermissionKind.allCases) { kind in
                    PermissionRow(kind: kind, state: vm.states[kind] ?? .notDetermined, hotkey: hotkey) {
                        Task { await vm.openSettings(kind) }
                    }
                    if kind != PermissionKind.allCases.last { Divider() }
                }
            }
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Color.primary.opacity(0.08)))
            if let issue = hotKeyIssue() {
                Label(issue.message, systemImage: "exclamationmark.triangle")
                    .foregroundStyle(Color.warnText)
                    .font(.system(size: 12))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Button("状態を確かめ直す") { Task { await vm.refreshPermissions() } }
                .buttonStyle(.link)
                .font(.system(size: 12))
        }
    }

    // MARK: モデル

    private var models: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("モデルの準備").font(.system(size: 20, weight: .bold))
            Text("文字起こし・検索・意図の推定に使う 3 つのモデルを、この Mac にダウンロードします（合計 約 8GB。意図の推定モデルは取得後にこの Mac で変換し、変換後のモデルは合計 約 5.3GB）。作業中は一時的に 約 13GB の空きが要ります。変換と初回の最適化に数分かかります。通信するのはこのときだけで、以降はオフラインで動きます。")
                .font(.system(size: 13))
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 10) {
                switch vm.modelState {
                case .notStarted:
                    Button("ダウンロードを始める") { vm.startModelPreparation() }
                        .buttonStyle(.borderedProminent)
                        .tint(Color.capture)
                    Text("電源につないだ状態をおすすめします。").font(.system(size: 12)).foregroundStyle(.secondary)
                case let .running(p):
                    ProgressView(value: p.fractionCompleted)
                        .tint(Color.capture)
                        .accessibilityLabel(p.phase == .downloading ? "ダウンロードの進み具合" : "最適化の進み具合")
                    Text(progressText(p))
                        .font(.system(size: 12, design: .monospaced))
                        .foregroundStyle(.secondary)
                    if p.phase == .optimizing {
                        Text("この Mac に合わせて最適化しています。数分かかります。このウインドウを閉じても続きます。")
                            .font(.system(size: 12)).foregroundStyle(.secondary)
                    }
                case .finished:
                    Label("準備ができました", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(Color.capture)
                        .font(.system(size: 14, weight: .semibold))
                case let .failed(message):
                    Label(message, systemImage: "exclamationmark.circle")
                        .foregroundStyle(Color.warnText)
                        .font(.system(size: 13))
                        .fixedSize(horizontal: false, vertical: true)
                    Button("もう一度始める") { vm.startModelPreparation() }
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.primary.opacity(0.03), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    private func progressText(_ p: ModelPreparationProgress) -> String {
        let fmt = ByteCountFormatter()
        fmt.countStyle = .file
        switch p.phase {
        case .downloading:
            let item = p.currentItem.map { " · \($0)" } ?? ""
            return "\(fmt.string(fromByteCount: p.completedBytes)) / \(fmt.string(fromByteCount: p.totalBytes))\(item)"
        case .optimizing:
            return "最適化 \(Int(p.fractionCompleted * 100))%" + (p.currentItem.map { " · \($0)" } ?? "")
        case .finished:
            return "完了"
        }
    }

    // MARK: 完了

    private var ready: some View {
        VStack(alignment: .leading, spacing: 16) {
            Image(systemName: "checkmark.circle")
                .font(.system(size: 40, weight: .light))
                .foregroundStyle(Color.capture)
            Text("準備ができました").font(.system(size: 24, weight: .bold))
            Text("気になる画面で \(hotkey) を押したまま話して、離してください。記録はメニューバーのアイコンから開く Inbox にたまります。")
                .font(.system(size: 14))
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: 下の操作

    private var footer: some View {
        HStack {
            HStack(spacing: 6) {
                ForEach(OnboardingViewModel.Step.allCases, id: \.rawValue) { s in
                    Circle()
                        .fill(s == vm.step ? Color.capture : Color.primary.opacity(0.18))
                        .frame(width: 7, height: 7)
                }
            }
            .accessibilityLabel("手順 \(vm.step.rawValue + 1) / \(OnboardingViewModel.Step.allCases.count)")
            Spacer()
            if vm.step != .welcome {
                Button("戻る") { vm.back() }
            }
            // 題名が手順ごとに変わってもボタンの幅を変えない。フルキーボードアクセスが有効だと、
            // このボタンにフォーカスリングが付く。フォーカス中のボタンの幅が変わると、リングは
            // 古い幅のまま新しい位置に残り、ずれて（ときにウインドウの外へ）描かれる。
            // 全手順の題名を見えない形で重ねて、最も長い題名の幅に揃える（文言や文字サイズが
            // 変わっても追随する）。重ねた分は読み上げに出さず、いまの題名だけを読ませる。
            Button { vm.next() } label: {
                ZStack {
                    ForEach(OnboardingViewModel.Step.allCases, id: \.rawValue) { step in
                        Text(Self.nextTitle(for: step)).hidden().accessibilityHidden(true)
                    }
                    Text(Self.nextTitle(for: vm.step))
                }
            }
                .buttonStyle(.borderedProminent)
                .tint(Color.capture)
                .disabled(!vm.canGoNext)
                .keyboardShortcut(.defaultAction)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
    }

    private static func nextTitle(for step: OnboardingViewModel.Step) -> String {
        switch step {
        case .welcome: return "はじめる"
        case .permissions, .models: return "次へ"
        case .ready: return "使いはじめる"
        }
    }
}

/// 権限 1 種の行（PRD §8.2 の「何に使うか／許可しないと」）。
struct PermissionRow: View {
    let kind: PermissionKind
    let state: PermissionState
    let hotkey: String
    var open: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: symbol)
                .font(.system(size: 18))
                .foregroundStyle(Color.capture)
                .frame(width: 26)
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(.system(size: 14, weight: .semibold))
                Text(purpose).font(.system(size: 12)).fixedSize(horizontal: false, vertical: true)
                Text("許可しないと: \(withoutIt)")
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 8)
            VStack(alignment: .trailing, spacing: 6) {
                stateLabel
                if state != .granted {
                    Button("システム設定を開く", action: open)
                        .controlSize(.small)
                }
            }
        }
        .padding(12)
        .accessibilityElement(children: .contain)
    }

    @ViewBuilder
    private var stateLabel: some View {
        switch state {
        case .granted:
            Label("許可済み", systemImage: "checkmark.circle.fill").foregroundStyle(Color.capture).font(.system(size: 12, weight: .medium))
        case .denied:
            Label("許可されていません", systemImage: "xmark.circle").foregroundStyle(Color.warnText).font(.system(size: 12))
        case .notDetermined:
            Text("まだ許可していません").foregroundStyle(.secondary).font(.system(size: 12))
        case .unknown:
            Text("ブラウザごとに初回に確認").foregroundStyle(.secondary).font(.system(size: 12))
        }
    }

    private var title: String {
        switch kind {
        case .microphone: return "マイク"
        case .screenRecording: return "画面収録"
        case .accessibility: return "アクセシビリティ"
        case .automation: return "オートメーション"
        }
    }

    private var symbol: String {
        switch kind {
        case .microphone: return "mic"
        case .screenRecording: return "rectangle.dashed.badge.record"
        case .accessibility: return "keyboard"
        case .automation: return "safari"
        }
    }

    private var purpose: String {
        switch kind {
        case .microphone: return "\(hotkey) を押している間だけ、あなたの声を録ります。"
        case .screenRecording: return "押した瞬間の前面ウインドウを 1 枚だけ撮ります（動画は撮りません）。"
        case .accessibility: return "録音のキーと、ウインドウのタイトルの取得に使います。"
        case .automation: return "ブラウザ（Safari・Chrome・Arc・Edge）で開いているページの URL を取得します。"
        }
    }

    private var withoutIt: String {
        switch kind {
        case .microphone: return "録音できないため、このアプリは使えません。"
        case .screenRecording: return "スクショなしで保存します。"
        case .accessibility: return "アプリ名だけ保存します。"
        case .automation: return "URL なしで保存します。"
        }
    }
}
