# junc

```
          :         L.                   .,
 ittttttttEf   ,ft  EW:        ,ft      ,Wt
 fDDK##DDiE#t  t#E  E##;       t#E     i#D.
    t#E   E#t  t#E  E###t      t#E    f#f
    t#E   E#t  t#E  E#fE#f     t#E  .D#i
    t#E   E#t  t#E  E#t D#G    t#E :KW,
    t#E   E#t  t#E  E#t  f#E.  t#E t#f
    t#E   E#t  t#E  E#t   t#K: t#E  ;#G
  jfL#E   E#t f#E:  E#t    ;#W,t#E   :KE.
  :K##E   E###f     E#t     :K#D#E    .DW:
    G#E   E#K,      E#t      .E##E      L#,
     tE   EL        ..         G#E       jt
      .   :                     fE
                                 ,
```

*A lightweight editor stitched together from pieces.*

A small, Lua-programmable terminal editor built with Zig 0.16.0, Litura, libvaxis and LuaJIT. One document, one visible surface, and a few pieces that fit together.

```sh
git clone https://github.com/mariuaas/junc.git
cd junc
zig build
zig build run -- path/to/file.txt
# Or ./zig-out/bin/junc for a scratch document.
zig build test
zig build check
zig fmt --check build.zig build.zig.zon src tests
```

The build fetches pinned source dependencies and builds LuaJIT in the build cache using `make` and a native C compiler. macOS arm64 with Zig 0.16.0 is the verified platform; cross compilation is not supported by the LuaJIT build step. Neither a sibling checkout nor a system LuaJIT installation is needed. libvaxis is pinned to `c0e8b09ba45af47722f0b6f211e18221b51493f2`, before its Zig 0.17 migration.

Arrow keys move; Home/End move within a line. Shift plus those keys extends the selection, and Ctrl-A selects all. Type to replace the selection. Backspace, Delete, Enter and Tab edit. The viewport follows the cursor vertically and horizontally; tabs use four-cell stops. The status line reports document and interaction revisions.

| Key | Command |
| --- | --- |
| Ctrl-S | Save (scratch saves to `scratch.txt` in the working directory) |
| Ctrl-Q | Quit; repeat if unsaved changes need discarding |
| Ctrl-Z / Ctrl-Y | Undo / redo |
| Ctrl-W | Wrap the selection in parentheses |
| Ctrl-P | Switch between the Lua Classic and Minimal presentations |
| Ctrl-R | Reload commands and presentation from the working directory |

The bundled commands, wrapping extension and presentation are embedded in the executable. Edit [lua/extension.lua](lua/extension.lua) or [lua/presentation.lua](lua/presentation.lua), then press Ctrl-R to replace them without closing the document. A failed reload retains the previous VM, commands and presentation. The presentation file is also loaded at startup when present; external command extensions retain their existing load-on-reload behavior. The extension function can replace built-in commands and keybindings as well as add its own. There is one insert mode; richer modes can be implemented in Lua.

Classic uses line numbers and terminal-derived colors; Minimal removes the gutter and uses a quiet green theme with a compact status line. Themes, status functions, gutter visibility and preset switching are ordinary Lua policy. See [the presentation interface](docs/presentation.md).

For repeatable real-terminal checks after building, run `python3 tests/terminal.py` and `python3 tests/presentation_terminal.py` outside a sandbox that denies `/dev/tty`. It uses a controlling PTY, drives actual key input and rendering, checks saved Unicode text, reloads an extension, resizes the terminal, and checks terminal restoration.

Litura keeps Unicode grapheme boundaries correct across edits, including combining accents entered separately. junc uses its contextual splice plan to place the cursor after edits that join neighboring clusters.

The implementation deliberately has no splits, project tree, daemon, IPC or plugin lifecycle. See [the Lua API and reflection boundary](docs/lua-api.md) for the submission mechanism and current Litura limitations. Source follows [Litura's style guide](https://github.com/mariuaas/litura/blob/bea86d0df696939eaef75ce84dd8087e15fe958d/docs/STYLE_GUIDE.md).
