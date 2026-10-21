#!/bin/bash
# Assembles the website into build/site: the pages in site/ plus the screenshots and animation
# from docs/images, which the README also uses (so they are kept in one place).
# The download buttons go to /download, which netlify.toml redirects to the newest release's
# Pulli.dmg. The version shown under the button is read from appcast.xml (which
# scripts/release.sh updates), so a release also updates the site.
# The site's own address (for link previews) comes from Netlify's URL variable when it builds.
# Preview: scripts/build-site.sh && python3 -m http.server -d build/site 8000
set -euo pipefail
site_url=${URL:-https://getpulli.com}
cd "$(dirname "$0")/.."

# The first item in the appcast is the newest release.
version=$(grep -m1 -oE '<sparkle:shortVersionString>[^<]+' appcast.xml | cut -d'>' -f2)
if [[ -z "$version" ]]; then
    echo "Error: no release found in appcast.xml" >&2
    exit 1
fi

out=build/site
rm -rf "$out"
mkdir -p "$out/images"
cp -R site/. "$out/"
cp docs/images/*.jpg docs/images/*.webp docs/images/pulli-icon.png docs/images/social-preview.png "$out/images/"
for page in "$out"/*.html; do
    sed -i.bak -e "s#{{VERSION}}#$version#g" -e "s#{{SITE_URL}}#$site_url#g" "$page"
    rm "$page.bak"
done
if grep -l "{{" "$out"/*.html; then
    echo "Error: unfilled placeholder in the pages above" >&2
    exit 1
fi
echo "✓ $out ($(du -sh "$out" | cut -f1)), Pulli $version"
