# Releases

Gloss is not sandboxed; it is signed with a Developer ID certificate, hardened runtime on, notarized, and updated
by Sparkle 2 from the GitHub releases of `colinc86/gloss`. Settings in the project: `ENABLE_HARDENED_RUNTIME = YES`,
`ENABLE_APP_SANDBOX = NO`. Signing comes from `Config/Signing.xcconfig`: a fresh clone signs ad hoc, and
`Config/Signing.local.xcconfig` (ignored by git; copy the `.example`) sets the maintainer's `DEVELOPMENT_TEAM =
4WS4246RA4` for everyday builds. `scripts/release.sh` passes the team to the archive itself, so a release doesn't
depend on the local file.

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
(`scripts/appcast.py`), and commits and pushes that. A version like `0.6.0-beta.1` becomes a GitHub prerelease;
the appcast lists it like any other release, so every copy that checks for updates is offered it.

If anything fails before the release commit, the version change is undone. If publishing fails after the tag was
pushed (a network failure, say), the script prints how to finish: `scripts/release.sh 0.2.0 notes.md --resume`
creates the GitHub release and the appcast entry from the zip left in `build/`, skipping whichever exists.

The notes are what people see twice: as the release's description on GitHub and in Sparkle's update dialog.

## How updates reach people

- `SUFeedURL` is `https://raw.githubusercontent.com/colinc86/gloss/main/appcast.xml`, read without a key now that
  the repository is public. `scripts/release.sh` lists each release's asset by its `browser_download_url`. Items
  published while the repository was private list the asset's API URL instead; it serves the bytes without a key
  when asked for an octet stream, which `UpdaterDelegate` does on every download. No request carries a key.
- The feed can't come from the contents API: Sparkle sets the feed's `Accept` itself, and that API then answers with
  JSON. (0.1.0 shipped with that URL, so 0.1.0 can't update itself.) Builds up to 0.6.0-beta.2 still refuse to check
  without a GitHub key saved; the first release after going public lifts that for everyone who installs it. They
  also send the saved key with every request, and raw.githubusercontent.com answers an invalid key with 404 even
  for a public file: someone on such a build whose key has expired or been revoked should remove it in Settings ›
  Integrations (or download the new release by hand) to update.
- **Repository settings** (once, after going public): turn on private vulnerability reporting (`SECURITY.md` links
  to it), secret scanning and push protection in the repository's Security settings.
- Debug builds never start the updater. To try an update, build Release with an older version
  (`MARKETING_VERSION=0.0.9 CURRENT_PROJECT_VERSION=1`) into a scratch folder and run it from there.

The child processes the app launches (`ssh`, `tmux`, `herdr`, `git`, `rg`) are system or Homebrew binaries; nothing
is embedded but Sparkle, which Xcode re-signs with the team's identity, so no entitlements are needed beyond the
hardened runtime defaults.
