#!/usr/bin/env python3
"""Automatic startup, protocol ordering, registry ownership and lifecycle without terminal rendering."""
import json
import os
from pathlib import Path
import socket
import stat
import struct
import subprocess
import tempfile
import time
import threading
from daemon_support import PROTOCOL_VERSION, Connection, DaemonRuntime

binary = Path(__file__).resolve().parents[1] / 'zig-out/bin/junc'

def launch(daemon, directory, filename):
    # Deliberately no controlling terminal: startup/open must finish before the TTY error detaches.
    return subprocess.Popen([str(binary), str(filename)], cwd=directory, env=daemon.environment(),
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True)

def wait(process):
    _, error = process.communicate(timeout=10)
    assert b'ServerStartup' not in error, error
    assert process.returncode != 0, 'this harness deliberately has no controlling terminal'
    return error

def okay(response):
    assert response['failure'] is None, response
    return response

def edit(connection, state, kind='replace', **fields):
    intent = dict(kind=kind, origin=state['revision'], interaction_origin=state['interaction_revision'], source='protocol-test', **fields)
    return connection.call('submit', buffer=state['buffer'], edit=intent)

def view(connection, state):
    return okay(connection.call('view', buffer=state['buffer'], revision=state['revision'], first_line=0, line_count=20))['view']

with tempfile.TemporaryDirectory(prefix='junc-files-') as directory, DaemonRuntime() as daemon:
    root = Path(directory)
    (root / 'one.lua').write_text('local x=1\n')
    (root / 'two.zig').write_text('const x=1;\n')
    (root / 'alias.lua').symlink_to(root / 'one.lua')
    first = launch(daemon, root, 'one.lua')
    second = launch(daemon, root, 'two.zig')
    wait(first)
    wait(second)
    owner = Connection(daemon.directory)
    okay(owner.hello)
    pid = owner.hello['server_pid']
    assert pid not in (first.pid, second.pid)
    assert os.getpgid(pid) not in (first.pid, second.pid)
    assert os.getsid(pid) not in (first.pid, second.pid)
    assert stat.S_IMODE(daemon.directory.stat().st_mode) == 0o700
    assert stat.S_IMODE((daemon.directory / 'session.sock').stat().st_mode) == 0o600
    assert stat.S_IMODE((daemon.directory / 'server.lock').stat().st_mode) == 0o600
    assert stat.S_IMODE((daemon.directory / 'server.log').stat().st_mode) == 0o600
    assert (daemon.directory / 'session.sock').stat().st_uid == os.getuid()
    probe = Connection(daemon.directory, attach=False)
    assert probe.hello['server_pid'] == pid and probe.hello['busy']
    probe.close()
    error = wait(launch(daemon, root, 'one.lua'))
    assert b'one attached editing client' not in error, error
    a = okay(owner.call('open', path=str(root / 'one.lua')))['state']
    alias = okay(owner.call('open', path=str(root / '.' / 'alias.lua')))['state']
    assert alias['buffer'] == a['buffer']
    assert alias['path'] == str((root / 'one.lua').resolve())
    b = okay(owner.call('open', path=str(root / 'two.zig')))['state']
    assert b['buffer'] != a['buffer']
    one = okay(owner.call('open'))['state']
    two = okay(owner.call('open'))['state']
    assert one['path'] is None and two['path'] is None and one['buffer'] != two['buffer']
    state = okay(owner.call('select', buffer=one['buffer']))['state']
    state = okay(edit(owner, state, start=0, finish=0, text='e'))['state']
    old = state
    state = okay(edit(owner, state, start=1, finish=1, text='́'))['state']
    assert state['count'] == 1 and state['cursor'] == 1 and state['dirty']
    observed = view(owner, state)
    assert observed['text'] == 'é' and observed['boundaries'] == [0, 3]
    rejected = edit(owner, old, start=0, finish=0, text='bad')
    assert rejected['failure']['code'] == 'StaleRevision'
    assert view(owner, state)['text'] == 'é'
    state = okay(edit(owner, state, kind='move', position=1, mark=0))['state']
    okay(owner.call('select', buffer=b['buffer']))
    restored = okay(owner.call('select', buffer=state['buffer']))['state']
    for key in ('cursor', 'mark', 'session', 'interaction_revision', 'revision', 'selection'):
        assert restored[key] == state[key], (key, restored, state)
    assert owner.call('kill', buffer=state['buffer'])['failure']['code'] == 'DirtyBuffer'
    assert owner.call('shutdown')['failure']['code'] == 'DirtyBuffers'
    okay(owner.call('detach'))
    owner.close()
    # Cross the actual idle deadline: clean unused hosts exit, while dirty detached hosts must survive.
    with DaemonRuntime() as unused:
        wait(launch(unused, root, 'one.lua'))
        until = time.monotonic() + 32
        while (unused.directory / 'session.sock').exists() and time.monotonic() < until:
            time.sleep(.1)
        assert not (unused.directory / 'session.sock').exists(), 'clean unused host did not expire'
        assert (daemon.directory / 'session.sock').exists(), 'dirty detached host expired'
    # The original launching processes have both exited; the daemon still owns unsaved bytes/history.
    owner = Connection(daemon.directory)
    assert owner.hello['server_pid'] == pid
    state2 = okay(owner.call('select', buffer=state['buffer']))['state']
    assert state2['cursor'] == 0 and state2['session'] != state['session']
    assert state2['revision'] == state['revision'] and view(owner, state2)['text'] == 'é'
    state2 = okay(edit(owner, state2, kind='undo'))['state']
    assert view(owner, state2)['text'] == 'e'
    saved = okay(owner.call('save', buffer=state2['buffer'], path=str(root / 'saved.txt')))['state']
    assert not saved['dirty'] and (root / 'saved.txt').read_text() == 'e'
    assert okay(owner.call('open', path=str(root / 'saved.txt')))['state']['buffer'] == saved['buffer']
    state2 = okay(edit(owner, saved, start=0, finish=0, text='dirty'))['state']
    result = okay(owner.call('kill', buffer=state2['buffer'], discard=True))
    assert all(item['id'] != state2['buffer'] for item in okay(owner.call('list'))['buffers'])
    # Each attachment enforces monotonically increasing ids; a duplicate gets an error then detaches.
    bad = dict(version=PROTOCOL_VERSION, id=owner.next_id-1, op='list')
    frame = json.dumps(bad).encode()
    owner.socket.sendall(struct.pack('<I', len(frame)) + frame)
    response = owner.reply(bad['id'])
    assert response['failure']['code'] == 'ProtocolOrder'
    assert owner.socket.recv(1) == b''
    owner.close()
    owner = Connection(daemon.directory)
    okay(owner.hello)
    owner.socket.sendall(struct.pack('<I', 0xffffffff))
    assert owner.socket.recv(1) == b''
    owner.close()
    deadline = time.monotonic() + 2
    while 'InvalidFrameLength' not in (daemon.directory / 'server.log').read_text() and time.monotonic() < deadline:
        time.sleep(.02)
    assert 'InvalidFrameLength' in (daemon.directory / 'server.log').read_text()
    # A later invocation from another cwd still selects this same server and canonical document.
    other = root / 'elsewhere'
    other.mkdir()
    wait(launch(daemon, other, root / 'one.lua'))
    owner = Connection(daemon.directory)
    assert owner.hello['server_pid'] == pid
    same = okay(owner.call('open', path=str(root / 'one.lua')))['state']
    assert same['buffer'] == a['buffer']
    okay(owner.call('shutdown'))
    owner.close()
    until = time.monotonic() + 3
    while (daemon.directory / 'session.sock').exists() and time.monotonic() < until:
        time.sleep(.02)
    assert not (daemon.directory / 'session.sock').exists(), 'graceful shutdown left its endpoint'

# Stale owned sockets can be removed under the lock. Regular files and symlinks cannot.
with tempfile.TemporaryDirectory(prefix='junc-files-') as directory, DaemonRuntime() as daemon:
    path = daemon.directory / 'session.sock'
    stale = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    stale.bind(str(path))
    path.chmod(0o600)
    stale.close()
    wait(launch(daemon, directory, 'new.txt'))
    owner = Connection(daemon.directory)
    okay(owner.hello)
    okay(owner.call('shutdown'))
    owner.close()

for symlink in (False, True):
    with tempfile.TemporaryDirectory(prefix='junc-files-') as directory, DaemonRuntime() as daemon:
        path = daemon.directory / 'session.sock'
        target = daemon.directory / 'retain.txt'
        if symlink:
            target.write_text('keep')
            path.symlink_to(target)
        else:
            path.write_text('keep')
            path.chmod(0o600)
        error = wait(launch(daemon, directory, 'new.txt'))
        assert b'UnsafeSocket' in error, error
        assert (target if symlink else path).read_text() == 'keep'

def frame(message):
    data = json.dumps(message).encode()
    return struct.pack('<I', len(data)) + data

def receive(connection):
    size = struct.unpack('<I', connection.recv(4, socket.MSG_WAITALL))[0]
    return json.loads(connection.recv(size, socket.MSG_WAITALL))

# Version mismatches fail explicitly in both directions, before either side decodes the rest.
with tempfile.TemporaryDirectory(prefix='junc-files-') as directory, DaemonRuntime() as daemon:
    wait(launch(daemon, directory, 'new.txt'))
    owner = Connection(daemon.directory)
    older = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    older.settimeout(5)
    older.connect(str(daemon.directory / 'session.sock'))
    older.sendall(frame(dict(version=PROTOCOL_VERSION - 1, id=1, op='hello', field_from_another_version=True)))
    response = receive(older)
    assert response['version'] == PROTOCOL_VERSION and response['id'] == 1, response
    assert response['failure']['code'] == 'UnsupportedVersion', response
    assert f'sent {PROTOCOL_VERSION - 1}' in response['failure']['message'], response
    assert older.recv(1) == b'', 'an incompatible client stayed attached'
    older.close()
    okay(owner.call('shutdown'))
    owner.close()

with tempfile.TemporaryDirectory(prefix='junc-files-') as directory, DaemonRuntime() as daemon:
    # A stand-in for a server from another junc version, answering the client's hello.
    listener = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    listener.bind(str(daemon.directory / 'session.sock'))
    (daemon.directory / 'session.sock').chmod(0o600)
    listener.listen(1)
    listener.settimeout(10)
    requests = []
    def answer():
        connection, _ = listener.accept()
        with connection:
            requests.append(receive(connection))
            connection.sendall(frame(dict(version=PROTOCOL_VERSION + 1, id=1, shape_from_another_version=[])))
            connection.recv(1)
    server = threading.Thread(target=answer)
    server.start()
    error = wait(launch(daemon, directory, 'new.txt'))
    server.join(10)
    listener.close()
    assert requests and requests[0]['version'] == PROTOCOL_VERSION and requests[0]['op'] == 'hello', requests
    assert b'IncompatibleServer' in error, error
    message = f'speaks hosting protocol {PROTOCOL_VERSION + 1}, but this client needs {PROTOCOL_VERSION}'
    assert message.encode() in error, error
    assert b'shutdown-server' in error, error

print('Daemon integration passed: auto-spawn/racing launches, cwd/process independence, multiple attachments, private/stale sockets, canonical buffers/scratch, sessions/Unicode/history, dirty retention, save/kill, framing/order, explicit protocol version mismatches and clean shutdown')
