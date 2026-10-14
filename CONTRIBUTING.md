# Contributing to Gloss

Thanks for helping. Bug reports and feature requests are welcome from inside the app (the ladybug in the toolbar,
or Help › Report a Bug or Request a Feature…) or with the issue templates on GitHub.

## Build

You need macOS 26 and Xcode 26.

1. Clone the repository and open `Gloss.xcodeproj`.
2. Build and run the **Gloss** scheme. With no setup, the app is signed to run locally, which is all you need to
   run it on your Mac.
3. To sign with your own team instead, copy `Config/Signing.local.xcconfig.example` to `Config/Signing.local.xcconfig`
   (it is ignored by git) and set your `DEVELOPMENT_TEAM`.

From the command line:

```sh
xcodebuild -project Gloss.xcodeproj -scheme Gloss -destination 'platform=macOS' build
```

Debug builds never check for updates, and `--reset-db` runs the app against a throwaway database.

## Test

```sh
# The app's tests
xcodebuild -project Gloss.xcodeproj -scheme Gloss -destination 'platform=macOS' test

# Each package's tests
swift test --package-path Packages/Core        # also Remote, Transports, Viewers, Integrations
```

Tests that need something on your machine skip when it isn't there: ssh to localhost, a running
[Herdr](https://herdr.dev), tmux, `GLOSS_REMOTE_HOST=<ssh alias>` for checks against a real host, and an
`integrations.env` file of GitHub and Atlassian keys (ignored by git) for read-only integration checks. Tests create
only throwaway resources and remove them on every path.

## Guidelines

- Swift 6 language mode with strict concurrency. Keep UI on the main actor and make what crosses actors `Sendable`.
- Run `swiftlint` before sending a change; `.swiftlint.yml` holds the rules.
- Child processes go through `posix_spawn`, never Foundation's `Process`.
- The integrations clients only read (a test asserts GET only). Agents make changes with their own tools.
- Fixtures, docs and commit messages use made-up identifiers: `o/r`, `acme/…`, `example.atlassian.net`, `CP-7`,
  `/home/me/proj`. Never a real organization, repository, issue key, site, host name or person.
- `docs/PRODUCT.md` describes what the app does and `docs/DESIGN.md` how it looks and behaves. Update them in the
  same change when you change a decision they record.
- `.claude/` and `CLAUDE.md` hold notes and protocol references for coding agents working on the repository.

## License

By contributing, you agree that your contributions are licensed under the [MIT License](LICENSE).
