# Security policy

## Reporting a vulnerability

Please report security problems privately, through GitHub's
[private vulnerability reporting](https://github.com/colinc86/gloss/security/advisories/new), not in a public issue.
Include what you found, how to reproduce it, and the Gloss and macOS versions. You'll hear back within a week.

## Supported versions

Only the latest release gets fixes. Gloss updates itself through Sparkle, so a fix reaches people in the next
release.

## Scope

Areas where a report is most useful:

- The local MCP server and its token.
- `gloss://` links and the token they carry.
- ssh and SFTP handling, including staged files on remote hosts.
- GitHub and Atlassian keys kept in the Keychain.
- The review browser, its `gloss-html://` pages and remote dev-server tunnels.
- Shared reviews (`.gloss` packages) opened from other people.
- Updates: the appcast, signatures and downloads.
