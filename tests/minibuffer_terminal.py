#!/usr/bin/env python3
"""Exercise live command/Lua/prompt contexts over a controlling PTY; Python stdlib only."""
import fcntl
import os
from pathlib import Path
import pty
import re
import select
import struct
import subprocess
import sys
import tempfile
import termios
import time

repo = Path(__file__).resolve().parents[1]
base = (repo / 'lua/presentation.lua').read_text()

with tempfile.TemporaryDirectory(prefix='junc-minibuffer-') as directory:
    root = Path(directory)
    (root / 'lua').mkdir()
    (root / 'sample.lua').write_text('local value = 1\n')
    (root / 'lua/presentation.lua').write_text("local p=(function()\n" + base + "\nend)()\n" + """
for _, preset in pairs(p.presets) do
  preset.status = function(s)
    return string.format('STATE|r=%d|i=%d|c=%d|m=%s',
      s.revision,s.interaction_revision,s.cursor,tostring(s.mark))
  end
end
return p
""")
    master, slave = pty.openpty()
    original = termios.tcgetattr(slave)

    def setup():
        os.setsid()
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)

    def resize(width, height=24):
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', height, width, 0, 0))

    resize(110)
    supervisor = "import pathlib, subprocess, sys, termios; r=subprocess.run([sys.argv[1], 'sample.lua']); pathlib.Path('restored.txt').write_text(repr(termios.tcgetattr(0))); sys.exit(r.returncode)"
    process = subprocess.Popen([sys.executable, '-c', supervisor, str(repo / 'zig-out/bin/junc')],
        stdin=slave, stdout=slave, stderr=slave, cwd=root, preexec_fn=setup,
        env=dict(os.environ, NO_COLOR='1', TERM='dumb'))
    output = bytearray()

    def drain(seconds=.25):
        until = time.monotonic() + seconds
        while time.monotonic() < until:
            if select.select([master], [], [], .02)[0]:
                chunk = os.read(master, 65536)
                output.extend(chunk)
                if b'\x1b[5n' in chunk:
                    os.write(master, b'\x1b[0n')

    def send(data):
        os.write(master, data)
        drain()

    current_width = 110

    def snapshot():
        global current_width
        start = len(output)
        current_width = 111 if current_width == 110 else 110
        resize(current_width)
        drain()
        raw = bytes(output[start:])
        clean = re.sub(rb'\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)', b'', raw)
        return re.sub(rb'\x1b\[[0-?]*[ -/]*[@-~]', b'', clean)

    def state(clean):
        match = re.search(rb'STATE\|r=(\d+)\|i=(\d+)\|c=(\d+)\|m=(\w+)', clean)
        assert match, clean
        return match.groups()

    def evaluate(source):
        # The normalized Meta-colon event is produced by a real ESC prefix.
        send(b'\x1b:')
        send(source.encode() + b'\r')
        return snapshot()

    try:
        drain(.6)
        send(b'\x1b[1;2C')  # Main selection survives all ordinary minibuffer operations.
        before = state(snapshot())
        assert before[0] == b'0' and before[2:] == (b'1', b'0'), before
        send(b'\x1bx')
        assert b'M-x ' in snapshot()
        send(b'describe-c\t')
        assert b'describe-command' in snapshot()
        send(b'\r')
        assert b'Describe command: ' in snapshot()
        send(b'sav\t\r')
        # Describe output is retained and visible on reopening any context.
        send(b'\x1b:')
        clean = snapshot()
        assert b'Save the current document' in clean and b'ctrl-s' in clean, clean
        assert state(clean) == before
        send(b'6*7\r')
        assert b'42' in snapshot()
        send(b"error('PTY-error')\r")
        assert b'PTY-error' in snapshot()
        send(b'40+3\r')
        assert b'43' in snapshot()
        # Native history survives closing; Down restores an unfinished draft.
        send(b'draft\x1b[A')
        assert b'40+3' in snapshot()
        send(b'\x1b[B')
        assert b'draft' in snapshot()
        send(b'\x07')
        clean = evaluate("editor.command_names()[1]")
        assert b'backspace' in clean, clean
        # A separately registered extension is discoverable immediately and binds through dispatch.
        clean = evaluate("editor.command('live-pty',function(c) return editor.replace(c,'LIVE') end); editor.bind('ctrl-b','live-pty')")
        assert state(clean) == before
        send(b'\x07\x1bxlive-p\t')
        assert b'live-pty' in snapshot()
        send(b'\r')
        assert state(snapshot())[0] == b'1'
        send(b'\x02\x13')
        assert (root / 'sample.lua').read_text() == 'LIVELIVEocal value = 1\n'
        # Unicode input and selection use the shared cell renderer, including narrow resize.
        send(b'\x0c')  # Ctrl-L fallback opens Lua.
        send("界é".encode())
        clean = snapshot()
        assert '界é'.encode() in clean, clean
        resize(9, 4)
        drain()
        resize(1, 1)
        drain()
        assert process.poll() is None
        send(b'\x1b[H')  # Return the horizontally scrolled input to its beginning.
        clean = snapshot()
        assert '界é'.encode() in clean, clean
        send(b'\x07\x0fselect-\t')  # Ctrl-O fallback, ambiguous completions.
        assert b'select-' in snapshot()
        send(b'\x1b[B')
        assert b'> select-' in snapshot()
        send(b'\x07')
        # A rejected whole-VM reload keeps a temporary live command/binding active.
        (root / 'lua/extension.lua').write_text('this is invalid Lua !!!')
        send(b'\x12\x02\x13')
        assert (root / 'sample.lua').read_text().startswith('LIVELIVELIVE')
        (root / 'lua/extension.lua').unlink()
        # Requesting reload from an executing Lua chunk defers replacement until pcall returns.
        clean = evaluate("editor.invoke('reload')")
        assert b'Lua> ' in clean, clean
        send(b'\x1b[A')
        assert b"editor.invoke('reload')" in snapshot()
        send(b'\x01')  # Select all previous history entry, then replace.
        send(b"editor.commands['live-pty']==nil\r")
        assert b'true' in snapshot()
        send(b'\x07\x1a\x13')
        assert (root / 'sample.lua').read_text() == 'LIVELIVEocal value = 1\n', 'reload lost main undo history'
        send(b'\x0fdraft')
        send(b'\x1b')  # A standalone Escape cancels as well as Ctrl-G.
        assert b'M-x ' not in snapshot()
        send(b'\x11')
        process.wait(timeout=5)
        drain(.1)
        assert process.returncode == 0
        assert output.count(b'\x1b[?1049h') == 1, 'terminal was recreated'
        assert b'\x1b[?1049l' in output
        assert (root / 'restored.txt').read_text() == repr(original)
        print('Minibuffer PTY passed: Meta keys/fallbacks, command discovery/completion, prompt, live Lua/commands/bindings, history/errors, Unicode/resize, reload, undo and restoration')
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)
        os.close(slave)
