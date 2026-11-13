# Litura's causal model in a two-client host

Two terminals can share document text while keeping separate cursors and Lua policy, but an edit in one terminal can invalidate coordinates observed by the other. Junc handles this with one server-owned Litura document per buffer, independent interaction sessions and serialized submissions. Clients query immutable views; the server rejects stale requests, and clients do not speculatively edit local replicas. This review examines what that arrangement establishes and which parts of Litura’s buffer protocol remain unsupported.

## Integration status

junc pins the published Litura commit [`b1b8c5c4700d7df4c0af9d6556c1765b4ea3ab0b`](https://github.com/mariuaas/litura/commit/b1b8c5c4700d7df4c0af9d6556c1765b4ea3ab0b) by immutable archive URL and Zig package hash. The application builds against that fetched package, without a sibling-checkout override.

Main-document edits, in-process commands and native minibuffer replacements share `src/local_document.zig`. It uses `set_selections` with `EditRef` for replacement endpoints and positional targets for navigation. Sessions own their endpoints; lifecycle requests return owned blocks that junc releases after recording the session and cursor identities. No client-side splice planning or endpoint projection remains. The two-client regressions assert that peer edits, undo and redo rebase anchors without advancing interaction revisions. That distinction matters because an unchanged interaction revision does not imply unchanged document coordinates.

## Implemented Litura capabilities

These references describe the pinned [SPEC](https://github.com/mariuaas/litura/blob/b1b8c5c4700d7df4c0af9d6556c1765b4ea3ab0b/docs/buffer-protocol/SPEC.md) and [transaction tests](https://github.com/mariuaas/litura/blob/b1b8c5c4700d7df4c0af9d6556c1765b4ea3ab0b/tests/transaction_test.zig). The named tests provide upstream contract evidence; junc's consumer and PTY tests exercise the integration separately.

| Capability | SPEC contract | Upstream regression evidence |
| --- | --- | --- |
| Exact sequential operation validation and rollback | §1.4 realized splices, §4.1 sequential payload and atomicity, §2.6.1 composite application | “a later operation invalidated by an earlier merge rejects the whole payload”; “rejection restores anchors killed by an earlier operation and drops hidden undo anchors”; “rejection preserves the redo branch and committed text”; “composite interaction positions are validated against the realized text, atomically” |
| Explicit interaction revisions | §2.6: only explicit interaction mutations advance the session revision; passive positions depend on both revision domains | “buffer edits, undo, redo and resurrection never advance interaction revisions”; “explicit interaction mutations advance the interaction revision once”; “position-bearing interaction requests require a current document origin” |
| `set_selections` | Native `InteractionOp.set_selections` replaces session-owned selections, retaining, moving or creating endpoints; revision validation follows §2.6–§2.6.1 | The edit-reference insertion and selection tests exercise the public operation; composite validation rejects invalid realized positions |
| `EditRef` symbolic targets | §2.6.1: reference one buffer operation's start or end; project and rebase internally through later operations; reject invalid/dead references atomically | “edit references place the cursor after inserted text without client-side coordinates”; “edit references replace a selection and select inserted text”; “edit references are carried through later operations in the payload”; “edit reference rejections leave no effect” |

For ordinary replacement junc submits one composite: buffer operation 0 replaces the requested range, followed by `set_selections` moving the existing cursor to `.{ .edit = .{ .op = 0, .edge = .end } }` as a caret, omitting the old mark. Navigation uses a positional target. Litura resolves Unicode contextual resegmentation and projects the inserted endpoint; junc must not calculate a new grapheme coordinate from inserted bytes, standalone grapheme counts or its own splice model.

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

SPEC §6.2 now declares `Reject` and bounded `Rebase` policies explicitly. The pinned engine reports `Reject`; its transaction regression “the declared Reject policy never interprets stale coordinates” tests this contract. Historical rebasing is therefore an unimplemented capability, rather than an ambiguity in junc's supported profile. junc must not reconstruct it from splices or duplicate Unicode segmentation.

Passive anchor rebasing still makes the dual-origin rule essential: B's interaction revision can match after A's insertion even though B's positional coordinates are old. Document origins are now mandatory in Litura's native types as well as junc's wire format. junc checks both origins even for symbolic replacement endpoints, because the replacement range came from an observed document.

### Canonical blocks and client observation

SPEC §7 now has a concrete upstream carrier. `SubmitResult.committed` owns a block with a gapless per-buffer sequence, intent identity, typed source, optional descriptive label, optional edit and all explicit interaction changes. Intrinsic session requests produce lifecycle blocks. Rejections own their report and consume no sequence. `engine.snapshot` includes sessions and the next sequence; provider callbacks borrow each published block and reject reentrant mutations. The regressions in `tests/interaction_test.zig` cover net per-session events, ownership, gapless sequencing, endpoint release and provisional identities.

junc generates a random native identity for each adapter submission, sets the typed source to `.extension = "junc.lua"` and carries the command name in `label`. Its wire `event` remains a compact command summary: a text-plus-interaction transition projects to `edit_event`, and the authoritative snapshot supplies the resulting interaction state. Interaction-only transitions project the issuing session's event; transitions without edit/interaction events report unchanged interaction revisions. An explicit selection request advances its interaction revision even when its selection delta is empty. This projection intentionally does not expose the full block.

The remaining gap is in junc's observation interface. Clients receive coalescible invalidations and query fresh views; they do not receive a retained canonical stream, native identities or sequence-based resumption. Transport request ids still order exchanges only within one connection. A future canonical observer needs a host delivery/retention contract around the upstream blocks, separate from these invalidation hints. The upstream composite-result limitation reported against the earlier pin is resolved.

### Client reconciliation

SPEC §7.2 applies when a client maintains speculative state and an in-flight intent queue. junc keeps neither. Its response is accepted authority followed by refresh, or rejection followed by refresh. A disconnect after transmission can leave the outcome unknown, so junc restores the terminal and exits without replay. This avoids inventing rebasing or exactly-once delivery guarantees; it does not implement or validate the SPEC's speculative reconciliation algorithm. §11's historical-rebasing discussion also identifies information absent from the current event contract for clients that would implement it.

### Allocation-failure guarantees

The pinned engine uses copy-on-write piece-tree transactions: committed nodes remain untouched, and rollback discards candidate nodes and restores anchor state without allocating. Interaction preparation reserves endpoint/session identities and owned blocks before publication. Upstream `tests/allocation_failure_test.zig` and `tests/transaction_test.zig` cover transient and persistent exhaustion, including splits, undo/redo, interaction-only changes, composites and session creation. The previously reported allocating-rollback and tree-insertion hazards are addressed; see the pinned [known issues](https://github.com/mariuaas/litura/blob/b1b8c5c4700d7df4c0af9d6556c1765b4ea3ab0b/docs/known-issues.md) for the current contract and costs.

junc consumes this guarantee rather than implementing rollback itself. Its integration tests do not independently exhaust every allocation point in Litura. Filesystem save atomicity remains separate: a failed synchronous write may leave partial file contents even though the saved revision and stored path stay unchanged.

## Verification boundaries

`tests/server_test.zig` exercises the same registry and submission adapter as the daemon. `tests/minibuffer_test.zig` covers captured origins and wrong-buffer rejection through Lua. `tests/multiclient_test.py` exercises separate real connections, racing requests, passive anchor/selection movement, mandatory origins, coherent observations, partial frames, backpressure, shared lifetimes and shutdown protection. `tests/multiclient_terminal.py` drives two real libvaxis PTYs, including idle invalidation redraw, edits, global undo, independent Lua definitions/themes, reload, resize, peer detach and terminal restoration.

Consumer regressions cover separately entered combining accents, deletion joining clusters, regional-indicator re-pairing, selection replacement, endpoint identity and disposal, explicit no-op interaction revisions, owned rejection summaries, mark clearing and undo/redo. The protocol tests check unchanged interaction revisions during shared undo and redo. Run the build, native and isolated process/PTY workflows in [the daemon guide](daemon.md#verification) against the pinned package; a sibling checkout is not a substitute for that consumer build.

The experiment establishes shared authority and safe observation with explicit stale rejection. It does not establish historical rebasing, client delivery of canonical blocks, speculative reconciliation, distributed collaboration, selective undo or durable storage across server restarts. Upstream block ownership and allocation-failure contracts are broader than what this consumer experiment alone verifies.
