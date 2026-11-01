#if DEBUG
import CoreAudio
import Foundation

enum VoiceSessionSelfTest {
    private final class FakeDoubaoState: DoubaoAudioStateProviding {
        var onSnapshotChanged: ((DoubaoAudioStateMonitor.Snapshot) -> Void)?
        private(set) var snapshot: DoubaoAudioStateMonitor.Snapshot
        let usesDeviceListFallback: Bool
        private let boundProcessObjectID: AudioObjectID?
        private let boundPID: pid_t?

        init(
            state: DoubaoAudioStateMonitor.State = .inactive,
            usesDeviceListFallback: Bool = false,
            processObjectID: AudioObjectID? = 456,
            pid: pid_t? = 123
        ) {
            self.usesDeviceListFallback = usesDeviceListFallback
            boundProcessObjectID = processObjectID
            boundPID = pid
            snapshot = Self.makeSnapshot(
                state,
                processObjectID: processObjectID,
                pid: pid
            )
        }

        func start() {}
        func stop() {}

        func snapshotNow() -> DoubaoAudioStateMonitor.Snapshot {
            snapshot
        }

        func emit(_ state: DoubaoAudioStateMonitor.State) {
            snapshot = Self.makeSnapshot(
                state,
                processObjectID: boundProcessObjectID,
                pid: boundPID
            )
            onSnapshotChanged?(snapshot)
        }

        private static func makeSnapshot(
            _ state: DoubaoAudioStateMonitor.State,
            processObjectID: AudioObjectID?,
            pid: pid_t?
        ) -> DoubaoAudioStateMonitor.Snapshot {
            DoubaoAudioStateMonitor.Snapshot(
                state: state,
                pid: pid,
                processObjectID: processObjectID,
                inputDeviceIDs: state == .active ? [789] : [],
                inputDeviceNames: state == .active ? ["vRemoteDr 2ch"] : []
            )
        }
    }

    private final class Harness {
        let doubao: FakeDoubaoState
        let coordinator: X6SessionCoordinator
        var clock = Date(timeIntervalSince1970: 1_000)
        var triggerTapCount = 0
        var routeChanges = [Bool]()
        var openRequests = [(VoiceRemoteID, Bool)]()
        var closeRequestCount = 0
        var openResults = [RemoteMicrophoneOpenResult]()
        var preferredRemote: VoiceRemoteID? = .chromecast

        init(
            initialState: DoubaoAudioStateMonitor.State = .inactive,
            usesDeviceListFallback: Bool = false,
            processObjectID: AudioObjectID? = 456,
            pid: pid_t? = 123
        ) {
            doubao = FakeDoubaoState(
                state: initialState,
                usesDeviceListFallback: usesDeviceListFallback,
                processObjectID: processObjectID,
                pid: pid
            )
            var routeSink: ((Bool) -> Void)?
            var triggerSink: (() -> Void)?
            var nowSink: (() -> Date)?
            coordinator = X6SessionCoordinator(
                doubaoState: doubao,
                setRemoteRouteActive: { routeSink?($0) },
                triggerTap: { triggerSink?() },
                now: { nowSink?() ?? Date(timeIntervalSince1970: 0) }
            )
            routeSink = { [weak self] active in
                self?.routeChanges.append(active)
            }
            triggerSink = { [weak self] in
                self?.triggerTapCount += 1
            }
            nowSink = { [weak self] in
                self?.clock ?? Date(timeIntervalSince1970: 0)
            }
            coordinator.preferredRemoteProvider = { [weak self] in
                self?.preferredRemote
            }
            coordinator.onMicrophoneOpenRequested = {
                [weak self] remote, bypass in
                guard let self else { return .unavailable }
                self.openRequests.append((remote, bypass))
                return self.openResults.isEmpty
                    ? .sent
                    : self.openResults.removeFirst()
            }
            coordinator.onMicrophoneCloseRequested = { [weak self] in
                self?.closeRequestCount += 1
            }
            coordinator.start()
        }

        func advance(_ seconds: TimeInterval) {
            clock = clock.addingTimeInterval(seconds)
        }

        func beginChromecastPress() {
            coordinator.remoteAudioStarted(
                remote: .chromecast,
                reason: 0x03,
                supportsPhysicalHoldGesture: true
            )
        }

        func endChromecastPress() {
            coordinator.remoteAudioStopped(remote: .chromecast, reason: 0x02)
        }
    }

    private final class CheckContext {
        private(set) var failures = 0

        func expect(
            _ condition: @autoclosure () -> Bool,
            _ message: String
        ) {
            if condition() {
                VoiceSessionSelfTest.emit("[SELF-TEST] PASS \(message)")
            } else {
                failures += 1
                VoiceSessionSelfTest.emit("[SELF-TEST] FAIL \(message)")
            }
        }
    }

    private static func emit(_ message: String) {
        FileHandle.standardError.write(Data((message + "\n").utf8))
    }

    static func run() -> Bool {
        let checks = CheckContext()
        testActiveBeforeRelease(checks)
        testStopBeforeActive(checks)
        testSecondTapCloses(checks)
        testLongPressCloses(checks)
        testKeyboardOpenRemoteClose(checks)
        testRemoteOpenKeyboardClose(checks)
        testX6ReasonZeroOpens(checks)
        testChromecastReasonZeroWhileClosedIsIgnored(checks)
        testIndependentRemoteStops(checks)
        testDebouncedRetry(checks)
        testNativeIdleClosesImmediately(checks)
        testFallbackIdleIsDebounced(checks)
        testNeverStartingSessionCloses(checks)
        testUnreadableStateKeepsSession(checks)
        testMissingProcessObjectCloses(checks)
        testUnbindableProcessKeepsSession(checks)
        testAudioRouteSwitchesInput(checks)
        testAudioRouteRestoresOnStop(checks)
        testAudioRouteSettlesLeftoverAfterCrash(checks)
        testAudioRouteRespectsUserChange(checks)
        testAudioRouteSkipsWhenTargetMissing(checks)
        testAudioRouteLeavesManualChoiceAlone(checks)
        testAudioRouteHonoursDisabledSwitch(checks)
        testAudioRouteProtectsOutput(checks)
        testAudioRouteFallsBackWhenSavedDeviceGone(checks)
        testAudioRouteManualRestoreWithoutHistory(checks)
        emit("[SELF-TEST] completed failures=\(checks.failures)")
        return checks.failures == 0
    }

    private static func testActiveBeforeRelease(_ c: CheckContext) {
        let h = Harness()
        h.beginChromecastPress()
        h.doubao.emit(.active)
        c.expect(h.openRequests.isEmpty, "active-before-release waits for physical STOP")
        h.advance(0.18)
        h.endChromecastPress()
        c.expect(h.triggerTapCount == 1, "first short tap sends one trigger")
        c.expect(h.openRequests.count == 1, "physical STOP immediately requests persistent stream")
        c.expect(h.openRequests.first?.0 == .chromecast, "recovery targets Chromecast")
        c.expect(h.openRequests.first?.1 == true, "recovery bypasses transport debounce")
        c.expect(h.coordinator.debugSnapshot.phase == "open", "active-before-release remains open")
    }

    private static func testStopBeforeActive(_ c: CheckContext) {
        let h = Harness()
        h.beginChromecastPress()
        h.advance(0.12)
        h.endChromecastPress()
        c.expect(h.openRequests.count == 1, "stop-before-active also opens without fixed delay")
        h.doubao.emit(.active)
        c.expect(h.openRequests.count == 1, "active confirmation does not duplicate MIC_OPEN")
        c.expect(h.coordinator.debugSnapshot.phase == "open", "late active completes opening")
    }

    private static func testSecondTapCloses(_ c: CheckContext) {
        let h = Harness()
        h.beginChromecastPress()
        h.advance(0.15)
        h.endChromecastPress()
        h.doubao.emit(.active)
        h.coordinator.remoteAudioStarted(remote: .chromecast, reason: 0x00)
        h.beginChromecastPress()
        h.advance(0.16)
        h.endChromecastPress()
        c.expect(h.triggerTapCount == 2, "second short tap sends exactly one close trigger")
        c.expect(h.openRequests.count == 1, "second tap never reopens microphone")
        c.expect(h.coordinator.debugSnapshot.phase == "closing", "second tap enters closing")
    }

    private static func testLongPressCloses(_ c: CheckContext) {
        let h = Harness()
        h.beginChromecastPress()
        h.doubao.emit(.active)
        h.advance(0.70)
        h.endChromecastPress()
        c.expect(h.triggerTapCount == 2, "long release sends one close trigger")
        c.expect(h.openRequests.isEmpty, "long release never requests persistent reopen")
        c.expect(h.coordinator.debugSnapshot.phase == "closing", "long release enters closing")
    }

    private static func testKeyboardOpenRemoteClose(_ c: CheckContext) {
        let h = Harness()
        h.coordinator.triggerDownObserved(isSynthetic: false)
        h.coordinator.triggerUpObserved(isSynthetic: false)
        c.expect(h.triggerTapCount == 0, "physical keyboard open is not replayed")
        c.expect(h.openRequests.first?.0 == .chromecast, "keyboard open selects preferred remote")
        h.doubao.emit(.active)
        h.coordinator.remoteAudioStarted(remote: .chromecast, reason: 0x00)
        h.beginChromecastPress()
        h.advance(0.14)
        h.endChromecastPress()
        c.expect(h.triggerTapCount == 1, "remote can close keyboard-opened session")
        c.expect(h.coordinator.debugSnapshot.phase == "closing", "cross-close enters closing")
    }

    private static func testRemoteOpenKeyboardClose(_ c: CheckContext) {
        let h = Harness()
        h.beginChromecastPress()
        h.advance(0.16)
        h.endChromecastPress()
        h.doubao.emit(.active)
        h.coordinator.remoteAudioStarted(remote: .chromecast, reason: 0x00)
        h.coordinator.triggerDownObserved(isSynthetic: false)
        h.coordinator.triggerUpObserved(isSynthetic: false)
        h.doubao.emit(.active)
        RunLoop.current.run(until: Date().addingTimeInterval(0.22))
        c.expect(h.triggerTapCount == 1, "keyboard close does not synthesize another trigger")
        c.expect(h.openRequests.count == 1, "stale active cannot reopen transport")
        c.expect(h.coordinator.debugSnapshot.phase == "closing", "stale active keeps closing phase")
        h.doubao.emit(.inactive)
        c.expect(h.coordinator.debugSnapshot.phase == "closed", "inactive completes keyboard close")
    }

    private static func testIndependentRemoteStops(_ c: CheckContext) {
        let h = Harness()
        h.coordinator.remoteAudioStarted(remote: .x6, reason: 0x00)
        h.coordinator.remoteAudioStarted(
            remote: .chromecast,
            reason: 0x03,
            supportsPhysicalHoldGesture: true
        )
        c.expect(h.triggerTapCount == 1, "second remote start does not toggle Doubao twice")
        c.expect(
            h.coordinator.debugSnapshot.streamingRemotes == Set([.x6, .chromecast]),
            "both remote transports are tracked independently"
        )
        h.coordinator.remoteAudioStopped(remote: .x6, reason: 0x00)
        c.expect(
            h.coordinator.debugSnapshot.streamingRemotes == Set([.chromecast]),
            "one remote STOP does not erase the other"
        )
    }

    private static func testX6ReasonZeroOpens(_ c: CheckContext) {
        let h = Harness()
        h.coordinator.remoteAudioStarted(remote: .x6, reason: 0x00)
        c.expect(h.triggerTapCount == 1, "X6 physical reason-0 sends one open trigger")
        c.expect(h.coordinator.debugSnapshot.phase == "opening", "X6 reason-0 begins opening")
        c.expect(
            h.coordinator.debugSnapshot.streamingRemotes == Set([.x6]),
            "X6 reason-0 keeps its physical stream"
        )
    }

    private static func testChromecastReasonZeroWhileClosedIsIgnored(
        _ c: CheckContext
    ) {
        let h = Harness()
        h.coordinator.remoteAudioStarted(remote: .chromecast, reason: 0x00)
        c.expect(h.triggerTapCount == 0, "stale Chromecast reason-0 sends no trigger")
        c.expect(h.coordinator.debugSnapshot.phase == "closed", "stale Chromecast reason-0 stays closed")
        c.expect(
            h.coordinator.debugSnapshot.streamingRemotes.isEmpty,
            "stale Chromecast reason-0 is closed locally"
        )
    }

    private static func testDebouncedRetry(_ c: CheckContext) {
        let h = Harness()
        h.openResults = [.retryAfter(0.02), .sent]
        h.beginChromecastPress()
        h.advance(0.13)
        h.endChromecastPress()
        c.expect(h.coordinator.debugSnapshot.openRequestedRemote == nil, "debounced request is not marked sent")
        RunLoop.current.run(until: Date().addingTimeInterval(0.08))
        c.expect(h.openRequests.count == 2, "debounced open receives a bounded retry")
        c.expect(
            h.coordinator.debugSnapshot.openRequestedRemote == .chromecast,
            "only the sent retry becomes pending"
        )
    }

    // MARK: - Capture-state source compatibility

    /// macOS 14.2+ path: `IsRunningInput` is authoritative, so an idle snapshot
    /// must close the session without any extra confirmation window.
    private static func testNativeIdleClosesImmediately(_ c: CheckContext) {
        let h = Harness()
        h.beginChromecastPress()
        h.doubao.emit(.active)
        h.advance(0.16)
        h.endChromecastPress()
        c.expect(h.coordinator.debugSnapshot.phase == "open", "native active opens")
        h.doubao.emit(.inactive)
        c.expect(
            h.coordinator.debugSnapshot.phase == "closed",
            "native idle closes immediately"
        )
    }

    /// macOS 13 fallback path: the device list can flicker, so an idle
    /// snapshot is confirmed once before the session is torn down.
    private static func testFallbackIdleIsDebounced(_ c: CheckContext) {
        let h = Harness(usesDeviceListFallback: true)
        h.beginChromecastPress()
        h.doubao.emit(.active)
        h.advance(0.16)
        h.endChromecastPress()
        c.expect(h.coordinator.debugSnapshot.phase == "open", "fallback active opens")

        h.doubao.emit(.inactive)
        c.expect(
            h.coordinator.debugSnapshot.phase == "open",
            "fallback idle waits for confirmation"
        )
        h.doubao.emit(.active)
        RunLoop.current.run(until: Date().addingTimeInterval(0.45))
        c.expect(
            h.coordinator.debugSnapshot.phase == "open",
            "fallback idle flicker is ignored"
        )

        h.doubao.emit(.inactive)
        RunLoop.current.run(until: Date().addingTimeInterval(0.45))
        c.expect(
            h.coordinator.debugSnapshot.phase == "closed",
            "fallback idle closes after confirmation"
        )
    }

    private static func testNeverStartingSessionCloses(_ c: CheckContext) {
        let h = Harness()
        h.beginChromecastPress()
        h.advance(0.16)
        h.endChromecastPress()
        c.expect(h.coordinator.debugSnapshot.phase == "opening", "session waits in opening")
        RunLoop.current.run(until: Date().addingTimeInterval(3.2))
        c.expect(
            h.coordinator.debugSnapshot.phase == "closed",
            "session that never records closes after retries"
        )
    }

    /// A bound process object with an unreadable state is the macOS 13 case
    /// that used to cut every dictation off after one second.
    private static func testUnreadableStateKeepsSession(_ c: CheckContext) {
        let h = Harness(initialState: .unavailable)
        h.beginChromecastPress()
        h.advance(0.16)
        h.endChromecastPress()
        RunLoop.current.run(until: Date().addingTimeInterval(3.2))
        c.expect(
            h.coordinator.debugSnapshot.phase == "open",
            "unreadable state keeps the session open"
        )
    }

    /// No pid and no process object means Doubao is not running at all; that
    /// keeps the original close behaviour.
    private static func testMissingProcessObjectCloses(_ c: CheckContext) {
        let h = Harness(
            initialState: .unavailable,
            processObjectID: nil,
            pid: nil
        )
        h.beginChromecastPress()
        h.advance(0.16)
        h.endChromecastPress()
        RunLoop.current.run(until: Date().addingTimeInterval(3.2))
        c.expect(
            h.coordinator.debugSnapshot.phase == "closed",
            "no Doubao process still closes"
        )
    }

    /// Doubao runs, but this system cannot bind a process object at all
    /// (possible on macOS 12). Never close on that basis.
    private static func testUnbindableProcessKeepsSession(_ c: CheckContext) {
        let h = Harness(
            initialState: .unavailable,
            processObjectID: nil,
            pid: 123
        )
        h.beginChromecastPress()
        h.advance(0.16)
        h.endChromecastPress()
        RunLoop.current.run(until: Date().addingTimeInterval(3.2))
        c.expect(
            h.coordinator.debugSnapshot.phase == "open",
            "running but unbindable Doubao keeps the session"
        )
    }

    // MARK: - 系统默认输入接管

    private static let builtInMic = AudioDeviceSnapshot(
        id: 1,
        uid: "AppleHDAEngineInput:1F,3,0,1,0:1",
        name: "Built-in Microphone",
        inputChannels: 2,
        outputChannels: 0
    )

    private static let builtInSpeaker = AudioDeviceSnapshot(
        id: 2,
        uid: "AppleHDAEngineOutput:1F,3,0,1,1:0",
        name: "Built-in Output",
        inputChannels: 0,
        outputChannels: 2
    )

    private static let virtualDriver = AudioDeviceSnapshot(
        id: 3,
        uid: "vRemoteDr2ch_UID",
        name: "vRemoteDr 2ch",
        inputChannels: 2,
        outputChannels: 2
    )

    private static let usbMic = AudioDeviceSnapshot(
        id: 4,
        uid: "USBAudioEngine:USB Mic:1",
        name: "USB Mic",
        inputChannels: 1,
        outputChannels: 0
    )

    private final class FakeAudioDevices: AudioDeviceProviding {
        private var devices: [AudioDeviceSnapshot]
        private var inputUID: String
        private var outputUID: String
        private(set) var setInputCalls: [String] = []
        private(set) var setOutputCalls: [String] = []

        init(
            devices: [AudioDeviceSnapshot],
            inputUID: String,
            outputUID: String
        ) {
            self.devices = devices
            self.inputUID = inputUID
            self.outputUID = outputUID
        }

        func allDevices() -> [AudioDeviceSnapshot] { devices }

        func defaultInput() -> AudioDeviceSnapshot? {
            devices.first { $0.uid == inputUID }
        }

        func defaultOutput() -> AudioDeviceSnapshot? {
            devices.first { $0.uid == outputUID }
        }

        @discardableResult
        func setDefaultInput(_ device: AudioDeviceSnapshot) -> Bool {
            setInputCalls.append(device.uid)
            inputUID = device.uid
            return true
        }

        @discardableResult
        func setDefaultOutput(_ device: AudioDeviceSnapshot) -> Bool {
            setOutputCalls.append(device.uid)
            outputUID = device.uid
            return true
        }

        /// 模拟用户手动切换默认输入。
        func selectInput(uid: String) { inputUID = uid }
        /// 模拟设备被拔掉。
        func removeDevice(uid: String) { devices.removeAll { $0.uid == uid } }
    }

    private final class FakeRouteStore: AudioRouteStoring {
        var autoRouteInput: Bool
        var savedInputUID: String?
        var pendingRestore: Bool

        init(
            autoRouteInput: Bool = true,
            savedInputUID: String? = nil,
            pendingRestore: Bool = false
        ) {
            self.autoRouteInput = autoRouteInput
            self.savedInputUID = savedInputUID
            self.pendingRestore = pendingRestore
        }
    }

    private static func makeRouteDevices(
        input: AudioDeviceSnapshot = builtInMic,
        output: AudioDeviceSnapshot = builtInSpeaker,
        includeVirtual: Bool = true,
        includeUSB: Bool = true
    ) -> FakeAudioDevices {
        var list = [builtInMic, builtInSpeaker]
        if includeVirtual { list.append(virtualDriver) }
        if includeUSB { list.append(usbMic) }
        return FakeAudioDevices(
            devices: list,
            inputUID: input.uid,
            outputUID: output.uid
        )
    }

    private static func testAudioRouteSwitchesInput(_ c: CheckContext) {
        let devices = makeRouteDevices()
        let store = FakeRouteStore()
        let route = AudioDeviceRoute(devices: devices, store: store)
        route.start()

        c.expect(
            devices.defaultInput()?.uid == virtualDriver.uid,
            "route moves default input to vRemoteDr"
        )
        c.expect(
            store.savedInputUID == builtInMic.uid,
            "route remembers the replaced input uid"
        )
        c.expect(
            store.pendingRestore,
            "route leaves a restore mark for crashes"
        )
        c.expect(
            devices.setOutputCalls.isEmpty,
            "route never touches the default output"
        )
    }

    private static func testAudioRouteRestoresOnStop(_ c: CheckContext) {
        let devices = makeRouteDevices()
        let store = FakeRouteStore()
        let route = AudioDeviceRoute(devices: devices, store: store)
        route.start()
        route.stop()

        c.expect(
            devices.defaultInput()?.uid == builtInMic.uid,
            "quit restores the original default input"
        )
        c.expect(
            !store.pendingRestore && store.savedInputUID == nil,
            "quit clears the restore mark"
        )
    }

    /// 强杀之后留下的标记：下次启动先把设备还回去，再按需重新接管。
    private static func testAudioRouteSettlesLeftoverAfterCrash(_ c: CheckContext) {
        let devices = makeRouteDevices(input: virtualDriver)
        let store = FakeRouteStore(
            savedInputUID: builtInMic.uid,
            pendingRestore: true
        )
        let route = AudioDeviceRoute(devices: devices, store: store)
        route.start()

        c.expect(
            devices.setInputCalls.first == builtInMic.uid,
            "leftover route is settled before re-taking the input"
        )
        c.expect(
            devices.defaultInput()?.uid == virtualDriver.uid,
            "running app re-takes the input after settling"
        )
        c.expect(
            store.savedInputUID == builtInMic.uid,
            "re-take records the settled device again"
        )
    }

    private static func testAudioRouteRespectsUserChange(_ c: CheckContext) {
        let devices = makeRouteDevices()
        let store = FakeRouteStore()
        let route = AudioDeviceRoute(devices: devices, store: store)
        route.start()
        devices.selectInput(uid: usbMic.uid)
        route.stop()

        c.expect(
            devices.defaultInput()?.uid == usbMic.uid,
            "user's own device choice survives quit"
        )
        c.expect(
            !store.pendingRestore,
            "quit clears the mark even when the user took over"
        )
    }

    private static func testAudioRouteSkipsWhenTargetMissing(_ c: CheckContext) {
        let devices = makeRouteDevices(includeVirtual: false)
        let store = FakeRouteStore()
        let route = AudioDeviceRoute(devices: devices, store: store)
        route.start()

        c.expect(
            devices.defaultInput()?.uid == builtInMic.uid,
            "missing driver leaves the input alone"
        )
        c.expect(
            !store.pendingRestore,
            "missing driver writes no restore mark"
        )
    }

    /// 默认输入已经是虚拟设备（上一版手动设的）：不做多余的设备写入，
    /// 但要接管还原责任，否则退出后系统会停在没人写入的设备上。
    private static func testAudioRouteLeavesManualChoiceAlone(_ c: CheckContext) {
        let devices = makeRouteDevices(input: virtualDriver)
        let store = FakeRouteStore()
        let route = AudioDeviceRoute(devices: devices, store: store)
        route.start()

        c.expect(
            devices.setInputCalls.isEmpty,
            "an already-correct input needs no device write"
        )
        c.expect(
            store.savedInputUID == builtInMic.uid && store.pendingRestore,
            "an existing virtual input is adopted for restore"
        )

        route.stop()
        c.expect(
            devices.defaultInput()?.uid == builtInMic.uid,
            "the adopted virtual input is reverted on quit"
        )
    }

    private static func testAudioRouteHonoursDisabledSwitch(_ c: CheckContext) {
        let devices = makeRouteDevices()
        let store = FakeRouteStore(autoRouteInput: false)
        let route = AudioDeviceRoute(devices: devices, store: store)
        route.start()

        c.expect(
            devices.defaultInput()?.uid == builtInMic.uid,
            "disabled auto-route leaves the system input untouched"
        )
    }

    /// vRemoteDr 2ch 出现在输出列表时，误选会让整机静音，必须救回来。
    private static func testAudioRouteProtectsOutput(_ c: CheckContext) {
        let devices = makeRouteDevices(output: virtualDriver)
        let store = FakeRouteStore(autoRouteInput: false)
        let route = AudioDeviceRoute(devices: devices, store: store)
        route.start()

        c.expect(
            devices.defaultOutput()?.uid == builtInSpeaker.uid,
            "virtual default output is moved back to the speaker"
        )
    }

    private static func testAudioRouteFallsBackWhenSavedDeviceGone(_ c: CheckContext) {
        let devices = makeRouteDevices(input: virtualDriver, includeUSB: false)
        let store = FakeRouteStore(
            savedInputUID: usbMic.uid,
            pendingRestore: true
        )
        let route = AudioDeviceRoute(devices: devices, store: store)
        route.start()

        c.expect(
            devices.setInputCalls.contains(builtInMic.uid),
            "unplugged original device falls back to the built-in mic"
        )
    }

    private static func testAudioRouteManualRestoreWithoutHistory(_ c: CheckContext) {
        // 自动切换关掉时不收养，模拟「用户手工选过虚拟设备、App 没有记录」。
        let devices = makeRouteDevices(input: virtualDriver)
        let store = FakeRouteStore(autoRouteInput: false)
        let route = AudioDeviceRoute(devices: devices, store: store)
        route.start()

        let restored = route.restoreNow()
        c.expect(restored, "manual restore works without a saved uid")
        c.expect(
            devices.defaultInput()?.uid == builtInMic.uid,
            "manual restore picks the built-in mic when history is missing"
        )
    }
}
#endif
