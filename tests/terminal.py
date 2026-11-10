#!/usr/bin/env python3
"""Exercise the built editor through a real POSIX PTY; no terminal emulator dependency."""
import fcntl
import os
from pathlib import Path
import pty
import select
import signal
import struct
import subprocess
import sys
import tempfile
import termios
import time

binary = Path(__file__).resolve().parents[1] / 'zig-out/bin/junc'
with tempfile.TemporaryDirectory(prefix='junc-terminal-') as directory:
    root = Path(directory)
    (root / 'lua').mkdir()
    (root / 'lua/extension.lua').write_text("return function(e) e.command('wrap', function(c) return e.replace(c, '['..c.selection..']') end) end")
    master, slave = pty.openpty()
    fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 24, 80, 0, 0))
    original = termios.tcgetattr(slave)
    def setup():
        os.setsid()
        fcntl.ioctl(0, termios.TIOCSCTTY, 0)
    supervisor = "import pathlib, subprocess, sys, termios; result=subprocess.run([sys.argv[1], 'sample.txt']); pathlib.Path('restored.txt').write_text(repr(termios.tcgetattr(0))); sys.exit(result.returncode)"
    process = subprocess.Popen([sys.executable, '-c', supervisor, str(binary)], stdin=slave, stdout=slave, stderr=slave, cwd=root, preexec_fn=setup)
    output = bytearray()
    def drain(seconds=.3):
        until = time.monotonic() + seconds
        while time.monotonic() < until:
            if select.select([master], [], [], .03)[0]:
                chunk = os.read(master, 65536)
                output.extend(chunk)
                if b"\x1b[5n" in chunk:
                    os.write(master, b"\x1b[0n")
    def send(data):
        os.write(master, data)
        drain()
    try:
        drain(.6)
        assert process.poll() is None
        assert b'\x1b[?1049h' in output
        send(b'e')
        send('́'.encode())  # Separate events must form one document grapheme.
        send(b'\x13')
        assert (root / 'sample.txt').read_text() == 'é'
        send(b'\x7f\x13')
        assert (root / 'sample.txt').read_text() == ''
        send(b'\x1a\x13')  # Undo deletion restores the whole cluster.
        assert (root / 'sample.txt').read_text() == 'é'
        send(b'\x1a\x13')  # Undo accent insertion restores the base.
        assert (root / 'sample.txt').read_text() == 'e'
        send(b'\x01')
        send('hello 界é👩‍💻\rsecond line'.encode())
        send(b'\x1b[D\x7f')  # left, Backspace
        send(b'\x1b[3~')     # Delete
        send(b'\x01\x17\x13')  # select all, default wrap, save
        expected = '(hello 界é👩‍💻\nsecond li)'
        assert (root / 'sample.txt').read_text() == expected
        send(b'\x12\x01\x17\x13')  # replace Lua, select all, extension wrap, save
        assert (root / 'sample.txt').read_text() == '[' + expected + ']'
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 10, 32, 0, 0))
        os.kill(process.pid, signal.SIGWINCH)
        drain()
        assert b'\x1b[10;' in output, 'status did not follow resize'
        send(('\r' + '\r'.join('scroll '+str(i) for i in range(30))).encode())
        send(b'\x13')
        drain(1)
        assert (root / 'sample.txt').read_text().endswith('scroll 29'), repr((root / 'sample.txt').read_text())
        send(b'x' * 100)
        send(b'\x11')
        assert not (root / 'restored.txt').exists(), 'unsaved quit did not require repetition'
        send(b'\x11')
        process.wait(timeout=5)
        drain(.1)
        assert process.returncode == 0
        assert b'\x1b[?1049l' in output
        assert (root / 'restored.txt').read_text() == repr(original), 'terminal settings were not restored'
        assert '界'.encode() in output and '👩‍💻'.encode() in output
        print('PTY passed: Unicode rendering, navigation/deletion, save, Lua reload, resize, clean exit/restoration')
    finally:
        if process.poll() is None:
            process.kill()
            process.wait()
        os.close(master)
        os.close(slave)
