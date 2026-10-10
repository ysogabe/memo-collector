import AppKit
import Observation
import SwiftUI

/// トーストの表示時間（PRD F-06）。
/// 「保存しました」は全文を 1.5 秒見せたあと、取り消せる 5 秒が終わるまで [取り消す] だけの小さな形に縮めて残す。
enum ToastTiming {
    /// 保存トーストの全文を見せる時間。
    static let savedFull: Duration = .milliseconds(1500)
    /// 保存から取り消しを受け付ける時間（この間 [取り消す] を出す）。
    static let undoWindow: Duration = .seconds(5)
    /// 「取り消しました」などの知らせ。
    static let info: Duration = .milliseconds(1500)
    /// エラー（読んでボタンを押す時間をとる）。
    static let error: Duration = .seconds(7)
}

@Observable
@MainActor
final class ToastModel {
    var content: ToastContent?
    /// 保存トーストを縮めた形（[取り消す] だけ）で出しているか。
    var compact = false
}

/// 保存トースト（画面右上）。前面アプリのフォーカスは奪わないが、ボタンは押せる。
@MainActor
final class ToastController {
    let model = ToastModel()
    private unowned let appModel: AppModel
    private var panel: OverlayPanel?
    private var timer: Task<Void, Never>?
    private static let width: CGFloat = 380

    init(model: AppModel) {
        self.appModel = model
    }

    func show(_ content: ToastContent) {
        model.content = content
        model.compact = false
        let panel = self.panel ?? makePanel()
        self.panel = panel
        layout(panel)
        panel.orderFrontRegardless()

        timer?.cancel()
        timer = Task { [weak self] in
            switch content.kind {
            case .saved:
                try? await Task.sleep(for: ToastTiming.savedFull)
                guard !Task.isCancelled, let self else { return }
                if content.actions.count == 1 {
                    // [取り消す] だけなら小さくして取り消しの残り時間だけ出しておく。
                    self.model.compact = true
                    self.layout(panel)
                }
                try? await Task.sleep(for: ToastTiming.undoWindow - ToastTiming.savedFull)
            case .info:
                try? await Task.sleep(for: ToastTiming.info)
            case .error:
                try? await Task.sleep(for: ToastTiming.error)
            }
            guard !Task.isCancelled else { return }
            self?.hide()
        }
    }

    func hide() {
        timer?.cancel()
        timer = nil
        panel?.orderOut(nil)
        model.content = nil
    }

    private func makePanel() -> OverlayPanel {
        let p = OverlayPanel(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 120), clickThrough: false)
        let host = NSHostingView(rootView: SaveToastView(model: model, perform: { [weak self] action in
            self?.hide()
            self?.appModel.perform(action)
        }))
        p.contentView = host
        return p
    }

    private func layout(_ p: NSPanel) {
        guard let host = p.contentView else { return }
        let fitting = host.fittingSize
        let size = NSSize(width: Self.width, height: max(44, fitting.height))
        let screen = NSScreen.main ?? NSScreen.screens.first
        guard let vf = screen?.visibleFrame else { return }
        p.setFrame(NSRect(x: vf.maxX - size.width - 12, y: vf.maxY - size.height - 10, width: size.width, height: size.height), display: true)
    }
}

struct SaveToastView: View {
    let model: ToastModel
    var perform: (ToastContent.Action) -> Void

    var body: some View {
        Group {
            if let c = model.content {
                if model.compact, let id = c.undoRecordID {
                    compact(id)
                } else {
                    full(c)
                }
            }
        }
        .frame(width: 380, alignment: .trailing)
    }

    private func full(_ c: ToastContent) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                icon(c.kind)
                Text(c.title).font(.system(size: 13, weight: .semibold))
                if let s = c.subtitle {
                    Text(s).font(.system(size: 12)).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                }
            }
            if let b = c.body {
                Text(b).font(.system(size: 13)).lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            if let n = c.note {
                Text(n).font(.system(size: 12)).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            if !c.actions.isEmpty {
                HStack {
                    Spacer()
                    ForEach(c.actions, id: \.title) { a in
                        Button(a.title) { perform(a) }
                            .controlSize(.small)
                    }
                }
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 12))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Color.primary.opacity(0.08)))
        .padding(4)
        .accessibilityElement(children: .contain)
        .accessibilityLabel([c.title, c.subtitle, c.body, c.note].compactMap { $0 }.joined(separator: "。"))
    }

    private func compact(_ id: String) -> some View {
        HStack(spacing: 8) {
            icon(.saved)
            Text("保存しました").font(.system(size: 12, weight: .medium))
            Button("取り消す") { perform(.undo(recordID: id)) }
                .controlSize(.small)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(.regularMaterial, in: Capsule())
        .overlay(Capsule().strokeBorder(Color.primary.opacity(0.08)))
        .padding(4)
    }

    @ViewBuilder
    private func icon(_ kind: ToastContent.Kind) -> some View {
        switch kind {
        case .saved: Image(systemName: "checkmark.circle.fill").foregroundStyle(Color.capture)
        case .info: Image(systemName: "arrow.uturn.backward.circle.fill").foregroundStyle(.secondary)
        case .error: Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Color.warnText)
        }
    }
}
