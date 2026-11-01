#!/bin/zsh
# 关闭 TelemetryDeck 依赖里「StoreKit 内购预设」两个文件的编译。
#
# 原因：这两个文件要求 macOS 14 SDK 才有的 StoreKit API
# （Transaction.currencyCode / Transaction.offer），而本机只有 13.3 SDK。
# vRemoter 只用到 TelemetryDeck 的 Config / initialize / signal，
# 不涉及内购预设，因此排除它们不影响 APP 行为。
#
# 幂等：重复执行不会叠加修改。clean 之后 .build 被删掉，重新跑一次即可。
set -euo pipefail

SCRIPT_DIR="${0:A:h}"
CHECKOUT="$SCRIPT_DIR/../.build/checkouts/SwiftSDK/Sources/TelemetryDeck/Presets"

if [[ ! -d "$CHECKOUT" ]]; then
  print "跳过：依赖尚未解析（先执行 swift package resolve）"
  exit 0
fi

PURCHASES="$CHECKOUT/TelemetryDeck+Purchases.swift"
TRIAL="$CHECKOUT/TrialConversionTracker.swift"

# 1) 内购预设：把 #if 条件改死
if [[ -f "$PURCHASES" ]]; then
  if grep -q "compiler(>=5.9.2) && false" "$PURCHASES"; then
    print "已处理：TelemetryDeck+Purchases.swift"
  else
    perl -0pi -e 's/#if canImport\(StoreKit\) && compiler\(>=5\.9\.2\)/#if canImport(StoreKit) \&\& compiler(>=5.9.2) \&\& false/' "$PURCHASES"
    print "已打补丁：TelemetryDeck+Purchases.swift"
  fi
fi

# 2) 试用转换追踪：整文件停用
if [[ -f "$TRIAL" ]]; then
  if head -1 "$TRIAL" | grep -q "VR_DISABLED"; then
    print "已处理：TrialConversionTracker.swift"
  else
    print -r -- "// VR_DISABLED: requires macOS 14 SDK StoreKit APIs" > "$TRIAL.tmp"
    print -r -- "#if false" >> "$TRIAL.tmp"
    cat "$TRIAL" >> "$TRIAL.tmp"
    print -r -- "#endif" >> "$TRIAL.tmp"
    mv "$TRIAL.tmp" "$TRIAL"
    print "已打补丁：TrialConversionTracker.swift"
  fi
fi

print "补丁完成。"
