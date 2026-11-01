import Foundation

enum VoiceRemoteID: String, CaseIterable {
    case x6
    case chromecast
}

enum RemoteMicrophoneOpenResult: Equatable {
    case sent
    case alreadyStreaming
    case retryAfter(TimeInterval)
    case unavailable
    case failed(String)
}

protocol DoubaoAudioStateProviding: AnyObject {
    var onSnapshotChanged: ((DoubaoAudioStateMonitor.Snapshot) -> Void)? {
        get set
    }

    /// See `usesDeviceListFallback` in the extension below.
    var usesDeviceListFallback: Bool { get }

    /// Short name of the input method behind the current snapshot, so status
    /// text reads「微信输入法录音中」instead of always naming Doubao.
    var activeHostTitle: String? { get }

    func start()
    func stop()
    func snapshotNow() -> DoubaoAudioStateMonitor.Snapshot
}

extension DoubaoAudioStateMonitor: DoubaoAudioStateProviding {}

extension DoubaoAudioStateProviding {
    /// True only when capture state is inferred from the input-device list,
    /// which is the macOS 13 fallback. Everywhere else the state comes from
    /// `kAudioProcessPropertyIsRunningInput` and behaves as before.
    var usesDeviceListFallback: Bool { false }

    var activeHostTitle: String? { nil }
}

/// Coordinates the input-method toggle, supported remote gestures, and each
/// remote's independent ATVV transport.
///
/// A transport START/STOP is never itself a keyboard toggle. A physical
/// keyboard trigger already reaches Doubao. A remote gesture synthesizes
/// exactly one trigger only when it changes the intended recognition state.
final class X6SessionCoordinator {
    private enum Phase: String {
        case closed
        case opening
        case open
        case closing
    }

    private enum Owner: String {
        case none
        case remote
        case keyboard
    }

    private struct PhysicalVoiceGesture {
        let beganAt: Date
        let recognitionWasOpen: Bool
        let generation: UInt64
    }

    struct DebugSnapshot: Equatable {
        let phase: String
        let generation: UInt64
        let sessionRemote: VoiceRemoteID?
        let streamingRemotes: Set<VoiceRemoteID>
        let openRequestedRemote: VoiceRemoteID?
    }

    private static let remoteHoldThreshold: TimeInterval = 0.55
    private static let openConfirmationTimeout: TimeInterval = 1.0
    private static let closeVerificationTimeout: TimeInterval = 1.2
    private static let maximumOpenAttempts = 3
    private static let startVerificationAttempts = 3
    private static let startVerificationInterval: TimeInterval = 1.0
    /// 短按锁定：按住时间短于这个值才算「短按」，松手后升级成免手扶；
    /// 超过它就是一次正常的「按住说完」。
    private static let tapToLatchThreshold: TimeInterval = 0.7
    /// 短按锁定：松开后至少按住这么久再发空格，越过微信输入法的长按
    /// 待定窗口。待定窗口内的空格会被它跳过、直接打进文档。
    private static let latchMinHold: TimeInterval = 0.5
    /// 短按锁定：松开后等输入法真正开始录音的观察窗口。超过这个时间还没
    /// 开始录音，说明没必要锁定，直接按普通短按收尾。
    private static let latchStartTimeout: TimeInterval = 0.9
    private static let latchStartProbeInterval: TimeInterval = 0.1
    /// 锁定之后确认录音仍在继续的时间点（微信输入法会忽略无效的空格）。
    private static let latchVerificationDelay: TimeInterval = 0.8
    /// 从免手扶结束录音时，按住触发键越过微信输入法的长按阈值（它会把
    /// 免手扶升级回按住说话），再松开才真正结束。
    private static let latchReleaseHold: TimeInterval = 0.5

    /// 合成按键当前处于哪一步。任何退出路径都必须把它清干净，否则用户
    /// 的键盘上会残留一个按住的 Fn/Option。
    private enum TriggerHoldState {
        case idle
        case holding(since: Date)
        case latched
        case closingGesture
    }

    private let doubaoState: any DoubaoAudioStateProviding
    private let setRemoteRouteActive: (Bool) -> Void
    private let triggerTap: () -> Void
    private let triggerDown: () -> Void
    private let triggerUp: () -> Void
    private let spaceTap: () -> Void
    private let triggerStyleProvider: () -> VoiceTriggerStyle
    private let now: () -> Date

    private var phase: Phase = .closed
    private var owner: Owner = .none
    private var generation: UInt64 = 0
    private var routeActive = false
    private var sessionRemote: VoiceRemoteID?
    private var streamingRemotes = Set<VoiceRemoteID>()
    private var openRequestedRemote: VoiceRemoteID?
    private var physicalVoiceGestures = [VoiceRemoteID: PhysicalVoiceGesture]()

    private var triggerHold: TriggerHoldState = .idle
    private var triggerWorkItem: DispatchWorkItem?
    private var latchProbeWorkItem: DispatchWorkItem?
    private var latchVerificationWorkItem: DispatchWorkItem?

    private var routeCloseWorkItem: DispatchWorkItem?
    private var startVerificationWorkItem: DispatchWorkItem?
    private var closeVerificationWorkItem: DispatchWorkItem?
    private var openRetryWorkItem: DispatchWorkItem?
    private var openConfirmationWorkItem: DispatchWorkItem?
    private var idleConfirmationWorkItem: DispatchWorkItem?

    var preferredRemoteProvider: (() -> VoiceRemoteID?)?
    var onMicrophoneOpenRequested:
        ((VoiceRemoteID, Bool) -> RemoteMicrophoneOpenResult)?
    var onMicrophoneCloseRequested: (() -> Void)?
    var onStateChanged: ((String) -> Void)?

    init(
        doubaoState: any DoubaoAudioStateProviding,
        setRemoteRouteActive: @escaping (Bool) -> Void = {
            AudioPipe.shared.setRemoteActive($0)
        },
        triggerTap: @escaping () -> Void = { Key.triggerTap() },
        triggerDown: @escaping () -> Void = { Key.triggerDown() },
        triggerUp: @escaping () -> Void = { Key.triggerUp() },
        spaceTap: @escaping () -> Void = { Key.spaceTap() },
        triggerStyle: @escaping () -> VoiceTriggerStyle = {
            VoiceTriggerStyle.resolve()
        },
        now: @escaping () -> Date = Date.init
    ) {
        self.doubaoState = doubaoState
        self.setRemoteRouteActive = setRemoteRouteActive
        self.triggerTap = triggerTap
        self.triggerDown = triggerDown
        self.triggerUp = triggerUp
        self.spaceTap = spaceTap
        self.triggerStyleProvider = triggerStyle
        self.now = now
    }

    var debugSnapshot: DebugSnapshot {
        DebugSnapshot(
            phase: phase.rawValue,
            generation: generation,
            sessionRemote: sessionRemote,
            streamingRemotes: streamingRemotes,
            openRequestedRemote: openRequestedRemote
        )
    }

    func start() {
        doubaoState.onSnapshotChanged = { [weak self] snapshot in
            self?.handleDoubaoSnapshot(snapshot)
        }
        doubaoState.start()
    }

    // MARK: - ATVV transport

    func remoteAudioStarted(
        remote: VoiceRemoteID,
        reason: UInt8,
        supportsPhysicalHoldGesture: Bool = false
    ) {
        let snapshot = doubaoState.snapshotNow()
        let inserted = streamingRemotes.insert(remote).inserted
        let wasRequested = openRequestedRemote == remote
        if wasRequested {
            openRequestedRemote = nil
            openConfirmationWorkItem?.cancel()
            openConfirmationWorkItem = nil
        }

        if phase == .closing {
            print(
                "[VOICE-SESSION] late AUDIO_START while closing " +
                "remote=\(remote.rawValue) reason=" +
                String(format: "0x%02x", reason)
            )
            closeAllRemoteTransports()
            return
        }

        // 免手扶锁定期间再按一次语音键 = 结束。由宿主主动请求的音频流不算
        // 按下动作，否则锁定后重新拉起麦克风会立刻把自己关掉。
        if isLatched, !wasRequested, phase == .open || phase == .opening {
            activateRemoteRoute()
            print("[VOICE-SESSION] latched session: press begins close gesture")
            beginClosing(sendTrigger: true, reason: "latched press")
            return
        }

        if supportsPhysicalHoldGesture, !usesPushToTalk, reason == 0x03 {
            let recognitionWasOpen = phase == .open || snapshot.isRecording
            if physicalVoiceGestures[remote] == nil {
                physicalVoiceGestures[remote] = PhysicalVoiceGesture(
                    beganAt: now(),
                    recognitionWasOpen: recognitionWasOpen,
                    generation: generation
                )
            }
            print(
                "[VOICE-SESSION] physical ATVV DOWN " +
                "remote=\(remote.rawValue) " +
                "recognitionWasOpen=\(recognitionWasOpen)"
            )

            if recognitionWasOpen {
                sessionRemote = remote
                activateRemoteRoute()
                publish("遥控器按住录音中")
                return
            }
        }

        if !inserted {
            print(
                "[VOICE-SESSION] duplicate AUDIO_START ignored " +
                "remote=\(remote.rawValue) reason=" +
                String(format: "0x%02x", reason)
            )
            return
        }

        activateRemoteRoute()
        print(
            "[VOICE-SESSION] AUDIO_START remote=\(remote.rawValue) reason=" +
            String(format: "0x%02x", reason) +
            " phase=\(phase.rawValue) owner=\(owner.rawValue) " +
            "doubaoBefore=\(snapshot.state.rawValue) " +
            "device=\(snapshot.deviceSummary)"
        )

        switch phase {
        case .opening, .open:
            publish("\(hostLabel)录音中 · 遥控器已接入")

        case .closed:
            // Chromecast reserves reason 0x03 for a physical voice press, so
            // a reason-0 stream while closed can only be a stale response to
            // an earlier host request. X6 is different: its verified physical
            // first press itself arrives as reason 0x00 and must remain a
            // valid open gesture.
            guard remote != .chromecast || reason != 0x00 else {
                print(
                    "[VOICE-SESSION] stale host AUDIO_START ignored " +
                    "remote=\(remote.rawValue)"
                )
                closeAllRemoteTransports()
                return
            }
            beginOpening(
                owner: .remote,
                remote: remote,
                sendTrigger: true,
                requestTransportImmediately: false
            )
            // beginOpening advances the session generation. Keep the
            // in-flight physical gesture attached to that new session so its
            // matching AUDIO_STOP can complete the tap/hold decision.
            if supportsPhysicalHoldGesture,
               reason == 0x03,
               let gesture = physicalVoiceGestures[remote]
            {
                physicalVoiceGestures[remote] = PhysicalVoiceGesture(
                    beganAt: gesture.beganAt,
                    recognitionWasOpen: gesture.recognitionWasOpen,
                    generation: generation
                )
            }

        case .closing:
            break
        }
    }

    func remoteAudioStopped(remote: VoiceRemoteID, reason: UInt8) {
        streamingRemotes.remove(remote)
        if openRequestedRemote == remote {
            openRequestedRemote = nil
            openConfirmationWorkItem?.cancel()
            openConfirmationWorkItem = nil
        }

        // 长按说话：遥控器松手（音频流结束）就是「说完了」。微信输入法的
        // 录音时长与按键时长一致，不需要常驻麦克风。
        if usesPushToTalk, case .holding = triggerHold,
           phase == .opening || phase == .open
        {
            if let gesture = physicalVoiceGestures.removeValue(forKey: remote) {
                print(
                    String(
                        format:
                            "[VOICE-SESSION] push-to-talk release remote=%@ " +
                            "duration=%.3fs",
                        remote.rawValue,
                        now().timeIntervalSince(gesture.beganAt)
                    )
                )
            }
            closeRecognitionFromRemote(reason: "push-to-talk release")
            return
        }

        // 免手扶收尾时我们自己按着触发键，此时遥控器的松开事件没有意义。
        if case .closingGesture = triggerHold {
            print("[VOICE-SESSION] release ignored during latch close gesture")
            return
        }

        if reason == 0x02,
           let gesture = physicalVoiceGestures.removeValue(forKey: remote)
        {
            let duration = now().timeIntervalSince(gesture.beganAt)
            let wasHold = duration >= Self.remoteHoldThreshold
            print(
                String(
                    format:
                        "[VOICE-SESSION] physical ATVV UP remote=%@ " +
                        "duration=%.3fs kind=%@ recognitionWasOpen=%@",
                    remote.rawValue,
                    duration,
                    wasHold ? "HOLD" : "TAP",
                    gesture.recognitionWasOpen ? "true" : "false"
                )
            )

            guard gesture.generation == generation else {
                print(
                    "[VOICE-SESSION] stale physical release ignored " +
                    "remote=\(remote.rawValue)"
                )
                return
            }

            if wasHold || gesture.recognitionWasOpen {
                closeRecognitionFromRemote(
                    reason: wasHold
                        ? "ATVV HOLD release"
                        : "ATVV TAP toggle"
                )
                return
            }

            // First Chromecast short tap: the physical stream ends at button
            // release. Immediately request a persistent stream from that same
            // remote. BLEBridge has already marked its local stream idle
            // before invoking this callback, so no fixed delay is necessary.
            guard phase == .opening || phase == .open else { return }
            sessionRemote = remote
            requestRemoteTransportOpen(
                remote,
                bypassDebounce: true,
                attempt: 1
            )
            publish("\(hostLabel)录音中 · 遥控器持续收音")
            return
        }

        print(
            "[VOICE-SESSION] AUDIO_STOP remote=\(remote.rawValue) reason=" +
            String(format: "0x%02x", reason) +
            " phase=\(phase.rawValue)"
        )

        // Do not automatically reopen a generic transport STOP. X6 may emit
        // it immediately before its HID toggle-off edge. Only the proven
        // Chromecast physical-tap path above performs an immediate recovery.
        if phase == .open || phase == .opening {
            publish("\(hostLabel)仍开启 · 遥控器音频已停止")
        } else if streamingRemotes.isEmpty {
            scheduleRouteClose(after: 0.08)
        }
    }

    func remoteDisconnected(_ remote: VoiceRemoteID) {
        streamingRemotes.remove(remote)
        physicalVoiceGestures.removeValue(forKey: remote)
        if openRequestedRemote == remote {
            openRequestedRemote = nil
            openRetryWorkItem?.cancel()
            openRetryWorkItem = nil
            openConfirmationWorkItem?.cancel()
            openConfirmationWorkItem = nil
        }

        guard sessionRemote == remote else { return }
        sessionRemote = preferredRemoteProvider?()
        guard phase == .opening || phase == .open,
              let replacement = sessionRemote
        else { return }
        requestRemoteTransportOpen(
            replacement,
            bypassDebounce: false,
            attempt: 1
        )
    }

    func remoteMicrophoneOpenFailed(remote: VoiceRemoteID, code: UInt16) {
        guard openRequestedRemote == remote,
              phase == .opening || phase == .open
        else { return }
        openRequestedRemote = nil
        openConfirmationWorkItem?.cancel()
        openConfirmationWorkItem = nil
        print(
            "[VOICE-SESSION] MIC_OPEN failed remote=\(remote.rawValue) " +
            String(format: "code=0x%04x", code)
        )
        scheduleOpenRetry(remote: remote, after: 0.20, attempt: 2)
    }

    // MARK: - X6 HID completion

    func remoteHIDShortPress() {
        closeRecognitionFromRemote(reason: "HID SHORT")
    }

    func remoteHIDLongPressEnded() {
        closeRecognitionFromRemote(reason: "HID LONG release")
    }

    // MARK: - Physical keyboard trigger

    /// Called before the real physical trigger reaches Doubao. It updates the
    /// remote transport only; it never synthesizes a second keyboard event.
    func triggerDownObserved(isSynthetic: Bool) {
        guard !isSynthetic else { return }
        let snapshot = doubaoState.snapshotNow()
        let shouldOpen: Bool
        switch phase {
        case .closed:
            shouldOpen = !snapshot.isRecording
        case .closing:
            // A second deliberate physical trigger reverses the user's last
            // intent even if CoreAudio has not published inactive yet.
            shouldOpen = true
        case .opening, .open:
            shouldOpen = false
        }

        print(
            "[TRIGGER] DOWN source=keyboard action=" +
            (shouldOpen ? "open" : "close") +
            " phase=\(phase.rawValue) " +
            "doubaoBefore=\(snapshot.state.rawValue) " +
            "device=\(snapshot.deviceSummary)"
        )

        if shouldOpen {
            guard let remote = preferredRemoteProvider?() else {
                beginOpeningWithoutRemote()
                return
            }
            beginOpening(
                owner: .keyboard,
                remote: remote,
                sendTrigger: false,
                requestTransportImmediately: true
            )
        } else {
            beginClosing(sendTrigger: false, reason: "keyboard trigger")
        }
    }

    func triggerUpObserved(isSynthetic: Bool) {
        guard !isSynthetic else { return }
        print(
            "[TRIGGER] UP source=keyboard phase=\(phase.rawValue) " +
            "owner=\(owner.rawValue)"
        )
        reconcileSoon(after: 0.03)
        reconcileSoon(after: 0.15)
    }

    // MARK: - Lifecycle / manual control

    func forceClose() {
        generation &+= 1
        cancelScheduledWork()
        releaseAllTriggers()
        phase = .closed
        owner = .none
        sessionRemote = nil
        physicalVoiceGestures.removeAll()
        closeRouteAndTransports()
        publish("已手动关闭")
    }

    func stop() {
        forceClose()
        doubaoState.stop()
    }

    // MARK: - Doubao observation

    private func handleDoubaoSnapshot(
        _ snapshot: DoubaoAudioStateMonitor.Snapshot
    ) {
        switch snapshot.state {
        case .active:
            switch phase {
            case .opening:
                startVerificationWorkItem?.cancel()
                startVerificationWorkItem = nil
                phase = .open
                activateRemoteRoute()
                if let remote = sessionRemote,
                   !streamingRemotes.contains(remote),
                   openRequestedRemote != remote
                {
                    requestRemoteTransportOpen(
                        remote,
                        bypassDebounce: false,
                        attempt: 1
                    )
                }
                publish("\(hostLabel)录音中 · \(snapshot.deviceSummary)")

            case .open:
                activateRemoteRoute()
                publish("\(hostLabel)录音中 · \(snapshot.deviceSummary)")

            case .closing:
                // CoreAudio can remain active briefly after the trigger has
                // toggled Doubao off. Never reinterpret this stale edge as a
                // fresh external opening.
                print(
                    "[VOICE-SESSION] active snapshot ignored while closing"
                )

            case .closed:
                adoptExternalActivation(snapshot)
            }

        case .inactive:
            switch phase {
            case .opening:
                // The opening verification owns this transient idle window.
                break
            case .open:
                if self.doubaoState.usesDeviceListFallback {
                    // The device list can drop a frame while the input method
                    // swaps buffers, so confirm before tearing down.
                    self.confirmIdleThenClose()
                } else {
                    self.finalizeClosed(reason: "Doubao inactive")
                }
            case .closing:
                finalizeClosed(reason: "Doubao inactive")
            case .closed:
                if routeActive || !streamingRemotes.isEmpty {
                    closeRouteAndTransports()
                }
            }
            publish("\(hostLabel)已就绪")

        case .unavailable:
            if phase != .opening {
                finalizeClosed(reason: "Doubao unavailable")
            }
            publish("等待\(hostLabel)")
        }
    }

    private func adoptExternalActivation(
        _ snapshot: DoubaoAudioStateMonitor.Snapshot
    ) {
        generation &+= 1
        cancelScheduledWork()
        phase = .open
        owner = .keyboard
        sessionRemote = preferredRemoteProvider?()
        activateRemoteRoute()
        print(
            "[VOICE-SESSION] Doubao external activation adopted " +
            "device=\(snapshot.deviceSummary)"
        )
        if let remote = sessionRemote {
            requestRemoteTransportOpen(
                remote,
                bypassDebounce: false,
                attempt: 1
            )
        }
        publish("\(hostLabel)录音中 · \(snapshot.deviceSummary)")
    }

    // MARK: - State transitions

    private func beginOpeningWithoutRemote() {
        generation &+= 1
        cancelScheduledWork()
        phase = .opening
        owner = .keyboard
        sessionRemote = nil
        activateRemoteRoute()
        scheduleStartVerification(for: generation)
        publish("\(hostLabel)正在启动 · 等待遥控器")
    }

    private func beginOpening(
        owner: Owner,
        remote: VoiceRemoteID,
        sendTrigger: Bool,
        requestTransportImmediately: Bool
    ) {
        generation &+= 1
        cancelScheduledWork()
        phase = .opening
        self.owner = owner
        sessionRemote = remote
        activateRemoteRoute()
        if sendTrigger {
            emitOpenTrigger()
        }
        if requestTransportImmediately {
            requestRemoteTransportOpen(
                remote,
                bypassDebounce: false,
                attempt: 1
            )
        }
        scheduleStartVerification(for: generation)
        publish(
            owner == .keyboard
                ? "\(hostLabel)正在启动 · 遥控器已预热"
                : "遥控器已启动 · 正在打开\(hostLabel)"
        )
    }

    // MARK: - Trigger emission

    /// 当前生效的触发方式。默认值由 `VoiceTriggerStyle.resolve` 决定：用户
    /// 显式选了长按就照做，否则按当前选中的输入法判断。
    private var triggerStyle: VoiceTriggerStyle { triggerStyleProvider() }

    private var usesPushToTalk: Bool { triggerStyle.usesPushToTalk }

    private var usesLatching: Bool { triggerStyle == .pushToTalkLatching }

    private var isLatched: Bool {
        if case .latched = triggerHold { return true }
        return false
    }

    /// 合成按键是否正被我们按着。长按说话、免手扶收尾都算。
    private var isTriggerHeld: Bool {
        switch triggerHold {
        case .holding, .closingGesture: return true
        case .idle, .latched: return false
        }
    }

    /// 用户可见的输入法短名。
    private var hostLabel: String {
        doubaoState.activeHostTitle ?? AppStorage.voiceInputHost.shortTitle
    }

    private func emitOpenTrigger() {
        guard usesPushToTalk else {
            triggerTap()
            return
        }
        guard case .idle = triggerHold else { return }
        triggerDown()
        triggerHold = .holding(since: now())
        print("[TRIGGER] push-to-talk DOWN")
    }

    private func emitCloseTrigger() {
        guard usesPushToTalk else {
            triggerTap()
            return
        }
        switch triggerHold {
        case .holding:
            triggerUp()
            triggerHold = .idle
            print("[TRIGGER] push-to-talk UP")

        case .latched:
            beginLatchedCloseGesture()

        case .closingGesture:
            break

        case .idle:
            // 物理键盘打开的会话：按键本身已经由系统送进输入法，
            // 这里不再合成第二个按键。
            print("[TRIGGER] no synthetic trigger to release")
        }
    }

    /// 短按：等输入法真的开始录音后，用一次空格把按住说话升级成免手扶。
    ///
    /// 空格必须发在「已经开始录音」之后。微信输入法在长按待定窗口内会跳过
    /// 空格（不消费），那一下会直接把空格打进用户正在编辑的文档。
    private func beginShortPressLatch(since beganAt: Date) {
        let elapsed = now().timeIntervalSince(beganAt)
        let delay = max(0, Self.latchMinHold - elapsed)
        scheduleLatchProbe(after: delay, beganAt: beganAt)
    }

    private func scheduleLatchProbe(after delay: TimeInterval, beganAt: Date) {
        latchProbeWorkItem?.cancel()
        let expectedGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == expectedGeneration else { return }
            self.latchProbeWorkItem = nil
            self.finishShortPressLatch(beganAt: beganAt)
        }
        latchProbeWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0, delay),
            execute: work
        )
    }

    private func finishShortPressLatch(beganAt: Date) {
        guard case .holding = triggerHold,
              phase == .opening || phase == .open
        else { return }

        if doubaoState.snapshotNow().isRecording {
            spaceTap()
            triggerUp()
            triggerHold = .latched
            phase = .open
            startVerificationWorkItem?.cancel()
            startVerificationWorkItem = nil
            print("[TRIGGER] hands-free latch ON")
            publish("\(hostLabel)录音中 · 已锁定，再按一次结束")
            // 免手扶期间遥控器已经松手，麦克风要重新拉起来，
            // 否则锁定的只是 Mac 麦克风。
            if let remote = sessionRemote, !streamingRemotes.contains(remote) {
                requestRemoteTransportOpen(
                    remote,
                    bypassDebounce: true,
                    attempt: 1
                )
            }
            scheduleLatchVerification()
            return
        }

        if now().timeIntervalSince(beganAt) < Self.latchStartTimeout {
            scheduleLatchProbe(
                after: Self.latchStartProbeInterval,
                beganAt: beganAt
            )
            return
        }

        // 输入法始终没开始录音：按普通短按收尾，绝不留住一个按下的键。
        print("[TRIGGER] 短按锁定放弃：输入法未开始录音")
        triggerUp()
        triggerHold = .idle
        beginClosing(sendTrigger: false, reason: "latch aborted")
    }

    /// 免手扶到底有没有保持住。微信输入法遇到无效的空格会静默忽略，
    /// 那就直接收尾，而不是留一个永远停不下来的会话。
    private func scheduleLatchVerification() {
        latchVerificationWorkItem?.cancel()
        let expectedGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == expectedGeneration else { return }
            self.latchVerificationWorkItem = nil
            guard self.isLatched, self.phase == .open else { return }
            guard self.doubaoState.snapshotNow().isRecording else {
                print("[TRIGGER] hands-free latch lost · closing")
                self.finalizeClosed(reason: "hands-free latch lost")
                self.publish("\(self.hostLabel)已结束录音")
                return
            }
            print("[TRIGGER] hands-free latch confirmed")
        }
        latchVerificationWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.latchVerificationDelay,
            execute: work
        )
    }

    /// 免手扶状态下结束录音：再按一次触发键并按住，微信输入法会把免手扶
    /// 升级回按住说话，松手才真正结束。
    private func beginLatchedCloseGesture() {
        triggerDown()
        triggerHold = .closingGesture
        print("[TRIGGER] latched close gesture DOWN")
        let expectedGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == expectedGeneration else { return }
            self.triggerWorkItem = nil
            guard case .closingGesture = self.triggerHold else { return }
            self.triggerUp()
            self.triggerHold = .idle
            print("[TRIGGER] latched close gesture UP")
        }
        triggerWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.latchReleaseHold,
            execute: work
        )
    }

    /// 任何退出路径都必须调用：把按住的合成按键还回去。
    private func releaseAllTriggers() {
        latchProbeWorkItem?.cancel()
        latchProbeWorkItem = nil
        latchVerificationWorkItem?.cancel()
        latchVerificationWorkItem = nil
        triggerWorkItem?.cancel()
        triggerWorkItem = nil
        if isTriggerHeld {
            triggerUp()
            print("[TRIGGER] released held synthetic trigger")
        }
        triggerHold = .idle
    }

    private func closeRecognitionFromRemote(reason: String) {
        guard phase == .opening || phase == .open else {
            print(
                "[VOICE-SESSION] \(reason) ignored phase=\(phase.rawValue)"
            )
            return
        }
        beginClosing(sendTrigger: true, reason: reason)
    }

    private func beginClosing(sendTrigger: Bool, reason: String) {
        guard phase != .closed, phase != .closing else {
            print(
                "[VOICE-SESSION] close ignored phase=\(phase.rawValue) " +
                "reason=\(reason)"
            )
            return
        }

        // 「长按 + 短按锁定」模式下，确实是一次短按才升级成免手扶；按住
        // 超过阈值再松手就是正常的「说完」，不能继续录。
        if sendTrigger, usesLatching, case .holding(let beganAt) = triggerHold,
           now().timeIntervalSince(beganAt) < Self.tapToLatchThreshold
        {
            print("[VOICE-SESSION] short press released → hands-free latch")
            beginShortPressLatch(since: beganAt)
            return
        }

        generation &+= 1
        cancelScheduledWork()
        phase = .closing
        owner = .none
        openRequestedRemote = nil
        if sendTrigger {
            emitCloseTrigger()
        }
        scheduleRouteClose(after: 0.10)
        scheduleCloseVerification(for: generation)
        publish("遥控器已结束 · 正在关闭\(hostLabel)")
        print(
            "[VOICE-SESSION] begin closing reason=\(reason) " +
            "trigger=\(sendTrigger ? "synthetic" : "physical")"
        )
    }

    private func finalizeClosed(reason: String) {
        generation &+= 1
        cancelScheduledWork()
        releaseAllTriggers()
        phase = .closed
        owner = .none
        sessionRemote = nil
        physicalVoiceGestures.removeAll()
        closeRouteAndTransports()
        print("[VOICE-SESSION] closed reason=\(reason)")
    }

    // MARK: - Remote transport requests

    private func requestRemoteTransportOpen(
        _ remote: VoiceRemoteID,
        bypassDebounce: Bool,
        attempt: Int
    ) {
        guard phase == .opening || phase == .open,
              !streamingRemotes.contains(remote),
              openRequestedRemote != remote
        else { return }

        guard let request = onMicrophoneOpenRequested else {
            print(
                "[VOICE-SESSION] MIC_OPEN unavailable " +
                "remote=\(remote.rawValue)"
            )
            return
        }

        let result = request(remote, bypassDebounce)
        switch result {
        case .sent:
            openRequestedRemote = remote
            scheduleOpenConfirmation(
                remote: remote,
                attempt: attempt,
                generation: generation
            )
            print(
                "[VOICE-SESSION] MIC_OPEN sent remote=\(remote.rawValue) " +
                "attempt=\(attempt)"
            )

        case .alreadyStreaming:
            streamingRemotes.insert(remote)
            openRequestedRemote = nil
            print(
                "[VOICE-SESSION] MIC_OPEN already streaming " +
                "remote=\(remote.rawValue)"
            )

        case .retryAfter(let delay):
            scheduleOpenRetry(
                remote: remote,
                after: delay,
                attempt: attempt + 1
            )

        case .unavailable:
            print(
                "[VOICE-SESSION] MIC_OPEN target unavailable " +
                "remote=\(remote.rawValue)"
            )

        case .failed(let message):
            print(
                "[VOICE-SESSION] MIC_OPEN failed remote=\(remote.rawValue) " +
                "message=\(message)"
            )
            scheduleOpenRetry(
                remote: remote,
                after: 0.20,
                attempt: attempt + 1
            )
        }
    }

    private func scheduleOpenRetry(
        remote: VoiceRemoteID,
        after delay: TimeInterval,
        attempt: Int
    ) {
        guard attempt <= Self.maximumOpenAttempts else {
            print(
                "[VOICE-SESSION] MIC_OPEN retries exhausted " +
                "remote=\(remote.rawValue)"
            )
            return
        }
        openRetryWorkItem?.cancel()
        let expectedGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.generation == expectedGeneration,
                  self.phase == .opening || self.phase == .open
            else { return }
            self.openRetryWorkItem = nil
            self.requestRemoteTransportOpen(
                remote,
                bypassDebounce: true,
                attempt: attempt
            )
        }
        openRetryWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + max(0.01, delay),
            execute: work
        )
    }

    private func scheduleOpenConfirmation(
        remote: VoiceRemoteID,
        attempt: Int,
        generation expectedGeneration: UInt64
    ) {
        openConfirmationWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.generation == expectedGeneration,
                  self.openRequestedRemote == remote,
                  !self.streamingRemotes.contains(remote),
                  self.phase == .opening || self.phase == .open
            else { return }
            self.openRequestedRemote = nil
            self.openConfirmationWorkItem = nil
            print(
                "[VOICE-SESSION] MIC_OPEN confirmation timeout " +
                "remote=\(remote.rawValue) attempt=\(attempt)"
            )
            self.scheduleOpenRetry(
                remote: remote,
                after: 0.05,
                attempt: attempt + 1
            )
        }
        openConfirmationWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.openConfirmationTimeout,
            execute: work
        )
    }

    // MARK: - Verification and route lifecycle

    private func scheduleStartVerification(
        for expectedGeneration: UInt64,
        attempt: Int = 1
    ) {
        startVerificationWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.generation == expectedGeneration,
                  self.phase == .opening
            else { return }
            self.startVerificationWorkItem = nil
            let snapshot = self.doubaoState.snapshotNow()
            if snapshot.isRecording {
                self.handleDoubaoSnapshot(snapshot)
                return
            }
            // Doubao needs close to a second to actually open the capture
            // device, so a single 1 s probe aborts dictations that are about
            // to start. Retrying only ever delays the auto-close of a session
            // that never opens: a real activation cancels this work item via
            // `handleDoubaoSnapshot(.active)`.
            if attempt < Self.startVerificationAttempts {
                print(
                    "[VOICE-SESSION] 开麦验证 attempt=\(attempt) " +
                    "state=\(snapshot.state.rawValue) · 重试"
                )
                self.scheduleStartVerification(
                    for: expectedGeneration,
                    attempt: attempt + 1
                )
                return
            }
            // `pid` is set whenever Doubao is running, `processObjectID` only
            // when this system can bind it. Either one means "Doubao is here
            // but its capture state is unreadable", which must never close a
            // session. No pid at all means Doubao is gone: close as before.
            let doubaoIsRunning = snapshot.processObjectID != nil
                || snapshot.pid != nil
            guard snapshot.state == .unavailable, doubaoIsRunning else {
                self.finalizeClosed(reason: "opening timeout")
                self.publish("\(self.hostLabel)未启动 · 遥控器自动关闭")
                return
            }
            // The process object exists but this platform cannot report its
            // capture state. Never close a session on an unknown answer.
            self.phase = .open
            self.activateRemoteRoute()
            print("[VOICE-SESSION] 豆包状态不可读 · 保持会话")
            self.publish("\(self.hostLabel)录音中 · 无法读取状态")
        }
        startVerificationWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.startVerificationInterval,
            execute: work
        )
    }

    private func scheduleCloseVerification(for expectedGeneration: UInt64) {
        closeVerificationWorkItem?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.generation == expectedGeneration,
                  self.phase == .closing
            else { return }
            self.closeVerificationWorkItem = nil
            let snapshot = self.doubaoState.snapshotNow()
            if snapshot.isRecording {
                // The requested close did not become observable. Follow the
                // real CoreAudio state without synthesizing another trigger.
                self.phase = .open
                self.owner = .keyboard
                self.sessionRemote = self.preferredRemoteProvider?()
                self.activateRemoteRoute()
                if let remote = self.sessionRemote {
                    self.requestRemoteTransportOpen(
                        remote,
                        bypassDebounce: false,
                        attempt: 1
                    )
                }
                self.publish("\(self.hostLabel)仍在录音 · 请再次关闭")
                print(
                    "[VOICE-SESSION] close not observed; restored open state"
                )
            } else {
                self.finalizeClosed(reason: "close verification")
                self.publish("\(self.hostLabel)已就绪")
            }
        }
        closeVerificationWorkItem = work
        DispatchQueue.main.asyncAfter(
            deadline: .now() + Self.closeVerificationTimeout,
            execute: work
        )
    }

    /// Capture state can flicker to idle for a single poll while Doubao swaps
    /// buffers. Re-read once before tearing the session down.
    private func confirmIdleThenClose() {
        idleConfirmationWorkItem?.cancel()
        let expectedGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self,
                  self.generation == expectedGeneration,
                  self.phase == .open
            else { return }
            self.idleConfirmationWorkItem = nil
            let snapshot = self.doubaoState.snapshotNow()
            guard !snapshot.isRecording else {
                print("[VOICE-SESSION] idle 抖动已恢复 · 保持会话")
                return
            }
            self.finalizeClosed(reason: "Doubao inactive")
        }
        idleConfirmationWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.35, execute: work)
    }

    private func reconcileSoon(after delay: TimeInterval) {
        let expectedGeneration = generation
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
            guard let self, self.generation == expectedGeneration else { return }
            self.handleDoubaoSnapshot(self.doubaoState.snapshotNow())
        }
    }

    private func activateRemoteRoute() {
        routeCloseWorkItem?.cancel()
        routeCloseWorkItem = nil
        guard !routeActive else { return }
        routeActive = true
        setRemoteRouteActive(true)
        print(
            "[VOICE-SESSION] audio route ON phase=\(phase.rawValue) " +
            "owner=\(owner.rawValue)"
        )
    }

    private func scheduleRouteClose(after delay: TimeInterval) {
        routeCloseWorkItem?.cancel()
        let expectedGeneration = generation
        let work = DispatchWorkItem { [weak self] in
            guard let self, self.generation == expectedGeneration else { return }
            self.routeCloseWorkItem = nil
            self.closeRouteAndTransports()
        }
        routeCloseWorkItem = work
        DispatchQueue.main.asyncAfter(deadline: .now() + delay, execute: work)
    }

    private func closeAllRemoteTransports() {
        onMicrophoneCloseRequested?()
        streamingRemotes.removeAll()
        openRequestedRemote = nil
        openRetryWorkItem?.cancel()
        openRetryWorkItem = nil
        openConfirmationWorkItem?.cancel()
        openConfirmationWorkItem = nil
    }

    private func closeRouteAndTransports() {
        let hadTransport =
            !streamingRemotes.isEmpty || openRequestedRemote != nil
        routeActive = false
        setRemoteRouteActive(false)
        if hadTransport {
            closeAllRemoteTransports()
        }
        print("[VOICE-SESSION] audio route OFF")
    }

    private func cancelScheduledWork() {
        routeCloseWorkItem?.cancel()
        routeCloseWorkItem = nil
        startVerificationWorkItem?.cancel()
        startVerificationWorkItem = nil
        closeVerificationWorkItem?.cancel()
        closeVerificationWorkItem = nil
        openRetryWorkItem?.cancel()
        openRetryWorkItem = nil
        openConfirmationWorkItem?.cancel()
        openConfirmationWorkItem = nil
        idleConfirmationWorkItem?.cancel()
        idleConfirmationWorkItem = nil
    }

    private func publish(_ status: String) {
        onStateChanged?(status)
    }
}
