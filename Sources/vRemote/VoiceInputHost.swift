import Carbon
import Foundation

/// How the remote voice key drives the input method's recognition session.
///
/// Doubao Input Method treats its Option shortcut as a toggle: one tap opens,
/// the next tap closes. WeChat Input Method treats Fn as push-to-talk: the
/// session lives exactly as long as the key is held. The styles below describe
/// those two behaviours, plus the hybrid WeChat mode described next.
enum VoiceTriggerStyle: String, CaseIterable, Identifiable {
    /// One short tap opens, the next short tap closes.
    case tapToggle
    /// Recognition runs only while the key is held.
    case pushToTalk
    /// Hold to talk; a short tap latches the session through WeChat Input
    /// Method's hands-free mode and a second tap ends it.
    case pushToTalkLatching

    var id: String { rawValue }

    var title: String {
        switch self {
        case .tapToggle: L10n.text("点按切换", "Tap to toggle")
        case .pushToTalk: L10n.text("长按说话", "Press and hold")
        case .pushToTalkLatching: L10n.text("长按 + 短按锁定", "Hold + tap to latch")
        }
    }

    /// One line that names the input method this style belongs to. Shown
    /// under the picker so the choice is not a guess.
    var detail: String {
        switch self {
        case .tapToggle:
            L10n.text(
                "按一下开始，再按一下结束 · 豆包输入法的默认方式",
                "Tap to start, tap again to stop · Doubao's default"
            )
        case .pushToTalk:
            L10n.text(
                "按住说话，松开即结束 · 对讲机式，不会忘记关闭",
                "Hold to talk, release to stop · walkie-talkie style"
            )
        case .pushToTalkLatching:
            L10n.text(
                "按住说话；短按一次可松手继续录，再短按结束 · 微信输入法",
                "Hold to talk; a short tap keeps recording, another tap stops · WeChat"
            )
        }
    }

    /// Longer explanation for the help popover.
    var scenario: String {
        switch self {
        case .tapToggle:
            L10n.text(
                "遥控器短按一次开始录音，再短按一次结束。适合豆包输入法，也适合需要长时间口述、不想一直按着的场景。",
                "A short remote press starts, another stops. Suits Doubao and long dictation."
            )
        case .pushToTalk:
            L10n.text(
                "按住遥控器语音键说话，松开就结束。和微信语音、对讲机一样，绝不会忘记关闭麦克风，但长句子要一直按着。",
                "Hold the remote voice key while talking. Nothing is left recording."
            )
        case .pushToTalkLatching:
            L10n.text(
                "默认按住说话、松开结束；如果只想说一句就松手，快速短按一次会让微信输入法进入免手扶模式继续录音，再短按一次结束。适合长段落口述。",
                "Hold to talk, release to stop. A quick tap latches WeChat's hands-free mode; tap again to end."
            )
        }
    }

    var usesPushToTalk: Bool {
        self != .tapToggle
    }
}

/// The input method that consumes the `vRemoteDr 2ch` capture stream.
///
/// vRemoter decides whether recognition is running by reading the input
/// method's own CoreAudio capture state, so the host has to be named here.
/// `automatic` watches every supported host at once and adopts whichever one is
/// actually recording, which keeps the app working when the user switches
/// input methods.
enum VoiceInputHost: String, CaseIterable, Identifiable {
    case automatic
    case doubao
    case weType

    var id: String { rawValue }

    var title: String {
        switch self {
        case .automatic: L10n.text("自动检测", "Automatic")
        case .doubao: L10n.text("豆包输入法", "Doubao Input Method")
        case .weType: L10n.text("微信输入法", "WeChat Input Method")
        }
    }

    /// Short name used inside status lines such as「微信输入法录音中」.
    var shortTitle: String {
        switch self {
        case .automatic: L10n.text("输入法", "Input method")
        case .doubao: L10n.text("豆包", "Doubao")
        case .weType: L10n.text("微信输入法", "WeChat input")
        }
    }

    /// Bundle IDs whose CoreAudio capture state should be observed.
    var bundleIDs: [String] {
        switch self {
        case .automatic: Self.doubao.bundleIDs + Self.weType.bundleIDs
        case .doubao: ["com.bytedance.inputmethod.doubaoime"]
        case .weType: ["com.tencent.inputmethod.wetype"]
        }
    }

    /// Human-readable name for a bundle ID reported by CoreAudio.
    static func host(forBundleID bundleID: String) -> VoiceInputHost? {
        [.doubao, .weType].first { $0.bundleIDs.contains(bundleID) }
    }

    static func title(forBundleID bundleID: String) -> String? {
        host(forBundleID: bundleID)?.shortTitle
    }
}

/// Trigger defaults that mirror each input method's own voice shortcut, so the
/// user does not have to reconfigure the input method to match vRemoter.
enum VoiceInputDefaults {
    /// Doubao ships with Option; WeChat Input Method ships with Fn.
    static func triggerKey(for host: VoiceInputHost) -> InputTriggerKey? {
        switch host {
        case .automatic: nil
        case .doubao: .option
        case .weType: .function
        }
    }

    static func triggerStyle(for host: VoiceInputHost) -> VoiceTriggerStyle? {
        switch host {
        case .automatic: nil
        case .doubao: .tapToggle
        case .weType: .pushToTalkLatching
        }
    }
}

/// Which input method the user has selected right now.
///
/// CoreAudio can only tell us who is *recording*; while everything is idle the
/// user may still be typing with either input method. `TIS` answers the
/// question directly, which is what the `automatic` host needs to pick the
/// right trigger gesture before the first press.
enum InputSourceProbe {
    static func currentInputMethodBundleID() -> String? {
        guard let source = TISCopyCurrentKeyboardInputSource()?
            .takeRetainedValue()
        else { return nil }
        guard let raw = TISGetInputSourceProperty(
            source,
            kTISPropertyBundleID
        ) else { return nil }
        return Unmanaged<CFString>
            .fromOpaque(raw)
            .takeUnretainedValue() as String
    }
}

extension VoiceTriggerStyle {
    /// 用户配置 + 实际选中的输入法 → 真正要用的触发方式。
    ///
    /// 「点按切换」是豆包的语义，「长按 + 短按锁定」是微信输入法的语义。
    /// 自动检测模式下跟随系统此刻选中的输入法，但只在配置值仍是「另一个
    /// 输入法的默认值」时才改——用户自己选过的组合不会被覆盖。
    static func resolve(
        configured: VoiceTriggerStyle = AppStorage.voiceTriggerStyle,
        host: VoiceInputHost = AppStorage.voiceInputHost,
        currentInputSource: () -> String? = InputSourceProbe
            .currentInputMethodBundleID
    ) -> VoiceTriggerStyle {
        guard host == .automatic,
              let bundleID = currentInputSource(),
              let detected = VoiceInputHost.host(forBundleID: bundleID),
              let preferred = VoiceInputDefaults.triggerStyle(for: detected),
              configured != preferred,
              VoiceInputDefaults.triggerStyle(
                  for: detected == .weType ? .doubao : .weType
              ) == configured
        else { return configured }
        return preferred
    }
}
