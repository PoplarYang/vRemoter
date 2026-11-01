#!/bin/zsh
# 在 Intel Mac 上构建并本地安装 vRemoter（APP 部分不需要管理员权限）
#
# 本机环境现状（macOS 13.7 / Intel）：
#   - 系统 CLT 只到 Xcode 14.3（Swift 5.8.1、SDK 13.3），而本项目
#     要求 swift-tools-version 5.9，且 DoubaoAudioStateMonitor 用了
#     macOS 14.2 才有的 CoreAudio 常量，必须用 SDK >= 14.
#   - 因此改用用户目录里的 Swift 5.10.1 工具链 + 解包出来的 MacOSX14.5.sdk，
#     通过一个「开发者目录镜像」让 xcrun/SwiftPM 找到它们，全程无需 sudo。
#
# 用法：
#   ./build-intel.sh                            # 只编 x86_64（本机用，最快）
#   VR_ARCHS="arm64 x86_64" ./build-intel.sh    # 通用二进制（Intel + Apple Silicon）
#
# 通用二进制不再依赖 Xcode：package-app.sh 逐架构编译后用 lipo 合并，
# 因此只有命令行工具的机器也能出双架构包。
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
export VR_ARCHS="${VR_ARCHS:-x86_64}"
export VR_NO_SANDBOX=1

TOOLCHAIN_DIR="$HOME/Library/Developer/Toolchains"
SDK_DIR="$HOME/Library/Developer/vremoter-sdk"
SHIM_ROOT="$HOME/.vremoter-shim/Library/Developer/CommandLineTools"
CLT="/Library/Developer/CommandLineTools"

# ---------- 1. 工具链 ----------
TOOLCHAIN=""
for candidate in "$TOOLCHAIN_DIR"/*.xctoolchain; do
  [[ -x "$candidate/usr/bin/swift" ]] && TOOLCHAIN="$candidate"
done

if [[ -z "$TOOLCHAIN" ]]; then
  print -u2 "找不到用户目录下的 Swift 工具链（$TOOLCHAIN_DIR）。"
  print -u2 "安装：installer -pkg <swift-5.10.1-RELEASE-osx.pkg> -target CurrentUserHomeDirectory"
  exit 1
fi

export PATH="$TOOLCHAIN/usr/bin:$PATH"
SWIFT_LINE="$(swift --version 2>&1 | head -1)"
print "Toolchain: $SWIFT_LINE"

# ---------- 2. SDK ----------
if [[ ! -d "$SDK_DIR/MacOSX14.5.sdk" ]]; then
  print -u2 "找不到 $SDK_DIR/MacOSX14.5.sdk"
  exit 1
fi

# 开发者目录镜像：名字必须是 CommandLineTools，xcrun 才认
if [[ ! -L "$SHIM_ROOT/SDKs/MacOSX.sdk" ]]; then
  rm -rf "$SHIM_ROOT"
  mkdir -p "$SHIM_ROOT/SDKs" "$SHIM_ROOT/Platforms/MacOSX.platform/Developer/SDKs"
  ln -s "$CLT/usr" "$SHIM_ROOT/usr"
  ln -s "$CLT/Library" "$SHIM_ROOT/Library"
  ln -s "$SDK_DIR/MacOSX14.5.sdk" "$SHIM_ROOT/SDKs/MacOSX.sdk"
  ln -s "$SDK_DIR/MacOSX14.5.sdk" "$SHIM_ROOT/Platforms/MacOSX.platform/Developer/SDKs/MacOSX.sdk"
fi

export DEVELOPER_DIR="$SHIM_ROOT"
print "SDK: $(xcrun --sdk macosx --show-sdk-path) ($(xcrun --sdk macosx --show-sdk-version))"

# ---------- 3. 编译 + 打包 ----------
# 注：只有回退到 SDK 13.x 时才需要 scripts/patch-telemetrydeck.sh。
print "\n=== 编译 (arch: $VR_ARCHS) ==="
"$SCRIPT_DIR/package-app.sh"

# ---------- 5. 安装 ----------
print "\n=== 停止旧实例 ==="
if pkill -f "Applications/vRemote.app/Contents/MacOS/vRemote" 2>/dev/null; then
  print "已停止运行中的 vRemote"
  sleep 1
else
  print "没有运行中的实例"
fi

print "\n=== 安装 APP ==="
if [[ -w /Applications ]]; then
  DEST="/Applications/vRemote.app"
else
  DEST="$HOME/Applications/vRemote.app"
  mkdir -p "$HOME/Applications"
fi
if [[ -d "$DEST" ]]; then
  mkdir -p "$HOME/.Trash"
  mv "$DEST" "$HOME/.Trash/vRemote-old-$(date +%H%M%S).app"
  print "旧版本已移入废纸篓"
fi
ditto "$SCRIPT_DIR/dist/build/vRemote.app" "$DEST"
print "Installed: $DEST ($(lipo -archs "$DEST/Contents/MacOS/vRemote"))"
print "Version: $(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$DEST/Contents/Info.plist") · $(/usr/libexec/PlistBuddy -c 'Print :VRBuildStamp' "$DEST/Contents/Info.plist" 2>/dev/null || print "-")"
codesign --verify --deep --strict "$DEST" 2>&1 | tail -3 || true

# ---------- 6. 驱动与启动 ----------
print "\n=== 驱动 ==="
if [[ -d /Library/Audio/Plug-Ins/HAL/vRemoteDriver.driver ]]; then
  print "vRemoteDriver.driver: 已安装"
else
  print "vRemoteDriver.driver: 缺失 —— 双击工作区的 install-vRemoteDriver.command（需一次管理员密码）"
fi

print "\n=== 启动 ==="
open "$DEST"
print "看屏幕右上角菜单栏。"
