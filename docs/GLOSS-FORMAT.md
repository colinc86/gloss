# The .gloss review package

Format 1, decided 2026-10-13. The implementation is in Packages/Core/Sources/Core/Collaboration; the app's capture and local-index layer is in Gloss/Collaboration and CollaborationStore. This is Gloss's own document, not an annotation written into the source file. One package holds one document's captured content, published notes, contributors and iterations.

## Type, identity and location

Extension: .gloss. Exported type: com.cnc.gloss.document, conforming to com.apple.package and public.composite-content. Finder shows one file; Gloss opens it under Reviews. The owner's live reviews are created in iCloud Drive/Gloss. Accepted reviews can also appear at the top level of iCloud Drive. The local index keys by instance, never by title or source basename.

| Identifier | Spelling | Meaning |
| --- | --- | --- |
| ReviewID | g_<ULID> | Review identity, retained by Send a Copy |
| InstanceID | i_<ULID> | One live package; a detached copy gets a new instance |
| AuthorID | u_<ULID> | One Gloss install's self-chosen contributor identity |
| NoteID | n_<ULID> | A published note |
| MessageID | m_<ULID> | A thread turn |
| EventID | e_<ULID> | A state change |
| rev | <ULID> | Mutable record revision |

Path identifiers use canonical uppercase Crockford ULIDs, with the lowercase prefixes above; aliases or alternate case are not accepted as filenames. SHA-256 names are 64 lowercase hexadecimal characters. A display name is not verified Apple identity, an access list or proof of presence.

Send a Copy retains the review id, owner and history, writes a new instance, and sets origin to the prior review/instance/iteration and copy time. Different instances never merge. A Finder duplicate retaining the same instance is a duplicate of the live review, not a detached copy.

## Layout

The following tree is schematic; angle-bracket values are placeholders.

~~~text
Review of README.md.gloss/
  Info.json
  content/<sha256>.<ext>
  content/<sha256>/manifest.json
  content/<sha256>/<capture members>
  iterations/<number>.json
  authors/u_<ULID>/author.json
  authors/u_<ULID>/notes/n_<ULID>.json
  authors/u_<ULID>/messages/m_<ULID>.json
  authors/u_<ULID>/events/e_<ULID>.json
  authors/u_<ULID>/attachments/<sha256>.<ext>
~~~

The owner controls Info, content and iterations. Each contributor writes its own author folder, even when a message/event concerns someone else's note. Note bodies are author-only edits; owner moderation is an event, not rewriting another author's comment. Multiple owner installs may write owner-controlled metadata, so those files also need deterministic conflict rules.

Info, authors, notes and iteration records are mutable and carry rev. Content, attachments, messages and events are write-once; the same bytes again are a no-op, different bytes at the same write-once path are refused. Open iterations are ended by rewriting their record. Captures remain available; v1 does not compact them.

## JSON and compatibility

JSON is pretty-printed with sorted keys and unescaped slashes. Dates are UTC ISO 8601 strings written from integer milliseconds, for example 2026-10-13T12:00:00.123Z; readers also accept dates without a fractional part and round to milliseconds. Stable encoding makes repeated publication idempotent.

Info carries format and minReader, both 1 for new packages. Readers refuse minReader above their supported version. Author/note/message/event/iteration records carry v: 1. Unknown source, document-kind, message-kind and event-type values can be retained; unknown events do not change folded state. Unknown record fields are preserved on rewrite, including nested object keys covered by the record's known-path rules. Known fields deliberately removed stay removed. Arrays are replaced as units, so preservation is not promised inside array elements. An unchanged note anchor retains its original JSON object.

Bad individual records are reported as issues while other usable records remain readable. Filename ids and author-folder ids must agree with each record. A note id appearing in more than one author folder is rejected from both rather than choosing an author by arrival order.

## Identifier and path validation

Info.json must be a regular file. readInfo refuses the package as unreadable unless id, instance, ownerAuthor, every ownerAuthors entry, origin.review and origin.instance are canonical and current.hash is a valid 64-character lowercase hexadecimal hash. Per-file Info conflict candidates with invalid identifiers or another instance are never chosen.

checkPath walks package-relative path components without following links. Empty components, . and .., symbolic links, FIFOs, devices and other special files are refused with unsafePath. All writes, including merge writes, use this check. Known-path reads use readIfSafe, requiring a regular file reached without links; author(ofNote:) cannot infer ownership from a planted link. readFile additionally resolves the path and requires a regular file within the resolved package root. contentURL(hash:) returns nil for an invalid hash or linked snapshot.

## Info.json

| Field | Meaning |
| --- | --- |
| format, minReader | Format and minimum reader version |
| id, instance | Review and live-instance identity |
| origin? | {review, instance, iteration, copiedAt}; present for a detached copy |
| createdAt | Review creation time |
| ownerAuthor | Named creator/primary owner author; unchanged when another install adopts ownership |
| ownerAuthors? | Additional owner-install identities; effective set also includes ownerAuthor |
| kind | DocumentKind string: text, code, markdown, csv, image, pdf, web or file |
| title | Display title, for example README.md |
| source | Portable source identity below |
| current | {hash, iteration, capturedAt} |
| content? | Current capture's per-kind facts |
| rev | Mutable revision ULID |

An older Info without ownerAuthors has the one ownerAuthor. The effective owner set is ownerAuthors union ownerAuthor; newly added owners are encoded in sorted order. On another install of the owner's Apple Account, Gloss calls the session's adoptOwnership on open, import and permission changes. Adoption permits a shared item only when the platform role is owner, or an unshared item in your own iCloud Drive with no role, as iCloud reports no owner role for such an item. Shared participant/unknown roles do not adopt ownership, and detached copies refuse adoption even if their local iCloud role is owner. The app uses info.isOwner/owners for owner rights and labels; ownerAuthor remains the named creator. Agent turns identify the contributor who routed them. The current owner names in records are not a substitute for native permissions, and agent delivery still requires an available original.

Owner rights use the effective owner set through info.owners/info.isOwner; owners join this set rather than handing ownership over. These checks are format semantics among invited contributors, not cryptographic authentication of JSON.

### Portable sources

| type | Fields / example |
| --- | --- |
| file | name: README.md; optional git: {origin: github.com/o/r, path: docs/README.md, commit?: <sha>} |
| web | url: https://example.com/review; reachable: false for a local/tunneled source (true is omitted) |
| github | repo: o/r, pull: 7, path: Sources/App.swift; optional head and base |
| jira | site: example.atlassian.net, key: CP-7 |
| confluence | site: example.atlassian.net, pageId: 123; optional version |
| unknown | Source JSON retained as written |

The source never needs the owner's absolute filesystem path or SSH alias. Known file sources require a filename and a relative work-tree path without traversal; git origin is a bare host/path without scheme, user, credentials or SSH host:path form. Known web sources require HTTP(S) without URL username/password. Source privacy checks run on creation and Info writes. Portable metadata does not grant source-service access.

Optional source fields are format capabilities, not a promise the app can obtain every revision/git fact for every source. The original-resource link and credentials remain local.

## Captured content

Single files use content/<hash>[.<ext>], where hash is SHA-256 of the file bytes. Folder captures use content/<hash>/; hash is SHA-256 of the encoded manifest.json, an object mapping member relative paths to their byte hashes. Including all member hashes means an image-only change is a new capture even if the text is unchanged.

Folder names must be nonempty relative paths without hidden/empty components, member/directory collisions or an explicitly supplied manifest.json. The writer validates names, builds the folder hidden and moves it into place whole. The reader recognizes a folder capture as arrived once the hash-matching manifest and all its listed members exist. App capture installation checks its required document/picture bytes before using them; a new Info pointer alone does not replace the last complete capture.

Current app capture conventions:

| Capture | Members and facts |
| --- | --- |
| Plain text/code/CSV/image/PDF/file | Saved provider bytes; optional content facts |
| Markdown with referenced pictures | document.md, images/<hash>.png, capture.json and manifest.json. Facts: {document: document.md, images: {<original image reference>: <member path>}} |
| Rendered HTML/live web | shot.png, capture.json and manifest.json. Facts: {capture: viewport, screenshot: shot.png, viewport: {x, y, w, h}} |

Markdown reference spelling/source coordinates stay unchanged; rendering resolves the captured reference map and never fetches missing original network/disk pictures. Image bytes must be valid and within the source resource bounds. Web/HTML shares only the visible viewport screenshot, not a DOM, a complete page or a live browser. Element notes retain portable anchors and are projected onto the screenshot where the viewport intersects them.

## Iteration records and publication

iterations/<number>.json contains v, number, optional name, startedAt, optional endedAt, snapshot (content hash), optional gitCommit and rev. The filename number must match the record.

A new review begins at share time with the current capture and local iteration number, which need not be 0. The app does not backfill pre-share rounds. It retains captures/iterations published after sharing.

Only the owner's existing source iteration rule starts automatic local iterations. Package publication mirrors an already-established higher number: end the old open record, make/reuse its content blob, write the new iteration record, then update Info.current. Changed bytes update capturedAt and content facts. A higher number with the same hash reuses the blob and preserves the capture time; it does not make a second local rollover. No higher number and unchanged bytes returns false/no write; changed bytes without a higher number are refused.

Readers adopt current only with its available content. Imported history is best effort after the complete current capture; a missing older blob must not make a valid current review unusable.

## Contributors, notes and turns

| Record | Fields |
| --- | --- |
| author.json | v, id, name, optional color, joinedAt, rev |
| notes/<id>.json | v, id, author, optional via: {agent}, createdAt, updatedAt, iteration, anchorType, anchor, body, color, optional attachments, rev |
| messages/<id>.json | v, id, note, author, optional via: {agent}, kind, body, optional inReplyTo, optional meta, createdAt |
| events/<id>.json | v, id, note, author, optional via: {agent}, type, at, optional data |

Author color is an avatar tint key, independent of note color. Notes use today's typed Anchor JSON (text, image, pdf, file, element, embedded-image) and NoteColor values. Notes have no stored draft/state/waitingOnUser field. State is folded from events and question turns. Agent-created questions are owner-folder notes with via.agent; human authorship does not become the agent's identity. Package reading clears via on notes and messages not authored by an owner; the fold honors a resolution's via only from an owner. Imports and waitingOnUser use this cleaned attribution.

Message kind is comment, question, reply or moved. The mapper uses meta.choices: {options, multi}; meta.selectedOptions: [zero-based indexes]; meta.customAnswer: true; meta.move: {from, to, removed}. inReplyTo identifies the question. Omitted metadata remains a plain turn. Private custom/choice answers do not enter the package until Send. Published turns are write-once.

Attachment refs on a note are {path, kind, width, height}. Path names a content-addressed file in that note author's own attachments folder; refs elsewhere are dropped/reported. The coordinated readFile API accepts content/attachment paths only, with path containment checks. Local cache filenames are derived from bytes' hash, not the untrusted ref path.

## Event fold and rights

Events and threads sort by identifier, not arrival order or (at, id). EventIDs are ULIDs; mapped transition ids are derived from rounded time milliseconds and a SHA-256 of note/type/author/time, so a retry recreates the same id. at remains the event's display/transition time. Resolution publication uses a stable resolvedAt, with agent-turn/send fallback, not updatedAt on every body/color edit. An acceptance is placed strictly after its resolution.

| type | data | Effect / allowed author |
| --- | --- | --- |
| sent | {review: <bool>, to?: <agent>} | Owner only; posted → sent; records first sentAt, clears prior resolution/acceptance |
| resolved | {outcome: done or skipped, message?: <text>} | Any contributor with write access; records attributed resolution and clears acceptance |
| accepted | none required | Owner only, on a resolved note; records acceptedAt |
| reopened | none required | Any writable contributor; posted if never agent-sent, otherwise sent; clears result/acceptance |
| deleted | none required | Note author or owner moderator; sets trashed |
| restored | none required | Note author or owner; clears trashed |
| moved | {anchorType, anchor, removed: <bool>} | Note author or owner; updates folded anchor/removal |

Initial state is posted (with owner), with no agent delivery. Agent visibility requires an authorized owner sent event and, on the app side, the exact delivered snapshot on an owner-authorized source. A participant receiving that event can see delivery status but gains no MCP eligibility. Non-owner send/accept and unauthorized moderation events are retained as refused ids, not applied. Unknown types are skipped.

Waiting on the user is derived for a nonresolved/nontrashed note: the last thread turn is an agent question with via, or an agent-created note has no turns yet. A participant's question-kind turn alone does not make the note wait on the user or enter Attention. Review waits when resolved, review requested, and acceptedAt absent. A participant's answer requires participant Send then explicit owner Send to reach an agent.

## Draft privacy and the local index

The package contains only published input. Local SQLite keeps private draft comments/edits/follow-ups and seen records; it is not shipped inside the package. The app preserves later input across imports and edits made during publication. Core bundles exclude unsent human turns, app-only turns and foreign imported turns; a writer refuses another author's note ids.

v17-collaboration maps remote note/message ids separately for each instance into valid local ids and records publication separately from agent delivery. The retained collaboration_document instance/document association and independent note/message mappings survive removal of the visible review index. Deletion or confirmed invalid-package opening closes captured viewers and removes that index entry, keeping notes and participant drafts; restoration reuses them and the owner's original source association. Ambiguous cloud unavailability keeps the index. Launch opens only indexed, downloaded and current packages in an independent background task, without folder discovery; stale, evicted or ambiguous packages wait for explicit opening.

Only owner reviews save agent_note_snapshot. note_json keeps the delivered note; attachments_json stores hashes and attachment metadata whose localPath points to retained files, not base64 payloads. Persistent databases retain files beside the database; temporary/in-memory databases use disposable storage. Reads verify each file's bytes against its hash. MCP packet/resources honor the saved words/bytes even before publication and get_note packet paths point to the retained immutable files, even if later edits remain private. Contributor names become the optional packet Author header and named human turns; the precise plain-text agent grammar is in the context-packet skill.

The local v17 note_message.agent_sent_at column records agent delivery independently of non-owner contributor publication. The migration backfills it from already-sent user turns; a successful agent Send stamps the exact carried turns. On an owner install, imports treat turns authored by any owner as sent and set agent_sent_at to createdAt, including on role upgrades. Non-owner contributor turns still need explicit owner forwarding; previously delivered turns remain sent across reimport. Neither adoption nor source linking sends a packet. This column is not a package message field. Imported agent questions still need local snapshot/send proof on an owner-authorized source before becoming MCP-eligible.

## Merge, conflicts and duplicates

Merge takes the union of regular, nonhidden files from versions of the same instance. It never deletes records from that union. Winner rules are deterministic:

| Path | Winner |
| --- | --- |
| Info.json | Higher current.iteration, then later current.capturedAt, then higher rev; union the owner sets within the instance |
| Note / author | Higher rev |
| Iteration | Prefer a current record matching winning Info's hash, then ended over open, then higher rev |
| File capture / attachment / manifest | Bytes matching the hash in the filename/folder |
| Folder member | Bytes matching its manifest hash |
| Message / event / unknown file | Greatest SHA-256 on unequal write-once bytes; report anomaly |

Readable records beat unreadable candidates; ties/fallback use greatest byte hash. Missing/invalid hashes and conflicting write-once files are reported, not claimed as semantic content merges. treeHash is SHA-256 of sorted regular-file entries joined as relative path + NUL + file SHA-256 + newline. Equal hashes confirm equal regular-file trees.

GlossReviewSession coordinates reads/writes off the main actor with NSFileCoordinator/NSFilePresenter and coalesces changes. Its adaptive fallback poll is a one-shot timer rescheduled after each run: 30 seconds after a presenter callback, back to pollInterval (5 seconds by default) when polling finds a missed change, and doubling toward 30 seconds while nothing changes. An idle review settles at 30 seconds; a change missed by the presenter can wait up to that next poll.

The session merges package/subitem conflict versions, resolves/removes versions only after successful merge, and retains unusable versions. On open, the app calls duplicates, absorbs each same-instance same-named sibling, then calls resolveConflictsNow. On a merged callback it scans and absorbs duplicates again; Try Again repeats consolidation. Successfully absorbed siblings move to Trash; detached instances are refused. When opening a duplicate of an already-open instance, the active session remains the destination so its presented package is not trashed. All consolidation runs off the main actor, with failures shown on the review rather than in a global modal loop.

The code/local tests do not establish native invitation delivery, cross-account permissions/latency, or real iCloud conflict/version behavior. These remain the two-Mac live acceptance gates; no Messages activity or presence service is part of this format.
