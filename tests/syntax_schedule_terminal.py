#!/usr/bin/env python3
"""Large source renders before parsing and receives syntax-completion redraws without input."""
from pathlib import Path
import re
import tempfile
import time

from daemon_support import DaemonRuntime
from terminal_support import Terminal

keyword = re.compile(rb'\x1b\[38[:;]2[:;]199[:;]146[:;]234m')
comment = re.compile(rb'\x1b\[38[:;]2[:;]113[:;]135[:;]121m')


def idle_color(terminal, pattern):
    deadline = time.monotonic() + 20
    while pattern.search(terminal.output) is None and time.monotonic() < deadline:
        terminal.drain(.03)
    assert terminal.process.poll() is None, bytes(terminal.output[-2000:])
    assert pattern.search(terminal.output), 'idle syntax completion never redrew the source'


with tempfile.TemporaryDirectory(prefix='junc-syntax-idle-') as directory, DaemonRuntime() as daemon:
    root = Path(directory)
    source = root / 'large.lua'
    original = 'local value = "界é" -- body\n' * 35000
    source.write_text(original)
    assert source.stat().st_size > 1024 * 1024
    terminal = Terminal(root, daemon, 'large.lua')
    try:
        first = bytes(terminal.output).split(b'\x1b[?2026l', 1)[0]
        assert b'local' in first, first[-2000:]
        assert keyword.search(first) is None, 'first frame waited for a parse instead of showing text'
        idle_color(terminal, keyword)
        start = len(terminal.output)
        terminal.send(b'\x1b[200~-- scheduled\n\x1b[201~')
        terminal.resize(50, 8)
        # A current-revision comment color must arrive without another key or resize request.
        deadline = time.monotonic() + 20
        while comment.search(terminal.output[start:]) is None and time.monotonic() < deadline:
            terminal.drain(.03)
        assert comment.search(terminal.output[start:]), 'edited large document did not catch up'
        assert '界'.encode() in terminal.output
        assert source.read_text() == original, 'background upkeep wrote the source file'
        terminal.send(b'\x11')
        terminal.restored()
    finally:
        terminal.close()

print('Scheduled syntax PTY passed: >1 MiB plain first frame, idle highlighting, edit/resize '
      'catch-up, Unicode, no implicit save and terminal restoration')
