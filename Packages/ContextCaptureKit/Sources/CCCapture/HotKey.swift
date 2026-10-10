import ApplicationServices
import Carbon.HIToolbox
import CoreGraphics
import Foundation

// MARK: - ショートカットの表現

/// グローバルホットキーのキーとモディファイア。既定は ⌥Space（F-02）。
public struct HotKeyShortcut: Sendable, Hashable, Codable {
    public struct Modifiers: OptionSet, Sendable, Hashable, Codable {
        public let rawValue: UInt8
        public init(rawValue: UInt8) { self.rawValue = rawValue }

        public static let command = Modifiers(rawValue: 1 << 0)
        public static let option = Modifiers(rawValue: 1 << 1)
        public static let control = Modifiers(rawValue: 1 << 2)
        public static let shift = Modifiers(rawValue: 1 << 3)
    }

    /// 仮想キーコード（`kVK_*`。例: Space は 49）。
    public var keyCode: UInt32
    public var modifiers: Modifiers

    public init(keyCode: UInt32, modifiers: Modifiers) {
        self.keyCode = keyCode
        self.modifiers = modifiers
    }

    /// ⌥Space。
    public static let optionSpace = HotKeyShortcut(keyCode: UInt32(kVK_Space), modifiers: [.option])

    /// Carbon `RegisterEventHotKey` 用のモディファイア。
    var carbonModifiers: UInt32 {
        var m: UInt32 = 0
        if modifiers.contains(.command) { m |= UInt32(cmdKey) }
        if modifiers.contains(.option) { m |= UInt32(optionKey) }
        if modifiers.contains(.control) { m |= UInt32(controlKey) }
        if modifiers.contains(.shift) { m |= UInt32(shiftKey) }
        return m
    }

    /// CGEvent のフラグから、このショートカットが見る 4 種のモディファイアだけを取り出す。
    static func modifiers(from flags: CGEventFlags) -> Modifiers {
        var m: Modifiers = []
        if flags.contains(.maskCommand) { m.insert(.command) }
        if flags.contains(.maskAlternate) { m.insert(.option) }
        if flags.contains(.maskControl) { m.insert(.control) }
        if flags.contains(.maskShift) { m.insert(.shift) }
        return m
    }

    /// keyDown がこのショートカットの押下か（モディファイアは完全一致。CapsLock・Fn 等は無視）。
    func matchesKeyDown(keyCode: Int64, flags: CGEventFlags) -> Bool {
        keyCode == Int64(self.keyCode) && Self.modifiers(from: flags) == modifiers
    }

    /// macOS 15 以降で Carbon が拒否しうる組み合わせ（⌥ のみ・⌥⇧ のみ・⇧ のみ）。
    /// 15.2 で緩和されたとの報告もあり、実際の可否は登録結果で判断する（ここは表示・ログ用）。
    public var mayBeRestrictedByCarbon: Bool {
        let restricted: [Modifiers] = [[.option], [.option, .shift], [.shift], []]
        return restricted.contains(modifiers)
    }

    /// 表示用（例: "⌥Space"）。
    public var displayString: String {
        var s = ""
        if modifiers.contains(.control) { s += "⌃" }
        if modifiers.contains(.option) { s += "⌥" }
        if modifiers.contains(.shift) { s += "⇧" }
        if modifiers.contains(.command) { s += "⌘" }
        return s + Self.keyName(keyCode)
    }

    static func keyName(_ keyCode: UInt32) -> String {
        switch Int(keyCode) {
        case kVK_Space: return "Space"
        case kVK_Return: return "Return"
        case kVK_Tab: return "Tab"
        case kVK_Escape: return "Esc"
        case kVK_F1: return "F1"
        case kVK_F2: return "F2"
        case kVK_F3: return "F3"
        case kVK_F4: return "F4"
        case kVK_F5: return "F5"
        case kVK_F6: return "F6"
        case kVK_F7: return "F7"
        case kVK_F8: return "F8"
        case kVK_F9: return "F9"
        case kVK_F10: return "F10"
        case kVK_F11: return "F11"
        case kVK_F12: return "F12"
        default: return "Key\(keyCode)"
        }
    }
}

// MARK: - 押下 / 解放イベント

/// ホットキーの押下 / 解放。時刻は OS のイベント時刻（キー入力の瞬間）で、ハンドラが走った時刻ではない。
public struct HotKeyEvent: Sendable, Equatable {
    public enum Kind: String, Sendable { case pressed, released }

    public var kind: Kind
    /// システム起動からの秒（`ProcessInfo.processInfo.systemUptime` と同じ時計）。
    public var uptime: TimeInterval
    /// 壁時計の時刻（uptime から換算）。
    public var date: Date
    /// released のとき、対応する押下からの経過秒。pressed では nil。
    public var pressDuration: TimeInterval?

    public init(kind: Kind, uptime: TimeInterval, date: Date, pressDuration: TimeInterval? = nil) {
        self.kind = kind
        self.uptime = uptime
        self.date = date
        self.pressDuration = pressDuration
    }

    /// released で、押下が 0.3 秒未満（誤操作として破棄すべき）なら true。
    public var isShortPress: Bool {
        guard kind == .released, let d = pressDuration else { return false }
        return PushToTalkTiming.isTooShort(d)
    }
}

/// Push-to-Talk の時間判定（F-02: 0.3 秒未満の押下は誤操作として破棄）。
public enum PushToTalkTiming {
    public static let minimumPressDuration: TimeInterval = 0.3

    public static func isTooShort(_ duration: TimeInterval, minimum: TimeInterval = minimumPressDuration) -> Bool {
        duration < minimum
    }
}

/// 生の押下 / 解放を受けて、多重押下（キーリピート・二重配送）と対の無い解放を落とす状態機械。
struct HotKeyGate: Sendable {
    private(set) var pressedAt: TimeInterval?

    var isPressed: Bool { pressedAt != nil }

    mutating func handle(_ kind: HotKeyEvent.Kind, uptime: TimeInterval, date: Date) -> HotKeyEvent? {
        switch kind {
        case .pressed:
            guard pressedAt == nil else { return nil }
            pressedAt = uptime
            return HotKeyEvent(kind: .pressed, uptime: uptime, date: date)
        case .released:
            guard let start = pressedAt else { return nil }
            pressedAt = nil
            return HotKeyEvent(kind: .released, uptime: uptime, date: date, pressDuration: max(0, uptime - start))
        }
    }

    mutating func reset() { pressedAt = nil }
}

// MARK: - グローバルホットキー

/// グローバルな Push-to-Talk ホットキー。押下 / 解放を `events`（AsyncStream）と `onEvent` で通知する。
///
/// - 主経路は Carbon `RegisterEventHotKey`（アクセシビリティ権限不要）。
/// - macOS 15 以降は ⌥ のみ・⌥⇧ のみの組み合わせを Carbon が拒否することがある。登録に失敗したとき、
///   `allowEventTapFallback` が true でアクセシビリティ権限があれば CGEventTap（キーを横取りして他アプリへ渡さない）に切り替える。
/// - **メインスレッドで生成・操作すること**（イベントはメインの run loop に届く）。
@MainActor
public final class GlobalPushToTalkHotKey {
    public enum Backend: String, Sendable {
        case carbon
        case eventTap
    }

    public enum HotKeyError: Error, Equatable, CustomStringConvertible {
        /// 他アプリが同じ組み合わせを登録済み（Carbon `eventHotKeyExistsErr`）。
        case alreadyInUse
        /// Carbon の登録が失敗し、フォールバックもできなかった。`accessibilityTrusted` が false なら権限を付ければ CGEventTap で動く。
        case registrationFailed(carbonStatus: OSStatus, accessibilityTrusted: Bool)

        public var description: String {
            switch self {
            case .alreadyInUse:
                return "ほかのアプリが同じショートカットを使っています"
            case let .registrationFailed(status, trusted):
                return "ホットキーを登録できませんでした（Carbon: \(status)、アクセシビリティ権限: \(trusted ? "あり" : "なし")）"
            }
        }
    }

    public private(set) var shortcut: HotKeyShortcut
    /// 動作中の方式。停止中は nil。
    public private(set) var activeBackend: Backend?
    /// 直近の Carbon 登録結果（診断用）。
    public private(set) var lastCarbonStatus: OSStatus?
    /// 押下 / 解放の通知（最大 16 件バッファ）。このオブジェクトの破棄で終わる。
    public let events: AsyncStream<HotKeyEvent>
    /// 押下 / 解放のコールバック（メインスレッドで呼ばれる）。`events` と併用してよい。
    public var onEvent: ((HotKeyEvent) -> Void)?

    private let continuation: AsyncStream<HotKeyEvent>.Continuation
    private var gate = HotKeyGate()
    private var carbon: CarbonHotKeyRegistration?
    private var tap: EventTapHotKey?
    private var allowEventTapFallback = true
    private var preferEventTap = false

    public init(shortcut: HotKeyShortcut = .optionSpace) {
        self.shortcut = shortcut
        let (stream, cont) = AsyncStream<HotKeyEvent>.makeStream(bufferingPolicy: .bufferingNewest(16))
        events = stream
        continuation = cont
    }

    deinit {
        continuation.finish()
        // carbon / tap はそれぞれの deinit で登録を解く。
    }

    /// 登録して監視を始める。既に動いていれば一度止めて登録し直す。
    /// - Parameters:
    ///   - allowEventTapFallback: Carbon の登録に失敗したら CGEventTap に切り替える（アクセシビリティ権限が要る）。
    ///   - preferEventTap: 最初から CGEventTap を使う（Carbon が登録には成功するのに届かない環境向けの逃げ道。権限が無ければ Carbon を試す）。
    @discardableResult
    public func start(allowEventTapFallback: Bool = true, preferEventTap: Bool = false) throws -> Backend {
        stop()
        self.allowEventTapFallback = allowEventTapFallback
        self.preferEventTap = preferEventTap
        if preferEventTap, AXIsProcessTrusted(), let t = makeEventTap() {
            tap = t
            activeBackend = .eventTap
            return .eventTap
        }
        let id = CarbonHotKeyCenter.register(owner: self)
        let (status, registration) = CarbonHotKeyRegistration.register(shortcut: shortcut, id: id)
        lastCarbonStatus = status
        if let registration {
            carbon = registration
            activeBackend = .carbon
            return .carbon
        }
        CarbonHotKeyCenter.unregister(id: id)
        if status == OSStatus(eventHotKeyExistsErr) {
            throw HotKeyError.alreadyInUse
        }
        let trusted = AXIsProcessTrusted()
        if allowEventTapFallback, trusted, let t = makeEventTap() {
            tap = t
            activeBackend = .eventTap
            return .eventTap
        }
        throw HotKeyError.registrationFailed(carbonStatus: status, accessibilityTrusted: trusted)
    }

    private func makeEventTap() -> EventTapHotKey? {
        EventTapHotKey(shortcut: shortcut, handler: { [weak self] kind, uptime in
            self?.deliver(kind, uptime: uptime)
        })
    }

    /// 登録を解いて監視をやめる（押下中なら解放は通知しない）。
    public func stop() {
        if let carbon {
            CarbonHotKeyCenter.unregister(id: carbon.id)
        }
        carbon = nil
        tap?.invalidate()
        tap = nil
        activeBackend = nil
        gate.reset()
    }

    /// ショートカットを変える。動作中なら登録し直す（失敗したら throw し、停止状態になる）。
    public func setShortcut(_ newValue: HotKeyShortcut) throws {
        let wasActive = activeBackend != nil
        shortcut = newValue
        if wasActive {
            try start(allowEventTapFallback: allowEventTapFallback, preferEventTap: preferEventTap)
        }
    }

    /// 押下中か。
    public var isPressed: Bool { gate.isPressed }

    fileprivate func deliver(_ kind: HotKeyEvent.Kind, uptime: TimeInterval) {
        let t = uptime > 0 ? uptime : ProcessInfo.processInfo.systemUptime
        guard let event = gate.handle(kind, uptime: t, date: Date.fromUptime(t)) else { return }
        continuation.yield(event)
        onEvent?(event)
    }
}

// MARK: - Carbon

/// Carbon のハンドラは C 関数ポインタなので、ID → 所有者の表をメインスレッドで持つ。
@MainActor
enum CarbonHotKeyCenter {
    private final class WeakOwner {
        weak var owner: GlobalPushToTalkHotKey?
        init(_ o: GlobalPushToTalkHotKey) { owner = o }
    }

    private static var handlerRef: EventHandlerRef?
    private static var owners: [UInt32: WeakOwner] = [:]
    private static var nextID: UInt32 = 1

    static func register(owner: GlobalPushToTalkHotKey) -> UInt32 {
        installHandlerIfNeeded()
        let id = nextID
        nextID &+= 1
        owners[id] = WeakOwner(owner)
        return id
    }

    static func unregister(id: UInt32) {
        owners[id] = nil
    }

    static func dispatch(id: UInt32, kind: HotKeyEvent.Kind, uptime: TimeInterval) {
        owners[id]?.owner?.deliver(kind, uptime: uptime)
    }

    private static func installHandlerIfNeeded() {
        guard handlerRef == nil else { return }
        var specs = [
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyPressed)),
            EventTypeSpec(eventClass: OSType(kEventClassKeyboard), eventKind: UInt32(kEventHotKeyReleased)),
        ]
        var ref: EventHandlerRef?
        let status = InstallEventHandler(GetEventDispatcherTarget(), carbonHotKeyCallback, specs.count, &specs, nil, &ref)
        if status == noErr { handlerRef = ref }
    }
}

/// `RegisterEventHotKey` の登録 1 件。破棄で登録を解く。
final class CarbonHotKeyRegistration: @unchecked Sendable {
    /// 'CCPT'
    static let signature: OSType = 0x4343_5054

    let id: UInt32
    private let ref: EventHotKeyRef

    private init(id: UInt32, ref: EventHotKeyRef) {
        self.id = id
        self.ref = ref
    }

    static func register(shortcut: HotKeyShortcut, id: UInt32) -> (OSStatus, CarbonHotKeyRegistration?) {
        var ref: EventHotKeyRef?
        let hotKeyID = EventHotKeyID(signature: signature, id: id)
        let status = RegisterEventHotKey(shortcut.keyCode, shortcut.carbonModifiers, hotKeyID, GetEventDispatcherTarget(), 0, &ref)
        guard status == noErr, let ref else { return (status == noErr ? OSStatus(eventInternalErr) : status, nil) }
        return (status, CarbonHotKeyRegistration(id: id, ref: ref))
    }

    deinit {
        UnregisterEventHotKey(ref)
    }
}

private func carbonHotKeyCallback(
    _ next: EventHandlerCallRef?,
    _ event: EventRef?,
    _ userData: UnsafeMutableRawPointer?
) -> OSStatus {
    guard let event else { return OSStatus(eventNotHandledErr) }
    var hotKeyID = EventHotKeyID()
    let status = GetEventParameter(
        event,
        EventParamName(kEventParamDirectObject),
        EventParamType(typeEventHotKeyID),
        nil,
        MemoryLayout<EventHotKeyID>.size,
        nil,
        &hotKeyID
    )
    guard status == noErr, hotKeyID.signature == CarbonHotKeyRegistration.signature else {
        return OSStatus(eventNotHandledErr)
    }
    let kindRaw = GetEventKind(event)
    let kind: HotKeyEvent.Kind
    switch Int(kindRaw) {
    case kEventHotKeyPressed: kind = .pressed
    case kEventHotKeyReleased: kind = .released
    default: return OSStatus(eventNotHandledErr)
    }
    let uptime = GetEventTime(event)
    let id = hotKeyID.id
    if Thread.isMainThread {
        MainActor.assumeIsolated { CarbonHotKeyCenter.dispatch(id: id, kind: kind, uptime: uptime) }
    } else {
        DispatchQueue.main.async { CarbonHotKeyCenter.dispatch(id: id, kind: kind, uptime: uptime) }
    }
    return noErr
}

// MARK: - CGEventTap（フォールバック）

/// キーを横取りする CGEventTap（`.defaultTap`）。アクセシビリティ権限が要る。
/// 一致したキーは nil を返して他アプリへ渡さない（⌥Space で no-break space が入力されないように）。
final class EventTapHotKey: @unchecked Sendable {
    typealias Handler = @MainActor (HotKeyEvent.Kind, TimeInterval) -> Void

    final class Context: @unchecked Sendable {
        let shortcut: HotKeyShortcut
        let handler: Handler
        var tap: CFMachPort?
        /// 押下中か（コールバックはメインの run loop で走るので、メインスレッドからしか触らない）。
        var isDown = false

        init(shortcut: HotKeyShortcut, handler: @escaping Handler) {
            self.shortcut = shortcut
            self.handler = handler
        }
    }

    private let context: Context
    private let tap: CFMachPort
    private let source: CFRunLoopSource

    init?(shortcut: HotKeyShortcut, handler: @escaping Handler) {
        let ctx = Context(shortcut: shortcut, handler: handler)
        let mask = (CGEventMask(1) << CGEventType.keyDown.rawValue) | (CGEventMask(1) << CGEventType.keyUp.rawValue)
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap,
            place: .headInsertEventTap,
            options: .defaultTap,
            eventsOfInterest: mask,
            callback: eventTapCallback,
            userInfo: Unmanaged.passUnretained(ctx).toOpaque()
        ) else { return nil }
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0) else {
            CFMachPortInvalidate(tap)
            return nil
        }
        ctx.tap = tap
        context = ctx
        self.tap = tap
        self.source = source
        CFRunLoopAddSource(CFRunLoopGetMain(), source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
    }

    private var invalidated = false

    /// メインスレッドから呼ぶ。2 回目以降は何もしない。
    func invalidate() {
        guard !invalidated else { return }
        invalidated = true
        CGEvent.tapEnable(tap: tap, enable: false)
        CFRunLoopRemoveSource(CFRunLoopGetMain(), source, .commonModes)
        CFMachPortInvalidate(tap)
    }

    deinit { invalidate() }
}

/// CGEventTap のイベント 1 件をどう扱うか（純粋関数。テスト用に切り出す）。
enum EventTapDecision: Equatable {
    case passThrough
    /// 横取りする。`deliver` が非 nil ならその種類を通知する。
    case swallow(deliver: HotKeyEvent.Kind?)

    static func decide(
        type: CGEventType,
        keyCode: Int64,
        flags: CGEventFlags,
        isAutorepeat: Bool,
        isDown: Bool,
        shortcut: HotKeyShortcut
    ) -> EventTapDecision {
        switch type {
        case .keyDown:
            if isDown, keyCode == Int64(shortcut.keyCode) {
                // 押下中のリピートは通知せず横取りだけする。
                return .swallow(deliver: nil)
            }
            guard shortcut.matchesKeyDown(keyCode: keyCode, flags: flags) else { return .passThrough }
            return .swallow(deliver: isAutorepeat ? nil : .pressed)
        case .keyUp:
            // モディファイアを先に離しても解放として扱う。
            guard isDown, keyCode == Int64(shortcut.keyCode) else { return .passThrough }
            return .swallow(deliver: .released)
        default:
            return .passThrough
        }
    }
}

private func eventTapCallback(
    _ proxy: CGEventTapProxy,
    _ type: CGEventType,
    _ event: CGEvent,
    _ userInfo: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let userInfo else { return Unmanaged.passUnretained(event) }
    let ctx = Unmanaged<EventTapHotKey.Context>.fromOpaque(userInfo).takeUnretainedValue()
    if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
        if let tap = ctx.tap { CGEvent.tapEnable(tap: tap, enable: true) }
        return Unmanaged.passUnretained(event)
    }
    let decision = EventTapDecision.decide(
        type: type,
        keyCode: event.getIntegerValueField(.keyboardEventKeycode),
        flags: event.flags,
        isAutorepeat: event.getIntegerValueField(.keyboardEventAutorepeat) != 0,
        isDown: ctx.isDown,
        shortcut: ctx.shortcut
    )
    switch decision {
    case .passThrough:
        return Unmanaged.passUnretained(event)
    case let .swallow(kind):
        if let kind {
            ctx.isDown = (kind == .pressed)
            // CGEvent.timestamp の単位は環境により揺れるので、コールバック時点の uptime を使う（タップは即時に呼ばれる）。
            let uptime = ProcessInfo.processInfo.systemUptime
            let handler = ctx.handler
            if Thread.isMainThread {
                MainActor.assumeIsolated { handler(kind, uptime) }
            } else {
                DispatchQueue.main.async { handler(kind, uptime) }
            }
        }
        return nil
    }
}
