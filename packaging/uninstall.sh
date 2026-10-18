#!/bin/bash
# Removes FanCurve and hands the fans back to Apple's control.
#
#   sudo /Applications/FanCurve.app/Contents/Resources/uninstall.sh
[ "$(id -u)" = 0 ] || exec sudo "$0" "$@"
LABEL=local.fancurve

console_uid=$(stat -f %u /dev/console)
if [ "$console_uid" -gt 0 ] 2>/dev/null; then
  launchctl bootout "gui/$console_uid/$LABEL.app" 2>/dev/null
fi
pkill -x FanCurve 2>/dev/null

# The service puts the fans back to Auto when it stops; --auto makes sure.
launchctl bootout "system/$LABEL" 2>/dev/null
[ -x /usr/local/libexec/fancurve ] && /usr/local/libexec/fancurve --auto

rm -f "/Library/LaunchDaemons/$LABEL.plist" "/Library/LaunchAgents/$LABEL.app.plist" /usr/local/libexec/fancurve
rm -f /Users/*/Library/LaunchAgents/$LABEL.app.plist
rm -rf "/Library/Application Support/fancurve" /Applications/FanCurve.app
rm -f /Library/Logs/fancurve.log
pkgutil --forget "$LABEL.pkg" >/dev/null 2>&1
echo "FanCurve를 제거했습니다. 팬은 Apple 자동 제어로 돌아갔습니다."
