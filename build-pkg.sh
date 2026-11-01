#!/bin/zsh
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
PLIST="$SCRIPT_DIR/Packaging/Info.plist"
VERSION=$(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$PLIST")
PACKAGE_VERSION=$(print -r -- "$VERSION" | sed -E 's/[^0-9.]+/./g; s/\.+/./g; s/^\.//; s/\.$//')
PAYLOAD_ROOT="$SCRIPT_DIR/dist/pkg-root"
UNSIGNED_PKG="$SCRIPT_DIR/dist/vRemoter-$VERSION-unsigned.pkg"
FINAL_PKG="$SCRIPT_DIR/dist/vRemoter-$VERSION.pkg"

"$SCRIPT_DIR/package-app.sh"
"$SCRIPT_DIR/Driver/build-driver.sh"

rm -rf "$PAYLOAD_ROOT" "$UNSIGNED_PKG" "$FINAL_PKG"
mkdir -p "$PAYLOAD_ROOT/Applications"
mkdir -p "$PAYLOAD_ROOT/Library/Audio/Plug-Ins/HAL"

ditto "$SCRIPT_DIR/dist/build/vRemote.app" "$PAYLOAD_ROOT/Applications/vRemote.app"
ditto "$SCRIPT_DIR/Driver/build/vRemoteDriver.driver" \
  "$PAYLOAD_ROOT/Library/Audio/Plug-Ins/HAL/vRemoteDriver.driver"

# 架构门：确认 APP 与驱动都带上了要求的 slice，否则不要出包。
# 默认只卡 Intel（历史上 1.1.1 就是因为漏了它，在 Intel Mac 上无法启动）。
# 出通用包时用 VR_REQUIRED_ARCHS="x86_64 arm64"。
REQUIRED_ARCHS="${VR_REQUIRED_ARCHS:-x86_64}"
for arch in ${=REQUIRED_ARCHS}; do
  for binary in \
    "$PAYLOAD_ROOT/Applications/vRemote.app/Contents/MacOS/vRemote" \
    "$PAYLOAD_ROOT/Library/Audio/Plug-Ins/HAL/vRemoteDriver.driver/Contents/MacOS/BlackHole"
  do
    if ! lipo -archs "$binary" 2>/dev/null | grep -qw "$arch"; then
      print -u2 "Error: ${binary:t} is missing $arch"
      exit 1
    fi
  done
done

pkgbuild \
  --root "$PAYLOAD_ROOT" \
  --scripts "$SCRIPT_DIR/Packaging/pkg-scripts" \
  --identifier "local.simaqingfeng.vRemoter.pkg" \
  --version "$PACKAGE_VERSION" \
  "$UNSIGNED_PKG"

if [[ -n "${INSTALLER_SIGN_IDENTITY:-}" ]]; then
  productsign \
    --sign "$INSTALLER_SIGN_IDENTITY" \
    "$UNSIGNED_PKG" \
    "$FINAL_PKG"
  rm -f "$UNSIGNED_PKG"
else
  mv "$UNSIGNED_PKG" "$FINAL_PKG"
  print -u2 "Warning: INSTALLER_SIGN_IDENTITY is not set; package is unsigned."
fi

pkgutil --check-signature "$FINAL_PKG" || true
print "Built: $FINAL_PKG"
