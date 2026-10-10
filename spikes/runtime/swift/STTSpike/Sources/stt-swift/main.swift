// fixtures/audio の 30 件を WhisperKit / FluidAudio(Parakeet JA) で文字起こしし、仮説とレイテンシを JSON に出す。
// CER は poc/scripts/common.py の cer() で採点する（scripts/stt_score.py）。
//
// usage: stt-swift <engine> <audio_dir> <models_dir> <out.json> [variant]
//   engine: whisperkit | parakeet-ja
//   variant (whisperkit): WhisperKit のモデル名（既定 openai_whisper-large-v3-v20240930）
//   WHISPER_PROMPT=1 で PoC と同じ語彙プロンプトを promptTokens として与える

import AVFoundation
import FluidAudio
import Foundation
import WhisperKit

let initialPrompt = "Hermes、Claude Code、OpenDots、GitHub、issue、pytest、adapter.ts"

func rssMB() -> Double {
    var info = mach_task_basic_info()
    var count = mach_msg_type_number_t(MemoryLayout<mach_task_basic_info>.size) / 4
    let kr = withUnsafeMutablePointer(to: &info) {
        $0.withMemoryRebound(to: integer_t.self, capacity: Int(count)) {
            task_info(mach_task_self_, task_flavor_t(MACH_TASK_BASIC_INFO), $0, &count)
        }
    }
    return kr == KERN_SUCCESS ? Double(info.resident_size) / 1e6 : -1
}

func loadWav(_ url: URL) throws -> [Float] {
    let f = try AVAudioFile(forReading: url)
    let fmt = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: f.fileFormat.sampleRate, channels: 1, interleaved: false)!
    let buf = AVAudioPCMBuffer(pcmFormat: fmt, frameCapacity: AVAudioFrameCount(f.length))!
    try f.read(into: buf)
    precondition(f.fileFormat.sampleRate == 16000)
    return Array(UnsafeBufferPointer(start: buf.floatChannelData![0], count: Int(buf.frameLength)))
}

let args = CommandLine.arguments
guard args.count >= 5 else { print("usage: stt-swift <engine> <audio_dir> <models_dir> <out.json> [variant]"); exit(2) }
let engine = args[1]
let audioDir = URL(fileURLWithPath: args[2])
let modelsDir = URL(fileURLWithPath: args[3])
let outURL = URL(fileURLWithPath: args[4])
let variant = args.count > 5 ? args[5] : "openai_whisper-large-v3-v20240930"
let usePrompt = ProcessInfo.processInfo.environment["WHISPER_PROMPT"] != nil

let files = (1...30).map { audioDir.appendingPathComponent(String(format: "c%02d.wav", $0)) }
let audios = try files.map(loadWav)
let rss0 = rssMB()

var transcribe: ([Float]) async throws -> String
let t0 = Date()
var meta: [String: Any] = ["engine": engine]
switch engine {
case "whisperkit":
    let cfg = WhisperKitConfig(model: variant, downloadBase: modelsDir.appendingPathComponent("whisperkit"),
                               verbose: false, logLevel: .error, download: true)
    let wk = try await WhisperKit(cfg)
    var opts = DecodingOptions()
    opts.language = "ja"
    opts.temperature = 0
    opts.usePrefillPrompt = true
    opts.detectLanguage = false
    opts.withoutTimestamps = true
    if usePrompt, let tok = wk.tokenizer {
        opts.promptTokens = tok.encode(text: " " + initialPrompt).filter { $0 < tok.specialTokens.specialTokenBegin }
    }
    meta["variant"] = variant
    meta["prompt"] = usePrompt
    meta["model_folder"] = wk.modelFolder?.path ?? ""
    transcribe = { a in
        let r = try await wk.transcribe(audioArray: a, decodeOptions: opts)
        return r.map { $0.text }.joined()
    }
case "parakeet-ja":
    let models = try await AsrModels.downloadAndLoad(to: modelsDir.appendingPathComponent("parakeet-ja"), version: .tdtJa)
    let mgr = AsrManager()
    try await mgr.loadModels(models)
    meta["variant"] = "parakeet-tdt_ctc-0.6b-ja (FluidAudio tdtJa)"
    transcribe = { a in
        var st = TdtDecoderState.make()
        return try await mgr.transcribe(a, decoderState: &st).text
    }
default:
    fatalError("unknown engine \(engine)")
}
let loadS = Date().timeIntervalSince(t0)
_ = try await transcribe(Array(repeating: 0, count: 16000))  // warm up

let iso = ISO8601DateFormatter()
let started = iso.string(from: Date())
var hyps: [String] = []
var perFile: [[Double]] = Array(repeating: [], count: files.count)
for rep in 0..<3 {
    for (i, a) in audios.enumerated() {
        let t = Date()
        let h = try await transcribe(a)
        perFile[i].append(Date().timeIntervalSince(t))
        if rep == 0 { hyps.append(h) }
    }
}
let finished = iso.string(from: Date())
let med = perFile.map { $0.sorted()[1] }
let out: [String: Any] = [
    "meta": meta, "load_s": loadS, "rss_mb_after": rssMB(), "rss_mb_before_load": rss0,
    "bench": ["started_at": started, "finished_at": finished],
    "rows": files.enumerated().map { i, f in
        ["id": i + 1, "file": f.lastPathComponent, "hyp": hyps[i], "latency_s_median3": med[i],
         "duration_s": Double(audios[i].count) / 16000] as [String: Any]
    },
]
try JSONSerialization.data(withJSONObject: out, options: [.prettyPrinted, .sortedKeys]).write(to: outURL)
print("load_s", loadS, "p50", med.sorted()[med.count / 2], "rss", rssMB())
