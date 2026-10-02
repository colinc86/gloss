---
name: run-app
description: How to build, launch, drive, and screenshot the Gloss macOS app from the command line so a change can be verified in the real app, not just in tests. Used by the built-in /run skill and by any session that needs to see the UI.
---

# Run the app

Scheme and project names contain spaces; always quote them.

## Build

```
xcodebuild -project "Gloss.xcodeproj" -scheme "Gloss" \
  -configuration Debug -destination 'platform=macOS' \
  -derivedDataPath build/DerivedData build 2>&1 | grep -E 'error:|warning: .*Gloss|BUILD' 
```

The built app lands at `build/DerivedData/Build/Products/Debug/Gloss.app`. `build/` is gitignored.

## Launch

```
APP="build/DerivedData/Build/Products/Debug/Gloss.app"
pkill -x "Gloss" 2>/dev/null
open -n "$APP" --args --root "$PWD" --host local
sleep 2
```

Supported launch arguments (add to `AppLaunchOptions` when new ones are needed): `--root <path>`, `--host <alias|local>`, `--open <path>`, `--reset-db` (uses a throwaway database under `$TMPDIR`, never the real one), `--follow` (start with Herdr follow mode on).

## Screenshot

```
osascript -e 'tell application "Gloss" to activate'
sleep 1
screencapture -x -l "$(osascript -e 'tell application "System Events" to get id of first window of process "Gloss"')" /tmp/gloss-shot.png
```

If the window-id lookup fails, fall back to `screencapture -x /tmp/gloss-shot.png` for the whole screen. Read the PNG with the Read tool to inspect it.

## Drive it

- The app registers the `gloss://` URL scheme. `open 'gloss://open?host=local&path=/abs/path'` opens a file; `gloss://note?host=..&path=..&line=12&text=...` creates a note. Use these from scripts instead of simulating clicks.
- Logs: `log stream --predicate 'subsystem == "com.cnc.Gloss"' --level debug` in the background while reproducing.
- Quit cleanly with `osascript -e 'tell application "Gloss" to quit'` so the database closes properly.

## Tests

```
xcodebuild -project "Gloss.xcodeproj" -scheme "Gloss" \
  -destination 'platform=macOS' -derivedDataPath build/DerivedData test 2>&1 | grep -E 'Test Case.*(failed|passed)|error:|\*\* TEST'
```

Swift package tests for `Packages/*` run faster with `swift test --package-path Packages/<Name>`.
