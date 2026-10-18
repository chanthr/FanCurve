#!/bin/bash
# Builds dist/FanCurve-<version>.pkg: the app, the service, the launchd files
# and the scripts that start them. Run through ./fan.sh package.
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VERSION=$(cat "$ROOT/VERSION")
LABEL=local.fancurve

RELEASE=1 "$ROOT/fan.sh" build >/dev/null

W=$(mktemp -d)
trap 'rm -rf "$W"' EXIT

P="$W/payload"
mkdir -p "$P/Applications" "$P/usr/local/libexec" "$P/Library/LaunchDaemons" "$P/Library/LaunchAgents"
ditto "$ROOT/build/FanCurve.app" "$P/Applications/FanCurve.app"
install -m 755 "$ROOT/build/fancurve" "$P/usr/local/libexec/fancurve"
install -m 644 "$ROOT/packaging/$LABEL.plist" "$P/Library/LaunchDaemons/"
install -m 644 "$ROOT/packaging/$LABEL.app.plist" "$P/Library/LaunchAgents/"

# Install to /Applications even when a FanCurve.app already sits elsewhere
# (for example in a build folder); otherwise Installer "relocates" to that copy.
pkgbuild --analyze --root "$P" "$W/components.plist" >/dev/null
plutil -replace 0.BundleIsRelocatable -bool NO "$W/components.plist"

mkdir -p "$W/scripts"
install -m 755 "$ROOT/packaging/scripts/preinstall" "$ROOT/packaging/scripts/postinstall" "$W/scripts/"
# Leave quarantine and Finder attributes out of the payload. (macOS keeps
# com.apple.provenance; Installer restores it as an attribute, which is harmless.)
xattr -cr "$P" "$W/scripts"
pkgbuild --root "$P" --component-plist "$W/components.plist" --scripts "$W/scripts" \
  --identifier "$LABEL.pkg" --version "$VERSION" --install-location / --ownership recommended \
  "$W/FanCurve.pkg" >/dev/null

# Installer screens: welcome, license, finish, and the logo in the corner.
mkdir -p "$W/resources"
cp "$ROOT/packaging/resources/"*.html "$W/resources/"
cp "$ROOT/LICENSE" "$W/resources/LICENSE.txt"
"$ROOT/build/FanCurve.app/Contents/MacOS/FanCurve" --make-icon "$W/icon.png" >/dev/null
sips -z 144 144 "$W/icon.png" --out "$W/resources/background.png" >/dev/null
sed "s/@VERSION@/$VERSION/g" "$ROOT/packaging/distribution.xml" > "$W/distribution.xml"

mkdir -p "$ROOT/dist"
productbuild --distribution "$W/distribution.xml" --resources "$W/resources" --package-path "$W" \
  "$ROOT/dist/FanCurve-$VERSION.pkg" >/dev/null
echo "만들었습니다: dist/FanCurve-$VERSION.pkg ($(du -h "$ROOT/dist/FanCurve-$VERSION.pkg" | cut -f1 | tr -d ' '))"
