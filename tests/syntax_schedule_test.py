#!/usr/bin/env python3
"""Input-first cooperative syntax upkeep, stale coordinates and idle completion over real sockets."""
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import time

from daemon_support import Connection, DaemonRuntime, PROTOCOL_VERSION

binary = Path(__file__).resolve().parents[1] / 'zig-out/bin/junc'


def okay(response):
    assert response['failure'] is None, response
    return response


def observe(c, state):
    return okay(c.call('observe', buffer=state['buffer'], first_line=0, line_count=10))


def completion(c, generation):
    deadline = time.monotonic() + 15
    while time.monotonic() < deadline:
        if any(n['generation'] > generation for n in c.notifications):
            return
        # No requests: only background completion can wake this observer.
        notice = c.envelope()
        assert notice['id'] == 0 and notice['invalidation'], notice
        c.notifications.append(notice['invalidation'])
    raise AssertionError('syntax completion did not notify an idle client')


with tempfile.TemporaryDirectory(prefix='junc-syntax-files-') as directory, DaemonRuntime() as daemon:
    root = Path(directory)
    small = root / 'small.lua'
    small.write_text('local value = 1\n')
    large = root / 'large.lua'
    large.write_text('local value = "界é" -- comment\n' * 35000)
    assert large.stat().st_size > 1024 * 1024
    # Auto-start the daemon; no TTY means the launching client detaches after opening its file.
    started = subprocess.run([str(binary), str(small)], env=daemon.environment(),
        stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
        start_new_session=True, timeout=10)
    assert started.returncode != 0
    a, b = Connection(daemon.directory), Connection(daemon.directory)
    try:
        sa = okay(a.call('open', path=str(small)))['state']
        # Queue all frames before the server sees work. Even a tiny parse must wait until this
        # input is serviced; observing text and submitting edits cannot perform maintenance.
        first_id = a.next_id
        requests = [
            dict(op='observe', buffer=sa['buffer'], first_line=0, line_count=10),
            dict(op='submit', buffer=sa['buffer'], edit=dict(kind='replace', origin=sa['revision'],
                interaction_origin=sa['interaction_revision'], source='schedule-test',
                start=0, finish=0, text='-- pending\n')),
            dict(op='snapshot', buffer=sa['buffer']),
            dict(op='observe', buffer=sa['buffer'], first_line=0, line_count=10),
        ]
        frames = []
        for index, request in enumerate(requests):
            data = json.dumps(dict(version=PROTOCOL_VERSION, id=first_id+index, **request)).encode()
            frames.append(struct.pack('<I', len(data)) + data)
        a.next_id += len(requests)
        a.socket.sendall(b''.join(frames))
        replies = [okay(a.reply(first_id+i)) for i in range(len(requests))]
        assert replies[0]['view']['syntax_state'] == 'stale'
        assert replies[0]['view']['tokens'] == []
        edited, viewed = replies[1], replies[3]
        assert edited['state']['revision'] == 1
        assert viewed['state']['revision'] == viewed['view']['revision'] == 1
        assert viewed['view']['syntax_state'] == 'stale' and viewed['view']['tokens'] == []
        assert viewed['generation'] == edited['generation'], 'maintenance ran ahead of queued input'
        a.socket.settimeout(15)
        completion(a, viewed['generation'])
        ready = observe(a, edited['state'])
        assert ready['view']['syntax_state'] == 'ready'
        assert ready['view']['tokens'][0]['category'] == 'comment'
        for field in ('revision', 'interaction_revision', 'cursor', 'mark'):
            assert ready['state'][field] == edited['state'][field], field

        sb = okay(b.call('open', path=str(large)))['state']
        pending = observe(b, sb)
        assert pending['view']['syntax_state'] == 'stale' and pending['view']['tokens'] == []
        # A large parse stays pending while another active buffer receives new work. Round-robin
        # upkeep must notify both observers, without further input from the large-file client.
        changed = okay(a.call('submit', buffer=sa['buffer'], edit=dict(kind='replace',
            origin=ready['state']['revision'], interaction_origin=ready['state']['interaction_revision'],
            source='schedule-test', start=0, finish=0, text='-- newer\n')))
        stale = observe(a, changed['state'])
        if stale['view']['syntax_state'] != 'ready':
            completion(a, changed['generation'])
        assert observe(a, changed['state'])['view']['syntax_state'] == 'ready'
        # Selecting an already-open buffer does not emit an unrelated registry invalidation.
        # Both idle clients must receive the shared provider's eventual completion.
        shared = okay(a.call('select', buffer=sb['buffer']))['state']
        shared_view = observe(a, shared)
        if shared_view['view']['syntax_state'] != 'ready':
            completion(a, shared_view['generation'])
        assert observe(a, shared)['view']['syntax_state'] == 'ready'
        b.socket.settimeout(15)
        completion(b, pending['generation'])
        large_ready = observe(b, sb)
        assert large_ready['view']['syntax_state'] == 'ready' and large_ready['view']['tokens']
        assert large_ready['state']['revision'] == large_ready['state']['interaction_revision'] == 0
        assert small.read_text() == 'local value = 1\n', 'maintenance saved the edited buffer'
    finally:
        a.close()
        b.close()

print('Syntax scheduling passed: input-first frames, parse-free views/submissions, stale-token exclusion, '
      'idle invalidations, >1 MiB highlighting, multiple active buffers and revision preservation')
