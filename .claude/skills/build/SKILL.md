---
name: build
description: Build Gloss and run its tests, returning only errors, warnings in our code, and failing test names. Invoke as /build, /build tests, or /build package <Name>.
argument-hint: "[tests|package <Name>]"
user-invocable: true
allowed-tools: Bash, Read
---

# /build $ARGUMENTS

Run the matching command from the `run-app` skill, filtered so the transcript stays small. Report in this order: build result, errors with `file:line`, then warnings only from files under `Gloss/` or `Packages/`, then failing tests with their assertion message. Say "build ok" or "tests ok" when clean. Never paste full xcodebuild output.

- No argument: build the app target (Debug).
- `tests`: build and run the full test suite.
- `package <Name>`: `swift build` and `swift test` for `Packages/<Name>` only.

When the build fails on a dependency rather than our code, say which package and stop; do not try to patch dependencies.
