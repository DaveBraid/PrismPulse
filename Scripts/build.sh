#!/bin/bash
set -euo pipefail

# 复用 SwiftPM 的 Release 产物；额外组装含系统权限说明的原生 App。
cd "$(dirname "${BASH_SOURCE[0]}")/.."
swift build -c release --product PrismPulse "$@"
bin="$(swift build -c release --show-bin-path "$@")"
mkdir -p build
staging="$(mktemp -d "$PWD/build/.app.XXXXXX")"
trap 'rm -rf -- "$staging"' EXIT
bundle="$staging/PrismPulse.app"
mkdir -p "$bundle/Contents/MacOS" "$bundle/Contents/Resources"
cp "$bin/PrismPulse" "$bundle/Contents/MacOS/"
cp Support/Info.plist "$bundle/Contents/"
if [[ -f Support/AppIcon.icns ]]; then cp Support/AppIcon.icns "$bundle/Contents/Resources/"; fi
codesign --force --sign "${PRISMPULSE_SIGN_IDENTITY:--}" --timestamp=none \
    --entitlements Support/Entitlements.plist "$bundle"
codesign --verify --strict "$bundle"
# 只替换本脚本生成的构建产物。
if [[ -e build/PrismPulse.app ]]; then rm -rf -- build/PrismPulse.app; fi
mv "$bundle" build/
printf '%s\n' "$PWD/build/PrismPulse.app"
