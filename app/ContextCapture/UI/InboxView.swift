import CCCore
import SwiftUI

/// Context Inbox（F-07, F-09 / F-10 の表示, F-11）。新しい順・日付で区切る。Enter / ダブルクリックで詳細。
struct InboxView: View {
    let app: AppModel
    @Bindable var vm: InboxViewModel
    @State private var path: [String] = []
    @FocusState private var searchFocused: Bool
    @FocusState private var listFocused: Bool

    var body: some View {
        NavigationStack(path: $path) {
            VStack(spacing: 0) {
                header
                Divider()
                content
            }
            .frame(minWidth: 640, minHeight: 420)
            .background(Color(nsColor: .windowBackgroundColor))
            .navigationTitle("Context Inbox")
            .navigationDestination(for: String.self) { id in
                DetailContainer(app: app, recordID: id) { path.removeAll() }
            }
            .overlay(alignment: .bottom) { flash }
        }
        .task { await vm.load() }
        .onChange(of: app.recordsRevision) { _, _ in Task { await vm.load() } }
        .onChange(of: vm.scope) { _, _ in
            Task {
                await vm.load()
                if vm.searchedQuery != nil { await vm.runSearch() }
            }
        }
        .confirmationDialog(
            "この記録を削除しますか？",
            isPresented: Binding(get: { vm.pendingDelete != nil }, set: { if !$0 { vm.pendingDelete = nil } }),
            presenting: vm.pendingDelete
        ) { _ in
            Button("削除する", role: .destructive) { Task { await vm.confirmDelete() } }
            Button("キャンセル", role: .cancel) { vm.pendingDelete = nil }
        } message: { _ in
            Text("スクショと音声も一緒に消えます。元に戻せません。")
        }
    }

    // MARK: 上部（検索欄と意図フィルタ）

    private var header: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
                TextField("話した内容や画面の見た目で探す（例: ビデオ会議の画面）", text: $vm.query)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .focused($searchFocused)
                    .onSubmit { Task { await vm.runSearch(); listFocused = true } }
                    .onKeyPress(.escape) {
                        guard !vm.query.isEmpty || vm.searchResults != nil else { return .ignored }
                        vm.clearSearch()
                        return .handled
                    }
                    .accessibilityLabel("検索")
                    .accessibilityHint("自然な文で入力して Enter で検索します")
                if vm.isSearching { ProgressView().controlSize(.small) }
                if !vm.query.isEmpty || vm.searchResults != nil {
                    Button { vm.clearSearch() } label: { Image(systemName: "xmark.circle.fill") }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .accessibilityLabel("検索を消す")
                }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 7)
            .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(searchFocused ? Color.capture : Color.primary.opacity(0.12)))

            HStack(spacing: 6) {
                ForEach(InboxScope.allCases) { scope in
                    ScopeChip(scope: scope, selected: vm.scope == scope) { vm.scope = scope }
                }
                Spacer(minLength: 0)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background {
            // ⌘F で検索欄へ。
            Button("") { searchFocused = true }.keyboardShortcut("f").hidden()
        }
    }

    // MARK: 一覧

    @ViewBuilder
    private var content: some View {
        if let message = vm.errorMessage {
            MessageView(systemImage: "exclamationmark.triangle", title: message, detail: nil)
        } else if vm.isEmpty {
            emptyState
        } else {
            list
        }
    }

    private var list: some View {
        List(selection: $vm.selection) {
            if let hits = vm.searchResults {
                Section {
                    ForEach(hits, id: \.record.id) { hit in
                        InboxRow(record: hit.record, showsDate: true).tag(hit.record.id)
                    }
                } header: {
                    Text("「\(vm.searchedQuery ?? "")」に近い記録 \(hits.count) 件")
                }
            } else {
                ForEach(vm.sections) { section in
                    Section {
                        ForEach(section.records) { r in
                            InboxRow(record: r, showsDate: false).tag(r.id)
                        }
                    } header: {
                        Text(section.title)
                    }
                }
            }
        }
        .listStyle(.inset)
        .focused($listFocused)
        .contextMenu(forSelectionType: String.self) { ids in
            if let id = ids.first {
                Button("詳細を開く") { open(id) }
                Button("Markdown でコピー") { vm.copyMarkdown(id: id) }
                Divider()
                Button("削除…") { vm.requestDelete(id: id) }
            }
        } primaryAction: { ids in
            // Enter とダブルクリック。
            if let id = ids.first { open(id) }
        }
        .onDeleteCommand { vm.requestDelete(id: vm.selection) }
        .onCopyCommand {
            guard let id = vm.selection, let r = vm.record(id: id) else { return [] }
            return [NSItemProvider(object: RecordMarkdown.render(r, includeScreenshotLink: true) as NSString)]
        }
    }

    @ViewBuilder
    private var emptyState: some View {
        if let q = vm.searchedQuery {
            MessageView(systemImage: "magnifyingglass",
                        title: "「\(q)」に近い記録は見つかりませんでした",
                        detail: "言い方を変えるか、画面に写っていたものの見た目で探してください。")
        } else if vm.scope != .all {
            MessageView(systemImage: "tray",
                        title: "「\(vm.scope.title)」の記録はありません",
                        detail: "上の「すべて」を選ぶと、未処理の記録をすべて表示します。")
        } else {
            MessageView(systemImage: "camera.viewfinder",
                        title: "\(app.settings.hotkey.display) を押して話すと、ここに記録がたまります",
                        detail: "押したまま一言話して離すだけ。見ている画面とアプリの情報が一緒に残ります。")
        }
    }

    @ViewBuilder
    private var flash: some View {
        if let f = vm.flash {
            Text(f)
                .font(.system(size: 12, weight: .medium))
                .padding(.horizontal, 12).padding(.vertical, 6)
                .background(.regularMaterial, in: Capsule())
                .padding(.bottom, 12)
                .transition(.opacity)
        }
    }

    private func open(_ id: String) {
        vm.selection = id
        path = [id]
    }
}

/// 意図フィルタの 1 つ。
private struct ScopeChip: View {
    let scope: InboxScope
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(scope.title)
                .font(.system(size: 12, weight: selected ? .semibold : .regular,
                              design: isIntent ? .monospaced : .default))
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .foregroundStyle(selected ? Color.white : Color.primary)
                .background(selected ? Color.capture : Color.primary.opacity(0.06), in: Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(scope.title)で絞り込む")
        .accessibilityAddTraits(selected ? .isSelected : [])
    }

    private var isIntent: Bool {
        if case .intent = scope { return true }
        return false
    }
}

/// 一覧の 1 行。
struct InboxRow: View {
    let record: ContextRecord
    var showsDate: Bool

    var body: some View {
        HStack(spacing: 10) {
            AppIconView(bundleID: record.app.bundleID, size: 20)
            Text(showsDate ? record.capturedAt.formatted(.dateTime.month().day()) + " " + DateText.time(record.capturedAt)
                           : DateText.time(record.capturedAt))
                .font(.system(size: 12, design: .monospaced))
                .foregroundStyle(.secondary)
                .frame(width: showsDate ? 96 : 42, alignment: .leading)
            Text(record.app.name)
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .frame(width: 104, alignment: .leading)
            annotation
                .frame(maxWidth: .infinity, alignment: .leading)
            if record.triage?.mentionsDatetime == true {
                Image(systemName: "calendar")
                    .foregroundStyle(.secondary)
                    .help("日時の言及あり")
                    .accessibilityLabel("日時の言及あり")
            }
            if record.guardInfo.status == .needsReview {
                NeedsReviewBadge()
            }
            if let t = record.triage {
                IntentTag(intent: t.intent)
            } else {
                Text("推定中")
                    .font(.system(size: 11))
                    .foregroundStyle(.tertiary)
                    .accessibilityLabel("意図は推定中")
            }
        }
        .padding(.vertical, 3)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var annotation: some View {
        let first = record.annotation.text.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
        if first.isEmpty {
            Text("（文字起こしなし）").foregroundStyle(.secondary).font(.system(size: 13))
        } else {
            Text(first).font(.system(size: 13)).lineLimit(1).truncationMode(.tail)
        }
    }
}

/// 空・エラーの表示。
struct MessageView: View {
    let systemImage: String
    let title: String
    let detail: String?

    var body: some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color.capture)
            Text(title)
                .font(.system(size: 15, weight: .semibold))
                .multilineTextAlignment(.center)
            if let detail {
                Text(detail)
                    .font(.system(size: 13))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
        }
        .padding(40)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
