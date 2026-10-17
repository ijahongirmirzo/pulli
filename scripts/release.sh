#!/bin/bash
# Builds and notarises Pulli, signs the DMG for Sparkle, and updates appcast.xml.
#
# Usage:
#   scripts/release.sh            Build, notarise, update appcast, and print publish commands
#   scripts/release.sh --publish  Additionally create the GitHub release and push appcast.xml
#
# Environment:
#   PULLI_RELEASES_DIR  Where appcast.xml lives (default: this repository, whose GitHub Releases
#                       hold the disk images)
set -euo pipefail
cd "$(dirname "$0")/.."

publish=false
for arg in "$@"; do
    if [[ "$arg" == "--publish" ]]; then
        publish=true
    fi
done

echo "› building and packaging release (PULLI_RELEASE=1)"
PULLI_RELEASE=1 scripts/make-app.sh
PULLI_RELEASE=1 scripts/make-dmg.sh

app="build/Pulli.app"
short_version=$(/usr/libexec/PlistBuddy -c "Print CFBundleShortVersionString" "$app/Contents/Info.plist" 2>/dev/null || echo "0.4.0")
build=$(/usr/libexec/PlistBuddy -c "Print CFBundleVersion" "$app/Contents/Info.plist" 2>/dev/null)
dmg="build/Pulli-${short_version}-${build}.dmg"

if [[ ! -f "$dmg" ]]; then
    echo "Error: Disk image $dmg was not found" >&2
    exit 1
fi

# Locate Sparkle's sign_update tool from SwiftPM artifacts
sign_update=$(find .build/artifacts -name "sign_update" -type f -perm +111 2>/dev/null | head -n 1)
if [[ -z "$sign_update" || ! -x "$sign_update" ]]; then
    echo "Error: sign_update not found in .build/artifacts" >&2
    exit 1
fi

echo "› signing disk image with Sparkle (EdDSA)"
signature=$("$sign_update" -p "$dmg")
length=$(stat -f%z "$dmg")
pub_date=$(date -u +"%a, %d %b %Y %H:%M:%S +0000")

# Release notes from release-notes.md
release_notes_file="release-notes.md"
release_notes="Improvements and bug fixes."
if [[ -f "$release_notes_file" ]]; then
    release_notes=$(cat "$release_notes_file")
fi

releases_dir="${PULLI_RELEASES_DIR:-.}"
appcast_file="$releases_dir/appcast.xml"

echo "› updating $appcast_file"
mkdir -p "$releases_dir"

python3 - <<PY
import os, sys

appcast_path = "$appcast_file"
short_version = "$short_version"
build = "$build"
pub_date = "$pub_date"
length = "$length"
signature = "$signature"
dmg_name = "Pulli-${short_version}-${build}.dmg"
tag_name = "v${short_version}-${build}"
url = f"https://github.com/ijahongirmirzo/pulli/releases/download/{tag_name}/{dmg_name}"

notes_path = "$release_notes_file"
notes = "<p>Improvements and bug fixes.</p>"
if os.path.isfile(notes_path):
    # Sparkle shows HTML: turn the Markdown notes (paragraphs, "- " lists, **bold**) into HTML.
    import html, re
    with open(notes_path, "r", encoding="utf-8") as f:
        lines = f.read().strip().splitlines()
    out, in_list = [], False
    for line in lines:
        text = re.sub(r"\*\*(.+?)\*\*", r"<b>\1</b>", html.escape(line.strip()[2:] if line.strip().startswith("- ") else line.strip()))
        if line.strip().startswith("- "):
            if not in_list: out.append("<ul>"); in_list = True
            out.append(f"<li>{text}</li>")
        else:
            if in_list: out.append("</ul>"); in_list = False
            if text: out.append(f"<p>{text}</p>")
    if in_list: out.append("</ul>")
    notes = "\n".join(out)

new_item = f'''        <item>
            <title>Version {short_version}</title>
            <sparkle:version>{build}</sparkle:version>
            <sparkle:shortVersionString>{short_version}</sparkle:shortVersionString>
            <sparkle:minimumSystemVersion>26.0</sparkle:minimumSystemVersion>
            <pubDate>{pub_date}</pubDate>
            <description><![CDATA[
{notes}
            ]]></description>
            <enclosure
                url="{url}"
                length="{length}"
                type="application/octet-stream"
                sparkle:edSignature="{signature}" />
        </item>'''

if os.path.isfile(appcast_path):
    with open(appcast_path, "r", encoding="utf-8") as f:
        content = f.read()
    if "<item>" in content:
        idx = content.find("<item>")
        content = content[:idx] + new_item.strip() + "\\n\\n        " + content[idx:]
    elif "</channel>" in content:
        idx = content.find("</channel>")
        content = content[:idx] + new_item + "\\n    " + content[idx:]
    else:
        content = f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>Pulli Updates</title>
        <link>https://raw.githubusercontent.com/ijahongirmirzo/pulli/main/appcast.xml</link>
        <description>Most recent updates to Pulli.</description>
        <language>en</language>
{new_item}
    </channel>
</rss>
'''
else:
    content = f'''<?xml version="1.0" encoding="utf-8"?>
<rss version="2.0" xmlns:sparkle="http://www.andymatuschak.org/xml-namespaces/sparkle" xmlns:dc="http://purl.org/dc/elements/1.1/">
    <channel>
        <title>Pulli Updates</title>
        <link>https://raw.githubusercontent.com/ijahongirmirzo/pulli/main/appcast.xml</link>
        <description>Most recent updates to Pulli.</description>
        <language>en</language>
{new_item}
    </channel>
</rss>
'''

with open(appcast_path, "w", encoding="utf-8") as f:
    f.write(content)
print(f"Updated {appcast_path} with Version {short_version} ({build})")
PY

tag="v${short_version}-${build}"
title="Pulli ${short_version}"

gh_cmd="gh release create \"$tag\" \"$dmg\" --repo ijahongirmirzo/pulli --title \"$title\" --notes-file \"$release_notes_file\""
git_cmd="git -C \"$releases_dir\" add appcast.xml && git -C \"$releases_dir\" commit -m \"Release $tag\" && git -C \"$releases_dir\" push origin main"

if $publish; then
    echo "› publishing release with gh"
    eval "$gh_cmd"
    echo "› committing and pushing appcast"
    eval "$git_cmd"
    # The Homebrew cask (ijahongirmirzo/homebrew-tap): new version and checksum.
    tap_dir="${PULLI_TAP_DIR:-../homebrew-tap}"
    cask="$tap_dir/Casks/pulli.rb"
    if [[ -f "$cask" ]]; then
        echo "› updating the Homebrew cask"
        sha=$(shasum -a 256 "$dmg" | cut -d' ' -f1)
        sed -i '' -E "s/^  version \".*\"/  version \"${short_version},${build}\"/; s/^  sha256 \".*\"/  sha256 \"${sha}\"/" "$cask"
        git -C "$tap_dir" add Casks/pulli.rb
        git -C "$tap_dir" commit -m "Pulli ${short_version} (${build})"
        git -C "$tap_dir" push origin main
    else
        echo "› no Homebrew tap at $tap_dir (set PULLI_TAP_DIR); skipped the cask"
    fi
    echo "✓ Published $tag"
else
    echo ""
    echo "Release prepared. To publish, run:"
    echo "  $gh_cmd"
    echo "  $git_cmd"
    echo ""
    echo "Or run: scripts/release.sh --publish"
fi
