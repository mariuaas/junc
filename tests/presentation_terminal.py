#!/usr/bin/env python3
"""Live Lua presentation replacement over a controlling PTY, using only Python stdlib."""
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

def presentation(marker, background):
    return "local p=(function()\n" + base + "\nend)()\n" + f"""
for _, preset in pairs(p.presets) do
  local theme = preset.theme
  preset.theme = function(t) local c=theme(t); c.bg='{background}'; return c end
  preset.status = function(s)
    return string.format('{marker}|r=%d|i=%d|c=%d|m=%s|top=%d|left=%d|%s',
      s.revision,s.interaction_revision,s.cursor,tostring(s.mark),s.top,s.left,s.preset)
  end
end
return p
"""

with tempfile.TemporaryDirectory(prefix='junc-presentation-') as directory, DaemonRuntime() as daemon:
    root = Path(directory)
    (root / 'lua').mkdir()
    source = root / 'lua/presentation.lua'
    source.write_text(presentation('LIVE-A', '#102030'))
    master, slave = pty.openpty()
    original = termios.tcgetattr(slave)
    def setup():
        os.setsid()
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)
    def resize(width, height=24):
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', height, width, 0, 0))
    resize(100)
    supervisor = "import pathlib, subprocess, sys, termios; r=subprocess.run([sys.argv[1], 'sample.txt']); pathlib.Path('restored.txt').write_text(repr(termios.tcgetattr(0))); sys.exit(r.returncode)"
    terminal_env = dict(os.environ, TERM='xterm-256color', COLORTERM='truecolor')
    terminal_env.pop('NO_COLOR', None)
    process = subprocess.Popen([sys.executable, '-c', supervisor, str(repo / 'zig-out/bin/junc')], stdin=slave, stdout=slave, stderr=slave, cwd=root, preexec_fn=setup, env=daemon.environment(terminal_env))
    output = bytearray()
    def drain(seconds=.3):
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
    current_width = 100
    def snapshot():
        global current_width
        start = len(output)
        current_width = 101 if current_width == 100 else 100
        resize(current_width)
        drain()
        raw = bytes(output[start:])
        clean = re.sub(rb'\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)', b'', raw)
        clean = re.sub(rb'\x1b\[[0-?]*[ -/]*[@-~]', b'', clean)
        return raw, clean
    def state(clean, marker):
        match = re.search(marker + rb'\|r=(\d+)\|i=(\d+)\|c=(\d+)\|m=(\w+)\|top=(\d+)\|left=(\d+)\|(classic|minimal)', clean)
        assert match, clean
        return match.groups()
    try:
        drain(.6)
        wait_ready(process, output, drain)
        # Exercise real libvaxis OSC report parsing; startup initially has no answers.
        assert b'\x1b]10;?' in output and b'\x1b]11;?' in output and b'\x1b]4;4;?' in output, output
        send(b'\x1b]10;rgb:dddd/eeee/ffff\x1b\\\x1b]11;rgb:1111/2222/3333\x1b\\\x1b]4;4;rgb:4444/5555/6666\x1b\\')
        send(b'abc\x1b[1;2D')
        raw, clean = snapshot()
        before = state(clean, b'LIVE-A')
        assert before[0] == b'3' and before[2:4] == (b'2', b'3'), before
        assert b'1 abc' in clean, clean
        assert re.search(rb'16[:;]32[:;]48', raw), raw
        assert re.search(rb'221[:;]238[:;]255', raw), raw
        # Replace both the theme and status function while the same process is open.
        source.write_text(presentation('LIVE-B', '#132333'))
        send(b'\x12')
        raw, clean = snapshot()
        assert state(clean, b'LIVE-B') == before
        assert re.search(rb'19[:;]35[:;]51', raw), raw
        assert output.count(b'\x1b[?1049h') == 1, 'terminal was recreated'
        send(b'\x18\x10')
        _, clean = snapshot()
        minimal = state(clean, b'LIVE-B')
        assert minimal[:-1] == before[:-1] and minimal[-1] == b'minimal'
        assert b'1 abc' not in clean and b'abc' in clean, clean
        # Syntax errors, invalid colors, and callback errors all retain the prior policy.
        for bad in ('this is not Lua !!!',
                    presentation('BROKEN', '#notrgb'),
                    presentation('BROKEN', '#ffffff').replace("return string.format('BROKEN", "error('bad status'); return string.format('BROKEN")):
            source.write_text(bad)
            send(b'\x12')
            _, clean = snapshot()
            assert state(clean, b'LIVE-B') == minimal
        send(b'\x13')
        assert (root / 'sample.txt').read_text() == 'abc'
        send(b'\x1a\x13')
        assert (root / 'sample.txt').read_text() == 'ab', 'presentation reload lost or altered undo history'
        send(b'\x11')
        process.wait(timeout=5)
        drain(.1)
        assert process.returncode == 0
        assert b'\x1b[?1049l' in output
        assert (root / 'restored.txt').read_text() == repr(original)
        print('Presentation PTY passed: live theme/status replacement, preset/gutter switch, failed reload, revision/selection preservation, undo, resize and restoration')
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)
        os.close(slave)
