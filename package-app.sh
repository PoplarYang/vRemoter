#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
APP="$SCRIPT_DIR/dist/build/vRemote.app"
CONTENTS="$APP/Contents"

cd "$SCRIPT_DIR"

# 目标架构。留空 = 只编当前机器架构（SwiftPM 默认行为）。
# 设为 "x86_64" 可产出 Intel 版；设为 "arm64 x86_64" 可产出通用二进制。
#
# 注意：`swift build --arch a --arch b` 在 Apple 平台上交给 Xcode 的构建
# 系统执行，只有 Command Line Tools 的机器会报
# "xcbuild executable ... does not exist"。所以多架构改成逐架构编译，
# 再用 lipo -create 合并——两条路径都不需要 Xcode.app。
ARCH_LIST=()
if [[ -n "${VR_ARCHS:-}" ]]; then
  ARCH_LIST=(${=VR_ARCHS})
  print "Building for: $VR_ARCHS"
else
  print "Building for: $(uname -m) (host default)"
fi

BUILD_ARGS=(-c release)

# 在某些受限环境（CI 容器、被沙箱包裹的自动化）里 SwiftPM 自己再套一层
# sandbox-exec 会失败，此时用 VR_NO_SANDBOX=1 关掉它。
if [[ "${VR_NO_SANDBOX:-0}" == "1" ]]; then
  BUILD_ARGS+=(--disable-sandbox)
fi

SLICES=()
BINARY_SOURCE=""
if (( ${#ARCH_LIST[@]} == 0 )); then
  swift build "${BUILD_ARGS[@]}"
  BINARY_SOURCE="$SCRIPT_DIR/.build/release/vRemote"
elif (( ${#ARCH_LIST[@]} == 1 )); then
  single_arch="${ARCH_LIST[1]}"
  swift build "${BUILD_ARGS[@]}" --arch "$single_arch"
  BINARY_SOURCE="$SCRIPT_DIR/.build/$single_arch-apple-macosx/release/vRemote"
else
  for arch in "${ARCH_LIST[@]}"; do
    print "compiling $arch"
    swift build "${BUILD_ARGS[@]}" --arch "$arch"
    slice="$SCRIPT_DIR/.build/$arch-apple-macosx/release/vRemote"
    if [[ ! -f "$slice" ]]; then
      print -u2 "Error: missing $arch slice at $slice"
      exit 1
    fi
    SLICES+=("$slice")
  done
fi

rm -rf "$APP"
mkdir -p "$CONTENTS/MacOS"
mkdir -p "$CONTENTS/Resources"
if (( ${#SLICES[@]} > 0 )); then
  # lipo 不能把输出写到自己的输入上，直接生成到 bundle 内。
  lipo -create "${SLICES[@]}" -output "$CONTENTS/MacOS/vRemote"
else
  cp "$BINARY_SOURCE" "$CONTENTS/MacOS/vRemote"
fi
cp "$SCRIPT_DIR/Packaging/Info.plist" "$CONTENTS/Info.plist"

# 架构校验：避免再次产出「只在打包机上能跑」的单架构包
ARCHS_BUILT="$(lipo -archs "$CONTENTS/MacOS/vRemote")"
print "Binary architectures: $ARCHS_BUILT"
if [[ -n "${VR_ARCHS:-}" ]]; then
  for arch in "${ARCH_LIST[@]}"; do
    if [[ " $ARCHS_BUILT " != *" $arch "* ]]; then
      print -u2 "Error: built binary is missing $arch (got: $ARCHS_BUILT)"
      exit 1
    fi
  done
fi

# 写入构建标识，让界面能区分「官方包」与「本地构建」。
# 只改打包产物里的 Info.plist，不动仓库里那份。
PLIST_BUDDY=/usr/libexec/PlistBuddy
for key in VRBuildOrigin VRBuildStamp VRBuildArchs; do
  "$PLIST_BUDDY" -c "Delete :$key" "$CONTENTS/Info.plist" >/dev/null 2>&1 || true
done
"$PLIST_BUDDY" -c "Add :VRBuildOrigin string ${VR_BUILD_ORIGIN:-local}" "$CONTENTS/Info.plist"
"$PLIST_BUDDY" -c "Add :VRBuildStamp string $(date '+%m-%d %H:%M')" "$CONTENTS/Info.plist"
"$PLIST_BUDDY" -c "Add :VRBuildArchs string $ARCHS_BUILT" "$CONTENTS/Info.plist"
for resource_bundle in "$SCRIPT_DIR/.build/release/"*.bundle; do
  [[ -d "$resource_bundle" ]] || continue
  ditto "$resource_bundle" "$CONTENTS/Resources/${resource_bundle:t}"
done
for localization in "$SCRIPT_DIR/Packaging"/*.lproj; do
  [[ -d "$localization" ]] || continue
  ditto "$localization" "$CONTENTS/Resources/${localization:t}"
done
cp "$SCRIPT_DIR/Design/vRemoter-Logo-v1/vRemoter-app-icon-v9.png" \
  "$CONTENTS/Resources/vRemoterLogo.png"

ICONSET="$SCRIPT_DIR/dist/vRemoter.iconset"
rm -rf "$ICONSET"
mkdir -p "$ICONSET"
sips -z 16 16 "$CONTENTS/Resources/vRemoterLogo.png" --out "$ICONSET/icon_16x16.png" >/dev/null
sips -z 32 32 "$CONTENTS/Resources/vRemoterLogo.png" --out "$ICONSET/icon_16x16@2x.png" >/dev/null
sips -z 32 32 "$CONTENTS/Resources/vRemoterLogo.png" --out "$ICONSET/icon_32x32.png" >/dev/null
sips -z 64 64 "$CONTENTS/Resources/vRemoterLogo.png" --out "$ICONSET/icon_32x32@2x.png" >/dev/null
sips -z 128 128 "$CONTENTS/Resources/vRemoterLogo.png" --out "$ICONSET/icon_128x128.png" >/dev/null
sips -z 256 256 "$CONTENTS/Resources/vRemoterLogo.png" --out "$ICONSET/icon_128x128@2x.png" >/dev/null
sips -z 256 256 "$CONTENTS/Resources/vRemoterLogo.png" --out "$ICONSET/icon_256x256.png" >/dev/null
sips -z 512 512 "$CONTENTS/Resources/vRemoterLogo.png" --out "$ICONSET/icon_256x256@2x.png" >/dev/null
sips -z 512 512 "$CONTENTS/Resources/vRemoterLogo.png" --out "$ICONSET/icon_512x512.png" >/dev/null
cp "$CONTENTS/Resources/vRemoterLogo.png" "$ICONSET/icon_512x512@2x.png"
iconutil -c icns "$ICONSET" -o "$CONTENTS/Resources/vRemoter.icns"
rm -rf "$ICONSET"

if [[ -d "$SCRIPT_DIR/Resources/PermissionGuides" ]]; then
  ditto "$SCRIPT_DIR/Resources/PermissionGuides" \
    "$CONTENTS/Resources/PermissionGuides"
fi
if [[ -d "$SCRIPT_DIR/Resources/buymeacoffee" ]]; then
  ditto "$SCRIPT_DIR/Resources/buymeacoffee" \
    "$CONTENTS/Resources/BuyMeACoffee"
fi
if [[ -d "$SCRIPT_DIR/Resources/Commerce" ]]; then
  ditto "$SCRIPT_DIR/Resources/Commerce" \
    "$CONTENTS/Resources/Commerce"
fi
if [[ -d "$SCRIPT_DIR/Resources/RemoteImages" ]]; then
  ditto "$SCRIPT_DIR/Resources/RemoteImages" \
    "$CONTENTS/Resources/RemoteImages"
fi
chmod 755 "$CONTENTS/MacOS/vRemote"
# SwiftPM resource bundles may contain read-only privacy manifests. The app
# bundle is a disposable build artifact, so make it owner-writable before
# clearing inherited metadata and applying the final ad-hoc signature.
chmod -R u+w "$APP"
xattr -cr "$APP"

# Give the ad-hoc build a stable designated requirement. Without this,
# codesign falls back to a CDHash-only requirement, so every rebuild looks
# like a different application to Accessibility/Input Monitoring (TCC).
codesign \
  --force \
  --deep \
  --sign - \
  --timestamp=none \
  --requirements '=designated => identifier "local.simaqingfeng.vRemote"' \
  "$APP"
codesign --verify --deep --strict --verbose=2 "$APP"
print "Built: $APP"
