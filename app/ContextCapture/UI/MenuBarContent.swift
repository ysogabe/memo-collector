import SwiftUI

/// メニューバーのアイコンと未処理件数（F-01）。録音中はアイコンを変える。
struct MenuBarLabel: View {
    let model: AppModel

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: model.isRecording ? "mic.circle.fill" : "camera.viewfinder")
            if model.unprocessedCount > 0 {
                Text("\(model.unprocessedCount)")
                    .monospacedDigit()
            }
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(accessibilityText)
    }

    private var accessibilityText: String {
        var s = "Context Capture"
        if model.isRecording { s += "、録音中" }
        s += "、未処理 \(model.unprocessedCount) 件"
        return s
    }
}

/// メニューの中身。
struct MenuBarContent: View {
    let model: AppModel

    var body: some View {
        Button("Inbox を開く") { model.windows.showInbox() }
            .keyboardShortcut("i")
        Text("今日の記録 \(model.todayCount) 件・未処理 \(model.unprocessedCount) 件")
        if let text = model.searchReadiness?.menuText {
            Text(text)
        }
        if let issue = model.hotKeyIssue {
            Divider()
            Text(issue.message)
            if let kind = issue.settingsKind {
                Button("システム設定を開く（アクセシビリティ）") {
                    Task { await model.env.permissions.openSystemSettings(for: kind) }
                }
            } else {
                Button("設定でキーを変える…") { model.windows.showSettings() }
            }
        }
        Divider()
        Button("設定…") { model.windows.showSettings() }
            .keyboardShortcut(",")
        if !model.settings.onboardingCompleted {
            Button("はじめの設定を続ける…") { model.windows.showOnboarding() }
        }
        if let fake = model.env.fakeCapture {
            Divider()
            Menu("フェイク操作") {
                Button("録音して保存する") { Task { await fake.simulateCapture() } }
                Button("録音して保存する（画面収録の許可なし）") { Task { await fake.simulateCapture(notice: .screenRecordingDenied) } }
                Button("声が入っていない録音") { Task { await fake.simulateNoVoice() } }
                Button("短すぎる押下") { Task { await fake.simulateShortPress() } }
                Button("文字起こしの失敗") { Task { await fake.simulateTranscriptionFailure() } }
                Button("マイクを使えない") { Task { await fake.simulateMicrophoneUnavailable() } }
                Divider()
                Button("オンボーディングを開く") { model.windows.showOnboarding() }
            }
        }
        if model.showsDebugMenu, let live = model.env.live {
            Divider()
            DebugMenu(model: model, live: live)
        }
        Divider()
        Button("Context Capture を終了") { NSApplication.shared.terminate(nil) }
            .keyboardShortcut("q")
    }
}
