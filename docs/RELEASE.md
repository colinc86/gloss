# Releases

Gloss is not sandboxed; it is signed with a Developer ID certificate, hardened runtime on, notarized, and updated
by Sparkle 2 from the GitHub releases of `colinc86/gloss`. Settings already in the project: `CODE_SIGN_STYLE =
Automatic`, `DEVELOPMENT_TEAM = 4WS4246RA4`, `ENABLE_HARDENED_RUNTIME = YES`, `ENABLE_APP_SANDBOX = NO`.

## One-time setup

1. **Developer ID Application certificate.** Xcode › Settings › Accounts › (team) › Manage Certificates › + ›
   Developer ID Application (needs the Account Holder role). An *Apple Development* certificate is not enough:
   Gatekeeper only opens downloaded apps signed with Developer ID and notarized. Check with
   `security find-identity -v -p codesigning`.
2. **Notary profile.** Create an app-specific password at account.apple.com (Sign-In and Security › App-Specific
   Passwords) and **leave it there**: the profile keeps a copy and every release uses it, so deleting it on the
   account breaks notarization (HTTP 401). Then, in a normal terminal (the password prompt needs one), run
   `xcrun notarytool store-credentials AC_PASSWORD --apple-id <id> --team-id 4WS4246RA4` and paste it at the
   prompt; never pass it with `--password` where it would be logged.
3. **Sparkle's signing key.** Build the app once so Xcode fetches Sparkle, then run its `generate_keys`
   (`~/Library/Developer/Xcode/DerivedData/Gloss-*/SourcePackages/artifacts/sparkle/Sparkle/bin/generate_keys`).
   It keeps the private EdDSA key in the login Keychain and prints the public key: put that in `SUPublicEDKey` in
   `Gloss/Info.plist` and commit it. Back the private key up (`generate_keys -x <file>`, somewhere safe and not in
   the repo): without it, installed copies can never be updated again.

## Releasing

Write the release notes as Markdown (what changed, for people using the app), then:

```sh
scripts/release.sh 0.2.0 notes.md --dry-run   # builds, notarizes, signs; changes nothing in git or on GitHub
scripts/release.sh 0.2.0 notes.md
```

The script checks the setup above and a clean `main`, sets `MARKETING_VERSION` to the version and
`CURRENT_PROJECT_VERSION` to the commit count (Sparkle compares build numbers), archives and exports with
`docs/ExportOptions.plist`, notarizes and staples, verifies the signature, Gatekeeper's verdict and the version,
zips the app as `build/Gloss-<version>.zip` and signs the zip with Sparkle's key. Then it commits "Release
<version>", tags `v<version>` (signed), pushes, creates the GitHub release with the zip and the notes, renders the
notes to HTML with GitHub's Markdown API and adds the release to `appcast.xml` at the repo root
(`scripts/appcast.py`), and commits and pushes that.

If anything fails before the release commit, the version change is undone. If publishing fails after the tag was
pushed (a network failure, say), the script prints how to finish: `scripts/release.sh 0.2.0 notes.md --resume`
creates the GitHub release and the appcast entry from the zip left in `build/`, skipping whichever exists.

The notes are what people see twice: as the release's description on GitHub and in Sparkle's update dialog.

## How updates reach people

- `SUFeedURL` is `https://api.github.com/repos/colinc86/gloss/contents/appcast.xml`; each item's enclosure is the
  release asset's API URL. While the repository is private both need the GitHub key from Settings › Integrations:
  `UpdaterDelegate` puts it on Sparkle's requests (`Accept: application/vnd.github.raw` for the feed,
  `application/octet-stream` for the zip, whose redirect to storage URLSession follows without the key) and
  refuses a check when no key is saved.
- **Going public:** point `SUFeedURL` at `https://raw.githubusercontent.com/colinc86/gloss/main/appcast.xml`, write
  enclosures with the asset's `browser_download_url` (and rewrite the existing items), remove the delegate's key
  handling and the "needs GitHub" wording, and release once. Copies already installed keep reading the API URL,
  which then works without a key.
- Debug builds never start the updater. To try an update, build Release with an older version
  (`MARKETING_VERSION=0.0.9 CURRENT_PROJECT_VERSION=1`) into a scratch folder and run it from there.

The child processes the app launches (`ssh`, `tmux`, `herdr`, `git`, `rg`) are system or Homebrew binaries; nothing
is embedded but Sparkle, which Xcode re-signs with the team's identity, so no entitlements are needed beyond the
hardened runtime defaults.
