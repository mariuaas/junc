#!/usr/bin/env python3
"""Real input, rendering, reload and two independent sessions with a shared cursor-set edit."""
from pathlib import Path
import re
import tempfile

from daemon_support import DaemonRuntime
from terminal_support import Terminal, repo


def inspect(terminal, expected):
    source = ("local s=editor.state(); return string.format('CURSORS:%d:R%d:I%d',"
              "#s.selections,s.revision,s.interaction_revision)")
    result = terminal.evaluate(source, expected)
    assert expected in result, result
    terminal.send(b'\x07')


with tempfile.TemporaryDirectory(prefix='junc-multicursor-') as directory, DaemonRuntime() as daemon:
    root = Path(directory)
    (root / 'lua').mkdir()
    presentation = root / 'lua/presentation.lua'
    presentation.write_text((repo / 'lua/presentation.lua').read_text())
    path = root / 'source.lua'
    path.write_text('e\ne\ne\n')
    (root / 'matches.zig').write_text('const value = 1;\n' * 60)
    a = Terminal(root, daemon, 'source.lua')
    b = None
    try:
        b = Terminal(root, daemon, 'source.lua')
        a.send(b'\x1b[C\x18\x1b[B\x18\x1b[B')
        inspect(a, b'CURSORS:3:R0:I3')
        inspect(b, b'CURSORS:1:R0:I0')
        raw, _ = a.snapshot()
        assert re.search(rb'\x1b\[[0-9;:]*4(?::1)?m', raw), 'secondary caret underline missing'
        a.send('́'.encode() + b'\x13')
        assert path.read_text() == 'é\né\né\n'
        inspect(a, b'CURSORS:3:R1:I4')
        inspect(b, b'CURSORS:1:R1:I0')
        a.send(b'\x1a\x13')
        assert path.read_text() == 'e\ne\ne\n', 'multi-cursor edit needed more than one undo'
        a.send(b'\x19\x13')
        assert path.read_text() == 'é\né\né\n'
        a.send(b'\x18\x10')  # Switch presentation, then reload it without losing carets.
        a.resize(18, 5)
        a.snapshot()
        a.send(b'\x12')
        inspect(a, b'CURSORS:3:R3:I4')
        switched = a.evaluate(
            "original=editor.state().buffer_id; editor.open_file('other.lua'); "
            "assert(#editor.state().selections==1); editor.select_buffer(original); "
            "assert(#editor.state().selections==3); return 'SWITCHED'", b'SWITCHED')
        assert b'SWITCHED' in switched
        a.send(b'\x07')
        presentation.write_text('invalid presentation !')
        a.send(b'\x12')
        inspect(a, b'CURSORS:3:R3:I4')
        presentation.write_text((repo / 'lua/presentation.lua').read_text())
        (root / 'lua/extension.lua').write_text("return function(e) e.command('live-multi',function(c) return e.replace(c,'X') end) end")
        a.send(b'\x12')
        a.command('live-multi')
        a.send(b'\x13')
        assert path.read_text() == 'éX\néX\néX\n'
        a.command('cursor-single')
        a.command('buffer-start')
        a.send(b'\x18d')  # Select the word at point, then the next exact occurrence.
        a.send(b'\x18d')
        clean = a.evaluate('assert(#editor.state().selections==2); return "NEXT-MATCH-OK"', b'NEXT-MATCH-OK')
        assert b'NEXT-MATCH-OK' in clean
        a.send(b'\x07')
        assert b'MATCHES-OPEN' in a.evaluate(
            "editor.open_file('matches.zig'); return 'MATCHES'..'-OPEN'", b'MATCHES-OPEN')
        a.send(b'\x07')
        a.send(b'\x18d' * 5)
        a.send(b'\x1b[B' * 20 + b'\x1b[D' * 3 + b'\x1b[C' * 2)
        a.send(b'\x18d' * 2)
        assert b'EXTEND-OK' in a.evaluate(
            "assert(#editor.state().selections==6); return 'EXTEND'..'-OK'", b'EXTEND-OK')
        a.send(b'\x07')
        a.send(b'\x18\x1b[C')  # Invalid prefix must not insert input into either selection.
        a.send(b'\x11')
        a.restored()
        b.send(b'\x11')
        b.restored()
    finally:
        a.close()
        if b is not None:
            b.close()

print('Multi-cursor PTY passed: prefix keys, secondary caret cells, Unicode batch edit/undo, '
      'independent peer selection state, resize, reload, live Lua command, next match and restoration')
