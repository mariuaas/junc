"""Private daemon fixtures and version-two protocol helpers for integration/PTY tests."""
import json
import os
from pathlib import Path
import signal
import socket
import struct
import tempfile
import time

def wait_ready(process, output, drain):
    """Auto-spawn adds startup work: wait for actual terminal initialization instead of a fixed delay."""
    until = time.monotonic() + 5
    while b'\x1b]4;15;?' not in output and process.poll() is None and time.monotonic() < until:
        drain(.05)
    assert b'\x1b]4;15;?' in output, bytes(output)


class Connection:
    def __init__(self, directory, attach=True):
        self.socket = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        self.socket.settimeout(5)
        try:
            self.socket.connect(str(Path(directory) / 'session.sock'))
            self.next_id = 1
            self.notifications = []
            self.hello = self.call('hello' if attach else 'ping')
        except BaseException:
            self.socket.close()
            raise

    def read(self, count):
        result = bytearray()
        while len(result) < count:
            part = self.socket.recv(count - len(result))
            if not part:
                raise EOFError('server closed a partial response')
            result.extend(part)
        return bytes(result)

    def call(self, op, **fields):
        request = dict(version=2, id=self.next_id, op=op, **fields)
        self.next_id += 1
        frame = json.dumps(request).encode()
        self.socket.sendall(struct.pack('<I', len(frame)) + frame)
        return self.reply(request['id'])

    def envelope(self):
        return json.loads(self.read(struct.unpack('<I', self.read(4))[0]))

    def reply(self, expected_id):
        while True:
            response = self.envelope()
            assert response['version'] == 2, response
            if response['id'] == 0:
                assert response['invalidation'] is not None, response
                self.notifications.append(response['invalidation'])
                continue
            assert response['id'] == expected_id, response
            return response

    def close(self):
        self.socket.close()

class DaemonRuntime:
    def __enter__(self):
        # Short paths also fit Darwin's sockaddr_un; no test shares the user's default server.
        self.temporary = tempfile.TemporaryDirectory(prefix='junc-test-', dir='/tmp')
        self.directory = Path(self.temporary.name)
        self.directory.chmod(0o700)
        return self

    def environment(self, base=None):
        return dict(os.environ if base is None else base, JUNC_RUNTIME_DIR=str(self.directory))

    def __exit__(self, *_):
        path = self.directory / 'session.sock'
        if path.exists() and not path.is_socket():
            self.temporary.cleanup()
            return
        pid = None
        deadline = time.monotonic() + 5
        while (self.directory / 'session.sock').exists() and time.monotonic() < deadline:
            connection = None
            try:
                connection = Connection(self.directory)
                pid = connection.hello['server_pid']
                if connection.hello.get('failure'):
                    time.sleep(.05)
                    continue
                # Explicitly discard fixture-only documents; no user runtime directory is contacted.
                response = connection.call('list')
                for buffer in response['buffers']:
                    result = connection.call('kill', buffer=buffer['id'], discard=True)
                    if result.get('failure'):
                        raise OSError(result['failure']['code'])
                result = connection.call('shutdown')
                if result.get('failure'):
                    raise OSError(result['failure']['code'])
                break
            except (OSError, EOFError):
                time.sleep(.05)
            finally:
                if connection is not None:
                    connection.close()
        until = time.monotonic() + 2
        while (self.directory / 'session.sock').exists() and time.monotonic() < until:
            time.sleep(.02)
        if (self.directory / 'session.sock').exists() and pid is not None:
            os.kill(pid, signal.SIGTERM)
        self.temporary.cleanup()
