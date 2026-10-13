import CoreGraphics
import XCTest
@testable import CCCapture

final class WindowMatcherTests: XCTestCase {
    private let pid: pid_t = 4242
    private let other: pid_t = 99

    private func c(_ id: CGWindowID, pid: pid_t? = nil, _ title: String?, _ frame: CGRect, layer: Int = 0, on: Bool = true, z: Int?) -> WindowCandidate {
        WindowCandidate(windowID: id, pid: pid ?? self.pid, title: title, frame: frame, layer: layer, isOnScreen: on, zIndex: z)
    }

    private let editor = CGRect(x: 100, y: 50, width: 1200, height: 800)
    private let side = CGRect(x: 1400, y: 50, width: 400, height: 600)

    func testFrameMatchWins() {
        let list = [
            c(1, "README.md — repo", side, z: 0),
            c(2, "main.swift — repo", editor, z: 1),
            c(3, pid: other, "main.swift — repo", editor, z: 2),
        ]
        let m = WindowMatcher.bestMatch(candidates: list, pid: pid, axFrame: editor.offsetBy(dx: 1, dy: -1), axTitle: nil)
        XCTAssertEqual(m?.windowID, 2, "誤差 2pt 以内で frame 一致、別 pid は除外")
    }

    func testFrameTieBrokenByTitleThenZ() {
        let list = [
            c(1, "Tab A", editor, z: 0),
            c(2, "Tab B", editor, z: 1),
        ]
        XCTAssertEqual(WindowMatcher.bestMatch(candidates: list, pid: pid, axFrame: editor, axTitle: "Tab B")?.windowID, 2)
        XCTAssertEqual(WindowMatcher.bestMatch(candidates: list, pid: pid, axFrame: editor, axTitle: "Other")?.windowID, 1)
    }

    func testTitleMatchWhenFrameDiffers() {
        let list = [
            c(1, "Inbox", side, z: 0),
            c(2, "Issue #128", editor, z: 1),
        ]
        let m = WindowMatcher.bestMatch(candidates: list, pid: pid, axFrame: CGRect(x: 0, y: 0, width: 10, height: 10), axTitle: "Issue #128")
        XCTAssertEqual(m?.windowID, 2)
    }

    func testFallbackToFrontmostNormalWindowOfApp() {
        let list = [
            c(9, pid: other, "Other app", editor, z: 0),
            c(1, nil, CGRect(x: 0, y: 0, width: 300, height: 24), layer: 25, z: 1),  // メニューバー項目等
            c(2, "Back", side, z: 5),
            c(3, "Front", editor, z: 2),
            c(4, "Offscreen", editor, on: false, z: nil),
        ]
        // AX が無い（権限なし）ときは pid の最前面の通常ウインドウ
        XCTAssertEqual(WindowMatcher.bestMatch(candidates: list, pid: pid, axFrame: nil, axTitle: nil)?.windowID, 3)
    }

    func testNoCandidatesForPid() {
        let list = [c(1, pid: other, "x", editor, z: 0), c(2, "tiny", CGRect(x: 0, y: 0, width: 1, height: 1), z: 0)]
        XCTAssertNil(WindowMatcher.bestMatch(candidates: list, pid: pid, axFrame: editor, axTitle: "x"))
    }

    func testDisplaySelection() {
        let displays = [CGRect(x: 0, y: 0, width: 1512, height: 982), CGRect(x: 1512, y: -200, width: 2560, height: 1440)]
        XCTAssertEqual(WindowMatcher.displayIndex(containing: CGRect(x: 2000, y: 100, width: 800, height: 600), displays: displays), 1)
        XCTAssertEqual(WindowMatcher.displayIndex(containing: CGRect(x: 10, y: 10, width: 100, height: 100), displays: displays), 0)
        XCTAssertNil(WindowMatcher.displayIndex(containing: CGRect(x: -5000, y: 0, width: 10, height: 10), displays: displays))
        XCTAssertNil(WindowMatcher.displayIndex(containing: nil, displays: displays))
    }
}
