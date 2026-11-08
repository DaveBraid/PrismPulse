#!/bin/bash
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."
if [[ $# != 2 ]]; then
    printf '用法: %s build/releases/vX.Y.Z release-notes.md\n' "$0" >&2
    exit 64
fi
directory="$1"
notes="$2"
tools="${SPARKLE_TOOLS_DIR:-$PWD/.build/artifacts/sparkle/Sparkle/bin}"
repo="DaveBraid/PrismPulse"
tag="$(basename "$directory")"
[[ "$tag" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]]
[[ -f "$directory/PrismPulse-macOS.zip" && -f "$directory/appcast.xml" && -f "$notes" ]]
test -z "$(git status --porcelain)"
commit="$(git rev-parse HEAD)"
[[ "$(git ls-remote origin refs/heads/main | cut -f 1)" == "$commit" ]]
gh release create "$tag" "$directory/PrismPulse-macOS.zip" "$directory/SHA256SUMS" \
    --repo "$repo" --target "$commit" --title "PrismPulse ${tag#v}" --notes-file "$notes" --draft
asset="$(gh release view "$tag" --repo "$repo" --json assets --jq '.assets[] | select(.name=="PrismPulse-macOS.zip") | .apiUrl')"
[[ "$asset" == https://api.github.com/repos/DaveBraid/PrismPulse/releases/assets/* ]]
# 使用官方资产 API，更新客户端无需登录 GitHub。
python3 - "$directory/appcast.xml" "$asset" <<'PY'
import sys
import xml.etree.ElementTree as ET
path, url = sys.argv[1:]
ET.register_namespace("sparkle", "http://www.andymatuschak.org/xml-namespaces/sparkle")
tree = ET.parse(path)
tree.find("./channel/item/enclosure").set("url", url)
tree.write(path, encoding="utf-8", xml_declaration=True)
PY
"$tools/sign_update" --account local.ethanlee.PrismPulse "$directory/appcast.xml"
"$tools/sign_update" --account local.ethanlee.PrismPulse --verify "$directory/appcast.xml"
gh release upload "$tag" "$directory/appcast.xml" --repo "$repo"
gh release edit "$tag" --repo "$repo" --draft=false --latest
cp "$directory/appcast.xml" appcast.xml
git add -- appcast.xml
git commit -m "Publish signed update feed for $tag"
git push origin main
