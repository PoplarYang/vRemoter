import CoreGraphics
import Foundation

/// A modifier key used as the voice trigger.
///
/// Option and Command exist on both sides of a full keyboard. This app always
/// presses the **left** one, and says so in the title, because that is the key
/// most people bind and because a silent mismatch ("I picked Option, nothing
/// happens") is the worst failure mode. The synthetic event also carries the
/// device-dependent "left side" bit, so an input method that records the side
/// sees a matching key; one that ignores the side behaves as it always did.
enum InputTriggerKey: String, CaseIterable, Identifiable {
    case option
    case command
    case control
    case shift
    case function

    var id: String { rawValue }

    var title: String {
        switch self {
        case .option: L10n.text("Option ⌥（左键）", "Option ⌥ (left key)")
        case .command: L10n.text("Command ⌘（左键）", "Command ⌘ (left key)")
        case .control: L10n.text("Control ⌃", "Control ⌃")
        case .shift: L10n.text("Shift ⇧", "Shift ⇧")
        case .function: "Fn / Globe"
        }
    }

    /// Whether the title already states which physical key is sent.
    var statesSide: Bool {
        switch self {
        case .option, .command: true
        case .control, .shift, .function: false
        }
    }

    /// Physical key codes that wake the trigger.
    ///
    /// Option and Command accept only the left key: the right one would fire a
    /// trigger this app then presses on the left, which only confuses a user
    /// whose input method is bound to the right key. Control and Shift keep
    /// both sides, since neither is ever bound per-side for dictation.
    var keyCodes: Set<Int64> {
        switch self {
        case .option: [0x3A]
        case .command: [0x37]
        case .control: [0x3B, 0x3E]
        case .shift: [0x38, 0x3C]
        case .function: [0x3F]
        }
    }

    /// The key code we synthesise when the remote asks for this trigger.
    var primaryKeyCode: CGKeyCode {
        switch self {
        case .option: 0x3A
        case .command: 0x37
        case .control: 0x3B
        case .shift: 0x38
        case .function: 0x3F
        }
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

    /// The "left side" bit (`NX_DEVICE*KEYMASK`) posted with the key-down.
    ///
    /// Sent on top of the device-independent flag above. Input methods that
    /// compare only `deviceIndependentFlagsMask` ignore it and behave exactly
    /// as before; input methods that keep the side see the left key.
    var deviceFlag: UInt64 {
        switch self {
        case .option: 0x0000_0020 // NX_DEVICELALTKEYMASK
        case .command: 0x0000_0008 // NX_DEVICELCMDKEYMASK
        case .control: 0x0000_0001 // NX_DEVICELCTLKEYMASK
        case .shift: 0x0000_0002 // NX_DEVICELSHIFTKEYMASK
        case .function: 0
        }
    }

    /// Flags posted with the synthetic key-down.
    var combinedFlags: CGEventFlags {
        CGEventFlags(rawValue: flag.rawValue | deviceFlag)
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
        event.flags = keyDown ? trigger.combinedFlags : []
        event.setIntegerValueField(.eventSourceUserData, value: syntheticMarker)
        event.post(tap: .cghidEventTap)
        print(
            "[KEY] synthetic \(trigger.title) " +
            (keyDown ? "DOWN" : "UP")
        )
    }
}
