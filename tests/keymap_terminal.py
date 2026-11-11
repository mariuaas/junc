#!/usr/bin/env python3
"""Layered keymaps and which-key feedback via real libvaxis input on a controlling PTY."""
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
from daemon_support import DaemonRuntime, wait_ready

repo = Path(__file__).resolve().parents[1]
base = (repo / 'lua/presentation.lua').read_text()
with tempfile.TemporaryDirectory(prefix='junc-keymaps-') as directory, DaemonRuntime() as daemon:
    root = Path(directory)
    (root / 'lua').mkdir()
    source = 'alpha\nbeta\ngamma\n'
    (root / 'sample.txt').write_text(source)
    (root / 'lua/presentation.lua').write_text("local p=(function()\n" + base + "\nend)()\n" + """
for _, preset in pairs(p.presets) do
  preset.status = function(s)
    return string.format('STATE|r=%d|i=%d|c=%d|m=%s | %s',
      s.revision,s.interaction_revision,s.cursor,tostring(s.mark),s.message)
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

    resize(170)
    supervisor = "import pathlib, subprocess, sys, termios; r=subprocess.run([sys.argv[1], 'sample.txt']); pathlib.Path('restored.txt').write_text(repr(termios.tcgetattr(0))); sys.exit(r.returncode)"
    process = subprocess.Popen([sys.executable, '-c', supervisor, str(repo / 'zig-out/bin/junc')],
        stdin=slave, stdout=slave, stderr=slave, cwd=root, preexec_fn=setup,
        env=daemon.environment(dict(os.environ, NO_COLOR='1', TERM='dumb')))
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

    current_width = 170

    def snapshot():
        global current_width
        start = len(output)
        current_width = 171 if current_width == 170 else 170
        resize(current_width)
        drain()
        raw = bytes(output[start:])
        clean = re.sub(rb'\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)', b'', raw)
        return re.sub(rb'\x1b\[[0-?]*[ -/]*[@-~]', b'', clean)

    def state(clean):
        match = re.search(rb'STATE\|r=(\d+)\|i=(\d+)\|c=(\d+)\|m=(\w+)', clean)
        assert match, clean
        return match.groups()

    def evaluate(code):
        send(b'\x1b:')
        send(code.encode() + b'\r')
        return snapshot()

    try:
        drain(.6)
        wait_ready(process, output, drain)
        send(b'\x1b[1;2C')
        before = state(snapshot())
        assert before[0] == b'0' and before[2:] == (b'1', b'0'), before
        clean = evaluate("editor.keymap('navigation',{j='down',k='up',['g g']='buffer-start',escape='keymap.pop'}); editor.push_keymap('navigation')")
        assert state(clean) == before
        clean = evaluate("editor.keymap_state().layers[1].name")
        assert b'navigation' in clean, clean
        send(b'\x07\x1bxdescribe-keymap\r')
        assert b'Describe keymap:' in snapshot()
        send(b'navig\t\r')
        clean = snapshot()
        assert b'navigation [active]' in clean and b'g g -> buffer-start' in clean, clean
        assert state(clean) == before
        send(b'jj')
        assert state(snapshot())[2] == b'12'
        send(b'g')
        clean = snapshot()
        assert b'g ... [navigation] g -> buffer-start' in clean, clean
        waiting = state(clean)
        # Resize with a pending prefix: its continuation survives and layout follows the terminal.
        resize(50, 8)
        drain()
        clean = snapshot()
        assert state(clean) == waiting
        send(b'g')
        assert state(snapshot())[2] == b'0'
        send(b'gx')
        clean = snapshot()
        assert b'Unbound sequence: g x' in clean and state(clean)[0] == b'0', clean
        send(b'g\x07')
        assert b'Prefix cancelled' in snapshot()
        send(b'j')
        assert state(snapshot())[2] == b'6', 'prefix cancellation popped the navigation map'
        send(b'\x1b')
        assert b'Popped navigation' in snapshot()
        send(b'j\x18\x13')  # Ordinary insertion returns immediately; C-x C-s saves through the registry.
        expected = 'alpha\njbeta\ngamma\n'
        assert (root / 'sample.txt').read_text() == expected
        clean = evaluate("editor.keymap('navigation',{['界']='buffer-end',space='buffer-start',['alt-z']='buffer-end',escape='keymap.pop'}); editor.push_keymap('navigation')")
        assert state(clean)[0] == b'1'
        send(b'\x07')
        send('界'.encode())
        assert state(snapshot())[2] == str(len(expected)).encode()
        send(b' ')
        assert state(snapshot())[2] == b'0'
        send(b'\x1bz')
        assert state(snapshot())[2] == str(len(expected)).encode(), 'Alt-z was not normalized'
        # Failed map configuration retains the active map and all interaction state.
        extension = root / 'lua/extension.lua'
        extension.write_text("return function(e) e.keymap('navigation',{x='home',['x x']='end'}) end")
        before = state(snapshot())
        send(b'\x12')
        assert state(snapshot()) == before
        send(b' ')
        assert state(snapshot())[2] == b'0'
        send(b'\x1b[1;2C')
        before = state(snapshot())
        extension.write_text("return function(e) e.keymap('new-map',{j='buffer-end',escape='keymap.pop'}); e.push_keymap('new-map') end")
        send(b'\x12')
        assert state(snapshot()) == before, 'reload changed document or selection state'
        clean = evaluate("editor.keymap_state().layers[1].name")
        assert b'new-map' in clean, clean
        send(b'\x07')
        send(b'\x1b')  # Standalone Escape must be separated from the following key event.
        send(b'\x1a\x13')  # Undo the insertion made before reload.
        assert (root / 'sample.txt').read_text() == source, repr((root / 'sample.txt').read_text())
        send(b'\x11')
        process.wait(timeout=5)
        drain(.1)
        assert process.returncode == 0
        assert output.count(b'\x1b[?1049h') == 1
        assert b'\x1b[?1049l' in output
        assert (root / 'restored.txt').read_text() == repr(original)
        print('Keymap PTY passed: live REPL activation, M-x inspection, prefix hints/cancellation/resize, context isolation, Unicode/Alt keys, pop/insertion, failed/successful reload, undo and restoration')
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)
        os.close(slave)
