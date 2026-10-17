#!/bin/zsh
# Packages build/Pulli.app as a disk image for testers: build/Pulli-<version>-<build>.dmg. It opens as an
# installer window: Pulli, an arrow, the Applications folder, and the steps (art drawn by
# `Pulli --dmg-background`, laid out by dmgbuild). Run scripts/make-app.sh first.
#
# With a Developer ID certificate (see make-app.sh) the image is signed too, and, when the
# notarisation profile exists (NOTARY_PROFILE, default "relay-notary"; see README › Signing), sent
# to Apple, waited for, and stapled: it then opens on any Mac without warnings. Otherwise
# testers allow Pulli once in System Settings › Privacy & Security › "Open Anyway".
set -euo pipefail
cd "$(dirname "$0")/.."

app=build/Pulli.app
[[ -d $app ]] || { echo "No $app: run scripts/make-app.sh first" >&2; exit 1; }
version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist" 2>/dev/null || echo dev)
build=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$app/Contents/Info.plist" 2>/dev/null || echo 0)
dmg="build/Pulli-${version}-${build}.dmg"

signed=false
notarise=false
profile="${NOTARY_PROFILE:-relay-notary}"
# Read once into a variable: with pipefail, `codesign | grep -q` fails when grep stops early.
signature=$(codesign -dv --verbose=2 "$app" 2>&1 || true)
if [[ $signature == *"Authority=Developer ID Application"* ]]; then
    signed=true
    xcrun notarytool history --keychain-profile "$profile" >/dev/null 2>&1 && notarise=true
fi

# The window's background, drawn by Pulli itself (with the "Open Anyway" hint unless notarised).
art=build/dmg-art
"$app/Contents/MacOS/Pulli" --dmg-background "$art" $($notarise || echo --unsigned) >/dev/null

# dmgbuild lays out the window (background, icon places, no toolbar) without scripting Finder.
tools=build/tools/dmg
if [[ ! -x $tools/bin/dmgbuild ]]; then
    echo "› installing dmgbuild (once)"
    python3 -m venv "$tools"
    "$tools/bin/pip" install -q dmgbuild
fi
settings=$(mktemp -t pulli-dmg).py
cat > "$settings" <<PY
import os
format = "UDZO"
filesystem = "APFS"
size = None
files = ["$app"]
symlinks = {"Applications": "/Applications"}
icon = "$app/Contents/Resources/AppIcon.icns"
background = "$art/background.png"
# The frame: the 660 × 420 picture plus the title bar.
window_rect = ((240, 160), (660, 448))
default_view = "icon-view"
show_status_bar = False
show_tab_view = False
show_toolbar = False
show_pathbar = False
show_sidebar = False
icon_size = 112
text_size = 13
arrange_by = None
label_pos = "bottom"
icon_locations = {"Pulli.app": (170, 188), "Applications": (490, 188)}
PY
rm -f "$dmg"
"$tools/bin/dmgbuild" -s "$settings" "Pulli" "$dmg" >/dev/null
rm -f "$settings"

if $signed; then
    identity=$(print -r -- "$signature" | awk -F= '/^Authority=Developer ID Application/ { print $2; exit }')
    codesign --force --sign "$identity" --timestamp "$dmg"
    if $notarise; then
        echo "› notarising (this takes a few minutes)"
        xcrun notarytool submit "$dmg" --keychain-profile "$profile" --wait
        xcrun stapler staple "$dmg"
        spctl --assess --type open --context context:primary-signature -v "$dmg"
    else
        echo "! signed but not notarised: no notarytool profile \"$profile\" (see README › Signing)"
    fi
fi
echo "✓ $dmg ($(du -h "$dmg" | cut -f1))"
