import CoreAudio
import Foundation

/// 一台音频设备的最小描述。
///
/// 默认设备按 `AudioDeviceID` 记录是不行的：ID 在重启、驱动重载后会变。
/// 所以跨会话只认 `uid`，名字只用于日志和兜底匹配。
struct AudioDeviceSnapshot: Equatable {
    let id: AudioDeviceID
    let uid: String
    let name: String
    let inputChannels: Int
    let outputChannels: Int
}

/// 默认音频设备的读写。抽成协议是为了让状态机能在自测里跑，
/// 不必依赖真实硬件。
protocol AudioDeviceProviding: AnyObject {
    func allDevices() -> [AudioDeviceSnapshot]
    func defaultInput() -> AudioDeviceSnapshot?
    func defaultOutput() -> AudioDeviceSnapshot?
    @discardableResult func setDefaultInput(_ device: AudioDeviceSnapshot) -> Bool
    @discardableResult func setDefaultOutput(_ device: AudioDeviceSnapshot) -> Bool
}

/// 跨会话需要记住的三件事。
protocol AudioRouteStoring: AnyObject {
    /// 用户是否允许自动把系统默认输入切到 vRemoteDr 2ch。
    var autoRouteInput: Bool { get set }
    /// 被替换掉的输入设备 UID。只在 `pendingRestore` 为真时有意义。
    var savedInputUID: String? { get set }
    /// 已切换但还没恢复的标记。崩溃后下次启动靠它还账。
    var pendingRestore: Bool { get set }
}

// MARK: - CoreAudio 实现

final class CoreAudioDeviceProvider: AudioDeviceProviding {
    private let systemObject = AudioObjectID(kAudioObjectSystemObject)

    private func address(
        _ selector: AudioObjectPropertySelector,
        _ scope: AudioObjectPropertyScope = kAudioObjectPropertyScopeGlobal
    ) -> AudioObjectPropertyAddress {
        AudioObjectPropertyAddress(
            mSelector: selector,
            mScope: scope,
            mElement: kAudioObjectPropertyElementMain
        )
    }

    private func stringProperty(
        _ object: AudioObjectID,
        _ selector: AudioObjectPropertySelector
    ) -> String? {
        var addr = address(selector)
        var value: Unmanaged<CFString>?
        var size = UInt32(MemoryLayout<Unmanaged<CFString>?>.size)
        guard AudioObjectGetPropertyData(
            object, &addr, 0, nil, &size, &value
        ) == noErr, let value else { return nil }
        return value.takeRetainedValue() as String
    }

    /// 统计某个方向上的总声道数。0 表示这台设备在该方向上没有通路。
    private func channelCount(
        _ device: AudioDeviceID,
        scope: AudioObjectPropertyScope
    ) -> Int {
        var addr = address(kAudioDevicePropertyStreamConfiguration, scope)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            device, &addr, 0, nil, &size
        ) == noErr, size > 0 else { return 0 }

        let raw = UnsafeMutableRawPointer.allocate(
            byteCount: Int(size), alignment: 16
        )
        defer { raw.deallocate() }
        guard AudioObjectGetPropertyData(
            device, &addr, 0, nil, &size, raw
        ) == noErr else { return 0 }

        let list = UnsafeMutableAudioBufferListPointer(
            raw.assumingMemoryBound(to: AudioBufferList.self)
        )
        return list.reduce(0) { $0 + Int($1.mNumberChannels) }
    }

    private func snapshot(_ device: AudioDeviceID) -> AudioDeviceSnapshot? {
        guard device != AudioDeviceID(kAudioObjectUnknown) else { return nil }
        guard let uid = stringProperty(device, kAudioDevicePropertyDeviceUID)
        else { return nil }
        let name = stringProperty(device, kAudioObjectPropertyName) ?? uid
        return AudioDeviceSnapshot(
            id: device,
            uid: uid,
            name: name,
            inputChannels: channelCount(device, scope: kAudioObjectPropertyScopeInput),
            outputChannels: channelCount(device, scope: kAudioObjectPropertyScopeOutput)
        )
    }

    func allDevices() -> [AudioDeviceSnapshot] {
        var addr = address(kAudioHardwarePropertyDevices)
        var size: UInt32 = 0
        guard AudioObjectGetPropertyDataSize(
            systemObject, &addr, 0, nil, &size
        ) == noErr, size > 0 else { return [] }

        var ids = [AudioDeviceID](
            repeating: 0,
            count: Int(size) / MemoryLayout<AudioDeviceID>.size
        )
        guard AudioObjectGetPropertyData(
            systemObject, &addr, 0, nil, &size, &ids
        ) == noErr else { return [] }
        return ids.compactMap(snapshot)
    }

    private func defaultDevice(
        _ selector: AudioObjectPropertySelector
    ) -> AudioDeviceSnapshot? {
        var addr = address(selector)
        var device = AudioDeviceID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioDeviceID>.size)
        guard AudioObjectGetPropertyData(
            systemObject, &addr, 0, nil, &size, &device
        ) == noErr else { return nil }
        return snapshot(device)
    }

    func defaultInput() -> AudioDeviceSnapshot? {
        defaultDevice(kAudioHardwarePropertyDefaultInputDevice)
    }

    func defaultOutput() -> AudioDeviceSnapshot? {
        defaultDevice(kAudioHardwarePropertyDefaultOutputDevice)
    }

    private func setDefault(
        _ device: AudioDeviceSnapshot,
        selector: AudioObjectPropertySelector
    ) -> Bool {
        var addr = address(selector)
        var id = device.id
        let status = AudioObjectSetPropertyData(
            systemObject, &addr, 0, nil,
            UInt32(MemoryLayout<AudioDeviceID>.size), &id
        )
        if status != noErr {
            print("[ROUTE] 设置默认设备失败 \(device.name) status=\(status)")
        }
        return status == noErr
    }

    func setDefaultInput(_ device: AudioDeviceSnapshot) -> Bool {
        setDefault(device, selector: kAudioHardwarePropertyDefaultInputDevice)
    }

    func setDefaultOutput(_ device: AudioDeviceSnapshot) -> Bool {
        setDefault(device, selector: kAudioHardwarePropertyDefaultOutputDevice)
    }
}

// MARK: - UserDefaults 实现

final class UserDefaultsAudioRouteStore: AudioRouteStoring {
    private enum Key {
        static let autoRoute = "audioAutoRouteInput"
        static let savedInputUID = "audioSavedInputUID"
        static let pending = "audioRoutePendingRestore"
    }

    private let defaults: UserDefaults

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    var autoRouteInput: Bool {
        get {
            // 默认开：没有写入过就当作开启，符合「装上就生效」的预期。
            if defaults.object(forKey: Key.autoRoute) == nil { return true }
            return defaults.bool(forKey: Key.autoRoute)
        }
        set { defaults.set(newValue, forKey: Key.autoRoute) }
    }

    var savedInputUID: String? {
        get { defaults.string(forKey: Key.savedInputUID) }
        set { defaults.set(newValue, forKey: Key.savedInputUID) }
    }

    var pendingRestore: Bool {
        get { defaults.bool(forKey: Key.pending) }
        set { defaults.set(newValue, forKey: Key.pending) }
    }
}

// MARK: - 状态机

/// 把系统默认输入切到 vRemoteDr 2ch，退出时还原。
///
/// 设计约束（来自实际踩过的坑）：
/// - **只碰 input scope**。vRemoteDr 2ch 的 output 侧是没有回放通路的黑洞，
///   一旦成为默认输出，整台机器彻底静音。
/// - **崩溃也要能收尾**。`applicationWillTerminate` 在强杀和断电时不会执行，
///   所以切换前先落盘 `savedInputUID` + `pendingRestore`，下次启动先还账。
/// - **不抢用户的主动修改**。运行期间用户手动换过设备，退出时不按旧记录覆盖。
final class AudioDeviceRoute {
    /// 目标设备。名称以驱动里写死的显示名为准，UID 作为首选匹配，
    /// 防止同名设备（比如用户自建的聚合设备）抢占。
    static let targetDeviceName = "vRemoteDr 2ch"
    private static let targetUIDPrefix = "vRemoteDr"

    private let devices: AudioDeviceProviding
    private let store: AudioRouteStoring
    private var started = false

    /// 供状态栏显示的一句话描述。
    private(set) var lastActionDescription: String?

    var onRouteChanged: (() -> Void)?

    init(
        devices: AudioDeviceProviding = CoreAudioDeviceProvider(),
        store: AudioRouteStoring = UserDefaultsAudioRouteStore()
    ) {
        self.devices = devices
        self.store = store
    }

    /// 驱动里写死的 UID，精确匹配优先级最高。
    private static let targetUID = "vRemoteDr2ch_UID"

    /// 目标设备是否就绪（驱动是否已安装且被枚举到）。
    ///
    /// 三级匹配：精确 UID → 精确名称 → UID 前缀。前两级都失败才用前缀，
    /// 避免同名前缀的自建设备被误当成虚拟声卡。
    func targetDevice() -> AudioDeviceSnapshot? {
        let all = devices.allDevices()
        if let exact = all.first(where: { $0.uid == Self.targetUID }) {
            return exact
        }
        if let byName = all.first(where: {
            $0.name == Self.targetDeviceName && $0.inputChannels > 0
        }) {
            return byName
        }
        return all.first {
            $0.uid.hasPrefix(Self.targetUIDPrefix) && $0.inputChannels > 0
        }
    }

    private func isTarget(_ device: AudioDeviceSnapshot?) -> Bool {
        guard let device else { return false }
        guard let target = targetDevice() else {
            // 设备已经不在了（驱动被卸载），按 UID / 名字判断残留引用。
            return device.uid.hasPrefix(Self.targetUIDPrefix)
                || device.name == Self.targetDeviceName
        }
        return device.uid == target.uid
    }

    private func device(uid: String) -> AudioDeviceSnapshot? {
        devices.allDevices().first { $0.uid == uid }
    }

    // MARK: 生命周期

    func start() {
        guard !started else { return }
        started = true

        // 1) 输出保护：不管开关如何，先把自己从「完全没声音」里捞出来。
        protectDefaultOutput()

        // 2) 崩溃兜底：上一轮没来得及还原的，这里补上。
        settleLeftoverRoute()

        // 3) 按开关决定是否切换。
        guard store.autoRouteInput else {
            print("[ROUTE] 自动切换已关闭，保持系统默认输入不变")
            return
        }
        routeToTarget()
    }

    func stop() {
        restore(reason: "应用退出")
    }

    /// 驱动加载可能比 App 慢一拍，启动时枚举不到设备的话，稍后再补一次。
    /// 已经切换成功或已经还原过就什么都不做。
    func retryIfNeeded() {
        guard started, store.autoRouteInput, !store.pendingRestore else { return }
        guard !isTarget(devices.defaultInput()) else { return }
        routeToTarget()
    }

    /// 开关当前状态。
    var autoRouteEnabled: Bool { store.autoRouteInput }

    /// 用户拨动开关。关掉时如果之前是我们接管的，立刻还回去；
    /// 打开时立即接管。
    func setAutoRoute(_ enabled: Bool) {
        store.autoRouteInput = enabled
        if enabled {
            routeToTarget()
        } else {
            restore(reason: "关闭自动切换")
        }
    }

    /// 手动恢复入口（菜单按钮）。
    ///
    /// 与自动恢复的区别是 `force`：用户自己把默认输入设成虚拟设备时
    /// 并没有 `savedInputUID`，按钮照样要能把他救回内置麦克风。
    @discardableResult
    func restoreNow() -> Bool {
        guard isTarget(devices.defaultInput()) else {
            print("[ROUTE] 当前默认输入不是 \(Self.targetDeviceName)，无需恢复")
            lastActionDescription = L10n.text(
                "当前输入不是虚拟设备，无需恢复",
                "Input is not the virtual device"
            )
            return false
        }
        return restore(reason: "手动恢复", force: true)
    }

    // MARK: 内部步骤

    private func routeToTarget() {
        guard let target = targetDevice() else {
            print(
                "[ROUTE] ⚠️ 找不到 \(Self.targetDeviceName)，" +
                "请确认 vRemoteDriver.driver 已安装"
            )
            lastActionDescription = L10n.text(
                "未找到 vRemoteDr 2ch",
                "vRemoteDr 2ch not found"
            )
            return
        }
        guard let current = devices.defaultInput() else { return }

        if current.uid == target.uid {
            // 默认输入已经是虚拟设备。两种可能：上一版 App 就这么设的，
            // 或者用户自己选的。两种情况都要接管还原责任 —— 否则关掉 App
            // 之后系统会停在一个没人写入的设备上，其他软件录音全是静音。
            guard store.autoRouteInput, let fallback = builtInInput() else {
                store.savedInputUID = nil
                store.pendingRestore = false
                print("[ROUTE] 默认输入已是 \(Self.targetDeviceName)，不接管还原")
                lastActionDescription = L10n.text(
                    "输入已是 vRemoteDr 2ch",
                    "Input already vRemoteDr 2ch"
                )
                return
            }
            store.savedInputUID = fallback.uid
            store.pendingRestore = true
            print(
                "[ROUTE] 默认输入已是虚拟设备，接管还原" +
                "（退出时回到 \(fallback.name)）"
            )
            lastActionDescription = L10n.text(
                "输入已是 vRemoteDr 2ch，退出时恢复",
                "Input already vRemoteDr 2ch, will restore on quit"
            )
            return
        }

        store.savedInputUID = current.uid
        store.pendingRestore = true
        if devices.setDefaultInput(target) {
            print(
                "[ROUTE] 默认输入 \(current.name) → \(target.name) " +
                "(原设备已记录 uid=\(current.uid))"
            )
            lastActionDescription = L10n.text(
                "已切换到 vRemoteDr 2ch",
                "Switched to vRemoteDr 2ch"
            )
            onRouteChanged?()
        } else {
            store.pendingRestore = false
            store.savedInputUID = nil
        }
    }

    @discardableResult
    private func restore(reason: String, force: Bool = false) -> Bool {
        // 没有待还原记录说明我们没改过，直接返回（手动恢复除外）。
        if !force, !store.pendingRestore { return false }
        // 用户运行期间换过设备：尊重他的选择，只清标记。
        guard isTarget(devices.defaultInput()) else {
            print("[ROUTE] 默认输入已被用户改动，跳过恢复（\(reason)）")
            store.pendingRestore = false
            store.savedInputUID = nil
            return false
        }

        let savedUID = store.savedInputUID
        let restored: AudioDeviceSnapshot?
        if let savedUID, let device = device(uid: savedUID) {
            restored = device
        } else {
            // 原设备拔掉了（USB 麦、耳机），或用户手工选的虚拟设备没有历史
            // 记录：两种情况下都退到内置麦克风。
            if savedUID != nil {
                print("[ROUTE] 原设备 uid=\(savedUID!) 不在了，改用内置麦克风")
            }
            restored = builtInInput()
        }

        guard let restored else {
            // 连内置麦都没有（Mac mini 且没接麦），清标记避免每次启动空转。
            store.pendingRestore = false
            store.savedInputUID = nil
            print("[ROUTE] 没有可用的恢复目标，保持现状（\(reason)）")
            return false
        }
        // 设置失败时保留标记，下次启动再试一次。
        guard devices.setDefaultInput(restored) else { return false }

        store.pendingRestore = false
        store.savedInputUID = nil
        print("[ROUTE] 恢复默认输入 → \(restored.name)（\(reason)）")
        lastActionDescription = L10n.text(
            "已恢复 \(restored.name)",
            "Restored \(restored.name)"
        )
        onRouteChanged?()
        return true
    }

    /// 启动时处理上一轮崩溃留下的残留。
    private func settleLeftoverRoute() {
        guard store.pendingRestore else { return }
        print("[ROUTE] 检测到上次未还原的输入设备，先补做")
        restore(reason: "上次未正常退出")
    }

    /// 默认输出如果是虚拟设备，说明用户或某个 App 把声音送进了黑洞。
    /// 这里不做自动切换，只在确认「当前输出没有回放通路」时救回来。
    private func protectDefaultOutput() {
        guard let current = devices.defaultOutput(), isTarget(current) else {
            return
        }
        let fallback = builtInOutput()
            ?? devices.allDevices().first {
                $0.outputChannels > 0 && !isTarget($0)
            }
        guard let fallback else {
            print("[ROUTE] ⚠️ 默认输出是虚拟设备且找不到替代，请手动选择扬声器")
            return
        }
        if devices.setDefaultOutput(fallback) {
            print("[ROUTE] ⚠️ 默认输出原为虚拟设备，已切回 \(fallback.name)")
            lastActionDescription = L10n.text(
                "输出已从虚拟设备切回 \(fallback.name)",
                "Output moved back to \(fallback.name)"
            )
        }
    }

    private func builtInInput() -> AudioDeviceSnapshot? {
        devices.allDevices().first {
            $0.inputChannels > 0 && !isTarget($0) && isBuiltIn($0)
        } ?? devices.allDevices().first { $0.inputChannels > 0 && !isTarget($0) }
    }

    private func builtInOutput() -> AudioDeviceSnapshot? {
        devices.allDevices().first {
            $0.outputChannels > 0 && !isTarget($0) && isBuiltIn($0)
        }
    }

    /// 内置设备靠 UID 前缀识别，比 transport type 少一次属性查询。
    private func isBuiltIn(_ device: AudioDeviceSnapshot) -> Bool {
        device.uid.hasPrefix("AppleHDAEngine")
    }
}
