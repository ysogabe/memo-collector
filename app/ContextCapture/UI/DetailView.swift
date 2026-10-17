import CCCore
import SwiftUI

/// Inbox から開く詳細。記録を読んで ViewModel を作る。
struct DetailContainer: View {
    let app: AppModel
    let recordID: String
    var close: () -> Void
    @State private var vm: DetailViewModel?
    @State private var missing = false

    var body: some View {
        Group {
            if let vm {
                DetailView(app: app, vm: vm, close: close)
            } else if missing {
                MessageView(systemImage: "questionmark.folder", title: "この記録は見つかりませんでした", detail: "削除された可能性があります。")
            } else {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
        .background {
            // 読み込み中・記録が無いときも Esc で戻れるように（詳細が出たら DetailView 側が受ける）。
            if vm == nil { EscapeToCloseButton(action: close) }
        }
        .task(id: recordID) {
            guard let r = try? await app.env.store.get(id: recordID) else { missing = true; return }
            let model = DetailViewModel(record: r, store: app.env.store, guardReview: app.env.guardReview,
                                        triage: app.env.triage) { [app] in
                app.recordsDidChange()
            }
            await model.load()
            vm = model
        }
    }
}

/// Esc で閉じるための不可視ボタン。フォーカスがどこにあっても効くようキー割り当てで受ける（⌘F と同じ流儀）。
private struct EscapeToCloseButton: View {
    var disabled = false
    let action: () -> Void

    var body: some View {
        Button("", action: action)
            .keyboardShortcut(.cancelAction)
            .disabled(disabled)
            .frame(width: 0, height: 0)
            .opacity(0)
            .accessibilityHidden(true)
    }
}

/// 詳細（F-08, F-09, F-10）。
struct DetailView: View {
    let app: AppModel
    @Bindable var vm: DetailViewModel
    var close: () -> Void
    @State private var confirmDelete = false
    @FocusState private var annotationFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if vm.needsReview { reviewBanner }
                    if vm.record.guardInfo.status == .masked { maskedNote }
                    screenshot
                    metadata
                    annotationEditor
                    intentPicker
                    if !vm.record.notes.isEmpty { notes }
                    if let e = vm.errorMessage {
                        Label(e, systemImage: "exclamationmark.circle").foregroundStyle(Color.warnText)
                    }
                }
                .padding(20)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Divider()
            actionBar
        }
        .navigationTitle(vm.record.app.name)
        .navigationSubtitle(DateText.full(vm.record.capturedAt))
        .onChange(of: vm.isClosed) { _, closed in if closed { close() } }
        .background {
            // Esc で一覧へ戻る。注釈の編集中は 1 回目の Esc で編集を抜ける（下の TextEditor）ので、ここは無効にする。
            // 削除の確認中はダイアログの「キャンセル」が Esc を受ける。
            EscapeToCloseButton(disabled: annotationFocused || confirmDelete, action: close)
        }
        .onDisappear {
            // 編集したまま離れても失わない。
            if vm.isAnnotationChanged { Task { await vm.saveAnnotation() } }
        }
        .confirmationDialog("この記録を削除しますか？", isPresented: $confirmDelete) {
            Button("削除する", role: .destructive) { Task { await vm.delete() } }
            Button("キャンセル", role: .cancel) {}
        } message: {
            Text("スクショと音声も一緒に消えます。元に戻せません。")
        }
    }

    // MARK: 要確認

    private var reviewBanner: some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("トークンらしき文字列が写っています。確認するまでエージェントには渡しません", systemImage: "exclamationmark.triangle.fill")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.warnText)
                .fixedSize(horizontal: false, vertical: true)
            Text("赤い枠が検出した箇所です（\(findingKinds)）。")
                .font(.system(size: 12))
                .foregroundStyle(Color.warnText.opacity(0.85))
            HStack {
                Button("確認済みにする") { Task { await vm.markReviewed() } }
                    .help("問題ないと確認した。元の画像をエージェントに渡せるようにします")
                Button("マスクした画像を使う") { Task { await vm.useMaskedImage() } }
                    .buttonStyle(.borderedProminent)
                    .tint(Color.capture)
                    .help("検出箇所を塗りつぶした画像を作り、エージェントにはそちらを渡します")
                if vm.isWorking { ProgressView().controlSize(.small) }
            }
            .disabled(vm.isWorking)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.warnSoft, in: RoundedRectangle(cornerRadius: 10))
        .accessibilityElement(children: .contain)
    }

    private var findingKinds: String {
        Array(Set(vm.record.guardInfo.findings.map(\.kind))).sorted().joined(separator: "、")
    }

    private var maskedNote: some View {
        Label("検出箇所を塗りつぶした画像をエージェントに渡します", systemImage: "checkmark.shield")
            .font(.system(size: 12))
            .foregroundStyle(.secondary)
    }

    // MARK: スクショ

    @ViewBuilder
    private var screenshot: some View {
        if let image = vm.image {
            Button {
                app.windows.showScreenshot(image, findings: vm.highlightedFindings, title: CaptureMessages.subtitle(vm.record))
            } label: {
                ScreenshotView(image: image, findings: vm.highlightedFindings)
                    .frame(maxHeight: 360)
            }
            .buttonStyle(.plain)
            .help("クリックで拡大")
            .accessibilityLabel(vm.needsReview ? "スクショ。トークンらしき箇所に枠があります。クリックで拡大" : "スクショ。クリックで拡大")
        } else if vm.imageLoaded {
            HStack {
                Image(systemName: "photo").foregroundStyle(.secondary)
                Text("スクショはありません").foregroundStyle(.secondary)
            }
            .font(.system(size: 13))
            .frame(maxWidth: .infinity, minHeight: 80)
            .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        }
    }

    // MARK: メタデータ

    private var metadata: some View {
        Grid(alignment: .leadingFirstTextBaseline, horizontalSpacing: 14, verticalSpacing: 8) {
            GridRow {
                label("アプリ")
                HStack(spacing: 6) {
                    AppIconView(bundleID: vm.record.app.bundleID, size: 16)
                    Text(vm.record.app.name)
                }
            }
            if let t = vm.record.window?.title, !t.isEmpty {
                GridRow {
                    label("ウインドウ")
                    Text(t).textSelection(.enabled)
                }
            }
            if let u = vm.record.url, let url = URL(string: u) {
                GridRow {
                    label("URL")
                    Link(u, destination: url)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .help("ブラウザで開く")
                }
            }
            GridRow {
                label("撮影")
                Text(DateText.full(vm.record.capturedAt))
            }
        }
        .font(.system(size: 13))
    }

    private func label(_ s: String) -> some View {
        Text(s).foregroundStyle(.secondary).gridColumnAlignment(.trailing)
    }

    // MARK: 注釈

    private var annotationEditor: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("注釈").font(.system(size: 13, weight: .semibold))
                if vm.record.annotation.edited {
                    Text("手直し済み").font(.system(size: 11)).foregroundStyle(.secondary)
                }
                Spacer()
                if vm.isAnnotationChanged {
                    Button("元に戻す") { vm.revertAnnotation() }
                        .controlSize(.small)
                    Button("注釈を保存") { Task { await vm.saveAnnotation() } }
                        .controlSize(.small)
                        .keyboardShortcut("s")
                }
            }
            TextEditor(text: $vm.draftText)
                .focused($annotationFocused)
                .onKeyPress(.escape) {
                    // 変換中の Esc は変換の取り消しなので IME に渡す（キーは key window にだけ届く）。それ以外は編集を抜ける（次の Esc で戻る）。
                    if (NSApp.keyWindow?.firstResponder as? NSTextView)?.hasMarkedText() == true { return .ignored }
                    annotationFocused = false
                    return .handled
                }
                .font(.system(size: 14))
                .scrollContentBackground(.hidden)
                .padding(6)
                .frame(minHeight: 64)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
                .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.12)))
                .accessibilityLabel("注釈")
        }
    }

    // MARK: 意図

    private var intentPicker: some View {
        HStack(spacing: 10) {
            Text("意図").font(.system(size: 13, weight: .semibold))
            Picker("意図", selection: Binding(
                get: { vm.record.triage?.intent },
                set: { new in Task { await vm.setIntent(new) } }
            )) {
                Text("未分類").tag(Intent?.none)
                Divider()
                ForEach(Intent.allCases, id: \.self) { i in
                    Text(IntentText.title(i)).tag(Intent?.some(i))
                }
            }
            .labelsHidden()
            .fixedSize()
            if vm.record.triage == nil {
                Text("推定中").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            if vm.record.triage?.mentionsDatetime == true {
                Label("日時の言及あり", systemImage: "calendar")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: メモ

    private var notes: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("メモ").font(.system(size: 13, weight: .semibold))
            ForEach(Array(vm.record.notes.enumerated()), id: \.offset) { _, n in
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(n.author) · \(DateText.full(n.at))").font(.system(size: 11)).foregroundStyle(.secondary)
                    Text(n.text).font(.system(size: 13)).textSelection(.enabled)
                }
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
            }
        }
    }

    // MARK: 操作

    private var actionBar: some View {
        HStack(spacing: 10) {
            Button {
                vm.copyMarkdown()
            } label: {
                Label("Markdown でコピー", systemImage: "doc.on.doc")
            }
            .keyboardShortcut("c", modifiers: [.command, .shift])
            .help("⇧⌘C")
            if let f = vm.flash {
                Text(f).font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Spacer()
            Button(role: .destructive) {
                confirmDelete = true
            } label: {
                Label("削除…", systemImage: "trash")
            }
            Button {
                Task { await vm.markDone() }
            } label: {
                Label("完了にする", systemImage: "checkmark")
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.capture)
            .keyboardShortcut(.return, modifiers: [.command])
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }
}

/// スクショと、検出箇所（正規化・左上原点）の枠。
struct ScreenshotView: View {
    let image: NSImage
    let findings: [SecretFinding]

    var body: some View {
        Image(nsImage: image)
            .resizable()
            .aspectRatio(contentMode: .fit)
            .overlay {
                GeometryReader { geo in
                    ForEach(Array(findings.enumerated()), id: \.offset) { _, f in
                        let r = CGRect(x: f.bbox.minX * geo.size.width, y: f.bbox.minY * geo.size.height,
                                       width: f.bbox.width * geo.size.width, height: f.bbox.height * geo.size.height)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(Color.findingStroke.opacity(0.18))
                            .overlay(RoundedRectangle(cornerRadius: 3).strokeBorder(Color.findingStroke, lineWidth: 2))
                            .frame(width: r.width, height: r.height)
                            .position(x: r.midX, y: r.midY)
                    }
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.1)))
    }
}
