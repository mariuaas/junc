# Multiple cursors

An editing session can hold several selections. Typing, paste, Backspace, Delete, Enter and ordinary navigation act on the set; text edits become one Litura composite and one shared undo step. Other terminal clients keep their own selection sets.

| Key | Command | Behaviour |
| --- | --- | --- |
| Ctrl-X Up | `cursor-add-above` | Add a caret at the same grapheme column on the preceding line |
| Ctrl-X Down | `cursor-add-below` | Add a caret at the same grapheme column on the following line |
| Ctrl-X d | `cursor-add-next` | Select the word at point, or add the next exact occurrence of the primary selection |
| Ctrl-X 1 | `cursor-single` | Retain only the primary selection |
| Ctrl-X h | `select-all` | Replace the set with one whole-document selection |

These commands are also available through M-x and the live Lua registry. The minibuffer remains a single input surface; adding document cursors while it has focus is unavailable.

Adding above or below extends from every current cursor, clamps at line boundaries and skips positions already occupied. Next-match uses Litura's word-span and byte-exact grapheme search APIs. The first invocation at a caret selects the word; subsequent invocations add matching selections, wrapping once and skipping ranges already selected. An exhausted search reports `NoFurtherMatch` without changing the set. Matching does not normalize Unicode representations or interpret a regular expression.

The first selection retains the primary cursor's identity. It controls viewport following and the scalar `cursor`, `mark` and `selection` fields kept for older Lua commands. Other carets use the same theme colors with bold and underline; all selections remain visible above syntax styling. Cursor count appears in both presentation presets. Cell width and clipping still belong to the libvaxis renderer, while every position in a selection is a Litura grapheme offset.

## Lua commands

`editor.state().selections` and command contexts expose an ordered array. Each entry contains `cursor_anchor`, optional `mark_anchor`, `cursor`, optional `mark`, sorted `first`/`last`, selected UTF-8 `selection`, zero-based `line`/`col`, and `left`, `right`, `up`, `down`, `home` and `end` targets. Those are copied observations of the session, not native document handles.

Use `editor.each` when the replacement depends on each selection:

```lua
editor.command('bracket-each', function(c)
  return editor.each(c, function(one)
    return editor.replace(one, '[' .. one.selection .. ']')
  end)
end)
```

Returning nil from a per-cursor callback keeps that cursor unchanged. The shipped wrapping extension uses this API too. `editor.replace(c, text)` with default bounds applies the same text to every selection. Explicit bounds, or raw legacy `replace`/`move` intents, act only on the primary cursor and preserve the others.

A `batch` intent contains `edits`, one action per observed cursor. Each action has its `cursor_anchor` and a `kind`: `replace` with `start`, `finish`, `text`; `move` with `position` and optional `mark`; or `keep`. A `selections` intent replaces the list using `move`/`keep` entries; `cursor_anchor=0` creates a new endpoint. The primary cursor must appear first and cannot be dropped. Both request forms retain the usual buffer identity and document/interaction origins. Invalid ownership, duplicate identities, incomplete batches and stale observations reject before mutation.

Navigation uses one `set_selections` submission, collapsing coincident cursor/mark pairs. Page commands apply the primary page target's grapheme displacement to the other cursors; there is no persistent preferred display column. Successful and failed Lua reloads leave native selections alive; temporary Lua definitions follow the existing whole-VM reload policy. Switching buffers restores the complete session set, while detaching releases it.

## Editing order and collisions

The host sorts replacement operations from higher to lower document positions, keeping selection order unchanged. It submits those buffer operations followed by one `set_selections` operation. Each edited cursor targets its operation's symbolic `EditRef` end. Litura resolves Unicode resegmentation and carries those targets through later operations; junc does not calculate post-edit cursor offsets.

Identical range/text edits run once. Touching or overlapping deletions merge into one deletion and one retained caret, preferring the primary identity. Other touching or overlapping replacements reject with `OverlappingEdits`; a batch mixing replacements with explicit positional moves rejects with `MixedCursorActions`. An unchanged cursor uses `keep`, so Litura can rebase it passively through the text edits.

The restriction on touching replacements is deliberate. Litura's buffer-operation coordinates describe the text immediately before each operation, rather than simultaneous ranges at the request origin. For example, in `e\ń`, deleting the newline first joins `e` and its accent. Replacing the original preceding `[0,1)` afterwards would also consume the accent. Descending order alone cannot preserve the original ranges in this case. Supporting arbitrary touching replacements needs an upstream mechanism for resolving origin-based ranges inside one transaction, or another explicit simultaneous-edit contract. `EditRef` solves resulting cursor placement, not this range problem. This is an API extension question, not evidence that Litura violates its sequential-operation contract.

Allocation or semantic failure before publication leaves the cursor-set edit unapplied. A response allocation can fail after publication, as with any hosted edit; junc never retries it. Consumer allocation-failure tests check that neither path leaves only one cursor's portion applied.

## Verification

Run `zig build test` for Unicode edits, one-step undo, selection replacement, endpoint identity, collision handling, stale/foreign requests, live Lua changes, many-cursor batches, allocation failure and cell rendering. After `zig build`, run `python3 tests/multicursor_terminal.py` for real prefix input, secondary caret styling, two clients, Unicode, resize, reload and terminal restoration.

The hosting protocol is version 4. Save buffers before stopping an older server, then start the rebuilt executable; clients deliberately refuse incompatible servers.
