#!/usr/bin/env python3
"""Bracketed paste uses one authoritative edit, literal data and bounded real-PTY interaction."""
import os
from pathlib import Path
import select
import signal
import tempfile
import time

from daemon_support import Connection, DaemonRuntime
from terminal_support import Terminal


def write(terminal, data):
    deadline = time.monotonic() + 5
    offset = 0
    while offset < len(data):
        assert time.monotonic() < deadline, 'PTY input stopped making progress'
        readable, writable, _ = select.select([terminal.master], [terminal.master], [], .02)
        if readable:
            terminal.drain(.001)
        if writable:
            try:
                offset += os.write(terminal.master, data[offset:offset + 4096])
            except BlockingIOError:
                pass


def snapshot(observer, buffer):
    response = observer.call('snapshot', buffer=buffer)
    assert response['failure'] is None, response
    return response['state']


def wait_revision(terminal, observer, buffer, revision):
    deadline = time.monotonic() + 5
    while time.monotonic() < deadline:
        terminal.drain(.02)
        state = snapshot(observer, buffer)
        if state['revision'] >= revision:
            assert state['revision'] == revision, state
            return state
    raise AssertionError(f'paste did not reach revision {revision}')


def text(observer, state):
    response = observer.call('view', buffer=state['buffer'], revision=state['revision'],
                             first_line=0, line_count=state['lines'])
    assert response['failure'] is None, response
    return response['view']['text']


with tempfile.TemporaryDirectory(prefix='junc-paste-') as directory, DaemonRuntime() as daemon:
    root = Path(directory)
    path = root / 'paste.lua'
    path.write_text('')
    terminal = Terminal(root, daemon, 'paste.lua')
    observer = None
    try:
        os.set_blocking(terminal.master, False)
        assert b'\x1b[?2004h' in terminal.output, 'bracketed paste was not enabled'
        observer = Connection(daemon.directory)
        state = observer.call('open', path=str(path))['state']
        buffer = state['buffer']

        started = time.monotonic()
        write(terminal, b'\x1b[200~' + b'x' * 512 + b'\x1b[201~')
        state = wait_revision(terminal, observer, buffer, 1)
        small_seconds = time.monotonic() - started
        assert state['count'] == 512 and text(observer, state) == 'x' * 512
        terminal.send(b'\x1a')
        state = wait_revision(terminal, observer, buffer, 2)
        assert text(observer, state) == '', 'paste required more than one undo'

        payload = ("local value = '界é👩‍💻' -- pasted\n" * 512).encode()
        # Split the start/end markers and UTF-8 across writes; an unfinished frame must not edit.
        started = time.monotonic()
        write(terminal, b'\x1b[20')
        terminal.drain(.03)
        write(terminal, b'0~' + payload)
        terminal.drain(.05)
        assert snapshot(observer, buffer)['revision'] == 2
        write(terminal, b'\x1b[20')
        terminal.drain(.03)
        write(terminal, b'1~')
        state = wait_revision(terminal, observer, buffer, 3)
        large_seconds = time.monotonic() - started
        assert text(observer, state) == payload.decode()
        terminal.send(b'\x1a')
        state = wait_revision(terminal, observer, buffer, 4)
        assert text(observer, state) == ''
        terminal.send(b'\x19')
        state = wait_revision(terminal, observer, buffer, 5)
        assert text(observer, state) == payload.decode()

        terminal.send(b'\x18h')  # Mark the whole buffer, then leave a prefix pending before paste.
        terminal.send(b'\x18')
        literal = b'x\r\n\t\x11\x13\x1b[A\nend'
        write(terminal, b'\x1b[200~' + literal + b'\x1b[201~')
        state = wait_revision(terminal, observer, buffer, 6)
        expected = literal.replace(b'\r\n', b'\n').decode()
        assert text(observer, state) == expected
        assert path.read_text() == '', 'pasted Ctrl-S executed a save'
        assert terminal.process.poll() is None, 'pasted Ctrl-Q quit the editor'
        terminal.send(b'z')
        state = wait_revision(terminal, observer, buffer, 7)
        assert text(observer, state) == expected + 'z', 'paste left a key prefix pending'

        terminal.send(b'\x1b:')
        write(terminal, b'\x1b[200~paste_executed=7\r\nreturn paste_executed\x11\x1b[201~')
        terminal.drain(.1)
        assert snapshot(observer, buffer)['revision'] == 7, 'minibuffer paste edited the document'
        terminal.send(b'\x07')
        assert b'true' in terminal.evaluate('paste_executed==nil'), 'paste evaluated REPL input'
        terminal.send(b'\x07\x11')
        terminal.restored()
        assert b'\x1b[?2004l' in terminal.output
        print(f'Paste PTY: 512 bytes in {small_seconds:.3f}s / one revision; '
              f'{len(payload)} Unicode bytes committed in {large_seconds:.3f}s / one revision')
    finally:
        if observer is not None:
            observer.close()
        terminal.close()

    # Connection loss during an unfinished paste must discard the payload and restore the terminal.
    terminal = Terminal(root, daemon, 'paste.lua')
    try:
        os.set_blocking(terminal.master, False)
        write(terminal, b'\x1b[200~incomplete paste')
        probe = Connection(daemon.directory, attach=False)
        pid = probe.hello['server_pid']
        probe.close()
        os.kill(pid, signal.SIGTERM)
        terminal.restored(success=False)
        assert b'\x1b[?2004l' in terminal.output
        assert b'Lost connection to junc server' in terminal.output
        assert b'error: EndOfStream' not in terminal.output
    finally:
        terminal.close()

print('Paste PTY passed: literal controls, fragmented frames, Unicode, one-step undo/redo, '
      'selection replacement, minibuffer isolation, error restoration and paste-mode teardown')
