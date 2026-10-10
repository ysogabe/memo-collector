import Carbon.HIToolbox
import CoreGraphics
import XCTest
@testable import CCCapture

/// ホットキーの純粋ロジック。RegisterEventHotKey は呼ばない（テスト中にユーザーの ⌥Space を奪わないため）。
final class HotKeyTests: XCTestCase {
    private let date = Date(timeIntervalSince1970: 0)

    func testGateDropsRepeatedPressesAndUnpairedReleases() {
        var gate = HotKeyGate()
        XCTAssertNil(gate.handle(.released, uptime: 1, date: date), "押していないのに解放は来ない")
        let p = gate.handle(.pressed, uptime: 10, date: date)
        XCTAssertEqual(p?.kind, .pressed)
        XCTAssertNil(p?.pressDuration)
        // キーリピート・二重配送
        XCTAssertNil(gate.handle(.pressed, uptime: 10.05, date: date))
        XCTAssertNil(gate.handle(.pressed, uptime: 10.10, date: date))
        let r = gate.handle(.released, uptime: 10.8, date: date)
        XCTAssertEqual(r?.kind, .released)
        XCTAssertEqual(r?.pressDuration ?? -1, 0.8, accuracy: 1e-9, "長さは最初の押下から")
        XCTAssertNil(gate.handle(.released, uptime: 11, date: date))
        XCTAssertNotNil(gate.handle(.pressed, uptime: 12, date: date), "解放後は再び押せる")
    }

    func testShortPressThreshold() {
        XCTAssertTrue(PushToTalkTiming.isTooShort(0.0))
        XCTAssertTrue(PushToTalkTiming.isTooShort(0.299))
        XCTAssertFalse(PushToTalkTiming.isTooShort(0.3))
        XCTAssertFalse(PushToTalkTiming.isTooShort(1.2))

        var gate = HotKeyGate()
        _ = gate.handle(.pressed, uptime: 100, date: date)
        XCTAssertTrue(gate.handle(.released, uptime: 100.2, date: date)!.isShortPress)
        _ = gate.handle(.pressed, uptime: 200, date: date)
        XCTAssertFalse(gate.handle(.released, uptime: 200.35, date: date)!.isShortPress)
        XCTAssertFalse(HotKeyEvent(kind: .pressed, uptime: 1, date: date).isShortPress, "押下イベントは短押し扱いしない")
    }

    func testUptimeToDate() {
        let now = Date(timeIntervalSince1970: 1_000_000)
        let d = Date.fromUptime(95, now: now, nowUptime: 100)
        XCTAssertEqual(d.timeIntervalSince1970, 999_995, accuracy: 1e-6)
    }

    func testDefaultShortcutAndCarbonModifiers() {
        let s = HotKeyShortcut.optionSpace
        XCTAssertEqual(s.keyCode, UInt32(kVK_Space))
        XCTAssertEqual(s.carbonModifiers, UInt32(optionKey))
        XCTAssertEqual(s.displayString, "⌥Space")
        XCTAssertTrue(s.mayBeRestrictedByCarbon)

        let all = HotKeyShortcut(keyCode: UInt32(kVK_F5), modifiers: [.command, .option, .control, .shift])
        XCTAssertEqual(all.carbonModifiers, UInt32(cmdKey | optionKey | controlKey | shiftKey))
        XCTAssertEqual(all.displayString, "⌃⌥⇧⌘F5")
        XCTAssertFalse(HotKeyShortcut(keyCode: 49, modifiers: [.control, .option]).mayBeRestrictedByCarbon)
    }

    func testShortcutCodableRoundTrip() throws {
        let s = HotKeyShortcut(keyCode: 49, modifiers: [.control, .shift])
        let data = try JSONEncoder().encode(s)
        XCTAssertEqual(try JSONDecoder().decode(HotKeyShortcut.self, from: data), s)
    }

    func testModifierMatchingIgnoresCapsLockAndFn() {
        let s = HotKeyShortcut.optionSpace
        XCTAssertTrue(s.matchesKeyDown(keyCode: 49, flags: [.maskAlternate]))
        XCTAssertTrue(s.matchesKeyDown(keyCode: 49, flags: [.maskAlternate, .maskAlphaShift, .maskSecondaryFn]))
        XCTAssertFalse(s.matchesKeyDown(keyCode: 49, flags: [.maskAlternate, .maskCommand]), "⌘⌥Space は別物")
        XCTAssertFalse(s.matchesKeyDown(keyCode: 49, flags: []))
        XCTAssertFalse(s.matchesKeyDown(keyCode: 36, flags: [.maskAlternate]))
    }

    func testEventTapDecision() {
        let s = HotKeyShortcut.optionSpace
        func decide(_ t: CGEventType, _ key: Int64, _ flags: CGEventFlags, repeat r: Bool = false, down: Bool) -> EventTapDecision {
            EventTapDecision.decide(type: t, keyCode: key, flags: flags, isAutorepeat: r, isDown: down, shortcut: s)
        }
        // 押下は横取りして通知（⌥Space で no-break space が入らない）
        XCTAssertEqual(decide(.keyDown, 49, [.maskAlternate], down: false), .swallow(deliver: .pressed))
        // 押下中のリピートは通知しないが横取りは続ける
        XCTAssertEqual(decide(.keyDown, 49, [.maskAlternate], repeat: true, down: true), .swallow(deliver: nil))
        // ⌥ を先に離してから Space を離しても解放になる
        XCTAssertEqual(decide(.keyUp, 49, [], down: true), .swallow(deliver: .released))
        // 押していないときの Space の keyUp や他キーは素通し
        XCTAssertEqual(decide(.keyUp, 49, [], down: false), .passThrough)
        XCTAssertEqual(decide(.keyDown, 49, [], down: false), .passThrough)
        XCTAssertEqual(decide(.keyDown, 0, [.maskAlternate], down: false), .passThrough)
        XCTAssertEqual(decide(.flagsChanged, 58, [.maskAlternate], down: false), .passThrough)
    }
}
