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

A small terminal editor for people who will inevitably want to mess with it. Zig is the glue; Litura handles text, libvaxis handles the terminal, and LuaJIT allows you to play with the program while it's running.

```sh
git clone https://github.com/mariuaas/junc.git
cd junc
zig build -Doptimize=ReleaseSafe
./zig-out/bin/junc path/to/file.txt
```

You'll need Zig **0.16.0**, `make` and a native C compiler. The build fetches its dependencies and builds LuaJIT for you. Tested on macOS arm64; cross compilation isn't supported. Run `junc` without a filename for a scratch buffer.

Arrow keys move, Shift selects, typing edits. Bracketed paste inserts text as one edit and one undo step. The document map is Emacs for motion: C-f / C-b, C-n / C-p, C-a / C-e, C-v / M-v, M-< / M->. Page Up / Page Down scroll a screenful too.

| Key | Action |
| --- | --- |
| Ctrl-S | Save; prompt for a filename if the buffer is unnamed |
| Ctrl-Q | Detach, leaving buffers in server memory |
| Ctrl-Z / Ctrl-Y | Undo / redo |
| M-x / Ctrl-O | Run a named command |
| M-: / Ctrl-L | Evaluate Lua in the running editor |
| Ctrl-R | Reload Lua commands and presentation |
| Ctrl-X Ctrl-P | Switch between Classic and Minimal |
| Ctrl-X h | Select all |
| Ctrl-X Up / Down | Add a cursor above / below |
| Ctrl-X d | Select the word, then add its next match |
| Ctrl-X 1 | Keep only the primary cursor |

[Multiple cursors](docs/multicursor.md) share one undoable edit; their selections live in Litura.

M-x gives you `open-file`, `switch-buffer`, `save-as` and friends. Tab completes; Escape or Ctrl-G gets you out of a prompt. Several terminals can share the same buffers, each with its own cursor and Lua setup. The local server starts automatically and keeps unsaved buffers after you detach. [How that works](docs/daemon.md).

Note that this will probably change. The project is still early days.

To make it yours, edit [lua/extension.lua](lua/extension.lua) or [lua/presentation.lua](lua/presentation.lua), then hit Ctrl-R. Commands, bindings, colors, the status line: fair game. A bad reload keeps the previous setup. Your document and undo history survive either way. There's also syntax highlighting for Zig, Lua and Fennel.

The wiring diagrams live in `docs/`: [commands and Lua](docs/lua-api.md), [minibuffer](docs/minibuffer.md), [keymaps](docs/keymaps.md), [presentation](docs/presentation.md) and [syntax](docs/syntax.md). The [Litura integration review](docs/litura-multiclient-review.md) covers the remaining protocol limits.

For hacking on Junc itself, see the [style guide](docs/STYLE_GUIDE.md):

```sh
zig build test
zig build check
zig fmt --check build.zig build.zig.zon src tests
```

[Terminal and server checks](docs/daemon.md#verification) exercise the executable too.
