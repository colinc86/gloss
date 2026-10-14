---
name: sftp-over-ssh
description: How Gloss talks to remote hosts - the system ssh binary with a ControlMaster socket, the SFTP version 3 wire protocol the app speaks itself over the sftp subsystem (packet types, ATTRS, status codes, OpenSSH extensions, atomic save via posix-rename), the exec channel, and socket/port forwarding commands. Read before writing or changing anything under Remote/.
---

# SFTP over the system ssh binary

Decision (2026-10-01): no pure-Swift SSH library. Spawn `/usr/bin/ssh`, which inherits `~/.ssh/config`, keys, ssh-agent, ProxyJump, and keepalives. The app speaks SFTP v3 itself over the `sftp` subsystem's stdio, runs commands over separate exec invocations, and adds forwards to the shared control connection.

## Connection lifecycle

```
CP=$TMPDIR/gl/<10-char host id>                 # NOT %C: ssh binds via "<path>.<16 random chars>", and %C alone is 40 chars
ssh -o ControlMaster=yes -o ControlPath="$CP" -o ControlPersist=no \
    -o ServerAliveInterval=15 -o ServerAliveCountMax=3 \
    -o StreamLocalBindUnlink=yes -o ExitOnForwardFailure=yes \
    -o StrictHostKeyChecking=yes -o LogLevel=ERROR \
    -N -- <host>                                 # master; keep this Process alive, do not use -f; NO BatchMode (see below)
ssh -o ControlPath="$CP" -o ControlMaster=no -o BatchMode=yes -O check -- <host>   # health check, exit 0 when master is up
ssh -o ControlPath="$CP" -s <host> sftp          # SFTP channel on stdin/stdout
ssh -o ControlPath="$CP" <host> -- <command>     # exec channel, one per command
ssh -o ControlPath="$CP" -O forward -L <local-sock>:<remote-sock> <host>
ssh -o ControlPath="$CP" -O forward -R <port>:127.0.0.1:<port> <host>
ssh -o ControlPath="$CP" -O cancel -L <local-sock>:<remote-sock> <host>
ssh -O exit <host>                               # tear down
```

- Unix socket paths on macOS are limited to 104 bytes including the NUL, and ssh binds the control socket through a temporary name with a 17-character suffix (`unix_listener: path ... too long`, verified 2026-10-01 with OpenSSH 10.3). So `$TMPDIR/gl/%C` (93 bytes + 17) fails too; the ControlPath is `$TMPDIR/gl/<10-char suffix of the host id>` (about 80 bytes with the suffix). Local forwarded sockets go under `$TMPDIR/gl/` for the same reason.
- First connection may need host key confirmation or a key passphrase. Run the master with a pty-less `Process`; if it exits with "Host key verification failed", surface the fingerprint and offer `-o StrictHostKeyChecking=accept-new` for that host only. Passphrases must come from ssh-agent; the app never prompts for them.
- Detect disconnect by the master Process exiting or `-O check` failing; reconnect with backoff, then re-open the SFTP channel and re-add forwards.
- `BatchMode=yes` and `ControlMaster=no` on everything except the master so nothing ever blocks on a prompt and a client never becomes a stray master.
- The master MUST NOT use BatchMode: the `devbox` key lives in the 1Password agent, which needs a GUI approval, and `ssh -o BatchMode=yes devbox` fails with `communication with agent failed` (verified 2026-10-01). Give the master a 90 s connect budget, poll `-O check` every 500 ms, set `SSH_ASKPASS_REQUIRE=never` in its environment, and show "waiting for SSH agent" in the UI.

## SFTP v3 wire format

Packet: `uint32 length` (of the rest) `byte type` `payload`. Strings are `uint32 len + bytes`. All integers big-endian. Request ids are `uint32` chosen by the client; responses echo them. Pipeline freely; the server may answer out of order.

| Type | Code | Request payload | Reply |
| --- | --- | --- | --- |
| INIT | 1 | `uint32 version=3` | VERSION 2: `uint32 version` + extension pairs |
| OPEN | 3 | id, path, `uint32 pflags`, ATTRS | HANDLE 102 |
| CLOSE | 4 | id, handle | STATUS |
| READ | 5 | id, handle, `uint64 offset`, `uint32 len` | DATA 103 (`string data`) or STATUS EOF |
| WRITE | 6 | id, handle, `uint64 offset`, `string data` | STATUS |
| LSTAT | 7 | id, path | ATTRS 105 |
| FSTAT | 8 | id, handle | ATTRS |
| SETSTAT | 9 | id, path, ATTRS | STATUS |
| FSETSTAT | 10 | id, handle, ATTRS | STATUS |
| OPENDIR | 11 | id, path | HANDLE |
| READDIR | 12 | id, handle | NAME 104 (`uint32 count` then count × `filename, longname, ATTRS`) or STATUS EOF |
| REMOVE | 13 | id, path | STATUS |
| MKDIR | 14 | id, path, ATTRS | STATUS |
| RMDIR | 15 | id, path | STATUS |
| REALPATH | 16 | id, path | NAME with one entry |
| STAT | 17 | id, path (follows symlinks) | ATTRS |
| RENAME | 18 | id, oldpath, newpath | STATUS (fails if newpath exists on OpenSSH) |
| READLINK | 19 | id, path | NAME |
| SYMLINK | 20 | id, linkpath, targetpath (OpenSSH historically swapped these; verify against the server) | STATUS |
| EXTENDED | 200 | id, `string name`, data | EXTENDED_REPLY 201 or STATUS |

STATUS 101 payload: `uint32 code`, `string message`, `string lang`. Codes: 0 OK, 1 EOF, 2 NO_SUCH_FILE, 3 PERMISSION_DENIED, 4 FAILURE, 5 BAD_MESSAGE, 6 NO_CONNECTION, 7 CONNECTION_LOST, 8 OP_UNSUPPORTED.

pflags: READ 0x01, WRITE 0x02, APPEND 0x04, CREAT 0x08, TRUNC 0x10, EXCL 0x20.

ATTRS: `uint32 flags` then, in order, if flag set: SIZE 0x01 → `uint64 size`; UIDGID 0x02 → `uint32 uid, uint32 gid`; PERMISSIONS 0x04 → `uint32 perms` (POSIX mode incl. S_IFDIR 0o040000, S_IFLNK 0o120000); ACMODTIME 0x08 → `uint32 atime, uint32 mtime` (seconds); EXTENDED 0x80000000 → `uint32 count` + pairs. An empty ATTRS is `flags=0`.

## OpenSSH extensions to request after VERSION

Advertised in the VERSION reply as name/version pairs. Use when present:

- `posix-rename@openssh.com` (oldpath, newpath): atomic overwrite. THIS is how saves work: write to `<dir>/.cc-<name>-<rand>.tmp`, FSETSTAT perms copied from the original, then posix-rename over the target. Fall back to REMOVE + RENAME when absent (not atomic; warn once).
- `fsync@openssh.com` (handle): call before rename on saves.
- `statvfs@openssh.com`, `hardlink@openssh.com`, `lsetstat@openssh.com`: optional.
- `limits@openssh.com` (no args): returns `uint64 max-packet-length, max-read-length, max-write-length, max-open-handles`. Use its read/write lengths; without it use 32768 byte chunks (safe on every server).

## Conflict detection on save

At open: record `size`, `mtime`, and SHA-256 of the bytes read. Before save: STAT the path; if `size` or `mtime` differ from the recorded values, READ the file, hash it, and if the hash differs show the three-way diff. Only then write. mtime has 1-second granularity in v3, so the hash check is not optional.

## Directory listing

OPENDIR, then READDIR until STATUS EOF, then CLOSE. Skip `.` and `..`. `longname` is an `ls -l` style string; ignore it and use ATTRS. For symlinks, issue a STAT on the path to learn whether the target is a directory. Sort client-side. Large directories (10k+ entries) stream in pages of READDIR replies; render incrementally.

## Exec channel conventions

- Always `ssh ... <host> -- sh -c '<quoted script>'` so behavior does not depend on the login shell.
- Quote with single quotes and escape embedded single quotes as `'\''`.
- Prefer tools present on any Linux or macOS host: `sh`, `find`, `grep`, `stat`, `mktemp`, `rm`, `mkdir`. Probe for `rg`, `git`, `herdr`, `tmux` once per connection and cache.
- Content search: `rg --json -n <pattern> <root>` when available, else `grep -rn`.
- Never run interactive commands on the exec channel.

## Testing

- Local loopback: `sudo systemsetup -setremotelogin on` once, then host `localhost` exercises the same code path end to end on this Mac.
- Protocol unit tests: encode and decode every packet type against byte fixtures captured from `sftp -v` traffic or hand-built per the table above.
- Remote: the single host in `~/.ssh/config` is the integration target; tests that need it are tagged and skipped when `GLOSS_REMOTE_HOST` is unset.
