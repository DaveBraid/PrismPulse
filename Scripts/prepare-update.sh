#!/bin/bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
if [[ $# != 2 ]]; then
    printf '用法: %s PrismPulse.app release-notes.md\n' "$0" >&2
    exit 64
fi

app="$1"
notes="$2"
tools="${SPARKLE_TOOLS_DIR:-$PWD/.build/artifacts/sparkle/Sparkle/bin}"
account="local.ethanlee.PrismPulse"
[[ -d "$app" && -f "$notes" && -x "$tools/generate_appcast" ]]
version="$(/usr/libexec/PlistBuddy -c 'Print :CFBundleShortVersionString' "$app/Contents/Info.plist")"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]
/usr/bin/codesign --verify --deep --strict --all-architectures "$app"
architectures="$(xcrun lipo -archs "$app/Contents/MacOS/PrismPulse")"
[[ "$architectures" == 'x86_64 arm64' || "$architectures" == 'arm64 x86_64' ]]
public_key="$("$tools/generate_keys" --account "$account" -p)"
[[ "$public_key" == "$(/usr/libexec/PlistBuddy -c 'Print :SUPublicEDKey' "$app/Contents/Info.plist")" ]]

output="$PWD/build/releases/v$version"
[[ ! -e "$output" ]]
mkdir -p "$PWD/build/releases"
staging="$(mktemp -d "$PWD/build/releases/.prepare.XXXXXX")"
trap 'rm -rf -- "$staging"' EXIT
/usr/bin/ditto -c -k --sequesterRsrc --keepParent "$app" "$staging/PrismPulse-macOS.zip"
cp "$notes" "$staging/PrismPulse-macOS.md"
# 签署安装包及更新信息，私钥始终由钥匙串提供。
"$tools/generate_appcast" --account "$account" --maximum-deltas 0 --embed-release-notes \
    --download-url-prefix "https://github.com/DaveBraid/PrismPulse/releases/download/v$version/" \
    --link "https://github.com/DaveBraid/PrismPulse/releases/tag/v$version" "$staging"
"$tools/sign_update" --account "$account" --verify "$staging/appcast.xml"
(
    cd "$staging"
    shasum -a 256 PrismPulse-macOS.zip > SHA256SUMS
)
mv "$staging" "$output"
printf '%s\n' "$output"
