import AVFoundation
import CCCore
import Foundation

/// Push-to-Talk の録音（AVAudioEngine）。入力デバイスのフォーマットから 16kHz モノラル Float32 に変換しながら貯める。
///
/// - アイドル時はマイクを開かない（エンジンは止めたまま。メニューバーのオレンジ表示は出ない想定）。
/// - `prepare()` を起動時に一度呼んでおくと、`start()`（押下 → 録音開始）が速くなる。
/// - 入力デバイスの変更（Bluetooth ヘッドセット接続など、`AVAudioEngineConfigurationChange`）では、録音中なら
///   タップを張り直して続ける。張り直せなければそれまでのサンプルを残し、`stop()` で返す。
/// - マイク権限は**要求しない**（`AVCaptureDevice.requestAccess` は `CapturePermissions.requestMicrophone()` で UI から）。
public final class PushToTalkRecorder: AudioRecording, @unchecked Sendable {
    public enum RecorderError: Error, Equatable, CustomStringConvertible {
        /// マイクが拒否・制限されている。
        case microphonePermissionDenied
        /// マイク権限をまだ尋ねていない（オンボーディングで要求すること）。
        case microphonePermissionNotDetermined
        /// 入力デバイスが無い・フォーマットが不正（0Hz / 0ch）。
        case noInputDevice
        /// エンジンを起動できなかった。
        case engineStartFailed(String)
        /// 録音していないのに stop した。
        case notRecording

        public var description: String {
            switch self {
            case .microphonePermissionDenied: return "マイクの使用が許可されていません"
            case .microphonePermissionNotDetermined: return "マイクの使用許可をまだ求めていません"
            case .noInputDevice: return "マイク（入力デバイス）が見つかりません"
            case let .engineStartFailed(m): return "録音を開始できませんでした: \(m)"
            case .notRecording: return "録音していません"
            }
        }
    }

    /// 1 回の録音の状態。`lock` で守る（タップは音声スレッド、操作は controlQueue から触る）。
    private final class Session: @unchecked Sendable {
        let lock = NSLock()
        var resampler: AudioResampler
        var samples: [Float] = []
        var levelWindow = LevelWindow()
        /// デバイス変更で張り直せなかった（以降のサンプルは来ない）。
        var interrupted = false

        init(resampler: AudioResampler) {
            self.resampler = resampler
            samples.reserveCapacity(Int(RecordedAudio.sampleRate) * 30)
        }
    }

    private let controlQueue = DispatchQueue(label: "CCCapture.Recorder", qos: .userInteractive)
    private let authorization: @Sendable () -> AVAuthorizationStatus
    private let writesFile: Bool
    private let fileDirectory: URL

    // controlQueue 上でだけ触る。
    private var engine: AVAudioEngine?
    private var configObserver: NSObjectProtocol?
    private var isPrepared = false
    private var session: Session?

    private let levelContinuations = Locked<[UUID: AsyncStream<Float>.Continuation]>([:])
    private let recordingFlag = Locked(false)

    /// - Parameters:
    ///   - writesFile: stop 時に 16kHz モノラル 16bit の WAV を一時ファイルに書くか。
    ///   - fileDirectory: WAV の置き場所（既定は一時ディレクトリ配下 `ContextCapture/Audio`）。
    public convenience init(
        writesFile: Bool = true,
        fileDirectory: URL = FileManager.default.temporaryDirectory.appendingPathComponent("ContextCapture/Audio", isDirectory: true)
    ) {
        self.init(writesFile: writesFile, fileDirectory: fileDirectory, authorization: {
            AVCaptureDevice.authorizationStatus(for: .audio)
        })
    }

    init(writesFile: Bool, fileDirectory: URL, authorization: @escaping @Sendable () -> AVAuthorizationStatus) {
        self.writesFile = writesFile
        self.fileDirectory = fileDirectory
        self.authorization = authorization
    }

    deinit {
        if let configObserver { NotificationCenter.default.removeObserver(configObserver) }
        engine?.inputNode.removeTap(onBus: 0)
        engine?.stop()
        levelContinuations.withLock { conts in
            for c in conts.values { c.finish() }
        }
    }

    /// 録音中か。
    public var isRecording: Bool { recordingFlag.current }

    /// 録音の下準備（エンジン生成・入力フォーマットの確認・`AVAudioEngine.prepare()`）。マイクは開かない。
    /// 起動時とデバイス変更後に呼んでおくと `start()` が速い。呼ばなくても `start()` が同じことをする。
    public func prepare() async throws {
        try await onControlQueue { try self.prepareLocked() }
    }

    public func start() async throws {
        try await onControlQueue { try self.startLocked() }
    }

    public func stop() async throws -> RecordedAudio {
        try await onControlQueue { try self.stopLocked() }
    }

    public func cancel() async {
        _ = try? await onControlQueue { () -> Void in self.cancelLocked() }
    }

    public func levels() async -> AsyncStream<Float> {
        let (stream, cont) = AsyncStream<Float>.makeStream(bufferingPolicy: .bufferingNewest(1))
        let id = UUID()
        levelContinuations.withLock { $0[id] = cont }
        cont.onTermination = { [weak self] _ in
            self?.levelContinuations.withLock { $0[id] = nil }
        }
        return stream
    }

    // MARK: - controlQueue 上の処理

    private func onControlQueue<T>(_ body: @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { (cont: CheckedContinuation<T, Error>) in
            controlQueue.async {
                do { cont.resume(returning: try body()) } catch { cont.resume(throwing: error) }
            }
        }
    }

    private func checkAuthorization() throws {
        switch authorization() {
        case .authorized: return
        case .notDetermined: throw RecorderError.microphonePermissionNotDetermined
        case .denied, .restricted: throw RecorderError.microphonePermissionDenied
        @unknown default: throw RecorderError.microphonePermissionDenied
        }
    }

    /// 入力フォーマットが使えるか（0Hz / 0ch でタップを張ると ObjC 例外で落ちるので必ず先に見る）。
    static func isUsable(_ format: AVAudioFormat) -> Bool {
        format.sampleRate > 0 && format.channelCount > 0
    }

    private func makeEngineIfNeeded() -> AVAudioEngine {
        if let engine { return engine }
        let e = AVAudioEngine()
        engine = e
        configObserver = NotificationCenter.default.addObserver(
            forName: .AVAudioEngineConfigurationChange,
            object: e,
            queue: nil
        ) { [weak self] _ in
            guard let self else { return }
            self.controlQueue.async { self.handleConfigurationChangeLocked() }
        }
        return e
    }

    private func prepareLocked() throws {
        try checkAuthorization()
        let e = makeEngineIfNeeded()
        let format = e.inputNode.outputFormat(forBus: 0)
        guard Self.isUsable(format) else { throw RecorderError.noInputDevice }
        if !isPrepared {
            e.prepare()
            isPrepared = true
        }
    }

    private func startLocked() throws {
        if session != nil { return }  // 録音中は何もしない
        try checkAuthorization()
        let e = makeEngineIfNeeded()
        let input = e.inputNode
        let format = input.outputFormat(forBus: 0)
        guard Self.isUsable(format) else { throw RecorderError.noInputDevice }
        let resampler: AudioResampler
        do { resampler = try AudioResampler(inputFormat: format) } catch { throw RecorderError.noInputDevice }
        let s = Session(resampler: resampler)
        installTap(on: input, format: format, session: s)
        if !isPrepared {
            e.prepare()
            isPrepared = true
        }
        do {
            try e.start()
        } catch {
            input.removeTap(onBus: 0)
            isPrepared = false
            throw RecorderError.engineStartFailed(error.localizedDescription)
        }
        session = s
        recordingFlag.withLock { $0 = true }
    }

    private func installTap(on input: AVAudioInputNode, format: AVAudioFormat, session s: Session) {
        input.installTap(onBus: 0, bufferSize: 1024, format: format) { [weak self] buffer, _ in
            // 音声スレッド。Task は作らず、ロックの中で変換して貯める。
            s.lock.lock()
            let converted = s.resampler.convert(buffer)
            s.samples.append(contentsOf: converted)
            let levels = s.levelWindow.append(converted)
            s.lock.unlock()
            guard !levels.isEmpty, let self else { return }
            let conts = self.levelContinuations.withLock { Array($0.values) }
            for level in levels {
                for c in conts { c.yield(level) }
            }
        }
    }

    private func stopLocked() throws -> RecordedAudio {
        guard let s = session else { throw RecorderError.notRecording }
        tearDownEngineForIdle()
        session = nil
        recordingFlag.withLock { $0 = false }
        s.lock.lock()
        s.samples.append(contentsOf: s.resampler.flush())
        let samples = s.samples
        let interrupted = s.interrupted
        s.lock.unlock()
        finishLevels()
        let duration = Double(samples.count) / RecordedAudio.sampleRate
        let url = writesFile ? writeWAV(samples) : nil
        return RecordedAudio(samples16kMono: samples, duration: duration, fileURL: url, wasInterrupted: interrupted)
    }

    private func cancelLocked() {
        guard session != nil else { return }
        tearDownEngineForIdle()
        session = nil
        recordingFlag.withLock { $0 = false }
        finishLevels()
    }

    /// タップを外してエンジンを止める（マイクを閉じる）。
    private func tearDownEngineForIdle() {
        guard let e = engine else { return }
        e.inputNode.removeTap(onBus: 0)
        e.stop()
        // stop で資源が解放されるので、次の押下に備えてすぐ prepare し直す（マイクは開かない想定。実機で要確認）。
        if Self.isUsable(e.inputNode.outputFormat(forBus: 0)) {
            e.prepare()
            isPrepared = true
        } else {
            isPrepared = false
        }
    }

    private func finishLevels() {
        let conts = levelContinuations.withLock { c -> [AsyncStream<Float>.Continuation] in
            let all = Array(c.values)
            c.removeAll()
            return all
        }
        for c in conts { c.finish() }
    }

    /// デバイス変更。届いた時点でエンジンは止まっている。
    private func handleConfigurationChangeLocked() {
        isPrepared = false
        guard let s = session, let e = engine else { return }
        let input = e.inputNode
        input.removeTap(onBus: 0)
        let format = input.outputFormat(forBus: 0)
        // 旧フォーマットの変換器に残った分を出し切ってから差し替える。
        s.lock.lock()
        s.samples.append(contentsOf: s.resampler.flush())
        s.lock.unlock()
        guard Self.isUsable(format), let resampler = try? AudioResampler(inputFormat: format) else {
            s.lock.lock(); s.interrupted = true; s.lock.unlock()
            return
        }
        s.lock.lock()
        s.resampler = resampler
        s.lock.unlock()
        installTap(on: input, format: format, session: s)
        e.prepare()
        do {
            try e.start()
            isPrepared = true
        } catch {
            input.removeTap(onBus: 0)
            s.lock.lock(); s.interrupted = true; s.lock.unlock()
        }
    }

    private func writeWAV(_ samples: [Float]) -> URL? {
        do {
            try FileManager.default.createDirectory(at: fileDirectory, withIntermediateDirectories: true)
            let url = fileDirectory.appendingPathComponent("\(UUID().uuidString).wav")
            try WAVEncoder.encodePCM16(samples: samples).write(to: url, options: .atomic)
            return url
        } catch {
            return nil
        }
    }
}
