# Release: Developer ID signing and notarization

The app is not sandboxed; it is signed with a Developer ID certificate, hardened runtime on, and notarized.
Settings already in the project: `CODE_SIGN_STYLE = Automatic`, `DEVELOPMENT_TEAM = 4WS4246RA4`,
`ENABLE_HARDENED_RUNTIME = YES`, `ENABLE_APP_SANDBOX = NO`.

```sh
xcodebuild -project "Gloss.xcodeproj" -scheme "Gloss" -configuration Release \
  -archivePath build/Gloss.xcarchive archive
xcodebuild -exportArchive -archivePath build/Gloss.xcarchive \
  -exportOptionsPlist docs/ExportOptions.plist -exportPath build/export
ditto -c -k --keepParent "build/export/Gloss.app" build/Gloss.zip
xcrun notarytool submit build/Gloss.zip --keychain-profile "AC_PASSWORD" --wait
xcrun stapler staple "build/export/Gloss.app"
```

`AC_PASSWORD` is a notarytool keychain profile created once with
`xcrun notarytool store-credentials AC_PASSWORD --apple-id <id> --team-id 4WS4246RA4`.

The child processes the app launches (`ssh`, `tmux`, `herdr`, `git`, `rg`) are system or Homebrew binaries;
nothing is embedded, so no extra entitlements are needed beyond the hardened runtime defaults.
