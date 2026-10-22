#!/bin/bash
# Builds build/Pulli.app: the SwiftUI app, the background helper, the per-phone worker, the
# vendored libmtp/libusb, fonts, sounds, the app icon and the helper's LaunchAgent plist.
#
#   scripts/make-app.sh            release build
#   scripts/make-app.sh --debug    debug build (faster to build)
#
# Signing: with a "Developer ID Application" certificate in the keychain (or SIGN_IDENTITY set
# to one), everything is signed with it, with the hardened runtime and a secure timestamp, as
# notarisation requires (scripts/make-dmg.sh then notarises). Without one, the app is signed
# ad hoc: it runs on this Mac, and testers must allow it once in Privacy & Security.
set -euo pipefail
cd "$(dirname "$0")/.."

configuration=release
[[ "${1:-}" == "--debug" ]] && configuration=debug

# CFBundleVersion must be a strictly increasing timestamp for Sparkle (YYYYMMDDHHMMSS).
build="$(date +%Y%m%d%H%M%S)"
commit="$(git rev-parse --short HEAD 2>/dev/null || echo dev)"
short_version="0.4.3"

# Feedback email: the environment wins over Config/release.env (which may hold an empty value).
env_feedback_email="${PULLI_FEEDBACK_EMAIL:-}"
if [[ -f Config/release.env ]]; then
    # shellcheck disable=SC1091
    source Config/release.env
fi
feedback_email="${env_feedback_email:-${PULLI_FEEDBACK_EMAIL:-}}"

# Sparkle auto-updates configuration
key_file="Config/sparkle-public-key.txt"
sparkle_key=""
is_placeholder=true
if [[ -f "$key_file" ]]; then
    sparkle_key="$(grep -v '^[[:space:]]*#' "$key_file" | tr -d '[:space:]' | head -n 1 || true)"
    if [[ -n "$sparkle_key" && "$sparkle_key" != *"PASTE_"* && "$sparkle_key" != *"REPLACE_"* && "$sparkle_key" != *"placeholder"* ]]; then
        is_placeholder=false
    fi
fi

enable_updates=false
if $is_placeholder; then
    if [[ "${PULLI_RELEASE:-0}" == "1" ]]; then
        echo "Error: Config/sparkle-public-key.txt contains a placeholder key. Add your Sparkle public key before releasing." >&2
        exit 1
    else
        echo "› warning: Config/sparkle-public-key.txt has placeholder key; building without updates enabled"
    fi
else
    enable_updates=true
fi

echo "› building ($configuration)"
for product in Pulli pulli-helper pulli-mtp-worker PulliWidget PulliFileProvider; do
    swift build -c "$configuration" --product "$product" >/dev/null
done
bin=$(swift build -c "$configuration" --show-bin-path)

app=build/Pulli.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Frameworks" "$app/Contents/Resources" "$app/Contents/Library/LaunchAgents"

cp "$bin/Pulli" "$bin/pulli-helper" "$bin/pulli-mtp-worker" "$app/Contents/MacOS/"
cp -R "$bin/Pulli_Pulli.bundle" "$app/Contents/Resources/"
cp Vendor/out/lib/libmtp.9.dylib Vendor/out/lib/libusb-1.0.0.dylib "$app/Contents/Frameworks/"
sparkle_framework=$(find .build/artifacts -name "Sparkle.framework" -type d | head -n 1)
if [[ -n "$sparkle_framework" && -d "$sparkle_framework" ]]; then
    echo "› embedding Sparkle.framework"
    cp -R "$sparkle_framework" "$app/Contents/Frameworks/"
    # For a non-sandboxed app, remove XPC services as Sparkle's documentation allows
    rm -rf "$app/Contents/Frameworks/Sparkle.framework/Versions/B/XPCServices"
    rm -rf "$app/Contents/Frameworks/Sparkle.framework/XPCServices"
fi
cp Helper/app.pulli.mac.helper.plist "$app/Contents/Library/LaunchAgents/"
mkdir -p "$app/Contents/Resources/Licenses"
cp Vendor/out/licenses/* "$app/Contents/Resources/Licenses/" 2>/dev/null || true
cp Sources/Pulli/Resources/Fonts/PlusJakartaSans-OFL.txt "$app/Contents/Resources/Licenses/"
cp LICENSE "$app/Contents/Resources/Licenses/Pulli-GPL-3.0.txt"
cp NOTICE "$app/Contents/Resources/Licenses/Pulli-NOTICE.txt"
[[ -f .build/artifacts/sparkle/Sparkle/LICENSE ]] && cp .build/artifacts/sparkle/Sparkle/LICENSE "$app/Contents/Resources/Licenses/Sparkle-LICENSE.txt"

# The worker and app find the libraries in Contents/Frameworks instead of the build folder.
for binary in "$app/Contents/MacOS/"*; do
    install_name_tool -add_rpath "@executable_path/../Frameworks" "$binary" 2>/dev/null || true
    install_name_tool -delete_rpath "$PWD/Vendor/out/lib" "$binary" 2>/dev/null || true
    install_name_tool -delete_rpath "$PWD/.build/out/Products/$configuration/PackageFrameworks" "$binary" 2>/dev/null || true
done

echo "› Shortcuts actions (App Intents metadata)"
# SwiftPM does not run Apple's App Intents metadata step; without it Shortcuts cannot see the
# actions. Run it here on the compiler's constant-value files for the app's sources.
objects="$(cd "$bin/../.." && pwd)/Intermediates.noindex/Pulli.build/$( [[ $configuration == release ]] && echo Release || echo Debug )/Pulli-p.build/Objects-normal/$(uname -m)"
lists=$(mktemp -d)
ls "$PWD"/Sources/Pulli/*.swift > "$lists/sources.txt"
find "$objects" -name "*.swiftconstvalues" > "$lists/constvalues.txt"
if [[ -s "$lists/constvalues.txt" ]]; then
    xcrun appintentsmetadataprocessor \
        --output "$app/Contents/Resources" \
        --toolchain-dir "$(dirname "$(dirname "$(dirname "$(xcrun --find swift)")")")" \
        --module-name Pulli \
        --sdk-root "$(xcrun --show-sdk-path)" \
        --xcode-version "$(xcodebuild -version | awk '/Build version/ {print $3}')" \
        --platform-family macOS --deployment-target 26.0 \
        --target-triple "$(uname -m)-apple-macos26.0" \
        --source-file-list "$lists/sources.txt" \
        --swift-const-vals-list "$lists/constvalues.txt" \
        --deployment-aware-processing --no-app-shortcuts-localization --force --quiet-warnings >/dev/null
else
    echo "  (no constant values found in $objects; Shortcuts actions will not be listed)"
fi

echo "› icon"
iconset=$(mktemp -d)/AppIcon.iconset
mkdir -p "$iconset"
"$bin/Pulli" --icon "$iconset/icon_512x512@2x.png"
for size in 16 32 128 256 512; do
    sips -z $size $size "$iconset/icon_512x512@2x.png" --out "$iconset/icon_${size}x${size}.png" >/dev/null
    double=$((size * 2))
    [[ $size != 512 ]] && sips -z $double $double "$iconset/icon_512x512@2x.png" --out "$iconset/icon_${size}x${size}@2x.png" >/dev/null
done
iconutil -c icns "$iconset" -o "$app/Contents/Resources/AppIcon.icns"

updates_plist=""
if $enable_updates; then
    updates_plist="    <key>SUFeedURL</key><string>https://raw.githubusercontent.com/ijahongirmirzo/pulli/main/appcast.xml</string>
    <key>SUPublicEDKey</key><string>$sparkle_key</string>"
fi

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>app.pulli.mac</string>
    <key>CFBundleName</key><string>Pulli</string>
    <key>CFBundleDisplayName</key><string>Pulli</string>
    <key>CFBundleExecutable</key><string>Pulli</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$short_version</string>
    <key>CFBundleVersion</key><string>$build</string>
    <key>PulliCommit</key><string>$commit</string>
    <key>PulliFeedbackEmail</key><string>$feedback_email</string>
$updates_plist
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleURLTypes</key>
    <array><dict>
        <key>CFBundleURLName</key><string>app.pulli.mac</string>
        <key>CFBundleURLSchemes</key><array><string>pulli</string><string>relay</string></array>
    </dict></array>
    <key>NSHumanReadableCopyright</key><string>© 2026 Jahongirmirzo. Free software under the GNU GPL v3.</string>
</dict>
</plist>
PLIST

echo "› desktop widget"
# A WidgetKit extension: sandboxed, of the widgetkit-extension point, inside Contents/PlugIns.
widget="$app/Contents/PlugIns/PulliWidget.appex"
mkdir -p "$widget/Contents/MacOS"
cp "$bin/PulliWidget" "$widget/Contents/MacOS/"
install_name_tool -delete_rpath "$PWD/Vendor/out/lib" "$widget/Contents/MacOS/PulliWidget" 2>/dev/null || true
cat > "$widget/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>app.pulli.mac.widget</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
    <key>DTPlatformName</key><string>macosx</string>
    <key>CFBundleName</key><string>Pulli</string>
    <key>CFBundleDisplayName</key><string>Pulli</string>
    <key>CFBundleExecutable</key><string>PulliWidget</string>
    <key>CFBundlePackageType</key><string>XPC!</string>
    <key>CFBundleShortVersionString</key><string>$short_version</string>
    <key>CFBundleVersion</key><string>$build</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSExtension</key>
    <dict><key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string></dict>
</dict>
</plist>
PLIST
entitlements=$(mktemp)
cat > "$entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict><key>com.apple.security.app-sandbox</key><true/></dict></plist>
PLIST

echo "› Finder location (File Provider extension)"
# Shows a phone in Finder's sidebar under Locations by its own name (docs/FINDER_LOCATION.md).
# Sandboxed, of the fileprovider-nonui extension point; it reaches the phone through Pulli's drive
# server on 127.0.0.1 (network client) and the app hands it each phone's address through the shared
# App Group. The group id starts with the team id, which macOS allows without a provisioning
# profile; a Developer ID app cannot carry one for an unprefixed group.
group="8Q2D6948R4.app.pulli.mac"
provider="$app/Contents/PlugIns/PulliFileProvider.appex"
mkdir -p "$provider/Contents/MacOS"
cp "$bin/PulliFileProvider" "$provider/Contents/MacOS/"
install_name_tool -delete_rpath "$PWD/Vendor/out/lib" "$provider/Contents/MacOS/PulliFileProvider" 2>/dev/null || true
cat > "$provider/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>app.pulli.mac.fileprovider</string>
    <key>CFBundleName</key><string>Pulli</string>
    <key>CFBundleDisplayName</key><string>Pulli</string>
    <key>CFBundleExecutable</key><string>PulliFileProvider</string>
    <!-- Finder's sidebar shows this symbol for the location: a phone, not a folder. -->
    <key>CFBundleIcons</key>
    <dict><key>CFBundlePrimaryIcon</key><dict><key>CFBundleSymbolName</key><string>smartphone</string></dict></dict>
    <key>CFBundlePackageType</key><string>XPC!</string>
    <key>CFBundleShortVersionString</key><string>$short_version</string>
    <key>CFBundleVersion</key><string>$build</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key><string>com.apple.fileprovider-nonui</string>
        <key>NSExtensionPrincipalClass</key><string>PulliFileProviderExtension</string>
        <key>NSExtensionFileProviderDocumentGroup</key><string>$group</string>
        <key>NSExtensionFileProviderSupportsEnumeration</key><true/>
    </dict>
    <!-- The phone's drive is plain http on 127.0.0.1 (this Mac only). -->
    <key>NSAppTransportSecurity</key>
    <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST
provider_entitlements=$(mktemp)
cat > "$provider_entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>com.apple.security.app-sandbox</key><true/>
    <key>com.apple.security.application-groups</key><array><string>$group</string></array>
    <key>com.apple.security.network.client</key><true/>
</dict></plist>
PLIST
# The app itself shares the group (it writes the phones' settings there for the extension).
app_entitlements=$(mktemp)
cat > "$app_entitlements" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
    <key>com.apple.security.application-groups</key><array><string>$group</string></array>
</dict></plist>
PLIST

identity="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ { print $2; exit }')}"
if [[ -n "$identity" ]]; then
    echo "› signing ($identity)"
    sign=(codesign --force --sign "$identity" --options runtime --timestamp)
else
    echo "› signing (ad hoc: no Developer ID certificate in the keychain)"
    sign=(codesign --force --sign - --timestamp=none)
fi
# Inside out: Sparkle internal binaries and framework first, then vendored dylibs and helper tools, widget, provider, app.
if [[ -d "$app/Contents/Frameworks/Sparkle.framework" ]]; then
    "${sign[@]}" "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Autoupdate"
    "${sign[@]}" "$app/Contents/Frameworks/Sparkle.framework/Versions/B/Updater.app"
    "${sign[@]}" "$app/Contents/Frameworks/Sparkle.framework"
fi
for item in "$app/Contents/Frameworks/"*.dylib "$app/Contents/MacOS/pulli-mtp-worker" "$app/Contents/MacOS/pulli-helper"; do
    "${sign[@]}" "$item"
done
"${sign[@]}" --entitlements "$entitlements" "$widget"
"${sign[@]}" --entitlements "$provider_entitlements" "$provider"
"${sign[@]}" --entitlements "$app_entitlements" "$app"
codesign --verify --deep --strict "$app"

# Tell Launch Services about the app (pulli:// links, Shortcuts actions) and the widget.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$PWD/$app" >/dev/null 2>&1 || true
pluginkit -a "$PWD/$widget" >/dev/null 2>&1 || true
echo "✓ $app ($(du -sh "$app" | cut -f1))"
