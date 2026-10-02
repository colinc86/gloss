# Gloss

Native macOS app: file explorer on the left, viewer on the right, annotate any region of any file and send the notes to Claude Code, Codex, or OpenCode. Replaces what was lost moving from Orca to Warp and Herdr. The product description with scope, data model, and milestone 1 acceptance checks lives at https://claude.ai/code/artifact/01a13d3e-5f5a-491b-b910-b5f1a57cc70c and is mirrored in @docs/PRODUCT.md.

## Settled decisions (do not re-litigate)

- Deployment target macOS 26. Swift 6 language mode, strict concurrency. SwiftUI shell, AppKit where SwiftUI falls short (outline view, text editor, PDF, image canvas).
- Storage is SQLite via GRDB. Notes are keyed by host + absolute path and never written into the file. The template's SwiftData `Item` model is to be deleted.
- Remote access uses the system `ssh` binary with ControlMaster, SFTP v3 spoken by the app, exec channel for commands, OpenSSH forwarding for the Herdr socket and the MCP port. No pure-Swift SSH library. See the `sftp-over-ssh` skill.
- Transport priority: Herdr socket, MCP server, Claude Code and Codex hooks, OpenCode HTTP API, tmux, clipboard. See `herdr-api` and `agent-integrations`.
- Packet format is fixed by the `context-packet` skill. Every transport emits the same text.
- Markdown viewer toggles rendered and source; anchors are stored in source coordinates. Text and markdown are editable; images, PDFs, spreadsheets are not.
- Not sandboxed, Developer ID signed and notarized. Milestone 1 is the whole product.

## Template leftovers to fix in the first implementation pass

- `MACOSX_DEPLOYMENT_TARGET` is 27.0 in the pbxproj; set to 26.0.
- `ENABLE_APP_SANDBOX = YES`; set to NO and drop the entitlement.
- `SWIFT_VERSION = 5.0`; set to 6.0.
- `Item.swift` and the SwiftData container in `GlossApp.swift` go away.

## Layout

- `Gloss/` app target. `Packages/Core`, `Packages/Remote`, `Packages/Transports`, `Packages/Viewers` as local Swift packages once they exist, each with its own tests.
- `docs/` product and design notes. Builds use Xcode's default DerivedData (never `-derivedDataPath`), so the app Xcode runs and the app scripts launch are the same copy.
- `.claude/skills/` holds the verified protocol references; read the relevant one before touching that area.

## Build and test

Use `/build` (delegates to the `xcode-builder` agent) rather than running xcodebuild inline. To see the UI, follow the `run-app` skill. Use `/verify-transport <name>` before claiming a transport works.

## Working rules

- Verify API signatures with the `apple-api-researcher` agent when unsure; never guess a framework or package API.
- Run `swift-reviewer` on a feature before ticking its milestone check.
- Quote every path: the project and scheme names contain spaces.
- Remote and Herdr code must never leave test panes, sessions, buffers, or temp files behind.
- Keep `docs/PRODUCT.md` in sync when a decision changes, and say so in the commit message.
- Commit only when asked.
