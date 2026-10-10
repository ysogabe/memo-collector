import XCTest
@testable import CCCore

final class ULIDTests: XCTestCase {
    func testFormat() {
        let s = ULID.generate().string
        XCTAssertEqual(s.count, 26)
        XCTAssertTrue(ULID.isValid(s), s)
        XCTAssertNil(s.rangeOfCharacter(from: CharacterSet(charactersIn: "ILOU")))
        XCTAssertNotNil(ULID(string: s.lowercased()), "小文字も受け付けて大文字に揃える")
    }

    func testRejectsInvalid() {
        XCTAssertNil(ULID(string: ""))
        XCTAssertNil(ULID(string: "01JA9Z3K8Q4V7X2M5N6P8R0T1"))     // 25 文字
        XCTAssertNil(ULID(string: "01JA9Z3K8Q4V7X2M5N6P8R0T1I"))    // I は使わない
        XCTAssertNil(ULID(string: "81JA9Z3K8Q4V7X2M5N6P8R0T1W"))    // 先頭 8 は 128bit を超える
    }

    func testKnownEncoding() {
        // 時刻 0・乱数 0 は全部 0、時刻最大・乱数最大は 7ZZZ…。
        XCTAssertEqual(ULID(timeMs: 0, randomHi: 0, randomLo: 0).string, String(repeating: "0", count: 26))
        XCTAssertEqual(ULID(timeMs: (1 << 48) - 1, randomHi: .max, randomLo: .max).string, "7" + String(repeating: "Z", count: 25))
        XCTAssertEqual(ULID(timeMs: 0, randomHi: 0, randomLo: 1).string, String(repeating: "0", count: 25) + "1")
        XCTAssertEqual(ULID(timeMs: 1, randomHi: 0, randomLo: 0).string, "0000000001" + String(repeating: "0", count: 16))
    }

    func testTimestampRoundTrip() {
        let now = Date(timeIntervalSince1970: 1_791_468_932.123)
        let id = ULIDGenerator().next(now: now)
        XCTAssertEqual(id.timestamp.timeIntervalSince1970, 1_791_468_932.123, accuracy: 0.0011)
    }

    func testMonotonicWithinSameMillisecond() {
        let gen = ULIDGenerator()
        let fixed = Date(timeIntervalSince1970: 1_791_468_932)
        var prev = gen.next(now: fixed)
        for _ in 0..<1000 {
            let next = gen.next(now: fixed)
            XCTAssertLessThan(prev, next)
            XCTAssertEqual(next.string.prefix(10), prev.string.prefix(10), "時刻部は同じ")
            prev = next
        }
    }

    func testMonotonicWhenClockGoesBackwards() {
        let gen = ULIDGenerator()
        let a = gen.next(now: Date(timeIntervalSince1970: 2_000_000_000))
        let b = gen.next(now: Date(timeIntervalSince1970: 1_000_000_000))
        XCTAssertLessThan(a, b)
    }

    func testMonotonicAcrossThreads() {
        let gen = ULIDGenerator()
        let lock = NSLock()
        var all: [ULID] = []
        DispatchQueue.concurrentPerform(iterations: 8) { _ in
            var local: [ULID] = []
            for _ in 0..<500 { local.append(gen.next()) }
            XCTAssertEqual(local, local.sorted(), "各スレッド内で増加")
            lock.lock(); all.append(contentsOf: local); lock.unlock()
        }
        XCTAssertEqual(Set(all).count, all.count, "重複なし")
    }

    func testCodable() throws {
        let id = ULID.generate()
        let data = try JSONEncoder().encode([id])
        XCTAssertEqual(try JSONDecoder().decode([ULID].self, from: data), [id])
        XCTAssertThrowsError(try JSONDecoder().decode([ULID].self, from: Data(#"["nope"]"#.utf8)))
    }
}
