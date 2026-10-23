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
  build 2>&1 | grep -E 'error:|warning: .*Gloss|BUILD' 
```

The build uses Xcode's default DerivedData, the same location Xcode's ⌘R uses, so there is exactly one copy of the
app registered with Launch Services (two copies made `gloss://` links land in a stale build once). Find it with:

```
APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/Gloss-*/Build/Products/Debug/"Gloss.app" | head -1)
```

Never pass `-derivedDataPath`.

## Launch

```
APP=$(ls -d ~/Library/Developer/Xcode/DerivedData/Gloss-*/Build/Products/Debug/"Gloss.app" | head -1)
pkill -x "Gloss" 2>/dev/null
open -n "$APP" --args --root "$PWD" --host local
sleep 2
```

Supported launch arguments (add to `AppLaunchOptions` when new ones are needed): `--root <path>`, `--host <alias|local>`, `--open <path>`, `--reset-db` (uses a throwaway database under `$TMPDIR`, never the real one), `--db <path>` (opens or creates the database at that path, never the real one: launch once to create it, quit, seed rows with `sqlite3`, relaunch — the only way to put notes awaiting review or resolve in front of the app without an agent session; `gloss://` links are not an alternative, they reach the installed app), `--follow` (start with Herdr follow mode on), `--appearance dark|light` (force one appearance for the run; `-AppleInterfaceStyle Dark` does not work on macOS 26). Debug builds also take `--integrations-env <path>` (a KEY=VALUE file of GitHub and Atlassian keys loaded into the run's credential store, so no key is ever typed into a field; with `--reset-db` the store is in memory and nothing persists) and `--atlassian-site <site>` when the file does not name the site. Those keys only ever read; check a live session with `log show --info --predicate 'subsystem == "com.cnc.Gloss" AND category == "integrations"'` and expect only GET lines.

## Screenshot

```
osascript -e 'tell application "Gloss" to activate'
sleep 1
screencapture -x -l "$(osascript -e 'tell application "System Events" to get id of first window of process "Gloss"')" /tmp/gloss-shot.png
```

If the window-id lookup fails, fall back to `screencapture -x /tmp/gloss-shot.png` for the whole screen. Read the PNG with the Read tool to inspect it.

## Drive it

- The app registers the `gloss://` URL scheme. A `note` link (and an `open` of a web URL through an ssh host) must carry `&token=$(cat ~/Library/Application\ Support/Gloss/url-token)`; without it the app refuses, since any web page can open such links. `open "gloss://open?host=local&path=/abs/path&token=$(cat ~/Library/Application\ Support/Gloss/url-token)"` opens a file (without the token the app asks the user to confirm first); `gloss://note?host=..&path=..&line=12&text=...` creates a note. Use these from scripts instead of simulating clicks.
- Logs: `log stream --predicate 'subsystem == "com.cnc.Gloss"' --level debug` in the background while reproducing.
- Quit cleanly with `osascript -e 'tell application "Gloss" to quit'` so the database closes properly.

## Tests

```
xcodebuild -project "Gloss.xcodeproj" -scheme "Gloss" \
  -destination 'platform=macOS' test 2>&1 | grep -E 'Test Case.*(failed|passed)|error:|\*\* TEST'
```

Swift package tests for `Packages/*` run faster with `swift test --package-path Packages/<Name>`.
