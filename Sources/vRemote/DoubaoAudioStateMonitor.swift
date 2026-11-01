import AppKit
import CoreAudio
import Foundation

/// Reads the input method's real CoreAudio capture state.
///
/// This is deliberately independent from the remote-button state machine.
/// `kAudioProcessPropertyIsRunningInput` is the source of truth for whether the
/// input method is currently recording, and `kAudioProcessPropertyDevices`
/// tells us which input device it actually opened.
///
/// The class keeps its original name because every call site and test still
/// refers to it as the input-method state source, but it now binds one CoreAudio
/// process object per monitored input method (Doubao, WeChat Input Method, or
/// both when the host is `automatic`).
///
/// macOS 13 knows the audio process object and its PID but rejects
/// `kAudioProcessPropertyIsRunningInput` with `'who?'` (the selector only
/// exists from 14.2). There the input device list is the fallback: it is
/// populated exactly while the process captures from an input device. Without
/// this fallback the state stays `unavailable`, and the session coordinator
/// closes every dictation after its one-second opening verification.
final class DoubaoAudioStateMonitor {
    enum State: String {
        case unavailable
        case inactive
        case active
    }

    struct Snapshot: Equatable {
        let state: State
        let pid: pid_t?
        let processObjectID: AudioObjectID?
        let inputDeviceIDs: [AudioDeviceID]
        let inputDeviceNames: [String]
        /// 这份快照来自哪个输入法。`automatic` 同时监控两个输入法时，
        /// 状态行要能说出「谁在录音」。
        let hostBundleID: String?

        init(
            state: State,
            pid: pid_t?,
            processObjectID: AudioObjectID?,
            inputDeviceIDs: [AudioDeviceID],
            inputDeviceNames: [String],
            hostBundleID: String? = nil
        ) {
            self.state = state
            self.pid = pid
            self.processObjectID = processObjectID
            self.inputDeviceIDs = inputDeviceIDs
            self.inputDeviceNames = inputDeviceNames
            self.hostBundleID = hostBundleID
        }

        var isRecording: Bool { state == .active }

        var deviceSummary: String {
            inputDeviceNames.isEmpty
                ? "无"
                : inputDeviceNames.joined(separator: "、")
        }

        /// 输入法的短名，例如「豆包」「微信输入法」。
        var hostTitle: String? {
            hostBundleID.flatMap(VoiceInputHost.title(forBundleID:))
        }
    }

    private static let targetDeviceName = "vRemoteDr 2ch"

    /// One CoreAudio process object per monitored input-method bundle ID.
    private struct Binding {
        let pid: pid_t
        let objectID: AudioObjectID
        /// nil 表示这个进程对象还没被探测过；true 表示
        /// `kAudioProcessPropertyIsRunningInput` 可用，false 表示只能用
        /// 输入设备列表推断。
        var usesNative: Bool?
    }

    private struct HostRead {
        let state: State
        let deviceIDs: [AudioDeviceID]
        let deviceNames: [String]
        let usesNative: Bool
    }

    private var started = false
    private var bindings = [String: Binding]()
    private var monitoredBundleIDs = [String]()
    /// 输入法在运行但还绑不上进程对象（例如刚启动）时的 pid，用于区分
    /// 「输入法没开」和「读不到状态」。
    private var runningUnboundPIDs = [String: pid_t]()
    private var lastSnapshot: Snapshot?
    private var pollTimer: Timer?

    /// 最近一次读取实际使用了哪条路径。macOS 14.2+ 一直是原生选择器；
    /// 13.x 上则是设备列表回退。会话协调器据此决定是否需要二次确认。
    private var lastReadUsedFallback = false

    private static let pollInterval: TimeInterval = 0.4

    var onSnapshotChanged: ((Snapshot) -> Void)?

    /// True only while the input-device list is the state source, i.e. while
    /// `kAudioProcessPropertyIsRunningInput` is unavailable on this system.
    var usesDeviceListFallback: Bool { lastReadUsedFallback }

    /// 正在录音的输入法；空闲时给出系统此刻选中的输入法。
    var activeHostBundleID: String? { lastSnapshot?.hostBundleID }

    var activeHostTitle: String? {
        // 录音中就以录音的那个为准，否则看用户现在用的是哪个输入法。
        if let snapshot = lastSnapshot, snapshot.isRecording,
           let title = snapshot.hostTitle
        {
            return title
        }
        if let bundleID = InputSourceProbe.currentInputMethodBundleID(),
           let host = VoiceInputHost.host(forBundleID: bundleID)
        {
            return host.shortTitle
        }
        return lastSnapshot?.hostTitle
    }

    private lazy var processListListener: AudioObjectPropertyListenerBlock = {
        [weak self] _, _ in
        DispatchQueue.main.async {
            self?.refreshBindingAndPublish(force: false)
        }
    }

    private lazy var inputStateListener: AudioObjectPropertyListenerBlock = {
        [weak self] _, _ in
        DispatchQueue.main.async {
            self?.publishCurrentSnapshot(force: false)
        }
    }

    func start() {
        guard !started else { return }
        started = true

        var address = Self.processListAddress
        let status = AudioObjectAddPropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            .main,
            processListListener
        )
        if status != noErr {
            print("[INPUT-STATE] 无法监听音频进程列表: \(Self.describe(status))")
        }
        refreshBindingAndPublish(force: true)
        startPolling()
    }

    /// The input-device listener is unreliable on 13.x, so a low-rate poll
    /// backs it up. `publishCurrentSnapshot` deduplicates, so polling only
    /// produces output when the state really changes.
    private func startPolling() {
        pollTimer?.invalidate()
        let timer = Timer(timeInterval: Self.pollInterval, repeats: true) {
            [weak self] _ in
            self?.refreshBindingAndPublish(force: false)
        }
        RunLoop.main.add(timer, forMode: .common)
        pollTimer = timer
    }

    func stop() {
        guard started else { return }
        started = false
        pollTimer?.invalidate()
        pollTimer = nil
        unbindAll()

        var address = Self.processListAddress
        AudioObjectRemovePropertyListenerBlock(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            .main,
            processListListener
        )
        lastSnapshot = nil
    }

    /// Synchronous pre-event snapshot. The event tap calls this before the key
    /// event reaches the input method, so the returned value is the old state
    /// that the trigger press is about to toggle.
    func snapshotNow() -> Snapshot {
        refreshBindingsIfNeeded()
        return readCurrentSnapshot()
    }

    private func refreshBindingAndPublish(force: Bool) {
        refreshBindingsIfNeeded()
        publishCurrentSnapshot(force: force)
    }

    private func refreshBindingsIfNeeded() {
        let wanted = AppStorage.voiceInputHost.bundleIDs
        if wanted != monitoredBundleIDs {
            if !monitoredBundleIDs.isEmpty {
                print("[INPUT-STATE] 监听目标变更 \(monitoredBundleIDs) → \(wanted)")
            }
            unbindAll()
            monitoredBundleIDs = wanted
        }

        var live = Set<String>()
        for bundleID in monitoredBundleIDs {
            guard let app = NSRunningApplication.runningApplications(
                withBundleIdentifier: bundleID
            ).first(where: { !$0.isTerminated }) else { continue }

            let pid = app.processIdentifier
            let objectID = Self.processObject(for: pid)
            guard objectID != kAudioObjectUnknown else {
                // 输入法在跑，但系统还没给它音频进程对象：记下 pid，
                // 让「输入法没开」和「状态读不到」保持可区分。
                runningUnboundPIDs[bundleID] = pid
                continue
            }
            runningUnboundPIDs.removeValue(forKey: bundleID)

            live.insert(bundleID)
            if let existing = bindings[bundleID] {
                if existing.objectID == objectID {
                    continue
                }
                removeListeners(for: existing.objectID)
            }
            addListeners(for: objectID)
            bindings[bundleID] = Binding(
                pid: pid,
                objectID: objectID,
                usesNative: nil
            )
            print(
                "[INPUT-STATE] 已绑定 \(bundleID) pid=\(pid) " +
                "audioProcess=\(objectID)"
            )
        }

        for (bundleID, binding) in bindings where !live.contains(bundleID) {
            removeListeners(for: binding.objectID)
            bindings.removeValue(forKey: bundleID)
            print("[INPUT-STATE] 已解绑 \(bundleID)")
        }
    }

    private func addListeners(for objectID: AudioObjectID) {
        var runningAddress = Self.runningInputAddress
        let runningStatus = AudioObjectAddPropertyListenerBlock(
            objectID,
            &runningAddress,
            .main,
            inputStateListener
        )
        var devicesAddress = Self.inputDevicesAddress
        let devicesStatus = AudioObjectAddPropertyListenerBlock(
            objectID,
            &devicesAddress,
            .main,
            inputStateListener
        )
        print(
            "[INPUT-STATE] listeners object=\(objectID) " +
            "\(Self.describe(runningStatus))/\(Self.describe(devicesStatus))"
        )
    }

    private func removeListeners(for objectID: AudioObjectID) {
        var runningAddress = Self.runningInputAddress
        AudioObjectRemovePropertyListenerBlock(
            objectID,
            &runningAddress,
            .main,
            inputStateListener
        )
        var devicesAddress = Self.inputDevicesAddress
        AudioObjectRemovePropertyListenerBlock(
            objectID,
            &devicesAddress,
            .main,
            inputStateListener
        )
    }

    private func unbindAll() {
        for binding in bindings.values {
            removeListeners(for: binding.objectID)
        }
        bindings.removeAll()
        runningUnboundPIDs.removeAll()
    }

    private func publishCurrentSnapshot(force: Bool) {
        guard started else { return }
        let snapshot = readCurrentSnapshot()
        guard force || snapshot != lastSnapshot else { return }
        lastSnapshot = snapshot
        print(
            "[INPUT-STATE] state=\(snapshot.state.rawValue) " +
            "host=\(snapshot.hostTitle ?? "-") " +
            "pid=\(snapshot.pid.map(String.init) ?? "-") " +
            "devices=\(snapshot.deviceSummary)"
        )
        if snapshot.isRecording,
           !snapshot.inputDeviceNames.contains(Self.targetDeviceName)
        {
            print(
                "[INPUT-STATE] ⚠️ 输入法正在录音，但实际输入不是 " +
                Self.targetDeviceName
            )
        }
        onSnapshotChanged?(snapshot)
        stopPollingIfNative()
    }

    /// On 14.2+ the property listeners are enough, so the poll is retired as
    /// soon as every binding answers through the native selector. Only the
    /// device-list fallback needs it.
    private func stopPollingIfNative() {
        guard pollTimer != nil, !bindings.isEmpty else { return }
        guard bindings.values.allSatisfy({ $0.usesNative == true }) else { return }
        pollTimer?.invalidate()
        pollTimer = nil
        print("[INPUT-STATE] 原生状态可用 · 停止轮询")
    }

    private func readCurrentSnapshot() -> Snapshot {
        guard !bindings.isEmpty else {
            return Snapshot(
                state: .unavailable,
                pid: runningUnboundPIDs.values.first,
                processObjectID: nil,
                inputDeviceIDs: [],
                inputDeviceNames: [],
                hostBundleID: nil
            )
        }

        var firstBound: (String, Binding)?
        var active: (String, Binding, HostRead)?
        var firstRead: HostRead?

        for bundleID in monitoredBundleIDs {
            guard var binding = bindings[bundleID] else { continue }
            if firstBound == nil {
                firstBound = (bundleID, binding)
            }
            let read = read(binding: binding)
            if binding.usesNative != read.usesNative {
                binding.usesNative = read.usesNative
                bindings[bundleID] = binding
            }
            if firstRead == nil {
                firstRead = read
                lastReadUsedFallback = !read.usesNative
            }
            if read.state == .active {
                active = (bundleID, binding, read)
                break
            }
        }

        if let active {
            let (bundleID, binding, read) = active
            lastReadUsedFallback = !read.usesNative
            return Snapshot(
                state: .active,
                pid: binding.pid,
                processObjectID: binding.objectID,
                inputDeviceIDs: read.deviceIDs,
                inputDeviceNames: read.deviceNames,
                hostBundleID: bundleID
            )
        }

        guard let firstBound else {
            return Snapshot(
                state: .unavailable,
                pid: runningUnboundPIDs.values.first,
                processObjectID: nil,
                inputDeviceIDs: [],
                inputDeviceNames: [],
                hostBundleID: nil
            )
        }
        let (bundleID, binding) = firstBound
        return Snapshot(
            state: firstRead?.state ?? .unavailable,
            pid: binding.pid,
            processObjectID: binding.objectID,
            inputDeviceIDs: firstRead?.deviceIDs ?? [],
            inputDeviceNames: firstRead?.deviceNames ?? [],
            hostBundleID: bundleID
        )
    }

    private func read(binding: Binding) -> HostRead {
        // Preferred path: macOS 14.2+ reports capture state directly.
        if let running = Self.uint32Property(
            object: binding.objectID,
            selector: kAudioProcessPropertyIsRunningInput,
            scope: kAudioObjectPropertyScopeGlobal
        ) {
            if binding.usesNative != true {
                print("[INPUT-STATE] \(binding.pid) 使用 IsRunningInput 探测录音状态")
            }
            let deviceIDs = Self.objectListProperty(
                object: binding.objectID,
                selector: kAudioProcessPropertyDevices,
                scope: kAudioObjectPropertyScopeInput
            ) ?? []
            return HostRead(
                state: running == 0 ? .inactive : .active,
                deviceIDs: deviceIDs,
                deviceNames: deviceIDs.map(Self.deviceName),
                usesNative: true
            )
        }

        // Fallback for 13.x: the selector is rejected, but the process object
        // still lists the input devices it currently holds open. The list is
        // empty while idle and contains the capture device while recording.
        if let deviceIDs = Self.objectListProperty(
            object: binding.objectID,
            selector: kAudioProcessPropertyDevices,
            scope: kAudioObjectPropertyScopeInput
        ) {
            if binding.usesNative != false {
                print(
                    "[INPUT-STATE] \(binding.pid) IsRunningInput 不可用，" +
                    "改用输入设备列表探测"
                )
            }
            return HostRead(
                state: deviceIDs.isEmpty ? .inactive : .active,
                deviceIDs: deviceIDs,
                deviceNames: deviceIDs.map(Self.deviceName),
                usesNative: false
            )
        }

        return HostRead(
            state: .unavailable,
            deviceIDs: [],
            deviceNames: [],
            usesNative: binding.usesNative ?? true
        )
    }

    private static func processObject(for pid: pid_t) -> AudioObjectID {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var qualifier = pid
        var result = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = withUnsafePointer(to: &qualifier) { qualifierPointer in
            AudioObjectGetPropertyData(
                AudioObjectID(kAudioObjectSystemObject),
                &address,
                UInt32(MemoryLayout<pid_t>.size),
                qualifierPointer,
                &size,
                &result
            )
        }
        return status == noErr ? result : AudioObjectID(kAudioObjectUnknown)
    }

    private static func uint32Property(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> UInt32? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: UInt32 = 0
        var size = UInt32(MemoryLayout<UInt32>.size)
        let status = AudioObjectGetPropertyData(
            object,
            &address,
            0,
            nil,
            &size,
            &value
        )
        return status == noErr ? value : nil
    }

    private static func objectListProperty(
        object: AudioObjectID,
        selector: AudioObjectPropertySelector,
        scope: AudioObjectPropertyScope
    ) -> [AudioObjectID]? {
        var address = AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            object,
            &address,
            0,
            nil,
            &size
        ) == noErr else { return nil }
        if size == 0 { return [] }

        var values = [AudioObjectID](
            repeating: 0,
            count: Int(size) / MemoryLayout<AudioObjectID>.size
        )
        guard AudioObjectGetPropertyData(
            object,
            &address,
            0,
            nil,
            &size,
            &values
        ) == noErr else { return nil }
        return values
    }

    private static func deviceName(_ deviceID: AudioDeviceID) -> String {
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioObjectPropertyName,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
        var value: CFString = "未知设备" as CFString
        var size = UInt32(MemoryLayout<CFString>.size)
        let status = withUnsafeMutablePointer(to: &value) { pointer in
            AudioObjectGetPropertyData(
                deviceID,
                &address,
                0,
                nil,
                &size,
                pointer
            )
        }
        return status == noErr ? value as String : "设备 \(deviceID)"
    }

    private static func describe(_ status: OSStatus) -> String {
        status == noErr ? "OK" : String(status)
    }

    private static var processListAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyProcessObjectList,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static var runningInputAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyIsRunningInput,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private static var inputDevicesAddress: AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: kAudioProcessPropertyDevices,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain
        )
    }
}
