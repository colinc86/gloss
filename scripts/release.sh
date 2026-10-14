#!/bin/zsh
# Builds, notarizes and publishes a Gloss release, then lists it in the Sparkle appcast.
#
#   scripts/release.sh <version> <notes.md> [--dry-run | --resume]
#
# The notes are Markdown: they become the GitHub release's description and, rendered by GitHub, the release
# notes Sparkle shows in the update dialog. --dry-run builds, notarizes and signs the zip, then stops before
# committing, tagging, pushing or publishing anything. --resume finishes a release whose tag was pushed but whose
# GitHub release or appcast entry wasn't made (a network failure, say), from the zip left in build/.
# See docs/RELEASE.md for the one-time setup.
set -euo pipefail

REPO=colinc86/gloss
PROFILE=AC_PASSWORD
TEAM=4WS4246RA4   # passed to the archive, so a release never depends on Config/Signing.local.xcconfig
ROOT=${0:A:h:h}
cd "$ROOT"

fail() { print -u2 "release: $*"; exit 1; }
step() { print "\n==> $*"; }

(( $# >= 2 )) || fail "usage: scripts/release.sh <version> <notes.md> [--dry-run | --resume]"
VERSION=$1
NOTES=${2:A}
MODE=${3:-}
[[ $VERSION =~ '^[0-9]+\.[0-9]+\.[0-9]+(-beta\.[0-9]+)?$' ]] || fail "version must look like 0.1.0 or 0.1.0-beta.1"
# A -beta.N version is a GitHub prerelease; the appcast lists it like any other release.
PRERELEASE=()
[[ $VERSION == *-beta.* ]] && PRERELEASE=(--prerelease)
[[ -s $NOTES ]] || fail "no notes at $NOTES"
[[ -z $MODE || $MODE == --dry-run || $MODE == --resume ]] || fail "unknown option $MODE"
ZIP=build/Gloss-$VERSION.zip

# Publishes the pushed tag's zip as a GitHub release and lists it in the appcast; each step is skipped when done.
publish() {
  local build=$(<build/build-number) signature=$(<build/signature)
  if ! gh release view "v$VERSION" --repo "$REPO" >/dev/null 2>&1; then
    step "Publishing the GitHub release"
    gh release create "v$VERSION" "$ZIP" --repo "$REPO" --title "Gloss $VERSION" --notes-file "$NOTES" --verify-tag $PRERELEASE
  fi
  if grep -q "<sparkle:shortVersionString>$VERSION<" appcast.xml 2>/dev/null; then
    step "Already in the appcast"
    return
  fi
  local asset=$(gh api "repos/$REPO/releases/tags/v$VERSION" --jq ".assets[] | select(.name == \"Gloss-$VERSION.zip\") | .browser_download_url")
  [[ -n $asset ]] || fail "the release has no Gloss-$VERSION.zip"
  step "Listing it in the appcast"
  gh api markdown -f mode=gfm -f context="$REPO" -f text="$(cat "$NOTES")" > build/notes.html
  python3 scripts/appcast.py appcast.xml --version "$VERSION" --build "$build" --url "$asset" \
    --signature "$signature" --notes build/notes.html
  git add appcast.xml
  git commit -q -m "Publish $VERSION in the appcast"
  git push -q origin main
}

if [[ $MODE == --resume ]]; then
  git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null || fail "no tag v$VERSION to resume"
  [[ -s $ZIP && -s build/signature && -s build/build-number ]] || fail "build/ doesn't hold v$VERSION's zip and signature"
  [[ $(git branch --show-current) == main && -z $(git status --porcelain) ]] || fail "resume on a clean main"
  publish
  step "Released Gloss $VERSION: https://github.com/$REPO/releases/tag/v$VERSION"
  exit 0
fi

step "Checking"
[[ $(git branch --show-current) == main ]] || fail "not on main"
[[ -z $(git status --porcelain) ]] || fail "the working tree has changes"
git rev-parse -q --verify "refs/tags/v$VERSION" >/dev/null && fail "tag v$VERSION exists"
security find-identity -v -p codesigning | grep -q "Developer ID Application" || fail "no Developer ID Application certificate (docs/RELEASE.md)"
xcrun notarytool history --keychain-profile "$PROFILE" >/dev/null 2>&1 || fail "notary profile $PROFILE missing (docs/RELEASE.md)"
gh auth status >/dev/null 2>&1 || fail "gh is not signed in"
SPARKLE_BIN=$(print -l ~/Library/Developer/Xcode/DerivedData/Gloss-*/SourcePackages/artifacts/sparkle/Sparkle/bin(N/) | head -1)
[[ -n $SPARKLE_BIN ]] || fail "Sparkle's tools not found: build the app once so Xcode resolves the package"
PUBLIC_KEY=$("$SPARKLE_BIN/generate_keys" -p 2>/dev/null) || fail "no Sparkle signing key in the Keychain (docs/RELEASE.md)"
[[ $(/usr/libexec/PlistBuddy -c "Print :SUPublicEDKey" Gloss/Info.plist) == "$PUBLIC_KEY" ]] \
  || fail "SUPublicEDKey in Gloss/Info.plist is not the Keychain's key ($PUBLIC_KEY)"

# Sparkle compares build numbers: the count of commits, including the release commit made below.
BUILD=$(( $(git rev-list --count HEAD) + 1 ))
PROJECT=Gloss.xcodeproj/project.pbxproj
# Put the version back if anything stops the release before its commit (and always on a dry run).
trap 'git checkout -- "$PROJECT"' EXIT
sed -i '' -E "s/MARKETING_VERSION = [^;]+;/MARKETING_VERSION = $VERSION;/; s/CURRENT_PROJECT_VERSION = [^;]+;/CURRENT_PROJECT_VERSION = $BUILD;/" "$PROJECT"

step "Archiving $VERSION ($BUILD)"
rm -rf build && mkdir build
xcodebuild -quiet -project Gloss.xcodeproj -scheme Gloss -configuration Release \
  -archivePath build/Gloss.xcarchive -allowProvisioningUpdates \
  DEVELOPMENT_TEAM=$TEAM CODE_SIGN_IDENTITY="Apple Development" archive
xcodebuild -quiet -exportArchive -archivePath build/Gloss.xcarchive \
  -exportOptionsPlist docs/ExportOptions.plist -exportPath build/export -allowProvisioningUpdates
APP=build/export/Gloss.app

step "Notarizing"
ditto -c -k --keepParent "$APP" build/notarize.zip
xcrun notarytool submit build/notarize.zip --keychain-profile "$PROFILE" --wait | tee build/notarize.log
grep -q "status: Accepted" build/notarize.log || fail "notarization was not accepted (xcrun notarytool log <id> --keychain-profile $PROFILE)"
xcrun stapler staple "$APP"

step "Verifying"
codesign --verify --deep --strict "$APP"
verdict=$(spctl -a -vv -t exec "$APP" 2>&1) || true
[[ $verdict == *"Notarized Developer ID"* ]] || fail "Gatekeeper doesn't see a notarized Developer ID app: $verdict"
[[ $(/usr/libexec/PlistBuddy -c "Print :CFBundleShortVersionString" "$APP/Contents/Info.plist") == "$VERSION" ]] || fail "the app's version is wrong"
[[ $(/usr/libexec/PlistBuddy -c "Print :CFBundleVersion" "$APP/Contents/Info.plist") == "$BUILD" ]] || fail "the app's build is wrong"
ditto -c -k --sequesterRsrc --keepParent "$APP" "$ZIP"
"$SPARKLE_BIN/sign_update" "$ZIP" > build/signature   # sparkle:edSignature="…" length="…"
print $BUILD > build/build-number

if [[ $MODE == --dry-run ]]; then
  step "Dry run done: $ZIP, build $BUILD, $(<build/signature)"
  exit 0
fi

step "Tagging"
git commit -q -am "Release $VERSION"
trap - EXIT
git tag -s "v$VERSION" -m "Gloss $VERSION"
git push -q origin main "v$VERSION"
# From here a failure is finished with --resume, which skips whatever was done.
trap 'print -u2 "release: v$VERSION is pushed but not fully published; finish with: scripts/release.sh $VERSION ${2} --resume"' ERR
publish
step "Released Gloss $VERSION: https://github.com/$REPO/releases/tag/v$VERSION"
