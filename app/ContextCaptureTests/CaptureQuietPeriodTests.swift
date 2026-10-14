import Foundation
import XCTest

@MainActor
final class CaptureQuietPeriodTests: XCTestCase {
    actor ManualSleep {
        var count = 0
        var sleepers: [CheckedContinuation<Void, Never>] = []
        var observers: [(Int, CheckedContinuation<Void, Never>)] = []
        func sleep(_ duration: Duration) async {
            await withCheckedContinuation { continuation in
                count += 1; sleepers.append(continuation)
                let ready = observers.filter { $0.0 <= count }; observers.removeAll { $0.0 <= count }
                ready.forEach { $0.1.resume() }
            }
        }
        func waitForRequests(_ target: Int) async {
            if count >= target { return }
            await withCheckedContinuation { observers.append((target, $0)) }
        }
        func releaseAll() { let pending = sleepers; sleepers = []; pending.forEach { $0.resume() } }
    }
    final class Queue: TriageQueuing, @unchecked Sendable {
        let states = Box<[Bool]>([])
        func enqueue(id: String) async {}
        func annotationEdited(id: String) async {}
        func reindex(id: String) async {}
        func resumePending() async throws -> Int { 0 }
        func waitUntilIdle() async {}
        func setCapturing(_ active: Bool) async { states.update { $0.append(active) } }
    }
    func testDefaultStillResumesImmediately() async {
        let q = Queue()
        let tested = TriageWiring(queue: q)
        tested.captureActivityChanged(true); tested.captureActivityChanged(false)
        await tested.waitForCaptureActivityForwarded()
        XCTAssertEqual(q.states.get(), [true, false])
    }
    func testQuietPeriodDelaysResumeAndEventuallyReleasesQueue() async {
        let q = Queue(), gate = ManualSleep()
        let wiring = TriageWiring(queue: q, postCaptureQuietPeriod: .milliseconds(750), quietSleep: { await gate.sleep($0) })
        wiring.captureActivityChanged(true)
        await wiring.waitForCaptureActivityForwarded()
        wiring.captureActivityChanged(false)
        await gate.waitForRequests(1)
        XCTAssertEqual(q.states.get(), [true])
        await gate.releaseAll(); await wiring.waitForCaptureQuietPeriod()
        XCTAssertEqual(q.states.get(), [true, false])
    }
    func testNewCaptureInvalidatesOldResumeEvenWhenSleepIgnoresCancellation() async {
        let q = Queue(), gate = ManualSleep()
        let wiring = TriageWiring(queue: q, postCaptureQuietPeriod: .milliseconds(750), quietSleep: { await gate.sleep($0) })
        wiring.captureActivityChanged(true)
        wiring.captureActivityChanged(false)
        await gate.waitForRequests(1)
        let stale = wiring.quietResumeTask
        wiring.captureActivityChanged(true)
        await wiring.waitForCaptureActivityForwarded()
        await gate.releaseAll(); await stale?.value
        XCTAssertEqual(q.states.get(), [true, true])
        wiring.captureActivityChanged(false)
        await gate.waitForRequests(2)
        await gate.releaseAll(); await wiring.waitForCaptureQuietPeriod()
        XCTAssertEqual(q.states.get(), [true, true, false])
    }
    func testOnlyLatestQuietPeriodResumes() async {
        let q = Queue(), gate = ManualSleep()
        let wiring = TriageWiring(queue: q, postCaptureQuietPeriod: .milliseconds(750), quietSleep: { await gate.sleep($0) })
        wiring.captureActivityChanged(true); wiring.captureActivityChanged(false)
        await gate.waitForRequests(1)
        let stale = wiring.quietResumeTask
        wiring.captureActivityChanged(false)
        await gate.waitForRequests(2)
        await gate.releaseAll(); await stale?.value; await wiring.waitForCaptureQuietPeriod()
        XCTAssertEqual(q.states.get(), [true, false])
    }
    func testReleasedWiringDoesNotLeaveLiveQueuePaused() async {
        let q = Queue(), gate = ManualSleep()
        var wiring: TriageWiring? = TriageWiring(queue: q, postCaptureQuietPeriod: .milliseconds(750), quietSleep: { await gate.sleep($0) })
        wiring!.captureActivityChanged(true)
        await wiring!.waitForCaptureActivityForwarded()
        wiring!.captureActivityChanged(false)
        await gate.waitForRequests(1)
        let pending = wiring!.quietResumeTask
        wiring = nil
        await gate.releaseAll(); await pending?.value
        XCTAssertEqual(q.states.get(), [true, false])
    }
}
