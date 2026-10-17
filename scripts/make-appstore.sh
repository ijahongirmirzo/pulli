#!/bin/bash
# Builds build/AppStore/Pulli.app: the sandboxed App Store edition of Pulli.
#
#   scripts/make-appstore.sh           developer build (signed with Developer ID for local testing)
#   scripts/make-appstore.sh --dev     same as above
#   scripts/make-appstore.sh --store   App Store build (Apple Distribution + provisioning profiles + productbuild pkg)
#
# Flags:
#   --debug    builds debug configuration instead of release
set -euo pipefail
cd "$(dirname "$0")/.."

mode="dev"
configuration="release"

for arg in "$@"; do
    case "$arg" in
        --store) mode="store" ;;
        --dev) mode="dev" ;;
        --debug) configuration="debug" ;;
        *)
            echo "Unknown argument: $arg" >&2
            echo "Usage: scripts/make-appstore.sh [--dev | --store] [--debug]" >&2
            exit 1
            ;;
    esac
done

build="$(date +%Y%m%d%H%M%S)"
commit="$(git rev-parse --short HEAD 2>/dev/null || echo dev)"
store_version="1.0"

app_id="app.pulli.store"
widget_id="app.pulli.store.widget"
provider_id="app.pulli.store.fileprovider"
group="8Q2D6948R4.app.pulli.store"

env_feedback_email="${PULLI_FEEDBACK_EMAIL:-}"
if [[ -f Config/release.env ]]; then
    # shellcheck disable=SC1091
    source Config/release.env
fi
feedback_email="${env_feedback_email:-${PULLI_FEEDBACK_EMAIL:-}}"

echo "› building App Store products ($configuration)"
export PULLI_APP_STORE=1
for product in Pulli PulliWidget PulliFileProvider; do
    swift build -c "$configuration" -Xswiftc -DPULLI_APP_STORE --scratch-path .build-appstore --product "$product" >/dev/null
done
bin=$(swift build -c "$configuration" -Xswiftc -DPULLI_APP_STORE --scratch-path .build-appstore --show-bin-path)

app=build/AppStore/Pulli.app
rm -rf "$app"
mkdir -p "$app/Contents/MacOS" "$app/Contents/Resources" "$app/Contents/PlugIns"

cp "$bin/Pulli" "$app/Contents/MacOS/"
cp -R "$bin/Pulli_Pulli.bundle" "$app/Contents/Resources/"

mkdir -p "$app/Contents/Resources/Licenses"
cp Sources/Pulli/Resources/Fonts/PlusJakartaSans-OFL.txt "$app/Contents/Resources/Licenses/"
cp LICENSE "$app/Contents/Resources/Licenses/Pulli-GPL-3.0.txt"
cp NOTICE "$app/Contents/Resources/Licenses/Pulli-NOTICE.txt"

cp Config/AppStore/PrivacyInfo.xcprivacy "$app/Contents/Resources/"

echo "› Shortcuts actions (App Intents metadata)"
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

cat > "$app/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$app_id</string>
    <key>CFBundleName</key><string>Pulli</string>
    <key>CFBundleDisplayName</key><string>Pulli</string>
    <key>CFBundleExecutable</key><string>Pulli</string>
    <key>CFBundleIconFile</key><string>AppIcon</string>
    <key>CFBundlePackageType</key><string>APPL</string>
    <key>CFBundleShortVersionString</key><string>$store_version</string>
    <key>CFBundleVersion</key><string>$build</string>
    <key>PulliCommit</key><string>$commit</string>
    <key>PulliFeedbackEmail</key><string>$feedback_email</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>LSApplicationCategoryType</key><string>public.app-category.utilities</string>
    <key>ITSAppUsesNonExemptEncryption</key><false/>
    <key>NSHighResolutionCapable</key><true/>
    <key>CFBundleURLTypes</key>
    <array><dict>
        <key>CFBundleURLName</key><string>$app_id</string>
        <key>CFBundleURLSchemes</key><array><string>pulli</string></array>
    </dict></array>
    <key>NSHumanReadableCopyright</key><string>Pulli. Plus Jakarta Sans © The Plus Jakarta Sans Project Authors (SIL OFL).</string>
</dict>
</plist>
PLIST

echo "› desktop widget"
widget="$app/Contents/PlugIns/PulliWidget.appex"
mkdir -p "$widget/Contents/MacOS" "$widget/Contents/Resources"
cp "$bin/PulliWidget" "$widget/Contents/MacOS/"
cp Config/AppStore/PrivacyInfo.xcprivacy "$widget/Contents/Resources/"
cat > "$widget/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$widget_id</string>
    <key>CFBundleDevelopmentRegion</key><string>en</string>
    <key>CFBundleInfoDictionaryVersion</key><string>6.0</string>
    <key>CFBundleSupportedPlatforms</key><array><string>MacOSX</string></array>
    <key>DTPlatformName</key><string>macosx</string>
    <key>CFBundleName</key><string>Pulli</string>
    <key>CFBundleDisplayName</key><string>Pulli</string>
    <key>CFBundleExecutable</key><string>PulliWidget</string>
    <key>CFBundlePackageType</key><string>XPC!</string>
    <key>CFBundleShortVersionString</key><string>$store_version</string>
    <key>CFBundleVersion</key><string>$build</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSExtension</key>
    <dict><key>NSExtensionPointIdentifier</key><string>com.apple.widgetkit-extension</string></dict>
</dict>
</plist>
PLIST

echo "› Finder location (File Provider extension)"
provider="$app/Contents/PlugIns/PulliFileProvider.appex"
mkdir -p "$provider/Contents/MacOS" "$provider/Contents/Resources"
cp "$bin/PulliFileProvider" "$provider/Contents/MacOS/"
cp Config/AppStore/PrivacyInfo.xcprivacy "$provider/Contents/Resources/"
cat > "$provider/Contents/Info.plist" <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>CFBundleIdentifier</key><string>$provider_id</string>
    <key>CFBundleName</key><string>Pulli</string>
    <key>CFBundleDisplayName</key><string>Pulli</string>
    <key>CFBundleExecutable</key><string>PulliFileProvider</string>
    <key>CFBundleIcons</key>
    <dict><key>CFBundlePrimaryIcon</key><dict><key>CFBundleSymbolName</key><string>smartphone</string></dict></dict>
    <key>CFBundlePackageType</key><string>XPC!</string>
    <key>CFBundleShortVersionString</key><string>$store_version</string>
    <key>CFBundleVersion</key><string>$build</string>
    <key>LSMinimumSystemVersion</key><string>26.0</string>
    <key>NSExtension</key>
    <dict>
        <key>NSExtensionPointIdentifier</key><string>com.apple.fileprovider-nonui</string>
        <key>NSExtensionPrincipalClass</key><string>PulliFileProviderExtension</string>
        <key>NSExtensionFileProviderDocumentGroup</key><string>$group</string>
        <key>NSExtensionFileProviderSupportsEnumeration</key><true/>
    </dict>
    <key>NSAppTransportSecurity</key>
    <dict><key>NSAllowsLocalNetworking</key><true/></dict>
</dict>
</plist>
PLIST

app_entitlements="Config/AppStore/Pulli.entitlements"
widget_entitlements="Config/AppStore/PulliWidget.entitlements"
provider_entitlements="Config/AppStore/PulliFileProvider.entitlements"

if [[ "$mode" == "dev" ]]; then
    identity="${SIGN_IDENTITY:-$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Developer ID Application/ { print $2; exit }')}"
    if [[ -n "$identity" ]]; then
        echo "› signing with Developer ID ($identity)"
        sign=(codesign --force --sign "$identity" --options runtime --timestamp)
    else
        echo "› signing (ad hoc: no Developer ID certificate in keychain)"
        sign=(codesign --force --sign - --timestamp=none)
    fi

    "${sign[@]}" --entitlements "$widget_entitlements" "$widget"
    "${sign[@]}" --entitlements "$provider_entitlements" "$provider"
    "${sign[@]}" --entitlements "$app_entitlements" "$app"
    codesign --verify --deep --strict "$app"

    /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$PWD/$app" >/dev/null 2>&1 || true
    pluginkit -a "$PWD/$widget" >/dev/null 2>&1 || true
    echo "✓ $app ($(du -sh "$app" | cut -f1))"

elif [[ "$mode" == "store" ]]; then
    echo "› checking App Store distribution prerequisites"

    app_profile="Config/AppStore/profiles/app.pulli.store.provisionprofile"
    [[ ! -f "$app_profile" && -f "Config/AppStore/profiles/app.pulli.store.mobileprovision" ]] && app_profile="Config/AppStore/profiles/app.pulli.store.mobileprovision"

    widget_profile="Config/AppStore/profiles/app.pulli.store.widget.provisionprofile"
    [[ ! -f "$widget_profile" && -f "Config/AppStore/profiles/app.pulli.store.widget.mobileprovision" ]] && widget_profile="Config/AppStore/profiles/app.pulli.store.widget.mobileprovision"

    provider_profile="Config/AppStore/profiles/app.pulli.store.fileprovider.provisionprofile"
    [[ ! -f "$provider_profile" && -f "Config/AppStore/profiles/app.pulli.store.fileprovider.mobileprovision" ]] && provider_profile="Config/AppStore/profiles/app.pulli.store.fileprovider.mobileprovision"

    dist_identity="$(security find-identity -v -p codesigning 2>/dev/null | awk -F'"' '/Apple Distribution/ { print $2; exit }' || true)"
    installer_identity="$(security find-identity -v 2>/dev/null | awk -F'"' '/3rd Party Mac Developer Installer|Mac Installer Distribution/ { print $2; exit }' || true)"

    missing=()
    [[ -z "$dist_identity" ]] && missing+=("• Keychain: 'Apple Distribution' certificate")
    [[ -z "$installer_identity" ]] && missing+=("• Keychain: 'Mac Installer Distribution' (or '3rd Party Mac Developer Installer') certificate")
    [[ ! -f "$app_profile" ]] && missing+=("• Provisioning Profile: Config/AppStore/profiles/app.pulli.store.provisionprofile")
    [[ ! -f "$widget_profile" ]] && missing+=("• Provisioning Profile: Config/AppStore/profiles/app.pulli.store.widget.provisionprofile")
    [[ ! -f "$provider_profile" ]] && missing+=("• Provisioning Profile: Config/AppStore/profiles/app.pulli.store.fileprovider.provisionprofile")

    if [[ ${#missing[@]} -gt 0 ]]; then
        echo "" >&2
        echo "Error: Missing App Store signing certificates or provisioning profiles:" >&2
        for item in "${missing[@]}"; do
            echo "  $item" >&2
        done
        echo "" >&2
        echo "Checklist to set up in your Apple Developer Account (Stage 3):" >&2
        echo "  1. Identifiers:" >&2
        echo "     - App Group: 8Q2D6948R4.app.pulli.store" >&2
        echo "     - App ID: app.pulli.store (enable App Groups)" >&2
        echo "     - App ID: app.pulli.store.widget (enable App Groups)" >&2
        echo "     - App ID: app.pulli.store.fileprovider (enable App Groups)" >&2
        echo "  2. Certificates in Keychain:" >&2
        echo "     - Apple Distribution" >&2
        echo "     - Mac Installer Distribution (or 3rd Party Mac Developer Installer)" >&2
        echo "  3. Provisioning Profiles (Mac App Store) in Config/AppStore/profiles/:" >&2
        echo "     - app.pulli.store.provisionprofile" >&2
        echo "     - app.pulli.store.widget.provisionprofile" >&2
        echo "     - app.pulli.store.fileprovider.provisionprofile" >&2
        exit 1
    fi

    echo "› embedding provisioning profiles"
    cp "$widget_profile" "$widget/Contents/embedded.provisionprofile"
    cp "$provider_profile" "$provider/Contents/embedded.provisionprofile"
    cp "$app_profile" "$app/Contents/embedded.provisionprofile"

    echo "› signing with Apple Distribution ($dist_identity)"
    sign=(codesign --force --sign "$dist_identity" --timestamp)
    "${sign[@]}" --entitlements "$widget_entitlements" "$widget"
    "${sign[@]}" --entitlements "$provider_entitlements" "$provider"
    "${sign[@]}" --entitlements "$app_entitlements" "$app"
    codesign --verify --deep --strict "$app"

    pkg="build/AppStore/Pulli.pkg"
    echo "› building installer package ($pkg)"
    productbuild --component "$app" /Applications --sign "$installer_identity" "$pkg"
    echo "✓ $pkg ($(du -sh "$pkg" | cut -f1))"
fi
