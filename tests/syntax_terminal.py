#!/usr/bin/env python3
"""Exercise source editing and editing/reloading the syntax palette itself in a real PTY."""
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

def exercise(language):
    with tempfile.TemporaryDirectory(prefix='junc-syntax-') as directory, DaemonRuntime() as daemon:
        root = Path(directory)
        (root / 'lua').mkdir()
        (root / 'lua/presentation.lua').write_text(base)
        (root / 'main.zig').write_text((repo / 'src/main.zig').read_text())
        path = 'main.zig' if language == 'zig' else 'lua/presentation.lua'
        master, slave = pty.openpty()
        original = termios.tcgetattr(slave)
        def setup():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)
        def resize(width, height=24):
            fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', height, width, 0, 0))
        resize(110)
        supervisor = "import pathlib,subprocess,sys,termios; r=subprocess.run(sys.argv[1:]); pathlib.Path('restored.txt').write_text(repr(termios.tcgetattr(0))); sys.exit(r.returncode)"
        environment = dict(os.environ, TERM='xterm-256color', COLORTERM='truecolor')
        environment.pop('NO_COLOR', None)
        process = subprocess.Popen([sys.executable, '-c', supervisor, str(repo / 'zig-out/bin/junc'), path], stdin=slave, stdout=slave, stderr=slave, cwd=root, preexec_fn=setup, env=daemon.environment(environment))
        output = bytearray()
        def drain(seconds=.35):
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
        width = 110
        def snapshot():
            nonlocal width
            start = len(output)
            width = 111 if width == 110 else 110
            resize(width)
            drain()
            return bytes(output[start:])
        def state(raw):
            clean = re.sub(rb'\x1b\[[0-?]*[ -/]*[@-~]', b'', raw)
            match = re.search(rb' r(\d+) i(\d+)', clean)
            assert match, clean
            return match.groups()
        def has_color(raw, rgb):
            return re.search(rb'[:;]'.join(str(channel).encode() for channel in rgb), raw)
        try:
            drain(.7)
            wait_ready(process, output, drain)
            raw = snapshot()
            assert has_color(raw, (199, 146, 234)), raw
            initial = state(raw)
            send(b'\x10')  # Minimal, same document/session.
            raw = snapshot()
            assert has_color(raw, (237, 207, 142)), raw
            send(b'\x10')
            assert state(snapshot()) == initial
            if language == 'zig':
                send(b'// edited\r')
                send(b'\x1a\x19\x13')  # undo, redo, save
                assert (root / path).read_text().startswith('// edited\n')
                send(b'\x1b[B' * 30)
                snapshot()
                # Scrolled source keeps syntax and survives a narrow horizontal viewport.
                resize(32, 10)
                drain()
                send(b'\x1b[F')
                resize(110, 24)
                drain()
            else:
                # Edit junc's own presentation code using only ordinary editor input.
                lines = base.splitlines()
                row = next(i for i, line in enumerate(lines) if "keyword = {fg='#c792ea'" in line)
                column = lines[row].index('#c792ea')
                send(b'\x1b[B' * row + b'\x1b[H' + b'\x1b[C' * column)
                send(b'\x1b[1;2C' * 7)
                send(b'#123456\x13')
                assert "keyword = {fg='#123456'" in (root / path).read_text()
                before = state(snapshot())
                send(b'\x12')
                raw = snapshot()
                assert state(raw) == before, 'palette reload changed document/interaction revisions'
                assert has_color(raw, (18, 52, 86)), raw
                assert output.count(b'\x1b[?1049h') == 1
                # A bad style retains the native palette and source document.
                (root / path).write_text((root / path).read_text().replace('#123456', '#notrgb'))
                send(b'\x12')
                raw = snapshot()
                assert has_color(raw, (18, 52, 86)) and state(raw) == before
                send(b'\x13')  # In-memory document is still the valid edited source.
                assert '#notrgb' not in (root / path).read_text()
            send(b'\x11')
            process.wait(timeout=5)
            drain(.1)
            assert process.returncode == 0
            assert b'\x1b[?1049l' in output
            assert (root / 'restored.txt').read_text() == repr(original)
            print(f'{language} syntax PTY passed: source styling, presets, editing, reload, resize and restoration')
        finally:
            if process.poll() is None:
                process.kill()
                process.wait()
            os.close(master)
            os.close(slave)

exercise('zig')
exercise('lua')
