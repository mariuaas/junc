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
from daemon_support import DaemonRuntime, wait_ready

binary = Path(__file__).resolve().parents[1] / 'zig-out/bin/junc'
with tempfile.TemporaryDirectory(prefix='junc-terminal-') as directory, DaemonRuntime() as daemon:
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
    process = subprocess.Popen([sys.executable, '-c', supervisor, str(binary)], stdin=slave, stdout=slave, stderr=slave, cwd=root, preexec_fn=setup, env=daemon.environment())
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
        wait_ready(process, output, drain)
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
        send(b'\x18h')
        send('hello 界é👩‍💻\rsecond line'.encode())
        send(b'\x1b[D\x7f')  # left, Backspace
        send(b'\x1b[3~')     # Delete
        send(b'\x18h\x17\x13')  # select all, default wrap, save
        expected = '(hello 界é👩‍💻\nsecond li)'
        assert (root / 'sample.txt').read_text() == expected
        send(b'\x12\x18h\x17\x13')  # replace Lua, select all, extension wrap, save
        assert (root / 'sample.txt').read_text() == '[' + expected + ']'
        fcntl.ioctl(slave, termios.TIOCSWINSZ, struct.pack('HHHH', 10, 32, 0, 0))
        os.kill(process.pid, signal.SIGWINCH)
        drain()
        assert b'\x1b[10;' in output, 'status did not follow resize'
        send(('\r' + '\r'.join('scroll '+str(i) for i in range(30))).encode())
        send(b'\x13')
        deadline = time.monotonic() + 5
        while not (root / 'sample.txt').read_text().endswith('scroll 29') and time.monotonic() < deadline:
            drain(.05)
        assert (root / 'sample.txt').read_text().endswith('scroll 29'), repr((root / 'sample.txt').read_text())
        send(b'x' * 100)
        send(b'\x11')
        # Quit detaches immediately; the private daemon retains these unsaved bytes.
        deadline = time.monotonic() + 5
        while process.poll() is None and time.monotonic() < deadline:
            drain(.02)
        process.wait(timeout=.1)
        drain(.1)
        assert process.returncode == 0
        assert b'\x1b[?1049l' in output
        assert (root / 'restored.txt').read_text() == repr(original), 'terminal settings were not restored'
        assert '界'.encode() in output and '👩‍💻'.encode() in output
        print('PTY passed: Unicode rendering, navigation/deletion, save, Lua reload, resize, clean exit/restoration')
    finally:
        if process.poll() is None:
            process.kill()
        os.close(master)
        os.close(slave)
        process.wait(timeout=5)
