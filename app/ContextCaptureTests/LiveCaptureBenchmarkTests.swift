import CCCapture
import CCCore
import CCEmbedding
import CCGuard
import CCIntent
import CCSTT
import CCStore
import CCTriage
import CoreGraphics
import Darwin
import Foundation
import ImageIO
import XCTest

/// Opt-in: actual AppCoordinator + TriageWiring + SQLite and three real models.
/// Hardware is replayed from authored fixtures; never accesses microphone, screen or user DB.
@MainActor
final class LiveCaptureBenchmarkTests: XCTestCase {
    struct Dataset: Decodable {
        struct Capture: Decodable { var id:Int; var screen:String; var text:String }
        struct Screen: Decodable { var id:String; var app:String; var window_title:String; var url:String? }
        var captures:[Capture];var screens:[Screen]
    }
    struct Memory {
        static func snapshot() -> [String:Double] {
            var info=task_vm_info_data_t(), count=mach_msg_type_number_t(MemoryLayout<task_vm_info_data_t>.size/MemoryLayout<natural_t>.size)
            let status=withUnsafeMutablePointer(to:&info) { $0.withMemoryRebound(to:integer_t.self,capacity:Int(count)) { task_info(mach_task_self_,task_flavor_t(TASK_VM_INFO),$0,&count) } }
            var usage=rusage();getrusage(RUSAGE_SELF,&usage)
            return ["physicalMB":status==KERN_SUCCESS ? Double(info.phys_footprint)/1e6 : -1,
                    "lifetimePeakPhysicalMB":status==KERN_SUCCESS ? Double(info.ledger_phys_footprint_peak)/1e6 : -1,
                    "lifetimePeakRSSMB":Double(usage.ru_maxrss)/1e6]
        }
    }
    func testReplayCaptureWithRealModels() async throws {
        let env=ProcessInfo.processInfo.environment
        guard env["CC_RUN_CAPTURE_BENCH"]=="1" else { throw XCTSkip("opt-in real-model capture benchmark") }
        guard let modelRoot=env["CC_MODELS_DIR"], let output=env["CC_CAPTURE_BENCH_OUT"] else { throw NSError(domain:"missing benchmark environment",code:1) }
        let phases=URL(fileURLWithPath:output+".phases.jsonl")
        func mark(_ phase:String) throws {
            let row:[String:Any]=["phase":phase,"epochSeconds":Date().timeIntervalSince1970,"pid":getpid()]
            let data=try JSONSerialization.data(withJSONObject:row,options:[.sortedKeys])+Data([10])
            if !FileManager.default.fileExists(atPath:phases.path) { try Data().write(to:phases) }
            let file=try FileHandle(forWritingTo:phases);defer { try? file.close() }
            try file.seekToEnd();try file.write(contentsOf:data)
        }
        try Data().write(to:phases,options:.atomic)
        try mark("started")
        let root=URL(fileURLWithPath:#filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let fixtures=root.appendingPathComponent("poc/fixtures")
        let dataset=try JSONDecoder().decode(Dataset.self,from:Data(contentsOf:fixtures.appendingPathComponent("dataset.json")))
        let screens=Dictionary(uniqueKeysWithValues:dataset.screens.map { ($0.id,$0) })
        let limit=max(3,min(30,Int(env["CC_CAPTURE_BENCH_LIMIT"] ?? "10") ?? 10))
        let captures=Array(dataset.captures.prefix(limit))
        let paths=CCPaths(dataRoot:FileManager.default.temporaryDirectory.appendingPathComponent("cc-live-capture-\(UUID().uuidString)"),modelsRoot:URL(fileURLWithPath:modelRoot))
        defer { try? FileManager.default.removeItem(at:paths.dataRoot) }
        try FileManager.default.createDirectory(at:paths.dataRoot,withIntermediateDirectories:true)
        let transcriber=WhisperKitTranscriber(paths:paths)
        let config=CoreMLEmbedder.Configuration.app(modelDirectory:paths.modelDirectory(.embedding),imageTokens:280)
        let embedder=CoreMLEmbedder(configuration:config)
        let classifier=D1IntentClassifier(modelDirectory:paths.modelDirectory(.d1))
        let scanner=VisionSecretScanner()
        let clock=ContinuousClock()
        func milliseconds(_ start:ContinuousClock.Instant) -> Double {
            let c=start.duration(to:clock.now).components
            return Double(c.seconds)*1000+Double(c.attoseconds)/1e15
        }
        func cpuSeconds()->Double {
            var usage=rusage();getrusage(RUSAGE_SELF,&usage)
            return Double(usage.ru_utime.tv_sec+usage.ru_stime.tv_sec)+Double(usage.ru_utime.tv_usec+usage.ru_stime.tv_usec)/1e6
        }
        func summary(_ values:[Double]) -> [String:Any] {
            func p(_ quantile:Double)->Double { let s=values.sorted();return s[max(0,Int(ceil(Double(s.count)*quantile))-1)] }
            return ["count":values.count,"p50Ms":p(0.5),"p90Ms":p(0.9),"p95Ms":p(0.95),"maxMs":values.max()!,"valuesMs":values]
        }
        var loads:[String:Double]=[:], snapshots:[String:[String:Double]]=["start":Memory.snapshot()]
        var start=clock.now;try await transcriber.prepare();loads["whisperMs"]=milliseconds(start);snapshots["whisper"]=Memory.snapshot()
        start=clock.now;_ = try await embedder.prepare(includeVision:true);loads["embeddingMs"]=milliseconds(start);snapshots["embedding"]=Memory.snapshot()
        start=clock.now;_ = try await classifier.load();loads["intentMs"]=milliseconds(start);snapshots["threeModels"]=Memory.snapshot()
        var audios:[Int:[Float]]=[:],images:[String:CGImage]=[:]
        for c in captures { audios[c.id]=try AudioFileIO.readMono16k(url:fixtures.appendingPathComponent(String(format:"audio/c%02d.wav",c.id))) }
        for screen in screens.values {
            let url=fixtures.appendingPathComponent("screens/\(screen.id).png")
            guard let source=CGImageSourceCreateWithURL(url as CFURL,nil),let image=CGImageSourceCreateImageAtIndex(source,0,nil) else { throw NSError(domain:"fixture image missing",code:1) }
            images[screen.id]=image
        }
        // Warm actual fixture audio separately; first-call specialization is not a warm capture.
        start=clock.now;_ = try await transcriber.transcribe(samples:audios[captures[0].id]!,vocabulary:[]);loads["firstFixtureSTTMs"]=milliseconds(start)
        // Warm inference separately from measured capture/triage.
        _ = try await classifier.classify(text:captures[0].text)
        _ = try await embedder.embedDocument(text:captures[0].text,title:screens[captures[0].screen]!.window_title,image:images[captures[0].screen])
        snapshots["warm"]=Memory.snapshot();try mark("ready")
        var reports:[String:Any]=[:]
        for condition in ["without_triage","with_triage"] {
            try mark(condition+":start")
            let cpuStart=cpuSeconds(),wallStart=clock.now
            let store=try SQLiteRecordStore(paths:CCPaths(dataRoot:paths.dataRoot.appendingPathComponent(condition),modelsRoot:paths.modelsRoot))
            let generation=try await store.beginGeneration(config.pipeline)
            let activated=try await store.activateGeneration(generation.id);XCTAssertTrue(activated)
            let queue=TriageQueue(store:store,classifier:classifier,scanner:scanner,embedder:embedder,screenshots:StoreScreenshotLoader(store:store))
            let wiring=TriageWiring(queue:queue)
            let capturer=FakeCapturer.standard(),recorder=FakeRecorder()
            let coordinator=AppCoordinator(dependencies:CaptureDependencies(capturer:capturer,recorder:recorder,transcriber:transcriber,store:store))
            var ids:[String]=[],busyCount=0,releaseTimes:[Double]=[],startTimes:[Double]=[],heartbeats:[Double]=[],physicalSamples:[Double]=[]
            coordinator.onRecordSaved={ id in ids.append(id);if condition=="with_triage" { wiring.recordSaved(id:id) } }
            coordinator.onCaptureActivityChanged={ wiring.captureActivityChanged($0) }
            var events=coordinator.events().makeAsyncIterator()
            let heartbeat=Task { @MainActor in
                while !Task.isCancelled {
                    let tick=clock.now
                    do { try await Task.sleep(for:.milliseconds(16)) } catch { return }
                    heartbeats.append(milliseconds(tick));physicalSamples.append(Memory.snapshot()["physicalMB"]!)
                }
            }
            for capture in captures {
                let screen=screens[capture.screen]!
                capturer.context.set(CaptureContext(capturedAt:Date(),app:AppInfo(name:screen.app,bundleID:"synthetic.replay"),window:WindowInfo(title:screen.window_title,frame:nil),url:screen.url,screenshot:images[capture.screen],extra:["fixture_id":String(capture.id)]))
                recorder.samples.set(audios[capture.id]!)
                if await queue.isBusy { busyCount+=1 }
                coordinator.handle(HotKeyEvent(kind:.pressed,uptime:ProcessInfo.processInfo.systemUptime,date:Date()))
                await coordinator.waitUntilSettled();await wiring.waitForCaptureActivityForwarded()
                try await Task.sleep(for:.milliseconds(350))
                coordinator.handle(HotKeyEvent(kind:.released,uptime:ProcessInfo.processInfo.systemUptime,date:Date(),pressDuration:0.35))
                await coordinator.waitUntilSettled();await wiring.waitForCaptureActivityForwarded()
                var saved:ContextRecord?
                while let event=await events.next() {
                    if case let .saved(record,_)=event { saved=record;break }
                    if case .failed=event { XCTFail("capture failed");break }
                }
                let record=try XCTUnwrap(saved)
                let durable=try await store.get(id:record.id);XCTAssertNotNil(durable)
                XCTAssertNotNil(record.audioPath);XCTAssertNotNil(record.screenshotPath)
                releaseTimes.append(coordinator.latency.samples[.releaseToSaved]!.values.last!)
                startTimes.append(coordinator.latency.samples[.pressToRecording]!.values.last!)
                try await Task.sleep(for:.milliseconds(20))
            }
            heartbeat.cancel();await heartbeat.value
            if condition=="without_triage" { for id in ids { await queue.enqueue(id:id) } }
            await queue.waitUntilIdle()
            let missing=try await store.missingGenerationIDs(generation.id,limit:100);XCTAssertTrue(missing.isEmpty)
            let query=try await embedder.embedQueryWithSignature(captures[0].text)
            let hits=try await store.search(vector:query.vector,limit:ids.count,statuses:[],compatibilityKey:query.compatibilityKey)
            XCTAssertEqual(hits.count,ids.count);XCTAssertTrue(hits.allSatisfy { ids.contains($0.record.id) })
            reports[condition]=["cpuSeconds":cpuSeconds()-cpuStart,"wallSeconds":milliseconds(wallStart)/1000,"releaseToSaved":summary(releaseTimes),"pressToRecordingReplay":summary(startTimes),"mainActorWakeInterval":summary(heartbeats),
                "capturePhysicalPeakMB":physicalSamples.max() ?? -1,"triageBusyAtPressCount":busyCount,"saved":ids.count,"indexed":hits.count,"afterTriageMemory":Memory.snapshot(),
                "captureP90Under2000Ms":(releaseTimes.sorted()[Int(ceil(Double(releaseTimes.count)*0.9))-1]<=2000)]
        }
        try mark("capture-complete")
        await classifier.unload();snapshots["afterIntentUnload"]=Memory.snapshot();await embedder.unload();snapshots["afterEmbeddingUnload"]=Memory.snapshot()
        let result:[String:Any]=["schemaVersion":1,"modelLoads":loads,"memory":snapshots,"conditions":reports,"hardwareMemoryBytes":ProcessInfo.processInfo.physicalMemory,
           "os":ProcessInfo.processInfo.operatingSystemVersionString,"lowPower":ProcessInfo.processInfo.isLowPowerModeEnabled,"thermalState":ProcessInfo.processInfo.thermalState.rawValue,
           "scope":"Release test bundle compiles actual AppCoordinator/TriageWiring; real Whisper/d1/CoreML/SQLite; fixture key/recorder/context replay; no real hotkey/microphone/screen/toast; external power sampling is correlated separately",
           "key":config.indexSignature,"captureCountPerCondition":captures.count]
        try mark("finished")
        try JSONSerialization.data(withJSONObject:result,options:[.prettyPrinted,.sortedKeys]).write(to:URL(fileURLWithPath:output),options:.atomic)
    }
}
