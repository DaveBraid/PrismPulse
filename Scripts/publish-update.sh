#!/bin/bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
if [[ $# != 2 ]]; then
    printf '用法: %s build/releases/vX.Y.Z release-notes.md\n' "$0" >&2
    exit 64
fi
directory="$1"
notes="$2"
repo="DaveBraid/PrismPulse"
tag="$(basename "$directory")"
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ -f "$directory/PrismPulse-macOS.zip" && -f "$directory/SHA256SUMS" && -f "$directory/appcast.xml" && -f "$notes" ]]
test -z "$(git status --porcelain)"
commit="$(git rev-parse HEAD)"
[[ "$(git ls-remote origin refs/heads/main | cut -f 1)" == "$commit" ]]
download_url="https://github.com/$repo/releases/download/$tag/PrismPulse-macOS.zip"
swift Scripts/verify-update.swift Support/Info.plist "$directory" "$download_url"
gh release create "$tag" "$directory/PrismPulse-macOS.zip" "$directory/SHA256SUMS" "$directory/appcast.xml" \
    --repo "$repo" --target "$commit" --title "PrismPulse ${tag#v}" --notes-file "$notes" --draft
gh release edit "$tag" --repo "$repo" --draft=false --latest

# 公开安装包可免登录下载后，再启用应用内更新。
downloaded="$(mktemp -t prismpulse-download)"
trap 'rm -f -- "$downloaded"' EXIT
curl --disable --fail --silent --show-error --location --retry 3 --retry-all-errors --retry-max-time 20 --max-time 15 \
    --header 'Accept: application/octet-stream' --output "$downloaded" "$download_url"
cmp "$directory/PrismPulse-macOS.zip" "$downloaded"
cp "$directory/appcast.xml" appcast.xml
git add -- appcast.xml
git commit -m "Publish signed update feed for $tag"
git push origin main
