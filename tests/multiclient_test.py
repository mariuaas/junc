#!/usr/bin/env python3
"""Authoritative two-session edits, stale rejection and nonblocking transport; no client replicas."""
import contextlib
from concurrent.futures import ThreadPoolExecutor
import json
from pathlib import Path
import struct
import subprocess
import tempfile
import threading
import time
import unittest
from daemon_support import Connection, DaemonRuntime

binary = Path(__file__).resolve().parents[1] / 'zig-out/bin/junc'

def okay(response):
    assert response['failure'] is None, response
    return response

def change(connection, state, kind='replace', **fields):
    return connection.call('submit', buffer=state['buffer'], edit=dict(kind=kind,
        origin=state['revision'], interaction_origin=state['interaction_revision'], source='two-client-test', **fields))

def observation(connection, buffer):
    response = okay(connection.call('observe', buffer=buffer, first_line=0, line_count=12))
    assert response['state']['revision'] == response['view']['revision']
    assert response['state']['buffer'] == response['view']['buffer'] == buffer
    return response

class SharedEditor(unittest.TestCase):
    def setUp(self):
        self.resources = contextlib.ExitStack()
        self.addCleanup(self.resources.close)
        self.root = Path(self.resources.enter_context(tempfile.TemporaryDirectory(prefix='junc-clients-')))
        self.daemon = self.resources.enter_context(DaemonRuntime())
        self.source = self.root / 'shared.txt'
        self.source.write_text('ab\n界é\n')
        process = subprocess.run([str(binary), str(self.source)], env=self.daemon.environment(), cwd=self.root,
            stdin=subprocess.DEVNULL, stdout=subprocess.PIPE, stderr=subprocess.PIPE, start_new_session=True, timeout=10)
        self.assertNotEqual(process.returncode, 0)  # Fixture intentionally has no controlling terminal.
        self.a = Connection(self.daemon.directory)
        self.resources.callback(self.a.close)
        self.b = Connection(self.daemon.directory)
        self.resources.callback(self.b.close)
        okay(self.a.hello); okay(self.b.hello)
        self.assertEqual(self.a.hello['server_pid'], self.b.hello['server_pid'])
        self.sa = okay(self.a.call('open', path=str(self.source)))['state']
        self.sb = okay(self.b.call('open', path=str(self.source)))['state']
        self.assertEqual(self.sa['buffer'], self.sb['buffer'])
        self.assertNotEqual(self.sa['session'], self.sb['session'])
        self.assertNotEqual(self.sa['cursor_anchor'], self.sb['cursor_anchor'])

    def test_racing_edits_commit_once_and_reject_the_other_origin(self):
        barrier = threading.Barrier(2)
        def submit(connection, state, text):
            barrier.wait(timeout=3)
            return change(connection, state, start=0, finish=0, text=text)
        with ThreadPoolExecutor(max_workers=2) as workers:
            a = workers.submit(submit, self.a, self.sa, 'A')
            b = workers.submit(submit, self.b, self.sb, 'B')
            replies = [a.result(timeout=5), b.result(timeout=5)]
        accepted = [reply for reply in replies if reply['failure'] is None]
        rejected = [reply for reply in replies if reply['failure'] is not None]
        self.assertEqual(len(accepted), 1, replies)
        self.assertEqual(len(rejected), 1, replies)
        self.assertEqual(rejected[0]['failure']['code'], 'StaleRevision')
        self.assertEqual(rejected[0]['state']['revision'], 1)
        a = observation(self.a, self.sa['buffer'])
        b = observation(self.b, self.sb['buffer'])
        self.assertEqual(a['view'], b['view'])
        self.assertEqual(a['state']['revision'], 1, 'rejected input was silently replayed')
        self.assertIn(a['view']['text'], ['Aab\n界é\n', 'Bab\n界é\n'])

    def test_passive_revisions_stale_origins_and_selection_replacement(self):
        a, b, sa, sb = self.a, self.b, self.sa, self.sb
        sb = okay(change(b, sb, kind='move', position=2, mark=1))['state']
        old_b = sb
        sa = okay(change(a, sa, start=0, finish=0, text='X'))['state']
        observed = observation(b, sb['buffer'])
        sb = observed['state']
        self.assertEqual(observed['view']['text'], 'Xab\n界é\n')
        self.assertEqual((sb['cursor'], sb['mark']), (3, 2))
        self.assertEqual(old_b['interaction_revision'], sb['interaction_revision'])
        for kind, fields in [('replace', dict(start=1, finish=2, text='WRONG')), ('move', dict(position=1))]:
            stale = change(b, old_b, kind=kind, **fields)
            self.assertEqual(stale['failure']['code'], 'StaleRevision')
            self.assertEqual(stale['state']['revision'], sa['revision'])
            self.assertEqual(stale['state']['interaction_revision'], sb['interaction_revision'])
            self.assertEqual(stale['state']['cursor'], sb['cursor'])
        self.assertEqual(observation(a, sa['buffer'])['view']['text'], 'Xab\n界é\n')
        before_a = observation(a, sa['buffer'])['state']
        sb = okay(change(b, sb, start=sb['first'], finish=sb['last'], text='é'))['state']
        after_a = observation(a, sa['buffer'])['state']
        self.assertIsNone(sb['mark'])
        self.assertEqual(sb['cursor'], 3)
        self.assertEqual(before_a['interaction_revision'], after_a['interaction_revision'])
        self.assertEqual(after_a['cursor_anchor'], before_a['cursor_anchor'])
        self.assertEqual(okay(a.call('list'))['buffers'][0]['revision'], sb['revision'])
        for kind, expected in [('undo', 'Xab\n界é\n'), ('redo', 'Xaé\n界é\n')]:
            before = sb
            sb = okay(change(b, sb, kind=kind))['state']
            peer = observation(a, sa['buffer'])
            self.assertEqual(peer['view']['text'], expected)
            self.assertEqual(sb['revision'], peer['state']['revision'])
            self.assertEqual(before['interaction_revision'], sb['interaction_revision'])
            self.assertEqual(after_a['interaction_revision'], peer['state']['interaction_revision'])

    def test_partial_frames_and_slow_readers_do_not_stall_another_client(self):
        a, b, sa, sb = self.a, self.b, self.sa, self.sb
        frame = json.dumps(dict(version=2, id=b.next_id, op='snapshot', buffer=sb['buffer'])).encode()
        pending_id = b.next_id; b.next_id += 1
        b.socket.sendall(struct.pack('<I', len(frame))[:2])
        started = time.monotonic()
        current = observation(a, sa['buffer'])['state']
        self.assertLess(time.monotonic() - started, 2)
        b.socket.sendall(struct.pack('<I', len(frame))[2:] + frame)
        self.assertEqual(okay(b.reply(pending_id))['state']['revision'], current['revision'])
        large = 'x' * 32_000
        sa = okay(change(a, current, start=0, finish=current['count'], text=large))['state']
        b_state = observation(b, sa['buffer'])['state']
        query = json.dumps(dict(version=2, id=b.next_id, op='view', buffer=sa['buffer'],
            revision=sa['revision'], first_line=0, line_count=1)).encode()
        view_id = b.next_id; b.next_id += 1
        b.socket.sendall(struct.pack('<I', len(query)) + query)
        # Establish that a large response began, then deliberately stop draining the socket.
        length = struct.unpack('<I', b.read(4))[0]
        while length <= 100_000:
            hint = json.loads(b.read(length))
            self.assertEqual(hint['id'], 0)
            b.notifications.append(hint['invalidation'])
            length = struct.unpack('<I', b.read(4))[0]
        started = time.monotonic()
        okay(a.call('ping'))
        self.assertLess(time.monotonic() - started, 1, 'slow peer blocked unrelated transport')
        started = time.monotonic()
        sa = okay(change(a, sa, start=0, finish=0, text='Z'))['state']
        self.assertLess(time.monotonic() - started, 3, 'slow reader blocked the mutation loop')
        old_view = json.loads(b.read(length))
        self.assertEqual(old_view['id'], view_id)
        self.assertEqual(old_view['view']['text'], large)
        self.assertEqual(old_view['view']['revision'], b_state['revision'])
        latest = observation(b, sa['buffer'])
        self.assertEqual(latest['view']['text'], 'Z' + large)
        self.assertTrue(b.notifications)
        self.assertTrue(all('generation' in hint and 'buffer' in hint and 'event' not in hint for hint in b.notifications))

    def test_shared_lifetimes_and_missing_origin_are_protected(self):
        a, b, sa = self.a, self.b, self.sa
        self.assertEqual(a.call('kill', buffer=sa['buffer'], discard=True)['failure']['code'], 'BufferInUse')
        self.assertEqual(a.call('shutdown')['failure']['code'], 'ClientsAttached')
        c = Connection(self.daemon.directory)
        try:
            okay(c.hello)
            cs = okay(c.call('open', path=str(self.source)))['state']
            missing = dict(version=2, id=c.next_id, op='submit', buffer=cs['buffer'],
                edit=dict(kind='move', interaction_origin=cs['interaction_revision'], source='missing-origin', position=0))
            encoded = json.dumps(missing).encode()
            c.socket.sendall(struct.pack('<I', len(encoded)) + encoded)
            try:
                self.assertEqual(c.socket.recv(1), b'')
            except ConnectionResetError:
                pass
        finally:
            c.close()
        self.assertEqual(observation(a, sa['buffer'])['state']['revision'], sa['revision'])
        okay(b.call('detach'))
        result = okay(a.call('kill', buffer=sa['buffer'], discard=True))
        self.assertNotEqual(result['state']['buffer'], sa['buffer'])
        okay(a.call('shutdown'))

    def test_killing_an_inactive_visit_does_not_leave_a_peer_with_a_dead_session(self):
        scratch = okay(self.b.call('open'))['state']
        old = self.sa['buffer']
        okay(self.a.call('kill', buffer=old, discard=True))
        rejected = self.b.call('select', buffer=old)
        self.assertEqual(rejected['failure']['code'], 'BufferNotFound')
        self.assertEqual(rejected['state']['buffer'], scratch['buffer'])
        current = observation(self.b, scratch['buffer'])['state']
        updated = okay(change(self.b, current, start=0, finish=0, text='still alive'))['state']
        self.assertEqual(observation(self.b, scratch['buffer'])['view']['text'], 'still alive')
        self.assertEqual(updated['session'], scratch['session'])

if __name__ == '__main__':
    unittest.main(verbosity=2)
