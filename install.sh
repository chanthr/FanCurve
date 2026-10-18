#!/bin/bash
# Installs the latest FanCurve release:
#
#   curl -fsSL https://raw.githubusercontent.com/chanthr/FanCurve/main/install.sh | bash
#
# Works while the repository is public; it downloads the newest .pkg from the
# GitHub releases and runs it with the macOS installer.
set -euo pipefail
REPO=chanthr/FanCurve

[ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] || { echo "FanCurve는 Apple Silicon(M1 이후) Mac 전용입니다."; exit 1; }
[ "$(sw_vers -productVersion | cut -d. -f1)" -ge 14 ] || { echo "macOS 14(Sonoma) 이상이 필요합니다."; exit 1; }

url=$(curl -fsSL "https://api.github.com/repos/$REPO/releases/latest" |
  grep -o '"browser_download_url": *"[^"]*\.pkg"' | head -n 1 | cut -d '"' -f 4)
[ -n "$url" ] || { echo "릴리스를 찾지 못했습니다: https://github.com/$REPO/releases"; exit 1; }

tmp=$(mktemp -d)
trap 'rm -rf "$tmp"' EXIT
echo "내려받는 중: $url"
curl -fL --progress-bar "$url" -o "$tmp/FanCurve.pkg"
echo "설치합니다. Mac 로그인 암호를 물으면 입력하세요."
sudo installer -pkg "$tmp/FanCurve.pkg" -target /
echo "끝났습니다. 메뉴 막대의 팬 아이콘을 확인하세요."
