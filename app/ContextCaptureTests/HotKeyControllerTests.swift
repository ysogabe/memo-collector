import AppKit
import CCCapture
import XCTest

@MainActor
final class HotKeyControllerTests: XCTestCase {
    final class Driver: HotKeyDriving {
        var onEvent: ((HotKeyEvent) -> Void)?
        var lastCarbonStatus: Int32? = 0
        var calls: [String] = []
        var shortcut: HotKeyShortcut?
        var result: Result<GlobalPushToTalkHotKey.Backend, Error> = .success(.carbon)
        func stop() { calls.append("stop") }
        func setShortcut(_ value: HotKeyShortcut) throws { calls.append("set"); shortcut = value }
        func start(allowEventTapFallback: Bool, preferEventTap: Bool) throws -> GlobalPushToTalkHotKey.Backend {
            calls.append("start")
            XCTAssertTrue(allowEventTapFallback)
            XCTAssertFalse(preferEventTap)
            return try result.get()
        }
    }

    func testResetStopsOldKeyBeforeRegisterAndForwardsEvents() {
        let driver = Driver()
        let key = HotKeyController(hotKey: driver)
        key.willReset = { driver.calls.append("reset") }
        key.onStatusChange = { _ in driver.calls.append("status") }
        XCTAssertEqual(key.register(.default), .active(.carbon))
        XCTAssertEqual(driver.calls, ["reset", "stop", "set", "start", "status"])
        var forwarded: HotKeyEvent?
        key.onEvent = { forwarded = $0 }
        let event = HotKeyEvent(kind: .pressed, uptime: 1, date: Date(timeIntervalSince1970: 1))
        driver.onEvent?(event)
        XCTAssertEqual(forwarded?.kind, .pressed)
        key.suspend()
    }

    func testErrorsMapToActionableStatusAndActiveKeyIsNotRetried() {
        let driver = Driver(), controller = HotKeyController(hotKey: driver)
        driver.result = .failure(GlobalPushToTalkHotKey.HotKeyError.alreadyInUse)
        XCTAssertEqual(controller.register(.default), .alreadyInUse)
        XCTAssertNil(HotKeyIssue.from(controller.status, hotkey: "X")?.settingsKind)
        driver.result = .failure(GlobalPushToTalkHotKey.HotKeyError.registrationFailed(carbonStatus: -1, accessibilityTrusted: false))
        XCTAssertEqual(controller.register(.default), .needsAccessibility(carbonStatus: -1))
        XCTAssertEqual(HotKeyIssue.from(controller.status, hotkey: "X")?.settingsKind, .accessibility)
        driver.result = .success(.eventTap)
        controller.retryIfNeeded()
        XCTAssertEqual(controller.status, .active(.eventTap))
        let count = driver.calls.count
        controller.retryIfNeeded()
        XCTAssertEqual(driver.calls.count, count)
        XCTAssertNil(HotKeyIssue.from(.notRegistered, hotkey: "X"))
        XCTAssertNil(HotKeyIssue.from(.active(.carbon), hotkey: "X"))
        XCTAssertNil(HotKeyIssue.from(.failed("error"), hotkey: "X")?.settingsKind)
        controller.suspend()
    }

    func testOnlySupportedModifierFlagsReachBackend() {
        let flags: NSEvent.ModifierFlags = [.command, .option, .control, .shift, .capsLock, .numericPad]
        let combo = HotkeyCombo(keyCode: 49, modifiers: flags.rawValue)
        XCTAssertEqual(combo.shortcut.keyCode, 49)
        XCTAssertEqual(combo.shortcut.modifiers, [.command, .option, .control, .shift])
    }
}
