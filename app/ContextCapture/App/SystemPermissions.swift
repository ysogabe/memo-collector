import AppKit
import ApplicationServices
import AVFoundation
import CoreGraphics

/// macOS の権限を実際に調べる実装（本番用）。
struct SystemPermissions: PermissionsProviding {
    func state(of kind: PermissionKind) async -> PermissionState {
        switch kind {
        case .microphone:
            switch AVCaptureDevice.authorizationStatus(for: .audio) {
            case .authorized: return .granted
            case .notDetermined: return .notDetermined
            default: return .denied
            }
        case .screenRecording:
            return CGPreflightScreenCaptureAccess() ? .granted : .notDetermined
        case .accessibility:
            return AXIsProcessTrusted() ? .granted : .notDetermined
        case .automation:
            // ブラウザごとに初回の Apple Event 送信時に聞かれるため、事前には分からない。
            return .unknown
        }
    }

    func request(_ kind: PermissionKind) async {
        switch kind {
        case .microphone:
            _ = await AVCaptureDevice.requestAccess(for: .audio)
        case .screenRecording:
            _ = CGRequestScreenCaptureAccess()
        case .accessibility:
            let key = kAXTrustedCheckOptionPrompt.takeUnretainedValue() as String
            _ = AXIsProcessTrustedWithOptions([key: true] as CFDictionary)
        case .automation:
            break
        }
    }

    func openSystemSettings(for kind: PermissionKind) async {
        let anchor: String
        switch kind {
        case .microphone: anchor = "Privacy_Microphone"
        case .screenRecording: anchor = "Privacy_ScreenCapture"
        case .accessibility: anchor = "Privacy_Accessibility"
        case .automation: anchor = "Privacy_Automation"
        }
        guard let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(anchor)") else { return }
        await MainActor.run { _ = NSWorkspace.shared.open(url) }
    }
}
