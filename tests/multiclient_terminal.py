#!/usr/bin/env python3
"""Two simultaneous independent Lua/libvaxis clients share one Litura document, without replicas."""
import re
from pathlib import Path
import tempfile
import time
from daemon_support import DaemonRuntime
from terminal_support import Terminal

repo = Path(__file__).resolve().parents[1]

def plain(raw):
    raw = re.sub(rb'\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)', b'', raw)
    return re.sub(rb'\x1b\[[0-?]*[ -/]*[@-~]', b'', raw)

def idle_change(terminal, start, marker):
    # Do not resize or send keys to the observing client: only an invalidation can cause this redraw.
    until = time.monotonic() + 5
    while marker not in plain(bytes(terminal.output[start:])) and time.monotonic() < until:
        terminal.drain(.1)
    delta = plain(bytes(terminal.output[start:]))
    assert marker in delta, delta

with tempfile.TemporaryDirectory(prefix='junc-two-tty-') as directory, DaemonRuntime() as daemon:
    root = Path(directory)
    (root / 'lua').mkdir()
    (root / 'shared.lua').write_text('ab\nlocal s="界é"\n')
    base = (repo / 'lua/presentation.lua').read_text()
    (root / 'lua/presentation.lua').write_text('local p=(function()\n'+base+'\nend)()\n'+'''
for _, preset in pairs(p.presets) do
  preset.status=function(s)
    return string.format('STATE|b=%d|r=%d|i=%d|c=%d|m=%s|t=%d|l=%d|%s | %s',
      s.buffer_id,s.revision,s.interaction_revision,s.cursor,tostring(s.mark),s.top,s.left,s.preset,s.message)
  end
end
return p
''')
    a = Terminal(root, daemon, 'shared.lua')
    b = None
    try:
        b = Terminal(root, daemon, 'shared.lua')
        sa, sb = a.state(), b.state()
        assert sa[0] == sb[0] == b'1' and sa[1:3] == sb[1:3] == (b'0', b'0')
        b.send(b'\x1b[C\x1b[1;2C')
        sb = b.state()
        assert sb[3:5] == (b'2', b'1')
        before = len(b.output)
        a.send(b'X')
        idle_change(b, before, b'X')
        sb_after = b.state()
        assert sb_after[1] == b'1' and sb_after[3:5] == (b'3', b'2'), sb_after
        assert sb[2] == sb_after[2], ('B after A insertion', sb, sb_after)
        sa = a.state()
        before = len(a.output)
        b.send(b'Y')
        idle_change(a, before, b'Y')
        a_after = a.state()
        assert a_after[1] == b'2'
        assert sa[2] == a_after[2], ('A after B replacement', sa, a_after)
        assert b.state()[3:5] == (b'3', b'nil')
        # Undo is the authoritative global Litura history, not per-client selective undo.
        b_before = b.state()
        before = len(b.output)
        a.send(b'\x1a')
        idle_change(b, before, b'b')
        assert a.state()[1] == b.state()[1] == b'3'
        assert b_before[2] == b.state()[2], 'shared undo advanced B interaction revision'
        # UI and extensions stay independent; a live command still submits through the shared bridge.
        a.evaluate("editor.command('only-a',function(c) return editor.replace(c,'Z') end); editor.bind('ctrl-b','only-a')")
        assert b'true' in b.evaluate("editor.commands['only-a']==nil")
        b.send(b'\x07')
        a.send(b'\x07\x10')
        assert a.state()[7] == b'minimal' and b.state()[7] == b'classic'
        before = len(b.output)
        a.send(b'\x02')
        idle_change(b, before, b'Z')
        assert a.state()[1] == b.state()[1] == b'4'
        # Resize one terminal while preserving both live sessions and shared source rendering.
        b.resize(18, 5); b.drain(.2)
        b.snapshot()
        before = b.state()
        b.send(b'\x12')
        assert b.state() == before, 'reload destroyed B interaction or presentation state'
        assert a.state()[7] == b'minimal'
        # Disconnecting one editor must not stop or reset its peer.
        b.send(b'\x11'); b.restored(); b.close(); b = None
        a.send(b'Q\x13')
        assert (root / 'shared.lua').read_text().startswith('XZQab\n')
        a.command('shutdown-server'); a.restored()
    finally:
        a.close()
        if b is not None: b.close()
print('Two-client PTY passed: idle invalidation redraw, independent cursor/selection/CAS, shared undo, independent Lua/theme/reload, resize, peer detachment and restoration')
