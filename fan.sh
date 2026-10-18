#!/bin/bash
# FanCurve: CPU·GPU 중 더 뜨거운 쪽 온도에 맞춰 맥 팬 속도를 조절합니다.
# 소스에서 빌드해 설치하는 스크립트입니다. 설치 패키지(.pkg)로 설치했다면 필요 없습니다.
#
#   sudo ./fan.sh install     빌드하고 설치 (서비스 + 앱, 부팅·로그인 때 자동 시작)
#   sudo ./fan.sh uninstall   전부 제거, 팬은 Apple 자동으로 돌아감
#   sudo ./fan.sh auto        비상용: 팬을 바로 Apple 자동으로 되돌림
#   sudo ./fan.sh run         서비스 없이 이 터미널에서만 제어 (Ctrl-C로 끝내면 Apple 자동)
#
#   ./fan.sh status           온도와 팬 상태
#   ./fan.sh test             팬은 건드리지 않고 계산만 2초마다 출력 (Ctrl-C로 종료)
#   ./fan.sh log              서비스 기록 보기 (Ctrl-C로 나옴)
#   ./fan.sh open             FanCurve 창 열기
#   ./fan.sh build            build/에 빌드만
#   ./fan.sh package          dist/에 설치 패키지(.pkg) 만들기
#
# 곡선과 모드(곡선 / 항상 최대 / Apple 자동)는 FanCurve 앱에서 바꿉니다.
set -euo pipefail

HERE="$(cd "$(dirname "$0")" && pwd)"
SELF="$HERE/$(basename "$0")"
BIN="$HERE/build/fancurve"
APP="$HERE/build/FanCurve.app"
LABEL=local.fancurve
DAEMON_BIN=/usr/local/libexec/fancurve
STATE_DIR="/Library/Application Support/fancurve"
LOG=/Library/Logs/fancurve.log
INSTALLED_APP=/Applications/FanCurve.app
VERSION=$(cat "$HERE/VERSION")
MIN_MACOS=14.0

# Build as the real user even under sudo, so build/ never ends up owned by root.
as_user() {
  if [ "$(id -u)" = 0 ] && [ -n "${SUDO_USER:-}" ]; then sudo -u "$SUDO_USER" "$@"; else "$@"; fi
}

check_mac() {
  [ "$(sysctl -n hw.optional.arm64 2>/dev/null)" = 1 ] || { echo "FanCurve는 Apple Silicon(M1 이후) Mac 전용입니다."; exit 1; }
  [ "$(sw_vers -productVersion | cut -d. -f1)" -ge 14 ] || { echo "macOS 14(Sonoma) 이상이 필요합니다."; exit 1; }
}

check_tools() {
  if ! xcrun --find swiftc >/dev/null 2>&1 || ! xcrun --find clang >/dev/null 2>&1; then
    echo "빌드 도구가 없습니다. 먼저 설치하세요: xcode-select --install"
    exit 1
  fi
}

# The app draws its own icon (--make-icon); iconutil turns it into AppIcon.icns.
make_icon() {
  local set="$HERE/build/AppIcon.iconset"
  as_user rm -rf "$set"
  as_user mkdir -p "$set"
  as_user "$APP/Contents/MacOS/FanCurve" --make-icon "$set/icon_512x512@2x.png" >/dev/null
  for s in 16 32 128 256 512; do
    as_user sips -z $s $s "$set/icon_512x512@2x.png" --out "$set/icon_${s}x${s}.png" >/dev/null
    [ $s = 512 ] || as_user sips -z $((s * 2)) $((s * 2)) "$set/icon_512x512@2x.png" --out "$set/icon_${s}x${s}@2x.png" >/dev/null
  done
  as_user iconutil -c icns "$set" -o "$APP/Contents/Resources/AppIcon.icns"
}

# RELEASE=1 leaves out the checkout path, which the app shows when the service
# is off ("sudo <path>/fan.sh install"); the .pkg build sets it.
build() {
  check_mac
  check_tools
  local src="$HERE/Sources" exe="$APP/Contents/MacOS/FanCurve"
  as_user mkdir -p "$HERE/build" "$APP/Contents/MacOS" "$APP/Contents/Resources"
  if [ ! -x "$BIN" ] || [ "$src/fancurve.c" -nt "$BIN" ]; then
    echo "엔진 빌드"
    as_user xcrun clang -O2 -Wall -mmacosx-version-min=$MIN_MACOS -framework IOKit "$src/fancurve.c" -o "$BIN"
  fi
  if [ ! -x "$exe" ] || [ "$src/FanCurveApp.swift" -nt "$exe" ]; then
    echo "앱 빌드 (10초쯤 걸립니다)"
    as_user xcrun swiftc -O -swift-version 5 -parse-as-library -target arm64-apple-macos$MIN_MACOS \
      "$src/FanCurveApp.swift" -o "$exe"
    make_icon
  fi
  [ -f "$APP/Contents/Resources/AppIcon.icns" ] || make_icon
  local source_key=""
  [ "${RELEASE:-0}" = 1 ] || source_key="<key>FanCurveSource</key><string>$HERE</string>"
  as_user tee "$APP/Contents/Info.plist" >/dev/null <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>CFBundleIdentifier</key><string>$LABEL.app</string>
  <key>CFBundleName</key><string>FanCurve</string>
  <key>CFBundleDisplayName</key><string>FanCurve</string>
  <key>CFBundleExecutable</key><string>FanCurve</string>
  <key>CFBundleIconFile</key><string>AppIcon</string>
  <key>CFBundlePackageType</key><string>APPL</string>
  <key>CFBundleShortVersionString</key><string>$VERSION</string>
  <key>CFBundleVersion</key><string>$VERSION</string>
  <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
  <key>LSMinimumSystemVersion</key><string>$MIN_MACOS</string>
  <key>LSUIElement</key><true/>
  <key>NSHumanReadableCopyright</key><string>© 2026 chanthr · MIT License</string>
  $source_key
</dict>
</plist>
EOF
  as_user install -m 755 "$HERE/packaging/uninstall.sh" "$APP/Contents/Resources/uninstall.sh"
  as_user codesign -s - --force "$APP" >/dev/null 2>&1 || true
}

need_root() {
  [ "$(id -u)" = 0 ] && [ -n "${SUDO_USER:-}" ] || { echo "sudo로 실행하세요: sudo $SELF $1"; exit 1; }
}

service_running() { pgrep -qf "^$DAEMON_BIN"; }

warn_mfc() {
  if pgrep -xq "Macs Fan Control"; then
    echo
    echo "주의: Macs Fan Control이 켜져 있습니다. 그 앱에서 두 팬을 '자동'으로 두거나 앱을 종료하세요."
    echo "      둘 다 팬을 조절하면 서로 속도를 덮어씁니다 (FanCurve 앱에 '충돌'로 표시됩니다)."
    echo
  fi
}

step=${1:-help}
shift || true
case "$step" in
  install)
    need_root install
    build
    # The same steps as the .pkg: stop, copy the files, start.
    bash "$HERE/packaging/scripts/preinstall"
    install -d -o root -g wheel -m 755 "$(dirname "$DAEMON_BIN")"
    install -o root -g wheel -m 755 "$BIN" "$DAEMON_BIN"
    install -o root -g wheel -m 644 "$HERE/packaging/$LABEL.plist" /Library/LaunchDaemons/
    install -o root -g wheel -m 644 "$HERE/packaging/$LABEL.app.plist" /Library/LaunchAgents/
    rm -rf "$INSTALLED_APP"
    ditto "$APP" "$INSTALLED_APP"
    bash "$HERE/packaging/scripts/postinstall"
    for _ in 1 2 3 4 5; do service_running && break; sleep 1; done
    if service_running; then
      echo "설치했습니다. 메뉴 막대에 팬 아이콘과 온도가 보이고, 응용 프로그램 폴더의 FanCurve로 창을 열 수 있습니다."
      echo "부팅·로그인 때마다 자동으로 시작합니다. 기록: $SELF log"
    else
      echo "서비스가 시작하지 못했습니다. 기록을 보세요: $LOG"
      exit 1
    fi
    warn_mfc
    ;;
  uninstall)
    need_root uninstall
    bash "$HERE/packaging/uninstall.sh"
    ;;
  auto)
    need_root auto
    build
    if service_running; then
      echo "서비스가 켜져 있어 곧 다시 조절합니다. 계속 Apple 자동으로 두려면 앱에서 'Apple 자동'을 고르거나 uninstall 하세요."
    fi
    "$BIN" --auto
    ;;
  run)
    need_root run
    build
    if service_running; then echo "서비스가 이미 팬을 조절하고 있습니다. 먼저: sudo $SELF uninstall"; exit 1; fi
    install -d -o root -g wheel -m 755 "$STATE_DIR"
    warn_mfc
    exec "$BIN" --log-every 10
    ;;
  status)
    build
    "$BIN" --status
    if service_running; then echo "서비스: 실행 중"
    elif [ -f "/Library/LaunchDaemons/$LABEL.plist" ]; then echo "서비스: 설치됨, 실행 중 아님 (기록: $LOG)"
    else echo "서비스: 설치 안 됨"; fi
    ;;
  test)
    build
    exec "$BIN" --dry-run --log-every 2
    ;;
  log)
    tail -n 30 -f "$LOG"
    ;;
  open)
    if [ -d "$INSTALLED_APP" ]; then open "$INSTALLED_APP"; else build; open "$APP"; fi
    ;;
  build)
    build
    echo "빌드했습니다: $BIN, $APP"
    ;;
  package)
    [ "$(id -u)" != 0 ] || { echo "package는 sudo 없이 실행하세요: $SELF package"; exit 1; }
    bash "$HERE/packaging/build-pkg.sh"
    ;;
  *)
    awk 'NR > 1 && /^#/ { sub(/^# ?/, ""); print; next } NR > 1 { exit }' "$SELF"
    ;;
esac
