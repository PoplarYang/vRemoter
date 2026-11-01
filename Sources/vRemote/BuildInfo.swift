import Foundation

/// 版本与构建来源。
///
/// 上游包只有 `CFBundleShortVersionString`。本地构建时 `package-app.sh`
/// 会额外往 Info.plist 写入 `VRBuildOrigin` / `VRBuildStamp` / `VRBuildArchs`，
/// 这样「现在跑的是官方包还是自己编的包、编的是哪个架构」在界面上就能直接看到，
/// 不必再靠 `lipo` 或日志去猜。
enum BuildInfo {
    /// 上游发布号，例：1.1.1
    static let version: String = Bundle.main.object(
        forInfoDictionaryKey: "CFBundleShortVersionString"
    ) as? String ?? "development"

    /// 编译时的目标架构。通用二进制里每个切片各自编译，因此这里报告的
    /// 就是当前正在执行的那一片（在 Rosetta 下会如实显示 x86_64）。
    static let architecture: String = {
        #if arch(arm64)
        return "arm64"
        #elseif arch(x86_64)
        return "x86_64"
        #else
        return "unknown"
        #endif
    }()

    /// 本地构建标记；官方包没有这个键。
    static let origin = Bundle.main.object(
        forInfoDictionaryKey: "VRBuildOrigin"
    ) as? String

    /// 构建时间戳，例：11-01 10:23
    static let stamp = Bundle.main.object(
        forInfoDictionaryKey: "VRBuildStamp"
    ) as? String

    static var isLocalBuild: Bool { origin == "local" }

    /// "1.1.1 (x86_64)"
    static var short: String { "\(version) (\(architecture))" }

    /// 菜单里的一行：本地构建带时间戳，官方包只显示版本与架构。
    static var menuTitle: String {
        guard let stamp else {
            return L10n.text("版本 \(short)", "Version \(short)")
        }
        return L10n.text(
            "版本 \(short) · 本地构建 \(stamp)",
            "Version \(short) · local build \(stamp)"
        )
    }

    /// 控制台标题用的短形式，避免和右侧状态挤在一起。
    static var compactTitle: String {
        isLocalBuild
            ? L10n.text("\(short) · 本地构建", "\(short) · local build")
            : short
    }

    /// 界面副标题用的第二行；官方包返回 nil，调用方据此隐藏。
    static var buildLine: String? {
        guard let stamp else { return nil }
        let label = isLocalBuild
            ? L10n.text("本地构建", "Local build")
            : L10n.text("构建", "Build")
        return "\(label) · \(stamp)"
    }
}
