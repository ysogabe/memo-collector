import CCCore
import CCEmbedding
import CCGuard
import CCIntent
import CCSTT
import CCStore
import CCTriage
import CoreGraphics
import Foundation
import MLX
import XCTest

/// Wave 4 e2e: 本物の 3 モデル（Whisper / EmbeddingGemma 2 / d1-3B）を 1 プロセスに同時に載せ、
/// アプリ（app/ContextCapture/App/Live/）と同じ部品・同じ設定で、キャプチャ経路・トリアージ・メモリ・d1 の数値一致を測る。
///
/// - `CC_RUN_E2E=1` のときだけ走る（それ以外は XCTSkip）。モデルは `CC_MODELS_DIR`（読み取りのみ）。データは一時ディレクトリ
/// - 結果は `docs/e2e/results/<timestamp>-<config>.json`（`CC_E2E_OUT` で上書き）
/// - `CC_E2E_MLX_CACHE_LIMIT_MB`: 実験用。MLX のキャッシュ上限（MB）を製品の既定（256MB）から変えて測る。`unlimited` で上限なし
///   （Wave 4 の本計測と同じ条件）。config 名を変えること
/// - `CC_E2E_ROUNDS`（既定 3）、`CC_E2E_LIMIT`（1 周の件数、既定 30）。動作確認だけなら `CC_E2E_ROUNDS=1 CC_E2E_LIMIT=3`
/// - 入口は `scripts/e2e.sh`
final class E2EHarnessTests: XCTestCase {
    private let env = ProcessInfo.processInfo.environment

    func testEndToEnd() async throws {
        guard env["CC_RUN_E2E"] == "1" else { throw XCTSkip("CC_RUN_E2E=1 のときだけ走る（scripts/e2e.sh）") }
        let rounds = max(1, Int(env["CC_E2E_ROUNDS"] ?? "") ?? 3)
        let limit = max(1, min(30, Int(env["CC_E2E_LIMIT"] ?? "") ?? 30))

        let modelPaths = CCPaths.resolve()
        let fm = FileManager.default
        let whisperLayout = WhisperModelLayout(paths: modelPaths)
        guard whisperLayout.missingFiles().isEmpty else { throw XCTSkip("Whisper が無い: \(whisperLayout.root.path)") }
        let embeddingDir = modelPaths.modelDirectory(.embedding)
        let d1Dir = modelPaths.modelDirectory(.d1)
        guard fm.fileExists(atPath: embeddingDir.appendingPathComponent("EmbeddingGemma2Text.mlmodelc").path),
              fm.fileExists(atPath: d1Dir.appendingPathComponent("model.safetensors").path)
        else { throw XCTSkip("埋め込みか d1 が無い: \(modelPaths.modelsRoot.path)") }

        let tempRoot = fm.temporaryDirectory.appendingPathComponent("cc-e2e-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: tempRoot, withIntermediateDirectories: true)
        defer { try? fm.removeItem(at: tempRoot) }

        #if DEBUG
        let buildConfig = "debug"
        #else
        let buildConfig = "release"
        #endif
        let configName = env["CC_E2E_CONFIG"] ?? "swiftpm-\(buildConfig)"

        var out: [String: Any] = [
            "schema": "cc-e2e/1",
            "config": configName,
            "build_configuration": buildConfig,
            "rounds": rounds, "items_per_round": limit,
            "started_at": E2EEnvironment.iso(),
            "uptime_before": E2EEnvironment.uptime(),
            "load_average_before": E2EEnvironment.loadAverage(),
            "top_processes_before": E2EEnvironment.topProcesses(),
            "machine": E2EEnvironment.machine(),
            "models_root": modelPaths.modelsRoot.path,
            "screenshot_format": E2EScreenshotEncoder.writableFormats.first?.fileExtension ?? "none",
            "notes": [
                "アプリと同じ部品・設定: WhisperKitTranscriber(Configuration() 既定, 語彙 [] = アプリの既定設定), "
                    + "CoreMLEmbedder(imageTokens 280, text/vision とも cpuAndNeuralEngine), D1IntentClassifier, VisionSecretScanner, "
                    + "StoreScreenshotLoader, TriageQueue(Configuration() 既定)",
                "キャプチャ経路は AppCoordinator.save と同じ並び: 符号化（detached）と STT を並行 → スクショ書き込み → 音声（WAV を読んで）書き込み → insert。"
                    + "実機の解放→保存トーストにはさらに録音停止（recorder.stop）と撮影タスクの待ち・トースト表示が入る（このハーネスでは測れない）",
                "with_triage は保存直後に enqueue して間を空けずに次の件を始める（直前の記録のトリアージが裏で動いている状態。実使用より厳しい）。"
                    + "with_triage_paced は次の件の前に音声の長さだけ待つ（録音中に前の記録のトリアージが進む）。without_triage はキャプチャ後にまとめてトリアージ",
            ],
        ]
        XCTAssertEqual(E2EScreenshotEncoder.writableFormats.first?.fileExtension, "heic", "アプリと同じ HEIC になる前提")

        var memory: [String: Any] = [:]
        func snap(_ name: String) {
            let f = ProcessMemory.footprint()
            memory[name] = MemorySample(
                footprintMB: f.current, footprintLifetimePeakMB: f.peak, residentMB: ProcessMemory.residentMB(),
                mlxActiveMB: Double(Memory.activeMemory) / 1e6, mlxPeakMB: Double(Memory.peakMemory) / 1e6,
                mlxCacheMB: Double(Memory.cacheMemory) / 1e6
            ).json.merging(["at": E2EEnvironment.iso()]) { a, _ in a }
            print("E2E memory \(name): \(memory[name]!)")
        }
        snap("1_start")

        // ---- データ
        let ds = try E2EDataset.load()
        let screens = Dictionary(uniqueKeysWithValues: ds.screens.map { ($0.id, $0) })
        let items = Array(ds.captures.prefix(limit))
        var samples: [Int: [Float]] = [:]
        var images: [String: CGImage] = [:]
        for c in ds.captures { samples[c.id] = try E2EMedia.loadWav(E2EPaths.audioURL(captureID: c.id)) }
        for s in ds.screens { images[s.id] = try E2EMedia.loadImage(E2EPaths.screenURL(s.id)) }

        // ---- モデル（アプリの起動順: Whisper → 埋め込み。d1 は最初のトリアージで読み込まれるが、ここでは明示的に読んで時点を分ける）
        var loads: [String: Any] = [:]
        let transcriber = WhisperKitTranscriber(paths: modelPaths)
        var t = now()
        try await transcriber.prepare()
        loads["whisper_prepare_s"] = now() - t
        snap("2_after_whisper_load")

        let coreML = CoreMLEmbedder(configuration: .init(
            modelDirectory: embeddingDir, imageTokens: .tokens280,
            textComputeUnits: .cpuAndNeuralEngine, visionComputeUnits: .cpuAndNeuralEngine
        ))
        t = now()
        let embedReport = try await coreML.prepare(includeVision: true)
        loads["embedding_prepare_s"] = now() - t
        loads["embedding_prepare_report"] = [
            "text_load_s": embedReport.textLoadSeconds, "vision_load_s": embedReport.visionLoadSeconds,
            "first_inference_s": embedReport.firstInferenceSeconds,
            "note": "この xctest バイナリで初めてなら ANE の初回コンパイル（2.5〜3 分）を含む。計測からは除く",
        ]
        snap("3_after_embedding_prepare")

        // MLX のバッファキャッシュの上限。製品（`D1IntentClassifier` の既定）は `load()` で 256MB を設定する。
        // 実験用に `CC_E2E_MLX_CACHE_LIMIT_MB` で上書きできる（`unlimited` なら設定しない = Wave 4 の本計測と同じ無制限）。
        var mlxCacheLimit: Int? = D1IntentClassifier.defaultMLXCacheLimitBytes
        if let v = env["CC_E2E_MLX_CACHE_LIMIT_MB"] {
            if v == "unlimited" {
                mlxCacheLimit = nil
                out["mlx_cache_limit_mb_experiment"] = "unlimited"
            } else if let mb = Int(v) {
                mlxCacheLimit = mb << 20
                out["mlx_cache_limit_mb_experiment"] = mb
            }
        }
        out["mlx_cache_limit_bytes"] = mlxCacheLimit.map { $0 as Any } ?? NSNull()
        let d1 = D1IntentClassifier(modelDirectory: d1Dir, mlxCacheLimitBytes: mlxCacheLimit)
        let d1Load = try await d1.load()
        loads["d1_load_s"] = d1Load.loadSeconds
        loads["d1_tokenizer_load_s"] = d1Load.tokenizerSeconds
        snap("4_after_d1_load_3_models")

        // ---- 初回呼び出し（計測から除く。別欄）
        let scanner = VisionSecretScanner()
        var warm: [String: Any] = [:]
        let c0 = ds.captures[0], s0 = screens[c0.screen]!
        t = now(); _ = try? await transcriber.transcribe(samples: samples[c0.id]!, vocabulary: []); warm["stt_first_s"] = now() - t
        t = now(); _ = try await scanner.scan(image: images[s0.id]!); warm["guard_first_s"] = now() - t
        t = now(); _ = try await d1.classify(text: c0.text); warm["d1_first_s"] = now() - t
        t = now(); _ = try await coreML.embedDocument(text: c0.text, title: s0.window_title, image: images[s0.id]!); warm["embed_first_s"] = now() - t
        t = now(); _ = E2EScreenshotEncoder.encode(images[s0.id]!); warm["encode_first_s"] = now() - t
        loads["first_calls"] = warm
        out["model_loads"] = loads
        snap("5_after_warmup")

        // ---- d1 の数値一致（3 モデル同時に載った状態で。CCIntentTests/D1NumericsTests と同じ 52 件・同じ指標）
        out["d1_numerics"] = try await d1Numerics(d1)
        snap("6_after_d1_numerics")

        // ---- ガード: 14 画面を直接（PNG と、アプリが保存する HEIC を読み戻したもの）
        out["guard_screens_direct"] = try await guardDirect(scanner: scanner, ds: ds, images: images)

        // ---- キャプチャ経路とトリアージ
        Memory.peakMemory = 0
        let sampler = FootprintSampler(mlxActive: { Memory.activeMemory })
        sampler.start()
        var roundsOut: [[String: Any]] = []
        // with_triage: 保存直後に enqueue し、間を空けずに次の件（最悪に近い）。
        // with_triage_paced: 次の件の前にその音声の長さだけ待つ（話している間 = 録音中に前の記録のトリアージが進む。実使用に近い）。
        // without_triage: キャプチャ中はトリアージを走らせない（全件の後にまとめて流す = トリアージ単独の値）。
        let conditions = ["with_triage", "with_triage_paced", "without_triage"]
        var captureTotals: [String: [[Double]]] = [:]
        var captureParts: [String: [String: [Double]]] = [:]
        var triageSteps: [String: [TriageStep: [[Double]]]] = [:]
        var saveToTriaged: [String: [Double]] = [:]
        var busyAtStart: [String: Int] = [:]
        for c in conditions { captureTotals[c] = []; captureParts[c] = [:]; triageSteps[c] = [:]; saveToTriaged[c] = []; busyAtStart[c] = 0 }
        let embedForQueries = coreML
        for r in 0..<rounds {
            // 条件の順は周ごとに入れ替える（順序の偏りを避ける）
            let order = (0..<conditions.count).map { conditions[($0 + r) % conditions.count] }
            for cond in order {
                let withTriage = cond != "without_triage"
                let dataRoot = tempRoot.appendingPathComponent("r\(r)-\(cond)", isDirectory: true)
                let store = try SQLiteRecordStore(paths: CCPaths(dataRoot: dataRoot, modelsRoot: modelPaths.modelsRoot))
                let clock = StepClock()
                let queue = TriageQueue(
                    store: store,
                    classifier: TimedClassifier(inner: d1, clock: clock),
                    scanner: TimedScanner(inner: scanner, clock: clock),
                    embedder: TimedEmbedder(inner: coreML, clock: clock),
                    screenshots: StoreScreenshotLoader(store: store)
                )
                let log = TriageEventLog()
                await log.attach(await queue.events())
                let loadBefore = E2EEnvironment.loadAverage()
                let startedAt = E2EEnvironment.iso()

                var perItem: [[String: Any]] = []
                var totals: [Double] = []
                var idToCapture: [String: Int] = [:]
                var cerErr = 0, cerLen = 0
                for c in items {
                    let s = screens[c.screen]!
                    if cond == "with_triage_paced" {
                        try await Task.sleep(for: .seconds(Double(samples[c.id]!.count) / 16_000))
                    }
                    let busy = await queue.isBusy
                    if busy { busyAtStart[cond]! += 1 }
                    let timing = try await captureOne(
                        capture: c, screen: s, samples: samples[c.id]!, image: images[s.id]!,
                        transcriber: transcriber, store: store
                    )
                    var row = timing.json
                    row["capture_id"] = c.id
                    row["triage_busy_at_start"] = busy
                    if let id = timing.recordID {
                        idToCapture[id] = c.id
                        if withTriage {
                            await log.markEnqueued(id, at: now())
                            await queue.enqueue(id: id)
                        }
                        let (e, n) = CER.distance(ref: c.text, hyp: timing.transcript)
                        cerErr += e; cerLen += n
                    }
                    totals.append(timing.total)
                    for (k, v) in timing.parts { captureParts[cond]![k, default: []].append(v) }
                    perItem.append(row)
                }
                let captureFinishedAt = E2EEnvironment.iso()
                // without_triage: キャプチャを全部終えてから（STT と競合しない状態で）トリアージを流す
                if !withTriage {
                    let t0 = now()
                    for id in idToCapture.keys.sorted() {
                        await log.markEnqueued(id, at: t0)
                        await queue.enqueue(id: id)
                    }
                }
                await queue.waitUntilIdle()
                await log.waitForFinished(count: idToCapture.count)
                await log.stop()
                let steps = await clock.snapshot()
                let triaged = await log.saveToTriaged()
                let outcomes = await log.outcomes()
                captureTotals[cond]!.append(totals)
                for step in TriageStep.allCases { triageSteps[cond]![step, default: []].append(steps[step] ?? []) }
                if withTriage { saveToTriaged[cond]!.append(contentsOf: triaged.values) }

                let quality = try await evaluate(store: store, ds: ds, idToCapture: idToCapture, outcomes: outcomes, embedder: embedForQueries)
                roundsOut.append([
                    "round": r, "condition": cond, "started_at": startedAt, "capture_finished_at": captureFinishedAt,
                    "load_average_before": loadBefore, "load_average_after": E2EEnvironment.loadAverage(),
                    "capture_total_s": Stats.summary(totals),
                    "triage_step_s": Dictionary(uniqueKeysWithValues: TriageStep.allCases.map { ($0.rawValue, Stats.summary(steps[$0] ?? [])) }),
                    "save_to_triaged_s": Stats.summary(Array(triaged.values)),
                    "stt_cer": cerLen > 0 ? Double(cerErr) / Double(cerLen) : NSNull(),
                    "quality": quality,
                    "items": perItem,
                ])
                print("E2E round \(r) \(cond): capture p50 \(Stats.percentile(totals, 0.5) ?? -1) p90 \(Stats.percentile(totals, 0.9) ?? -1)")
            }
        }
        let peak = sampler.stop()
        snap("7_after_rounds")
        memory["peak_during_capture_and_triage"] = peak.merging(["mlx_peak_mb": Double(Memory.peakMemory) / 1e6]) { a, _ in a }

        // ---- d1 の解放（アプリでは 10 分使われなければ TriageQueue が unload する。同じ unload を直接呼ぶ）
        await d1.unload()
        try? await Task.sleep(for: .seconds(2))
        snap("8_after_d1_unload_idle_2_models")

        // ---- まとめ
        var summary: [String: Any] = [:]
        for cond in conditions {
            var parts: [String: Any] = [:]
            for (k, v) in captureParts[cond]! { parts[k] = Stats.summary(v) }
            var steps: [String: Any] = [:]
            for step in TriageStep.allCases { steps[step.rawValue] = Stats.rounds(triageSteps[cond]![step] ?? []) }
            summary[cond] = [
                "capture_total_s": Stats.rounds(captureTotals[cond]!),
                "capture_parts_s": parts,
                "triage_step_s": steps,
                "save_to_triaged_s": Stats.summary(saveToTriaged[cond]!),
                "captures_started_while_triage_busy": busyAtStart[cond]!,
            ]
        }
        out["summary"] = summary
        out["rounds_detail"] = roundsOut
        out["memory"] = memory
        out["finished_at"] = E2EEnvironment.iso()
        out["uptime_after"] = E2EEnvironment.uptime()
        out["load_average_after"] = E2EEnvironment.loadAverage()

        let url: URL
        if let p = env["CC_E2E_OUT"], !p.isEmpty {
            url = URL(fileURLWithPath: p)
        } else {
            let f = DateFormatter()
            f.dateFormat = "yyyyMMdd-HHmmss"
            url = E2EPaths.resultsDir.appendingPathComponent("\(f.string(from: Date()))-\(configName).json")
        }
        try fm.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
        let data = try JSONSerialization.data(withJSONObject: Self.sanitize(out), options: [.prettyPrinted, .sortedKeys])
        try data.write(to: url)
        print("E2E results: \(url.path)")
    }

    // MARK: - キャプチャ 1 件（AppCoordinator.save と同じ並び）

    struct CaptureTiming {
        var recordID: String?
        var transcript: String
        var total: Double
        var parts: [String: Double]
        var noSpeech: Bool

        var json: [String: Any] {
            ["record_id": recordID ?? NSNull(), "total_s": total, "parts_s": parts, "no_speech": noSpeech, "transcript": transcript]
        }
    }

    private func captureOne(
        capture c: E2EDataset.Capture, screen s: E2EDataset.Screen, samples: [Float], image: CGImage,
        transcriber: WhisperKitTranscriber, store: SQLiteRecordStore
    ) async throws -> CaptureTiming {
        let t0 = now()
        let capturedAt = Date().roundedToMilliseconds
        // 符号化（重い）は文字起こしと並行に（AppCoordinator と同じ detached / userInitiated）
        let encodeTask = Task.detached(priority: .userInitiated) { () -> ((data: Data, fileExtension: String)?, Double) in
            let t = now()
            let e = E2EScreenshotEncoder.encode(image)
            return (e, now() - t)
        }
        var parts: [String: Double] = [:]
        var t = now()
        let transcript: Transcript
        do {
            transcript = try await transcriber.transcribe(samples: samples, vocabulary: [])
        } catch STTError.noSpeech {
            encodeTask.cancel()
            return CaptureTiming(recordID: nil, transcript: "", total: now() - t0, parts: ["stt": now() - t], noSpeech: true)
        }
        parts["stt"] = now() - t
        t = now()
        let (encoded, encodeSeconds) = await encodeTask.value
        parts["encode_wait_after_stt"] = now() - t
        parts["encode"] = encodeSeconds

        let id = ULID.generate(now: capturedAt).string
        t = now()
        var screenshotPath: String?
        if let encoded {
            screenshotPath = try await store.writeAttachment(encoded.data, id: id, kind: .screenshot, ext: encoded.fileExtension, capturedAt: capturedAt)
        }
        parts["write_screenshot"] = now() - t
        t = now()
        let audioData = try Data(contentsOf: E2EPaths.audioURL(captureID: c.id))
        let audioPath = try await store.writeAttachment(audioData, id: id, kind: .audio, ext: "wav", capturedAt: capturedAt)
        parts["write_audio"] = now() - t
        t = now()
        let record = ContextRecord(
            id: id, capturedAt: capturedAt,
            app: AppInfo(name: s.app, bundleID: nil),
            window: WindowInfo(title: s.window_title, frame: nil),
            url: s.url,
            extra: ["e2e_capture_id": String(c.id), "e2e_screen": s.id],
            screenshotPath: screenshotPath, audioPath: audioPath,
            annotation: Annotation(text: transcript.text, sttEngine: transcript.engine),
            guardInfo: GuardInfo(status: .pending)
        )
        try await store.insert(record)
        parts["insert"] = now() - t
        parts["save_total"] = (parts["write_screenshot"] ?? 0) + (parts["write_audio"] ?? 0) + (parts["insert"] ?? 0)
        return CaptureTiming(recordID: id, transcript: transcript.text, total: now() - t0, parts: parts, noSpeech: false)
    }

    // MARK: - 品質（意図・ガード・検索）

    private func evaluate(
        store: SQLiteRecordStore, ds: E2EDataset, idToCapture: [String: Int],
        outcomes: [String: [TriageStep: TriageStepOutcome]], embedder: CoreMLEmbedder
    ) async throws -> [String: Any] {
        let captures = Dictionary(uniqueKeysWithValues: ds.captures.map { ($0.id, $0) })
        let screens = Dictionary(uniqueKeysWithValues: ds.screens.map { ($0.id, $0) })
        var top1 = 0, thresholded = 0, unclassified = 0, datetime = 0, n = 0
        var screenFlag: [String: Bool] = [:]
        var notSucceeded: [String] = []
        for (id, cid) in idToCapture {
            guard let r = try await store.get(id: id), let c = captures[cid] else { continue }
            n += 1
            for (step, o) in outcomes[id] ?? [:] where o != .succeeded { notSucceeded.append("\(cid):\(step.rawValue):\(o)") }
            if let tr = r.triage {
                if let probs = tr.intentProbabilities, let best = Intent.allCases.max(by: { (probs[$0] ?? 0) < (probs[$1] ?? 0) }),
                   best.rawValue == c.intent { top1 += 1 }
                if let i = tr.intent { if i.rawValue == c.intent { thresholded += 1 } } else { unclassified += 1 }
                if tr.mentionsDatetime == c.has_deadline { datetime += 1 }
            }
            let flagged = r.guardInfo.status == .needsReview
            screenFlag[c.screen] = (screenFlag[c.screen] ?? false) || flagged
        }
        var tp = 0, fp = 0, fn = 0
        for (sid, flagged) in screenFlag {
            let secret = screens[sid]?.contains_secret ?? false
            if flagged && secret { tp += 1 } else if flagged { fp += 1 } else if secret { fn += 1 }
        }
        // 検索: 本番と同じく embedQuery → store.search（この周の 30 件だけが入ったストア）
        var hits3: [Double] = [], rr: [Double] = []
        for q in ds.text_queries {
            let v = try await embedder.embedQuery(q.q)
            let hits = try await store.search(vector: v, limit: idToCapture.count)
            let order = hits.compactMap { $0.record.extra["e2e_capture_id"].flatMap(Int.init) }
            let rel = Set(q.relevant)
            hits3.append(Double(rel.intersection(order.prefix(3)).count) / Double(min(3, rel.count)))
            rr.append(order.firstIndex(where: { rel.contains($0) }).map { 1 / Double($0 + 1) } ?? 0)
        }
        return [
            "records": n,
            "intent_top1_correct": top1, "intent_thresholded_correct": thresholded, "intent_unclassified": unclassified,
            "datetime_correct": datetime,
            "guard_screens": ["seen": screenFlag.count, "tp": tp, "fp": fp, "fn": fn,
                              "secret_screens_seen": screenFlag.keys.filter { screens[$0]?.contains_secret == true }.count],
            "text_query_r_at_3": hits3.isEmpty ? NSNull() : hits3.reduce(0, +) / Double(hits3.count),
            "text_query_mrr": rr.isEmpty ? NSNull() : rr.reduce(0, +) / Double(rr.count),
            "steps_not_succeeded": notSucceeded.sorted(),
        ]
    }

    // MARK: - ガード（14 画面を直接）

    private func guardDirect(scanner: VisionSecretScanner, ds: E2EDataset, images: [String: CGImage]) async throws -> [String: Any] {
        var rows: [[String: Any]] = []
        var tpPNG = 0, fpPNG = 0, tpHEIC = 0, fpHEIC = 0
        var lat: [Double] = []
        for s in ds.screens {
            let img = images[s.id]!
            let t = now()
            let fPNG = try await scanner.scan(image: img)
            lat.append(now() - t)
            let heic = E2EScreenshotEncoder.encode(img)!
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("e2e-\(s.id).\(heic.fileExtension)")
            try heic.data.write(to: url)
            // CGImageSource の画像は遅延デコードなので、ファイルは走査が終わってから消す（先に消すと真っ白な画像を OCR する）
            let back = try E2EMedia.loadImage(url)
            let fHEIC = try await scanner.scan(image: back)
            try? FileManager.default.removeItem(at: url)
            if !fPNG.isEmpty { if s.contains_secret { tpPNG += 1 } else { fpPNG += 1 } }
            if !fHEIC.isEmpty { if s.contains_secret { tpHEIC += 1 } else { fpHEIC += 1 } }
            rows.append(["screen": s.id, "contains_secret": s.contains_secret, "png_findings": fPNG.map(\.kind),
                         "heic_findings": fHEIC.map(\.kind), "heic_bytes": heic.data.count])
        }
        let secrets = ds.screens.filter(\.contains_secret).count
        return ["secret_screens": secrets, "png": ["tp": tpPNG, "fp": fpPNG], "heic": ["tp": tpHEIC, "fp": fpHEIC],
                "png_scan_s": Stats.summary(lat), "screens": rows]
    }

    // MARK: - d1 の数値一致（D1NumericsTests と同じ指標）

    private func d1Numerics(_ clf: D1IntentClassifier) async throws -> [String: Any] {
        let ref = try D1Reference.load()
        let labels = Intent.allCases.map(\.rawValue)
        func argmax(_ p: [Double]) -> Int { p.indices.max { p[$0] < p[$1] }! }
        var maxIntent = 0.0, maxDeadline = 0.0
        var top1 = 0, dtTop1 = 0
        var correct: [String: Int] = [:], total: [String: Int] = [:]
        var rows: [[String: Any]] = []
        var lats: [Double] = []
        for row in ref.rows {
            let iq = row.q["intent"]!, dq = row.q["deadline"]!
            let t = now()
            let p = try await clf.probabilities(text: row.text)
            lats.append(now() - t)
            let pd = [p.datetime, 1 - p.datetime]
            maxIntent = max(maxIntent, zip(p.intent, iq.chain_probs).map { abs($0 - $1) }.max()!)
            maxDeadline = max(maxDeadline, zip(pd, dq.chain_probs).map { abs($0 - $1) }.max()!)
            if argmax(p.intent) == argmax(iq.chain_probs) { top1 += 1 }
            if argmax(pd) == argmax(dq.chain_probs) { dtTop1 += 1 }
            total[row.split, default: 0] += 1
            if labels[argmax(p.intent)] == row.gold_intent { correct[row.split, default: 0] += 1 }
            rows.append(["id": row.id, "intent": p.intent, "datetime": p.datetime])
        }
        return [
            "intent_max_abs_dp_vs_chain": maxIntent, "datetime_max_abs_dp_vs_chain": maxDeadline,
            "intent_top1_agree_chain": "\(top1)/\(ref.rows.count)", "datetime_top1_agree_chain": "\(dtTop1)/\(ref.rows.count)",
            "accuracy_dev": "\(correct["dev"] ?? 0)/\(total["dev"] ?? 0)",
            "accuracy_holdout": "\(correct["holdout"] ?? 0)/\(total["holdout"] ?? 0)",
            "latency_2q_s": Stats.summary(lats),
            "tolerance": 0.05,
            "rows": rows,
        ]
    }

    // MARK: - JSON

    /// JSONSerialization は NaN / 無限大を書けないので null にする。
    static func sanitize(_ v: Any) -> Any {
        switch v {
        case let d as Double: return d.isFinite ? d : NSNull()
        case let a as [Any]: return a.map(sanitize)
        case let m as [String: Any]: return m.mapValues(sanitize)
        default: return v
        }
    }
}
