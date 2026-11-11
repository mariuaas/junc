# Live presentation

Edit `lua/presentation.lua` in junc's working directory, then press Ctrl-R. Ctrl-P switches between the shipped Classic and Minimal presets. Neither action reopens the document or terminal. The executable embeds a fallback copy, so it also works without a Lua directory.

Classic uses terminal-default text colors, a numbered gutter, a distinct selection, a cell cursor and a detailed status line. Minimal hides the gutter, uses an explicit green palette, and supplies a compact status function. Both use the same interface; Zig contains no Classic/Minimal rendering branches. Preset names are open strings.

## Interface

The module returns a plain table with `default`, `next(name)` and `presets`. Each entry in `presets` is a plain table with:

| Field | Contract |
| --- | --- |
| `theme(terminal)` | Returns a plain table containing the ten colors below |
| `gutter` | Plain table with boolean `visible` and `line_numbers` |
| `minibuffer` | Optional plain table with `fg`, `bg`, `prompt_fg` and `output_fg` colors |
| `syntax` | Optional table of Litura token-group styles; see [syntax highlighting](syntax.md) |
| `status_visible` | Boolean; false releases the status row to the document |
| `status(state)` | Returns one UTF-8 line, at most 4096 bytes, without control characters |

`default` names an existing preset. `next(name)` returns an existing preset name; the bundled Ctrl-P command uses it. The active name survives reload, so a replacement module must still define that name. Names contain 1–63 bytes of printable UTF-8. Metatables on configuration tables are rejected.

The theme fields are `fg`, `bg`, `selection_fg`, `selection_bg`, `cursor_fg`, `cursor_bg`, `gutter_fg`, `gutter_bg`, `status_fg` and `status_bg`. Each color is `"default"`, an integer palette index from 0 through 255, or an RGB string such as `"#b8ce9a"`.

Minibuffer colors use the same color representation. Missing foreground/background inherit ordinary text colors; prompt/output foregrounds inherit the gutter foreground. Selection and cursor retain their normal theme roles. The table is validated in every preset during the same reload transaction. Zig reserves up to three rows only while input is focused; Lua supplies colors without controlling cell layout. See [input contexts and the live REPL](minibuffer.md).

For example, change a shipped preset's `status` function to:

```lua
status = function(s)
  return string.format(' %s%s | %d:%d | %s',
    s.path, s.dirty and ' *' or '', s.line, s.column, s.message)
end,
```

The status snapshot includes `path`, `message`, `dirty`, `cursor`, optional `mark`, one-based `line` and `column`, grapheme `count`, `lines`, `revision`, `interaction_revision`, `preset`, terminal `width` and `height`, and zero-based viewport `top` (line) and `left` (cell). Document positions and columns are Litura graphemes. The viewport's horizontal offset is terminal cells. These are copied observations, not document handles.

## Terminal colors

`theme` receives `terminal.foreground`, `terminal.background` and zero-indexed `terminal.palette[0]` through `[15]`. Values use the same color representation. Before replies arrive, foreground/background are `"default"` and palette entries are their numeric indices. Classic therefore blends with an ordinary terminal even when it reports no RGB values. Explicit colors, as in Minimal, are equally supported.

junc uses libvaxis `queryColor` and `color_report` for OSC 10 (foreground), OSC 11 (background) and OSC 4 (the first sixteen palette entries). These are standard [xterm color-query protocols](https://invisible-island.net/xterm/ctlseqs/ctlseqs.html#h3-Operating-System-Commands), independent of TUIOS. Queries are asynchronous and never gate editing. Late reports update the terminal snapshot and trigger a newly validated frame. Queries are issued at startup; automatic re-query on an OS theme change is not implemented. Terminal or multiplexer support can vary; unanswered queries require no timeout recovery.

libvaxis's `NO_COLOR` handling remains in effect. In that case, selection and cursor use inverse cells so editing remains visible. The cursor is a software cell cursor; junc does not change global terminal foreground, background, palette or cursor colors. libvaxis restores cursor visibility and the alternate screen on exit.

## Replacement and ownership

Ctrl-R uses the existing whole-VM reload transaction. A candidate VM loads the bundled command registry, extension and presentation, applies `lua/extension.lua` if present, and replaces the presentation with `lua/presentation.lua` if present. Every preset's theme, gutter, status callback and switch target is validated against the current terminal/editor snapshot. Only then are the VM and copied native presentation frame activated together. Startup loads the presentation file without changing the previous command-extension startup behavior.

Syntax errors, invalid values, missing callbacks and callback errors retain the previous VM, commands and frame. Callbacks are also protected and validated during rendering; a later failure retains the last complete frame and records a diagnostic in the editor message. Validation cannot prove arbitrary Lua functions correct for every future state. Callbacks should be pure; Lua is trusted code with standard libraries, and external side effects cannot be rolled back.

Document text, revisions, sessions, anchors, selection and undo history remain owned by the same Litura instance. The Surface and terminal also survive reload. Viewport offsets are retained; normal visibility adjustment can still scroll when a changed gutter or status row reduces the space available for the cursor. Lua-local variables reset with the VM, as in command reload.

Zig continues to own cell layout, width measurement, clipping, tab stops, scroll mapping and terminal lifetimes. Presentation code does not receive libvaxis objects, and native mutation callbacks reject calls outside explicit command evaluation. The interface describes semantic roles rather than native cells: future decorations or additional visual regions can add declarative fields without exposing terminal internals. The current regions are document, gutter, status and the focused minibuffer.

## Verification

`zig build test` covers defaults, reported colors, preset switching, successful replacement, malformed modules (including inactive presets), and late callback failure. It checks document/session/selection/viewport/history preservation. `python3 tests/presentation_terminal.py` drives a real PTY, rewrites theme and status code while open, checks emitted RGB colors and status state, switches the gutter, rejects failed reloads, performs undo, resizes and verifies terminal restoration. It supplies color-query replies; the existing `tests/terminal.py` exercises unanswered queries and ordinary editing.
