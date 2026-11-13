# Global buffers and the local server

Run `junc path/to/file.zig`, or `junc` for a new scratch buffer. The executable connects to the default per-user server and starts it automatically when needed. Neither the server identity nor the buffer collection depends on the working directory. Relative file arguments and prompt input resolve against the terminal client's working directory.

Several terminals can edit the same buffer without keeping separate mutable copies of its text. Each client has its own Litura interaction session, cursor, selection, Lua VM and viewport. The server serializes submissions and tells peers when their cached views are stale; each peer then queries a fresh observation.

## Working with buffers

Use M-x (or Ctrl-O) for these ordinary Lua commands:

| Command | Behavior |
| --- | --- |
| `open-file` | Prompt for a file; empty input creates a fresh scratch buffer |
| `switch-buffer` | Complete over global buffer ids and names; Enter selects |
| `list-buffers` | Open the same chooser with candidates already displayed |
| `kill-buffer` | Kill the current buffer; dirty contents require typing `yes` in a confirmation prompt |
| `save-as` | Save the current buffer under a filename |
| `shutdown-server` | Stop the server and close the terminal; refuses dirty buffers or another attached client |

Tab and Up/Down use the existing minibuffer completion interface. Labels include the stable buffer id, display name, current-buffer marker and dirty marker. Selection uses ids, so files with equal basenames remain unambiguous. The chooser lists buffers; filename completion is not implemented.

Ctrl-S saves the selected buffer. For an unnamed scratch buffer, Ctrl-S opens the `save-as` filename prompt. Enter a filename relative to the client's working directory, or cancel with Escape/Ctrl-G to keep editing without saving. Empty input keeps the prompt open. Once named, later saves use that path. Saving to a canonical path already owned by another buffer is rejected. Ctrl-Q **detaches immediately**, including with unsaved changes, because the documents remain in the server. Use `kill-buffer` to discard a buffer explicitly.

Switching away preserves this attachment's cursor, selection and viewport for that buffer. The Lua VM, commands, keymaps, presentation preset and local minibuffer stay alive across switching. Reload replaces Lua policy without reopening buffers or sessions. A later attachment starts fresh client policy, viewports and interaction sessions, while document text, revisions, dirty state and undo/redo history remain shared in the running server.

## Ownership and lifetimes

The server's flat registry owns stable, separately allocated buffers. Each buffer has a monotonically allocated id, an optional canonical absolute path, an owned display name, one Litura `BufferEngine`, and its syntax-provider/cache lifetime. Ids are not reused during that server lifetime. Empty invocations and empty `open-file` submissions create distinct scratch buffers. Existing symlinks and `.`/`..` path aliases deduplicate through `realpath`; absent files use the canonical existing parent plus basename. Dangling symlinks are rejected. Hard-link aliases are not inode-deduplicated. The registry is flat; buffer identity does not depend on workspace, project or directory membership.

An attachment owns one Litura cursor/session per visited buffer. Switching reuses it. Detaching, EOF or a transport timeout drops those interaction resources through Litura's public lifetime APIs, without editing text or clearing history. Killing a buffer selected by another attached client is rejected as `BufferInUse`, even with discard confirmation. Otherwise killing the current buffer chooses another registry buffer, or creates a fresh scratch buffer if necessary. Other clients forget any inactive visits to the killed identity. A killed identity never becomes another document.

The client owns libvaxis, its terminal, LuaJIT VM, presentation, keymaps, per-buffer viewport offsets, and the local Litura minibuffer. It caches an immutable server snapshot and the current visible line range, without constructing a main-document engine. The server supplies text, line boundaries, grapheme-to-byte offsets and token spans; the client measures grapheme cell widths, clips and renders. No remote text edit is applied speculatively, and there is no client-side parser or mutable replica. libvaxis copies its previous-frame strings internally; current view strings remain alive until the frontend clears its cells and prepares a replacement view.

An `Editor` owns no document. It borrows a `Connection`, which the application obtains from `Connection.connect` and never replaces with a local engine when the server is unavailable. Tests attach the same `Editor` to an `InProcessHost` instead: a registry and one attachment answering requests through the server's own handlers, with each reply serialized and decoded as if it had crossed the socket. Editing, rendering and buffer switching therefore take one path in both cases; framing, invalidation hints and daemon lifetime are left to the process and PTY suites. The same native intent adapter builds Litura submissions for hosted buffers and the client minibuffer.

## Startup, security and shutdown

The default endpoint is `/tmp/junc-<uid>/session.sock`. The directory must be owned by the user with mode 0700; the socket and persistent `server.lock` file use mode 0600. Unsafe directories, symlinks at the endpoint, ordinary files at the endpoint, unexpected ownership and permissive modes are rejected. junc creates only an AF_UNIX listener, with no TCP or remote-network interface. `JUNC_RUNTIME_DIR` selects an explicit private absolute directory for isolated testing; ordinary launches use the same uid-derived default regardless of cwd.

Startup uses a nonblocking advisory `flock` on the permanent lock file. The winning client double-forks, creates a separate session/process group, redirects standard I/O to `/dev/null`, closes unrelated descriptors and execs the same executable in an internal server mode. The inherited lock stays held for the server's whole lifetime. The launcher reaps its intermediate child and waits up to five seconds for readiness. A simultaneous launch waits for that owner rather than binding another endpoint. The internal server verifies the inherited descriptor against the expected lock inode before listening.

Only a holder of the lifetime lock may remove a stale endpoint, and only if that endpoint is an owned private socket that refuses connections. A listening endpoint is never overwritten. Normal exit removes only the socket inode that this process bound. The lock file is intentionally retained so concurrent launchers cannot lock different replacement inodes.

After the last detachment, a clean server exits after 30 seconds without an attached client. **Any dirty buffer disables idle exit**, regardless of which buffer was selected. `shutdown-server` refuses dirty state and other attached clients. Explicit process termination, machine shutdown or a crash can still lose in-memory documents; sessions are not persisted across restarts. SIGTERM/SIGINT request cleanup on the event-loop thread; they are explicit termination, not a save operation. A server never depends on the first client's terminal, process group, cwd or continued existence.

## Hosting transport

Each frame is a four-byte unsigned little-endian JSON byte length followed by that many UTF-8 bytes. Envelopes contain the hosting protocol `version`, currently 3, and a request `id`; replies echo both. Frames are limited to 64 MiB to bound transport allocation. This is a wire limit rather than a new file-size limit: extremely long visible lines or huge selections can exceed it and receive `FrameTooLarge`. Litura's existing file-open limit and the configured syntax fallback remain in effect.

Each client has one outstanding request at a time. The first request is `hello` with id 1. Subsequent ids increase exactly by one. The single server event loop executes requests serially; there is no ordering promise between requests from different connections before dispatch. Replies echo their request ids. Unsolicited invalidation hints use id 0 and may precede a reply. `ping` on a separate short connection returns server pid and whether any client is attached, without acquiring a session.

The host keeps one encoded outgoing frame and one coalesced unsent invalidation per connection. Input and output use explicitly nonblocking sockets with a 64 KiB per-turn budget. In-flight frame bytes are immutable and never interleaved. A partial sender or slow reader cannot block another connection's transport; document parsing, saving and mutation work remain synchronous. Handshakes, partial input frames and nonprogressing output time out after five seconds; idle attached clients do not. The host permits at most 64 connections. These bounds protect host resources, rather than changing Litura semantics.

Version/order violations produce an error and close the connection; malformed payloads close without dispatch. A failed handshake, timeout or EOF cannot acquire another client's session.

The version changes whenever a message's shape or an operation's meaning does. Version 3 kept version 2's messages but stopped `observe` from moving the requested range to the cursor. A version 2 client would still decode every reply and simply stop scrolling, so the bump turns a silent disagreement into a refusal. Both sides read only `version` and `id` before decoding the rest of a frame. A server answers a mismatched request with `UnsupportedVersion`, naming both versions, and closes the connection; a client that receives a mismatched reply exits with `IncompatibleServer` and asks you to stop the running server with `shutdown-server` from its own executable. A clean server also exits by itself once idle.

| Operation | Fields and result |
| --- | --- |
| `hello` / `ping` | Attach independently or probe; reply includes `server_pid` and `busy` |
| `open` | Optional absolute `path`; selects the canonical file or a new scratch buffer |
| `list` | Return buffer ids, names, paths, revisions and dirty flags |
| `select` | `buffer` id; create or reuse this attachment's interaction session |
| `snapshot` | Selected `buffer`; return document and interaction observations/navigation targets |
| `view` | Selected `buffer`, exact `revision`, `first_line`, `line_count`; return immutable lines, grapheme byte boundaries and tokens |
| `observe` | Selected `buffer`, `first_line`, `line_count`; return a snapshot and visible view from one serialized observation. `first_line` is clamped to the document but never moved toward the cursor |
| `submit` | Selected `buffer` and `edit`; return a submission summary and fresh snapshot |
| `save` | Selected `buffer` and optional absolute destination `path`; return fresh snapshot |
| `kill` | `buffer`, with `discard` false by default; reject dirty buffers unless explicitly confirmed |
| `detach` | Acknowledge and release the attachment, retaining documents |
| `shutdown` | Acknowledge and stop only if all buffers are clean and no other client is attached |

`submit.edit` carries the existing junc Lua intent kind (`replace`, `move`, `undo`, `redo`), `origin` document revision, `interaction_origin`, command `source` and applicable range/text/position/mark fields. The server binds it to the selected buffer and that connection's own cursor/session; clients cannot nominate another session. Both origins must match current observations. They are mandatory JSON fields: omitting one rejects the message rather than treating its coordinates as current. Both origins matter because a peer can change text and passively rebase anchors without advancing this session’s interaction revision. The session revision may still match while the coordinates refer to old text. Unsupported stale positions are rejected, never silently rebased or retried. A replacement becomes one Litura composite: buffer operation 0 replaces the requested range, then `set_selections` moves the retained cursor endpoint to its symbolic `EditRef` end and clears the mark. Litura resolves the endpoint after contextual resegmentation. Navigation uses positional `set_selections` with both origins checked. No server command directly moves anchors to perform editing. Initialization and session teardown remain explicit lifetime operations.

Each reply carries a hosting `generation`, separate from both Litura revision domains. A document revision change invalidates peers currently viewing that buffer; opening, saving and killing conservatively invalidate registry observations. A hint contains only `{ generation, buffer }`, where null buffer means all cached observations. Multiple hints may collapse into one. An encoded older view can finish sending after a newer edit; its revision remains unchanged and the subsequent hint requests refresh. Clients never interpret a hint as a document delta or canonical Litura event.

The frontend's `observe` call obtains interaction state, text boundaries and syntax for one document revision without a snapshot/view race. It clears cells borrowing the old view before replacing that view's arena. A later mutation can immediately make this observation old; its origin is retained when a command submits. On stale rejection the server returns a fresh snapshot, the client displays the error and redraws, and the rejected command is not replayed.

Viewport policy belongs to the client. The surface scrolls from the cursor line in its latest snapshot and observes that range. A peer may have moved the cursor in the meantime, for example by inserting lines above it, so the fresh snapshot in the reply can place the cursor outside the returned lines. The surface then observes once more from the corrected position. If another peer edit races that second request as well, the cursor stays unobserved for one frame and the next frame catches up.

Snapshots include ids, names/paths, byte/grapheme/line counts, dirty/revision state, current selection and navigation targets. View text and token coordinates are Litura graphemes, with server-produced byte offsets for slicing returned UTF-8. Terminal columns are computed only by the client. Syntax queries refresh through the same existing Litura providers and retain their full-parse performance limitation; palette reload does not rebuild syntax trees.

Replies use optional `state`, `buffers`, `view` and `event` fields. A structured `failure` contains `code` and `message`, including `BufferInUse`, `ClientsAttached`, `DirtyBuffer`, `DirtyBuffers`, `BufferNotSelected`, `StaleRevision`, `StaleInteractionRevision` and file errors. Decoded slices belong to that message's arena. The server serializes borrowed engine observations before handling another request; the client copies Lua-visible strings and owning result summaries before freeing their response arena. A view remains borrowed only until the next prepared view or connection teardown.

There is no retry or replay after an editing request is transmitted. A lost reply may follow a committed mutation, so the client exits and restores the terminal on connection loss; it does not spawn a replacement server and replay cached text. Startup may retry a failed `hello` because no document operation has been sent yet. Litura's documented allocation-failure/transaction limits remain unchanged; the hosting protocol does not strengthen them into durable or exactly-once delivery guarantees. It is a junc hosting protocol, not a new editing protocol or complete implementation of Litura's reflective event contract.

## Lua controls and current limits

`editor.buffers()` queries the global roster. `editor.open_file(path)` opens/selects a file, with nil/empty creating scratch. `editor.select_buffer(id)`, `editor.kill_buffer(optional_id, optional_discard)`, `editor.save_as(path)` and `editor.shutdown_server()` perform explicit hosting actions in the current attachment. Mutating controls reject presentation-time use. `editor.state()` additionally exposes the current `buffer_id`, name/path and authoritative document/session metadata. Existing command functions and bindings retain their signatures. Submission summaries include `buffer_id` and pin revision metadata before result observers run, so an observer that switches buffers cannot relabel the completed edit.

Requests and saves are synchronous. Clients refresh in response to coalescible invalidation hints, but do not replay requests after reconnect or persist sessions across server restarts. Undo/redo traverse the shared Litura history, including edits from other clients; per-client selective undo is not implemented. The [Litura causal-model review](litura-multiclient-review.md) explains the remaining event and reconciliation limits.

File changes made outside junc are not automatically reloaded. The viewport cache transfers whole visible lines, including text outside the horizontal viewport, so very long lines and selections can produce large responses. Completion uses the bounded minibuffer display.

Litura updates its stored path and saved revision after a successful write. The host separately commits canonical registry identity after success; subsequent saves always supply that canonical destination. A failed write can still leave partial file contents because saving does not atomically replace the filesystem target. Litura also lacks a public provider-replacement/removal API: saving an already-parsed buffer under a different language extension retains its existing provider until that buffer is killed and reopened. Saving an unparsed scratch buffer under a source extension attaches the appropriate provider normally. Both behaviors are handled in the host without modifying Litura.

## Verification

```sh
zig build
zig build test
zig build check
zig fmt --check build.zig build.zig.zon src tests
python3 tests/daemon_test.py
python3 tests/terminal_support_test.py
python3 tests/daemon_terminal.py
python3 tests/multiclient_test.py
python3 tests/multiclient_terminal.py
python3 tests/paste_terminal.py
```

The process test races ordinary launches, checks per-user endpoint safety and canonical identities, crosses the real idle deadline for clean and dirty detached servers, checks revision rejection and history across attachments, and exercises save/kill/framing/order/shutdown. The PTY test opens several source/scratch buffers, switches with completion, checks exact cursor/selection/viewport restoration, uses the live Lua VM and keymaps, reloads policy, detaches dirty state, attaches a new independent client, and verifies graceful and connection-loss terminal restoration. The existing terminal, syntax, presentation, minibuffer and keymap suites also run against isolated private daemons.

The two-client suites exercise distinct session identities, passive anchor projection, exact document/interaction origin checks, mandatory origins, shared selection replacement and undo, atomic observations, partial senders and backpressure, independent Lua/presentation/reload, idle peer redraw, scrolling to a cursor displaced by a peer's insertion, resize, detach and terminal restoration. They explicitly assert that passive anchor rebasing preserves interaction revisions, including after shared undo.
