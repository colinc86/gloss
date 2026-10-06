#!/bin/zsh
# Renders every icon style (docs/icon/variants/*.icon) to a 512 px PNG in the app's asset catalog, for the
# Settings › General icon picker and the Dock icon it sets. Run after make-variants.swift.
set -euo pipefail
cd "$(dirname "$0")/../.."
ictool="/Applications/Xcode.app/Contents/Applications/Icon Composer.app/Contents/Executables/ictool"
catalog="Gloss/Assets.xcassets/AppIconStyles"
mkdir -p "$catalog"
print '{"info":{"author":"xcode","version":1},"properties":{"provides-namespace":true}}' > "$catalog/Contents.json"
for doc in docs/icon/variants/*.icon; do
    name=${doc:t:r}
    set="$catalog/$name.imageset"
    mkdir -p "$set"
    "$ictool" "$doc" --export-image --output-file "$set/$name.png" --platform macOS --rendition Default \
        --width 512 --height 512 --scale 1 --design-generation 26 >/dev/null
    print "{\"images\":[{\"filename\":\"$name.png\",\"idiom\":\"universal\"}],\"info\":{\"author\":\"xcode\",\"version\":1}}" > "$set/Contents.json"
    print $name
done
