#!/bin/bash
# Runs the development build of pulli-helper under launchd, like the app's LaunchAgent will.
#
#   scripts/dev-helper.sh install [--mock]   build, then load it (starts now and at login)
#   scripts/dev-helper.sh uninstall          unload it and remove the plist
#   scripts/dev-helper.sh status             launchd's view of it
#   scripts/dev-helper.sh logs               follow its log
#
# This writes ~/Library/LaunchAgents/app.pulli.mac.helper.plist: a change to your login items.
# The released app registers the helper itself (SMAppService) instead.
set -euo pipefail
cd "$(dirname "${BASH_SOURCE[0]}")/.."

LABEL="app.pulli.mac.helper"
PLIST="$HOME/Library/LaunchAgents/$LABEL.plist"
LOG="$HOME/Library/Logs/Pulli/pulli-helper.log"
DOMAIN="gui/$(id -u)"

case "${1:-}" in
  install)
    swift build --product pulli-helper
    BIN="$(swift build --show-bin-path)/pulli-helper"
    ARGS="<string>$BIN</string>"
    [[ "${2:-}" == "--mock" ]] && ARGS="$ARGS<string>--mock</string>"
    mkdir -p "$(dirname "$PLIST")" "$(dirname "$LOG")"
    cat > "$PLIST" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
  <key>Label</key><string>$LABEL</string>
  <key>ProgramArguments</key><array>$ARGS</array>
  <key>MachServices</key><dict><key>$LABEL</key><true/></dict>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><dict><key>SuccessfulExit</key><false/></dict>
  <key>ProcessType</key><string>Interactive</string>
  <key>StandardErrorPath</key><string>$LOG</string>
</dict></plist>
PLIST
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    launchctl bootstrap "$DOMAIN" "$PLIST"
    echo "Loaded $LABEL ($BIN${2:+ $2}). Log: $LOG"
    ;;
  uninstall)
    launchctl bootout "$DOMAIN/$LABEL" 2>/dev/null || true
    rm -f "$PLIST"
    echo "Unloaded $LABEL."
    ;;
  status)
    launchctl print "$DOMAIN/$LABEL" | grep -E "state|pid|last exit|program" || echo "$LABEL is not loaded."
    ;;
  logs)
    tail -f "$LOG"
    ;;
  *)
    sed -n '2,11p' "$0"; exit 2 ;;
esac
