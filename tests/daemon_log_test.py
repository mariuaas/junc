#!/usr/bin/env python3
"""Detached daemon diagnostics remain private, append across restarts and reject unsafe files."""
import os
from pathlib import Path
import stat
import subprocess
import tempfile
import time

from daemon_support import Connection, DaemonRuntime

binary = Path(__file__).resolve().parents[1] / 'zig-out/bin/junc'


def launch(daemon, root):
    result = subprocess.run([str(binary), str(root / 'sample.txt')], cwd=root,
        env=daemon.environment(), stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
        stderr=subprocess.PIPE, start_new_session=True, timeout=10)
    assert result.returncode != 0  # Startup/open finishes; this process has no controlling terminal.
    return result.stderr


with tempfile.TemporaryDirectory(prefix='junc-log-files-') as directory, DaemonRuntime() as daemon:
    root = Path(directory)
    launch(daemon, root)
    log = daemon.directory / 'server.log'
    assert stat.S_IMODE(log.stat().st_mode) == 0o600
    owner = Connection(daemon.directory)
    # A malformed frame is rejected at the actual socket boundary and logged by the daemon.
    bad = Connection(daemon.directory)
    bad.socket.sendall(b'\xff\xff\xff\xff')
    assert bad.socket.recv(1) == b''
    bad.close()
    deadline = time.monotonic() + 3
    while 'InvalidFrameLength' not in log.read_text() and time.monotonic() < deadline:
        time.sleep(.02)
    before = log.read_bytes()
    assert b'InvalidFrameLength' in before
    result = owner.call('shutdown')
    assert result['failure'] is None, result
    owner.close()
    deadline = time.monotonic() + 3
    while (daemon.directory / 'session.sock').exists() and time.monotonic() < deadline:
        time.sleep(.02)
    launch(daemon, root)
    assert log.read_bytes().startswith(before), 'restart truncated the daemon log'

for kind in ('symlink', 'fifo', 'permissive', 'hardlink'):
    with tempfile.TemporaryDirectory(prefix='junc-log-files-') as directory, DaemonRuntime() as daemon:
        root = Path(directory)
        log = daemon.directory / 'server.log'
        target = root / 'keep.txt'
        target.write_text('keep')
        target.chmod(0o600)
        if kind == 'symlink':
            log.symlink_to(target)
        elif kind == 'fifo':
            os.mkfifo(log, 0o600)
        elif kind == 'hardlink':
            os.link(target, log)
        else:
            log.write_text('keep')
            log.chmod(0o640)
        error = launch(daemon, root)
        assert b'ServerLogOpenFailed' in error or b'UnsafeServerLog' in error, error
        assert not (daemon.directory / 'session.sock').exists()
        assert target.read_text() == 'keep'

print('Daemon log passed: private permissions, real diagnostics, append across restarts, '
      'symlink/FIFO/mode/hardlink rejection')
