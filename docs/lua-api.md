# Commands and the reflection boundary

Litura owns text, anchors, selections, sessions, revisions, history and persistence. libvaxis owns terminal decoding, capability detection, cell widths and rendering. Zig owns lifetimes, the viewport and a small intent adapter. LuaJIT owns command implementations, keybindings and [presentation policy](presentation.md). The editor and each VM are instance-owned; there is no application-wide mutable editor singleton.

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

`editor.command(name, function(context, input_text))` replaces or registers a command. `editor.bind(key, name)` maps a normalized key name to a command. Unbound text invokes `insert`. The complete built-in registry is in `src/commands.lua`.

The read-only snapshot includes `cursor`, `count`, `mark` (optional), `first`, `last`, `selection` (UTF-8), `revision`, `interaction_revision`, and navigation targets `left`, `right`, `up`, `down`, `home`, `end`, plus `presentation` (the active preset name). Positions are zero-based Litura grapheme offsets, never terminal columns or UTF-8 byte offsets. Vertical navigation preserves the grapheme column where possible; it does not retain a preferred display column across short lines. Rendering separately measures graphemes using the terminal's detected libvaxis width method. There is no bidi layout or soft wrapping.

Commands return nil or a declarative intent table:

- `{kind='replace', start=first, finish=last, text=utf8}` replaces a half-open grapheme range and collapses selection after the inserted text. `editor.replace(context, text, first, last)` supplies selection defaults.
- `{kind='move', position=offset, mark=optional_offset}` submits cursor and selection changes. `editor.move(context, offset, extend)` supplies selection defaults.
- `{kind='undo'}` or `{kind='redo'}` submits Litura history intents.
- `{kind='save'}`, `{kind='quit'}` and `{kind='reload'}` request editor-shell effects. `{kind='presentation', name=preset}` activates a validated Lua presentation without a document mutation.

After a submission, `editor.on_result(result)` receives `kind`, the current `revision` and `interaction_revision`, plus `old_revision` and `new_revision` for successful results, `source` for edits, or `message` for rejection. The default observer stores `editor.last_result`; an extension can replace the observer. Observer failure is reported after the mutation has completed; it does not roll back the mutation. Ordinary and extension commands have identical access to this API. Source strings identify command names rather than the SPEC's typed event sources.

The host validates Lua values and UTF-8, then passes text and interaction intents to `BufferEngine.submit`. A replacement submits one composite: a buffer replacement followed by revision-aware cursor movement and selection clearing. The cursor target comes from Litura’s public contextual splice plan and grapheme iterator, projecting the insertion endpoint forward to a surviving boundary. It is not calculated by adding the standalone inserted-text grapheme count; nor is it necessarily the splice end, which can include right context. Navigation uses interaction submissions with the current session revision. No editing command calls `apply`, `moveAnchor` or a direct selection setter. Native intrinsic anchor/session creation is limited to editor initialization.

Reload constructs a candidate VM, installs the bundled registry and extension, then evaluates the optional external extension and presentation module. All presentation presets and their callbacks are validated before activation. Only successful loading swaps VMs. Document state, anchors, interaction revisions and undo history remain in Litura. Lua-local variables and result observers reset. This is whole-registry replacement, not general module hot reload. Lua has the standard libraries, including FFI, and is trusted code rather than a sandbox. Extension loading should define commands without side effects: only VM replacement is transactional.

## What this establishes, and what it does not

Tests exercise ordinary insertion and an independently defined equivalent insertion, with Lua observing both revision transitions and results. The wrapping extension uses the same replacement mechanism. Other tests cover revision-aware interaction rejection, malformed extension intents, Unicode cluster deletion, and command replacement preserving history.

This establishes a shared public submission path. It does not establish complete conformance with Litura's draft Extension Reflection Principle or protocol. Lua snapshot evaluation happens in the editor, outside `bufferEval`; it is not isolated, fuel-metered evaluation. Extensions cannot intercept pending intents, register guards through this adapter, or subscribe to a canonical event stream. `on_result` observes submissions in this instance only.

At pinned Litura revision `bea86d0df696939eaef75ce84dd8087e15fe958d`:

- Public interaction submission supports revision-checked cursor movement and marks. No API change was needed for this milestone. Its interaction operations differ from the SPEC's full selection/register model.
- `SubmitResult` returns either an edit event, an interaction result or a validation report. A composite containing text and interaction changes returns only the edit event. junc queries the resulting interaction revision for Lua visibility. The smallest useful library addition would be a composite result containing both results.
- There is no general public subscription API exposing unified edit and interaction events with deltas/source/cause. The smallest next addition would be an ordered drainable event queue or observer registration covering both result types, with explicit ownership and delivery semantics. A submission callback in junc cannot substitute for that contract.
- Native validation reports borrow their input intent. junc copies rejection messages into its owned bridge result so the Lua intent can expire safely.
- Litura documents incomplete allocation-failure rollback, including composite/replacement mutation. junc cannot strengthen that guarantee without library work. Constructors also have documented allocation-failure cleanup gaps.
- Litura save is synchronous, copies the document, and writes without atomic filesystem replacement. Save-as updates its stored path before the write succeeds. junc exposes failures in the status line; it inherits these persistence limits.

- Contextual grapheme segmentation, anchor projection and undo operate on realized splices. Consumer tests cover separately entered combining accents, deletion joining clusters, and cursor placement inside a splice that re-pairs regional indicators. Litura owns all document mutation and rebasing; junc only predicts the post-edit cursor for its interaction intent.
- Litura still documents approximate multi-operation length preflight: a later operation can pass validation and then fail after an earlier operation changes segmentation. junc currently submits one buffer operation per editing command and computes its cursor from the actual splice plan. This does not establish general multi-operation transaction safety.

The pinned libvaxis SIGWINCH callback calls blocking Io operations inside a signal handler. A PTY resize check hung with the registered callback. junc disables that handler and polls `Tty.getWinsize` on its main thread at idle intervals of 16 ms, while still processing libvaxis resize events. Idle frames do not redraw unless needed.

Neither Litura nor Substrate is modified. Substrate informed the LuaJIT C-API embedding and native static build, without importing its application runtime.
