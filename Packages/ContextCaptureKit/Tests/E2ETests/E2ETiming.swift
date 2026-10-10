import CCCore
import CCTriage
import CoreGraphics
import Foundation

// トリアージの各ステップの所要時間を、製品コードに手を入れずに測るための薄い包み。
// `TriageQueue` に本物の代わりにこれを渡す（中身は本物をそのまま呼ぶ）。キューは直列なので、呼ばれた順 = 処理した順。

actor StepClock {
    private(set) var durations: [TriageStep: [Double]] = [:]

    func add(_ step: TriageStep, _ seconds: Double) {
        durations[step, default: []].append(seconds)
    }

    func reset() { durations = [:] }

    func snapshot() -> [TriageStep: [Double]] { durations }
}

struct TimedScanner: SecretScanning {
    let inner: any SecretScanning
    let clock: StepClock

    func scan(image: CGImage) async throws -> [SecretFinding] {
        let t = now()
        do {
            let r = try await inner.scan(image: image)
            await clock.add(.guardScan, now() - t)
            return r
        } catch {
            await clock.add(.guardScan, now() - t)
            throw error
        }
    }
}

struct TimedClassifier: IntentClassifying, ModelUnloadable {
    let inner: any IntentClassifying & ModelUnloadable
    let clock: StepClock

    func classify(text: String) async throws -> TriageResult {
        let t = now()
        do {
            let r = try await inner.classify(text: text)
            await clock.add(.intent, now() - t)
            return r
        } catch {
            await clock.add(.intent, now() - t)
            throw error
        }
    }

    func unload() async { await inner.unload() }
    var isLoaded: Bool { get async { await inner.isLoaded } }
}

struct TimedEmbedder: Embedder {
    let inner: any Embedder
    let clock: StepClock
    var dimension: Int { inner.dimension }

    func embedQuery(_ text: String) async throws -> [Float] {
        try await inner.embedQuery(text)
    }

    func embedDocument(text: String, title: String?, image: CGImage?) async throws -> [Float] {
        let t = now()
        do {
            let r = try await inner.embedDocument(text: text, title: title, image: image)
            await clock.add(.index, now() - t)
            return r
        } catch {
            await clock.add(.index, now() - t)
            throw error
        }
    }
}

/// `TriageQueue.events()` を時刻つきで貯める。
actor TriageEventLog {
    struct Entry {
        var at: Double
        var event: TriageEvent
    }

    private(set) var entries: [Entry] = []
    private var enqueuedAt: [String: Double] = [:]
    private var task: Task<Void, Never>?

    func attach(_ stream: AsyncStream<TriageEvent>) {
        task = Task { [weak self] in
            for await e in stream {
                await self?.append(Entry(at: now(), event: e))
            }
        }
    }

    private func append(_ e: Entry) { entries.append(e) }

    func markEnqueued(_ id: String, at t: Double) { enqueuedAt[id] = t }

    /// 保存（enqueue）からその記録のトリアージが全部終わるまでの秒数（キュー待ちを含む）。
    func saveToTriaged() -> [String: Double] {
        var out: [String: Double] = [:]
        for e in entries {
            if case let .recordFinished(id) = e.event, let t0 = enqueuedAt[id] { out[id] = e.at - t0 }
        }
        return out
    }

    /// ステップごとの結果（id → step → outcome）。
    func outcomes() -> [String: [TriageStep: TriageStepOutcome]] {
        var out: [String: [TriageStep: TriageStepOutcome]] = [:]
        for e in entries {
            if case let .stepFinished(id, step, outcome) = e.event { out[id, default: [:]][step] = outcome }
        }
        return out
    }

    /// recordFinished が `count` 件たまるまで待つ（イベントの配送は非同期なので waitUntilIdle の直後には揃っていないことがある）。
    func waitForFinished(count: Int, timeout: Double = 10) async {
        let deadline = now() + timeout
        while now() < deadline {
            let n = entries.filter { if case .recordFinished = $0.event { return true } else { return false } }.count
            if n >= count { return }
            try? await Task.sleep(for: .milliseconds(20))
        }
    }

    func stop() { task?.cancel() }
}
