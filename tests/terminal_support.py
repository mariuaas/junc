"""Controlling PTY harness shared by hosted editor integration checks."""
import fcntl
import os
from pathlib import Path
import pty
import re
import select
import struct
import subprocess
import sys
import termios
import time
from daemon_support import wait_ready

repo = Path(__file__).resolve().parents[1]

class Terminal:
    """Owns a controlling PTY and child process; close also handles failed construction."""
    def __init__(self, root, daemon, path):
        self.process = None
        self.master, self.slave = pty.openpty()
        try:
            self._start(root, daemon, path)
        except BaseException:
            self.close()
            raise

    def _start(self, root, daemon, path):
        self.original = termios.tcgetattr(self.slave)
        self.resize(120, 12)
        def setup():
            os.setsid()
            fcntl.ioctl(0, termios.TIOCSCTTY, 0)
        supervisor = "import pathlib,subprocess,sys,termios; r=subprocess.run(sys.argv[1:]); pathlib.Path('restored.txt').write_text(repr(termios.tcgetattr(0))); sys.exit(r.returncode)"
        environment = daemon.environment(dict(os.environ, TERM='xterm-256color', COLORTERM='truecolor'))
        environment.pop('NO_COLOR', None)
        self.process = subprocess.Popen([sys.executable, '-c', supervisor, str(repo / 'zig-out/bin/junc'), path],
            stdin=self.slave, stdout=self.slave, stderr=self.slave, cwd=root, preexec_fn=setup, env=environment)
        self.output = bytearray()
        self.width = 120
        self.root = root
        self.drain(.7)
        wait_ready(self.process, self.output, self.drain)

    def resize(self, width, height=12):
        fcntl.ioctl(self.slave, termios.TIOCSWINSZ, struct.pack('HHHH', height, width, 0, 0))

    def drain(self, seconds=.25):
        until = time.monotonic() + seconds
        while time.monotonic() < until:
            if select.select([self.master], [], [], .02)[0]:
                chunk = os.read(self.master, 65536)
                self.output.extend(chunk)
                if b'\x1b[5n' in chunk:
                    os.write(self.master, b'\x1b[0n')

    def send(self, data):
        os.write(self.master, data)
        self.drain()

    def snapshot(self):
        start = len(self.output)
        self.width = 121 if self.width == 120 else 120
        self.resize(self.width)
        self.drain()
        raw = bytes(self.output[start:])
        clean = re.sub(rb'\x1b\][^\x07\x1b]*(?:\x07|\x1b\\)', b'', raw)
        return raw, re.sub(rb'\x1b\[[0-?]*[ -/]*[@-~]', b'', clean)

    def state(self):
        _, clean = self.snapshot()
        match = re.search(rb'STATE\|b=(\d+)\|r=(\d+)\|i=(\d+)\|c=(\d+)\|m=(\w+)\|t=(\d+)\|l=(\d+)\|(classic|minimal)', clean)
        assert match, clean
        return match.groups()

    def evaluate(self, source, expected=None):
        self.send(b'\x1b:')
        self.send(source.encode() + b'\r')
        clean = self.snapshot()[1]
        until = time.monotonic() + 5
        while expected is not None and expected not in clean and time.monotonic() < until:
            self.drain(.1)
            clean = self.snapshot()[1]
        return clean

    def command(self, name):
        self.send(b'\x1bx' + name.encode() + b'\r')

    def restored(self, success=True):
        # Debug error traces can fill the PTY; keep draining while waiting for restoration/exit.
        deadline = time.monotonic() + 5
        while self.process.poll() is None and time.monotonic() < deadline:
            self.drain(.02)
        self.process.wait(timeout=.1)
        self.drain(.1)
        assert (self.process.returncode == 0) == success
        assert bytes(self.output).count(b'\x1b[?1049h') == 1
        assert b'\x1b[?1049l' in self.output
        assert (self.root / 'restored.txt').read_text() == repr(self.original)

    def close(self):
        """Reap the owned child and release both PTY descriptors, including incomplete startup."""
        if self.process is not None and self.process.poll() is None:
            self.process.kill()
        for name in ('master', 'slave'):
            descriptor = getattr(self, name)
            if descriptor >= 0:
                os.close(descriptor)
                setattr(self, name, -1)
        if self.process is not None:
            self.process.wait(timeout=5)

