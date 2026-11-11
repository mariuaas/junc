# Litura's causal model in a two-client host

Two terminals can share document text while keeping separate cursors and Lua policy, but an edit in one terminal can invalidate coordinates observed by the other. Junc handles this with one server-owned Litura document per buffer, independent interaction sessions and serialized submissions. Clients query immutable views; the server rejects stale requests, and clients do not speculatively edit local replicas. This review examines what that arrangement establishes and which parts of Litura’s buffer protocol remain unsupported.

## Integration status

junc pins the published Litura commit [`4864521859c7106f89326d9936c3d0a17dff1e35`](https://github.com/mariuaas/litura/commit/4864521859c7106f89326d9936c3d0a17dff1e35) by immutable archive URL and Zig package hash. The application builds against that fetched package, without a sibling-checkout override.

Main-document edits, in-process commands and native minibuffer replacements share `src/local_document.zig`. It uses `place_cursor` with `EditRef` for replacement endpoints and positional targets for navigation. No client-side splice planning or endpoint projection remains. The two-client regressions assert that peer edits, undo and redo rebase anchors without advancing interaction revisions. That distinction matters because an unchanged interaction revision does not imply unchanged document coordinates.

## Implemented Litura capabilities

These references describe the pinned [SPEC](https://github.com/mariuaas/litura/blob/4864521859c7106f89326d9936c3d0a17dff1e35/docs/buffer-protocol/SPEC.md) and [transaction tests](https://github.com/mariuaas/litura/blob/4864521859c7106f89326d9936c3d0a17dff1e35/tests/transaction_test.zig). The named tests provide upstream contract evidence; junc's consumer and PTY tests exercise the integration separately.

| Capability | SPEC contract | Upstream regression evidence |
| --- | --- | --- |
| Exact sequential operation validation and rollback | §1.4 realized splices, §4.1 sequential payload and atomicity, §2.6.1 composite application | “a later operation invalidated by an earlier merge rejects the whole payload”; “rejection restores anchors killed by an earlier operation and drops hidden undo anchors”; “rejection preserves the redo branch and committed text”; “composite interaction positions are validated against the realized text, atomically” |
| Explicit interaction revisions | §2.6: only explicit interaction mutations advance the session revision; passive positions depend on both revision domains | “buffer edits, undo, redo and resurrection never advance interaction revisions”; “explicit interaction mutations advance the interaction revision once”; “position-bearing interaction requests require a current document origin” |
| `place_cursor` | Native `InteractionOp.place_cursor` combines cursor placement and an optional mark; revision validation follows §2.6–§2.6.1 | The edit-reference insertion and selection tests exercise the public operation; composite validation rejects invalid realized positions |
| `EditRef` symbolic targets | §2.6.1: reference one buffer operation's start or end; project and rebase internally through later operations; reject invalid/dead references atomically | “edit references place the cursor after inserted text without client-side coordinates”; “edit references replace a selection and select inserted text”; “edit references are carried through later operations in the payload”; “edit reference rejections leave no effect” |

For ordinary replacement junc submits one composite: buffer operation 0 replaces the requested range, followed by `place_cursor` with `at = .{ .edit = .{ .op = 0, .edge = .end } }` and no mark. Navigation uses a positional target. Litura resolves Unicode contextual resegmentation and projects the inserted endpoint; junc must not calculate a new grapheme coordinate from inserted bytes, standalone grapheme counts or its own splice model.

The symbolic target addresses the result of this transaction. The replacement range is still calculated from an observed revision, so the document origin remains mandatory. Symbolic positioning cannot make an old edit range current.

## What the host establishes

Each attachment has a separate cursor/session for each visited buffer. Selecting the same canonical file deduplicates the document, history and dirty state. Returning to a visited buffer restores that attachment's session and viewport. Lua command implementations, keymaps, minibuffer, theme and reload lifetime remain client-owned. Closing one terminal drops only its interaction resources. Undo/redo operate on the shared history, including another client's latest edit; selective per-client undo is not implemented.

Every edit, including an extension-defined command, reaches the same `BufferEngine.submit` adapter. The host requires both document and interaction origins and binds requests to the connection's selected buffer and session. It rejects unsupported stale positions, returns the current authoritative snapshot and never replays the rejected input. Two racing submissions from the same document revision can therefore produce one commit and one explicit stale rejection. The user sees the rejection and can issue a new command against the refreshed view.

`observe` obtains a session snapshot, visible text, grapheme boundaries and syntax spans during one serialized host operation. The response's state and view have the same document revision. Rendering may display an older immutable observation while another client commits, but it never combines a new selection snapshot with old text as though they were one revision. Any subsequent command retains the origin of the observation it used.

A Lua command can retain a context and use it after another edit. Its helpers therefore preserve `buffer_id`, `origin` and `interaction_origin`; dispatch fills only absent fields. Otherwise, dispatch could stamp old coordinates with the current invocation revision and make a stale request appear valid. The captured-context regression checks that wrong-buffer and stale-context requests reject before mutation.

The host's `generation` counter and id-0 invalidation hints are coalescible cache signals. They contain no text operations, canonical event cause or interaction deltas. An unsent hint can replace several hints; a partly sent view is never rewritten. The client refreshes from authority rather than replaying hints. This keeps observation invalidation distinct from the lossless canonical events required by §7.

## Remaining protocol questions

### Historical coordinate rebasing

`EditRef` resolves positions produced within a transaction. It does not project coordinates observed before that transaction. For example, B observes `ab` at revision 0 and prepares replacement `[1,2)`. A inserts `X` at 0. B's request still has origin 0 and must not replace the current `[1,2)` (`a`). junc returns `StaleRevision` and does not retry at revision 1.

SPEC §6.2 describes rebasing positional requests over `origin..head`, while §11 item 11 explicitly leaves the mechanism open and permits rejection of stale positional intents. Those sections need one consistent capability/profile statement before stabilization. Litura does not presently provide historical position projection to this host. The smallest upstream improvement would be to specify the stale-rejection profile explicitly; supporting rebasing additionally needs retained realized-splice context and an authoritative origin-to-head projection API. junc should not reconstruct it from `affected_ranges` or duplicate Unicode segmentation.

Passive anchor rebasing makes the dual-origin rule essential: B's interaction revision may still match after A's insertion even though every positional coordinate B observed is old. The native Litura intent permits an omitted document origin, interpreted at head. junc's wire type makes it mandatory and preserves it through Lua helpers; this stricter hosting rule does not change the upstream optional-origin contract.

### Canonical event subscriptions and acknowledgments

SPEC §2.6.2 and §7 require a unified ordered stream of edit and interaction events, with a composite's contiguous edit-then-interaction block. §7.1 additionally requires typed cause/provenance and acknowledgments tied to intent identity. The native submission result returns either an edit event, an interaction result or a validation report; a buffer-plus-interaction composite exposes only the edit result. The host queries the session revision after submission. That is useful observability, but does not expose the complete canonical event block.

There is no general public canonical subscription API used by this experiment. Provider refresh callbacks do not substitute for it. junc's wire `event` is a compact submission summary, and its request ids order exchanges within one connection; neither is the SPEC's typed transaction-cause stream. The smallest upstream mechanism needed for a conforming observer is a public subscription/drain interface exposing each committed canonical event block, including its interaction event and causal identity, with explicit ownership and delivery behavior. Coalescing belongs only to junc's view invalidations.

### Client reconciliation

SPEC §7.2 applies when a client maintains speculative state and an in-flight intent queue. junc keeps neither. Its response is accepted authority followed by refresh, or rejection followed by refresh. A disconnect after transmission can leave the outcome unknown, so junc restores the terminal and exits without replay. This avoids inventing rebasing or exactly-once delivery guarantees; it does not implement or validate the SPEC's speculative reconciliation algorithm. §11's historical-rebasing discussion also identifies information absent from the current event contract for clients that would implement it.

### Allocation-failure guarantees

Exact semantic rejection rollback is implemented upstream. The pinned commit also reserves history entries, provider-notification sets and mark anchors before commit. Its test “a transient allocation failure anywhere in a composite leaves no observable effect” injects one failing allocation at each allocation point in a representative composite, checking text, revisions, anchors and history. These reservations close the previously identified post-commit allocation windows.

Complete allocation-failure atomicity is still not established. The pinned [known issues](https://github.com/mariuaas/litura/blob/4864521859c7106f89326d9936c3d0a17dff1e35/docs/known-issues.md) identify two transaction hazards: piece-tree insertion can allocate after removing the old range, and inverse rollback itself allocates. The transient-failure composite test explicitly does not exercise that tree-insertion window. The undo/redo injection test in `tests/transaction_test.zig` is explicitly skipped pending its repair. Persistent exhaustion can prevent rollback from restoring consistency. Constructor cleanup, history error recovery and provider destruction retain additional documented allocation-failure concerns.

The host checks actual document revisions after a submission even if it returns an error, and invalidates peers if authority advanced. That avoids relying on an error alone as proof of no commit. It cannot repair an internally inconsistent engine after a failed rollback, especially when the revision did not advance. The smallest upstream correction is reserving piece-tree node capacity, including splits, before mutation, followed by enabling the skipped undo/redo injection test and making rollback reliable under exhaustion. A competing junc transaction layer would obscure the defect.

## Verification boundaries

`tests/server_test.zig` exercises the same registry and submission adapter as the daemon. `tests/minibuffer_test.zig` covers captured origins and wrong-buffer rejection through Lua. `tests/multiclient_test.py` exercises separate real connections, racing requests, passive anchor/selection movement, mandatory origins, coherent observations, partial frames, backpressure, shared lifetimes and shutdown protection. `tests/multiclient_terminal.py` drives two real libvaxis PTYs, including idle invalidation redraw, edits, global undo, independent Lua definitions/themes, reload, resize, peer detach and terminal restoration.

In the recorded integration run on macOS arm64 with Zig 0.16.0 against the published package, `zig build`, `zig build check`, formatting and all 49 native tests passed. The parser-disabled test/check configuration passed with 46 tests and three syntax-dependent skips. All five two-client protocol tests, the daemon lifecycle suite and all seven PTY scripts passed, including the simultaneous two-client scenario. Native replacement tests cover separately entered combining accents, deletion joining clusters, regional-indicator re-pairing, selection replacement, mark clearing and undo/redo. The protocol tests check unchanged interaction revisions during both shared undo and redo.

The experiment establishes shared authority and safe observation with explicit stale rejection. It does not establish historical rebasing, canonical event subscriptions, speculative reconciliation, distributed collaboration, selective undo, durable storage or complete allocation-failure atomicity. Consumer tests retain document-origin checks even when interaction revisions match, and symbolic cursor placement does not weaken that requirement.
