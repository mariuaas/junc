# Commands and the reflection boundary

A Lua command reads a snapshot and returns an intent describing what to change. Zig validates that intent and submits it to Litura, so built-in and extension commands share the same editing path. Litura owns text, anchors, selections, sessions, revisions, history and persistence; Lua supplies command implementations, keybindings and [presentation policy](presentation.md).

The [local server](daemon.md) hosts the global document registry and main-document interaction sessions. Each terminal client owns its LuaJIT VM, viewport and minibuffer, and retains immutable views queried from the server. libvaxis handles terminal decoding, capability detection, cell widths and rendering.

## Lua command API

An extension file returns a function accepting `editor`:

```lua
return function(editor)
  editor.command('wrap', function(context)
    return editor.replace(context, '(' .. context.selection .. ')')
  end)
  editor.bind('ctrl-w', 'wrap')
end
```

`editor.command(name, function(context, input_text), optional_metadata)` replaces or registers a command. Metadata accepts optional string `description` and `category` fields. `editor.bind(sequence, name)` installs a global binding in the layered [keymap resolver](keymaps.md); nil removes it. `editor.keymap` defines named tries, and `push_keymap`, `pop_keymap` and `set_context_keymap` select layers. Prefix, shadowing and introspection semantics are documented there. Unbound printable input invokes `insert`; incomplete and invalid sequences consume input without insertion. The complete built-in registry is in `src/commands.lua`.

The read-only snapshot includes `selections` (one observation per Litura selection), `surface` (`document` or `minibuffer`), `cursor`, `count`, `mark` (optional), `first`, `last`, `selection` (UTF-8), `revision` and `interaction_revision`. It also contains navigation targets (`left`, `right`, `up`, `down`, `home`, `end`, `page_up`, `page_down`), the matching viewport origins `page_up_top` and `page_down_top`, `presentation` (the active preset name), and authoritative buffer/session metadata such as `buffer_id`, `name` and optional canonical `path`. Positions are zero-based Litura grapheme offsets, never terminal columns or UTF-8 byte offsets. Vertical navigation preserves the grapheme column where possible; it does not retain a preferred display column across short lines. Page commands call `editor.scroll(top)` so the window moves a screenful; follow-scroll alone would only nudge far enough to keep the cursor visible. Rendering separately measures graphemes using the terminal's detected libvaxis width method. There is no bidi layout or soft wrapping.

Bracketed paste invokes the Lua `paste` command once on the focused document or minibuffer. The default command replaces the selection, normalizes CRLF and CR line endings to LF, and clears any pending key prefix. Pasted tabs, newlines and control bytes are text, so they cannot trigger bindings or submit a minibuffer prompt. Empty paste does nothing. You can redefine `paste` through the ordinary command registry; its edits use the same revision-checked submission path as typing.

The terminal reader enables bracketed-paste mode and collects its payload before asking Lua to edit. It uses libvaxis's parser and capability handling for ordinary terminal events, while paste bytes bypass key decoding and enter the document in one transaction. An unfinished paste is discarded on disconnect; no partial edits are submitted. Terminals that do not send bracketed paste retain ordinary key handling. Syntax providers still perform their existing synchronous refresh after the edit, rather than once per pasted character.

Commands return nil or a declarative intent table:

- `{kind='replace', start=first, finish=last, text=utf8}` replaces a half-open grapheme range and collapses selection after the inserted text. `editor.replace(context, text, first, last)` supplies selection defaults.
- `{kind='move', position=offset, mark=optional_offset}` submits cursor and selection changes. `editor.move(context, offset, extend)` supplies selection defaults.
- `{kind='undo'}` or `{kind='redo'}` submits Litura history intents.
- `{kind='save'}`, `{kind='quit'}` and `{kind='reload'}` request editor-shell effects. The raw `save` intent requires an associated filename; the Lua `save` command opens the `save-as` prompt for an unnamed buffer. `{kind='presentation', name=preset}` activates a validated Lua presentation without a document mutation.

After a submission, `editor.on_result(result)` receives `surface`, `buffer_id`, `kind`, the current `revision` and `interaction_revision`, plus `old_revision` and `new_revision` for successful results, `source` for edits, or `message` for rejection. Submission summaries capture the affected buffer and revision before the observer runs, so switching buffers in an observer cannot relabel the completed edit. The default observer stores `editor.last_result`; an extension can replace the observer. Observer failure is reported after the mutation has completed; it does not roll back the mutation. Ordinary and extension commands have identical access to this API. Source strings identify command names rather than the SPEC's typed event sources.

Intent helpers preserve the `buffer_id`, document `origin` and `interaction_origin` of their context. Dispatch supplies missing stamps from the invocation snapshot for compatibility with hand-written intents; it never overwrites supplied stamps. Reusing a captured old context therefore rejects with `StaleRevision` rather than applying its old coordinates at the current revision. An intent for a different buffer rejects with `BufferChanged`.

The client validates Lua intent values and UTF-8, then sends the main-document intent with buffer identity and both revision origins to the server. The server realizes it through `BufferEngine.submit`; minibuffer editing uses that same adapter locally. A replacement submits one composite: buffer operation 0 replaces the range, followed by `set_selections` moving the retained cursor endpoint to its symbolic `EditRef` end and clearing the mark. Litura resolves and projects that endpoint through contextual Unicode resegmentation. Navigation uses positional `set_selections` with both document and interaction origins. Peer edits passively rebase cursor/mark anchors without advancing this session’s interaction revision; a matching interaction revision alone cannot validate old document coordinates. No editing command calls `apply`, `moveAnchor` or a direct selection setter. Native intrinsic anchor/session creation and teardown are limited to local input initialization and host attachment/buffer lifetimes.

Reload constructs a candidate VM, installs the bundled registry and extension, then evaluates the optional external extension and presentation module. All presentation presets and their callbacks are validated before activation. Only successful loading swaps VMs. Document state, anchors, interaction revisions and undo history remain in the same server-owned Litura buffers. Lua-local variables and result observers reset. The persistent minibuffer document/session and native histories also survive; a generic prompt is cancelled when its VM-owned callback is replaced. Reload replaces the whole registry; it does not reload individual modules. Lua has the standard libraries, including FFI. Extension loading should define commands without external side effects, since discarding a failed candidate VM cannot undo those effects.

## Live runtime facade

The [minibuffer and REPL](minibuffer.md) use this registry directly. `editor.command_names(optional_prefix)` returns sorted active names. `editor.command_info(name)` returns metadata and current bindings. `editor.invoke(name, optional_text)` uses the same execution and submission bridge as key dispatch, targeting the main document. `editor.state()` returns a copied main-document command snapshot. `editor.scroll(top)` sets this client's document viewport origin during an explicit command; presentation callbacks cannot call it. `editor.input_action(action)` performs a Lua-selected minibuffer control action while input is focused; its context map supplies the bindings. `editor.output(value)` writes to the output history and, outside an active prompt, the status message. `editor.buffers()`, `open_file`, `select_buffer`, `kill_buffer`, `save_as` and `shutdown_server` expose the [explicit hosting controls](daemon.md). `editor.prompt{label, history, initial, complete, submit}` opens a generic input context with optional prefix completion and a required submit callback.

Ordinary input editing uses the same Lua command implementations against a separate Litura document/session. Native completion and history replacements submit revision-aware composite intents. The `surface` field distinguishes the two revision domains in command snapshots and result observers. Temporary REPL maps, activations, commands, bindings and globals live in the active VM and reset on successful whole-VM reload. Reload requested from a running Lua callback is deferred until it returns. Presentation callbacks cannot call the native mutation bridge.

## Submission coverage and reflection limits

Tests exercise ordinary insertion and an independently defined equivalent insertion, with Lua observing both revision transitions and results. The wrapping extension uses the same replacement mechanism. Other tests cover revision-aware interaction rejection, malformed extension intents, Unicode cluster deletion, and command replacement preserving history.

These tests exercise the shared public submission path for local input and hosted main-document edits. Complete conformance with Litura’s draft Extension Reflection Principle requires additional mechanisms. Lua snapshot evaluation happens in the editor, outside `bufferEval`; it is not isolated, fuel-metered evaluation. Extensions cannot intercept pending intents, register guards through this adapter, or subscribe to a canonical event stream. `on_result` observes command-adapter submissions in this instance only. Native input replacement for opening contexts, history and completion also submits to Litura, but does not call this command observer.

At pinned Litura revision `b1b8c5c4700d7df4c0af9d6556c1765b4ea3ab0b`:

- Sessions own selection endpoints. The adapter retains the active cursor identity, reuses the fixed endpoint while extending a selection, and lets Litura release omitted endpoints when collapsing it. Replacement positions use symbolic edit references; no client-side grapheme projection is involved.
- Every native request has an opaque 128-bit identity. The adapter generates it at submission, records `.extension = "junc.lua"` as the typed source, and uses the Lua command name as the descriptive label. These identities correlate native results; they do not promise deduplication or exactly-once execution.
- Native submissions return an owned canonical block or an owned rejection. A transition includes its optional edit and all explicit interaction changes. junc deliberately projects that block into its existing compact `edit_event` or `interaction_result` summary and queries authoritative state. A transition without edit/interaction events reports unchanged interaction revisions; an explicit selection request advances its interaction revision even when its positional delta is empty. `on_result` is still a command observer, not a canonical event subscription.
- Litura exposes ordered blocks through submission results and provider callbacks, plus a snapshot with the next sequence. junc does not forward or retain this stream for clients. Its invalidation hints remain coalescible hosting signals.
- Document and interaction origins are mandatory upstream as well as on junc's wire. Litura declares stale-coordinate rejection; junc preserves captured origins and never silently retries.
- Upstream transactions use copy-on-write tree rollback and prepare interaction changes and owned results before publication. Allocation-failure tests cover persistent exhaustion, undo/redo and composites. junc relies on that contract; it does not implement a second transaction layer.
- Save remains synchronous, copies the document and does not atomically replace the filesystem target. Failed writes may leave partial file contents; stored path and saved revision update only after success.

See [the two-client causal-model review](litura-multiclient-review.md) for the distinction between upstream canonical blocks, junc's command summaries and client invalidation.

For cursor-set commands, use `editor.each(context, function(one) ... end)` to return one per-cursor `replace` or `move` intent as a single batch. The `one` context carries that selection’s grapheme positions, active/fixed anchor identities, selection text and navigation targets, plus the parent’s revision and buffer origins. Returning nil keeps that cursor unchanged. `editor.replace(context, text)` with default bounds applies to every selection; explicit bounds retain legacy primary-only behavior. Raw legacy `replace` and `move` intents preserve all other selections. See [multiple cursors](multicursor.md) for the request shapes and collision policy.
