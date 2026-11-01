import CoreGraphics
import Foundation

enum InputTriggerKey: String, CaseIterable, Identifiable {
    case option
    case command
    case control
    case shift
    case function

    var id: String { rawValue }

    var title: String {
        switch self {
        case .option: "Option (⌥)"
        case .command: "Command (⌘)"
        case .control: "Control (⌃)"
        case .shift: "Shift (⇧)"
        case .function: "Fn / Globe"
        }
    }

    var keyCodes: Set<Int64> {
        switch self {
        case .option: [0x3A, 0x3D]
        case .command: [0x37, 0x36]
        case .control: [0x3B, 0x3E]
        case .shift: [0x38, 0x3C]
        case .function: [0x3F]
        }
    }

    var primaryKeyCode: CGKeyCode {
        CGKeyCode(keyCodes.min() ?? 0x3A)
    }

    var flag: CGEventFlags {
        switch self {
        case .option: .maskAlternate
        case .command: .maskCommand
        case .control: .maskControl
        case .shift: .maskShift
        case .function: .maskSecondaryFn
        }
    }

    /// 用户配置 + 实际选中的输入法 → 真正要按的键。
    ///
    /// 豆包的语音快捷键是 Option，微信输入法是 Fn。自动检测模式下跟随
    /// 系统此刻选中的输入法，但只在配置值仍是「另一个输入法的默认键」
    /// 时才改——用户自己选过的组合键不会被覆盖。
    static func resolve(
        configured: InputTriggerKey = AppStorage.inputTriggerKey,
        host: VoiceInputHost = AppStorage.voiceInputHost,
        currentInputSource: () -> String? = InputSourceProbe
            .currentInputMethodBundleID
    ) -> InputTriggerKey {
        guard host == .automatic,
              let bundleID = currentInputSource(),
              let detected = VoiceInputHost.host(forBundleID: bundleID),
              let preferred = VoiceInputDefaults.triggerKey(for: detected),
              configured != preferred,
              VoiceInputDefaults.triggerKey(
                  for: detected == .weType ? .doubao : .weType
              ) == configured
        else { return configured }
        return preferred
    }
}

enum Key {
    /// Lets the event tap distinguish vRemoter-generated events from physical
    /// keyboards, Bluetooth buttons, and external remappers.
    static let syntheticMarker: Int64 = 0x4D_49_52_42 // "MIRB"

    static func triggerDown(_ trigger: InputTriggerKey = .resolve()) {
        post(trigger: trigger, keyDown: true)
    }

    static func triggerUp(_ trigger: InputTriggerKey = .resolve()) {
        post(trigger: trigger, keyDown: false)
    }

    /// A deliberate short modifier click for Doubao's toggle mode.
    static func triggerTap(
        _ trigger: InputTriggerKey = .resolve(),
        completion: (() -> Void)? = nil
    ) {
        triggerDown(trigger)
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.06) {
            triggerUp(trigger)
            completion?()
        }
    }

    /// A plain Space tap with no modifiers.
    ///
    /// WeChat Input Method turns a held Fn (push-to-talk) into its hands-free
    /// mode when Space arrives while it is recording: the key event is consumed
    /// by the input method, so nothing is typed into the focused document. That
    /// is the only documented way to keep the session alive after the trigger
    /// is released, which is what a short remote press needs.
    static func spaceTap() {
        let source = CGEventSource(stateID: .hidSystemState)
        for keyDown in [true, false] {
            guard let event = CGEvent(
                keyboardEventSource: source,
                virtualKey: 0x31,
                keyDown: keyDown
            ) else { continue }
            event.flags = []
            event.setIntegerValueField(
                .eventSourceUserData,
                value: syntheticMarker
            )
            event.post(tap: .cghidEventTap)
        }
        print("[KEY] synthetic Space tap (hands-free)")
    }

    private static func post(trigger: InputTriggerKey, keyDown: Bool) {
        let source = CGEventSource(stateID: .hidSystemState)
        guard let event = CGEvent(
            keyboardEventSource: source,
            virtualKey: trigger.primaryKeyCode,
            keyDown: keyDown
        ) else { return }
        event.flags = keyDown ? trigger.flag : []
        event.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        event.post(tap: .cghidEventTap)
        print(
            "[KEY] synthetic \(trigger.title) " +
            (keyDown ? "DOWN" : "UP")
        )
    }
}
