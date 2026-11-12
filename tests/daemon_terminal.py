#!/usr/bin/env python3
"""Multibuffer sessions and independent client policy over actual libvaxis terminal input/rendering."""
import os
from pathlib import Path
import re
import signal
import tempfile
import time
from daemon_support import Connection, DaemonRuntime

from terminal_support import Terminal

repo = Path(__file__).resolve().parents[1]

with tempfile.TemporaryDirectory(prefix='junc-buffers-') as directory, DaemonRuntime() as daemon:
    root = Path(directory)
    (root / 'lua').mkdir()
    one = 'local one = "界é"\n' + ''.join(f'local item{i}={i}\n' for i in range(35)) + 'local long="' + 'x'*250 + '"\n'
    two = 'const value = 42;\n'
    (root / 'one.lua').write_text(one)
    (root / 'two.zig').write_text(two)
    base = (repo / 'lua/presentation.lua').read_text()
    (root / 'lua/presentation.lua').write_text("local p=(function()\n" + base + "\nend)()\n" + """
for _, preset in pairs(p.presets) do
  preset.status=function(s)
    return string.format('STATE|b=%d|r=%d|i=%d|c=%d|m=%s|t=%d|l=%d|%s | %s',
      s.buffer_id,s.revision,s.interaction_revision,s.cursor,tostring(s.mark),s.top,s.left,s.preset,s.message)
  end
end
return p
""")
    terminal = Terminal(root, daemon, 'one.lua')
    try:
        raw, clean = terminal.snapshot()
        assert re.search(rb'199[:;]146[:;]234', raw), raw
        probe = Connection(daemon.directory, attach=False)
        pid = probe.hello['server_pid']
        probe.close()
        assert os.getpgid(pid) != os.getpgid(terminal.process.pid)
        assert os.getsid(pid) != os.getsid(terminal.process.pid)
        terminal.evaluate("client_token=99; editor.invoke('buffer-end'); editor.invoke('left'); editor.invoke('select-left')")
        terminal.send(b'\x07\x18\x10')  # Presentation remains client-local while buffers change.
        terminal.send(b'\x1b:')
        before = terminal.state()
        assert before[0] == b'1' and before[1] == b'0' and before[4] != b'nil'
        assert int(before[5]) > 0 and int(before[6]) > 0 and before[7] == b'minimal'
        terminal.command('open-file')
        terminal.send(b'two.zig\r')
        assert terminal.state()[0] == b'2'
        assert b'99' in terminal.evaluate('client_token')
        terminal.evaluate("editor.invoke('insert','// persistent\\n')")
        terminal.send(b'\x07\x13')
        assert (root / 'two.zig').read_text() == '// persistent\n' + two
        terminal.command('switch-buffer')
        terminal.send(b'1\t\r')
        terminal.send(b'\x1b:')
        assert terminal.state() == before, 'cursor, selection, viewport or presentation did not survive switching'
        assert b'99' in terminal.evaluate('client_token')
        terminal.command('open-file')
        terminal.send(b'\r')
        assert terminal.state()[0] == b'3'
        terminal.send(b'scratch dirty')
        unrelated = root / 'scratch.txt'
        unrelated.write_text('keep this unrelated file')
        before_save = terminal.state()
        terminal.send(b'\x13')
        assert b'Save as: ' in terminal.snapshot()[1]
        assert terminal.state() == before_save
        terminal.send(b'\r')
        assert b'A filename is required' in terminal.snapshot()[1]
        terminal.send(b'cancelled.lua\x1b')
        assert terminal.state() == before_save
        assert not (root / 'cancelled.lua').exists()
        assert unrelated.read_text() == 'keep this unrelated file'
        terminal.send(b'\x13')
        filename = 'named scratch 界.lua'
        terminal.send(filename.encode() + b'\r')
        assert (root / filename).read_text() == 'scratch dirty'
        assert terminal.state() == before_save, 'naming scratch changed document or interaction revisions'
        terminal.send(b'!\x13')
        assert (root / filename).read_text() == 'scratch dirty!'
        assert b'Save as: ' not in terminal.snapshot()[1]
        assert unrelated.read_text() == 'keep this unrelated file'
        terminal.send(b'?')
        terminal.command('kill-buffer')
        assert ('Discard ' + filename).encode() in terminal.snapshot()[1]
        terminal.send(b'no\r')
        assert b'Buffer retained' in terminal.snapshot()[1]
        terminal.send(b'\x07')
        assert terminal.state()[0] == b'3'
        terminal.command('kill-buffer')
        terminal.send(b'yes\r')
        assert terminal.state()[0] == b'1'
        terminal.command('list-buffers')
        clean = terminal.snapshot()[1]
        assert b'one.lua' in clean and b'two.zig' in clean, clean
        terminal.send(b'\x1b[B\x1b[B\r')
        assert terminal.state()[0] == b'2'
        before_reload = terminal.state()
        extension = root / 'lua/extension.lua'
        extension.write_text('invalid Lua !!!')
        terminal.send(b'\x12')
        assert terminal.state() == before_reload
        extension.unlink()
        terminal.send(b'\x12')
        assert terminal.state() == before_reload
        assert b'true' in terminal.evaluate('client_token==nil')
        terminal.send(b'\x07\x1a\x13')
        assert (root / 'two.zig').read_text() == two, 'switching/reload lost the authoritative undo history'
        terminal.evaluate("editor.invoke('insert','// unsaved\\n')")
        terminal.send(b'\x07')
        terminal.command('shutdown-server')
        assert b'DirtyBuffers' in terminal.snapshot()[1]
        assert terminal.process.poll() is None
        terminal.send(b'\x07')
        terminal.evaluate("attachment_token=101; editor.keymap('private',{j='down'}); editor.push_keymap('private')")
        terminal.send(b'\x07\x11')  # Detach keeps dirty document state; no discard confirmation.
        terminal.restored()
        assert (root / 'two.zig').read_text() == two
    finally:
        terminal.close()
    owner = Connection(daemon.directory)
    assert owner.hello['server_pid'] == pid
    state = owner.call('open', path=str(root / 'two.zig'))['state']
    observed = owner.call('view', buffer=state['buffer'], revision=state['revision'], first_line=0, line_count=5)['view']
    assert '// unsaved\n' in observed['text'] and state['dirty']
    owner.call('detach')
    owner.close()
    terminal = Terminal(root, daemon, 'two.zig')
    try:
        assert terminal.state()[0] == b'2' and terminal.state()[7] == b'classic'
        assert b'true' in terminal.evaluate('attachment_token==nil')
        assert b'emacs' in terminal.evaluate('editor.keymap_state().layers[1].name')
        terminal.send(b'\x07\x13')
        assert '// unsaved\n' in (root / 'two.zig').read_text()
        terminal.command('shutdown-server')
        terminal.restored()
    finally:
        terminal.close()
    deadline = time.monotonic() + 3
    while (daemon.directory / 'session.sock').exists() and time.monotonic() < deadline:
        time.sleep(.02)
    assert not (daemon.directory / 'session.sock').exists()
    # Connection loss unwinds the client and restores the terminal; it does not replay or respawn edits.
    terminal = Terminal(root, daemon, 'two.zig')
    try:
        probe = Connection(daemon.directory, attach=False)
        new_pid = probe.hello['server_pid']
        probe.close()
        assert new_pid != pid
        os.kill(new_pid, signal.SIGTERM)
        until = time.monotonic() + 3
        while (daemon.directory / 'session.sock').exists() and time.monotonic() < until:
            time.sleep(.02)
        terminal.send(b'x')
        terminal.restored(success=False)
    finally:
        terminal.close()
    terminal = Terminal(root, daemon, 'observer.txt')
    try:
        terminal.evaluate("editor.on_result=function(r) if r.surface=='document' then editor.open_file('two.zig') end end")
        terminal.evaluate("result=editor.invoke('insert','X')")
        result = terminal.evaluate("result.buffer_id,result.revision,editor.state().buffer_id,editor.state().revision", expected=b'1    1    2    0')
        assert b'1    1    2    0' in result, result
        terminal.evaluate("editor.on_result=function(r) editor.last_result=r end; editor.kill_buffer(1,true)")
        terminal.send(b'\x07')
        terminal.command('shutdown-server')
        terminal.restored()
    finally:
        terminal.close()
    print('Daemon PTY passed: server process/session independence, multiple source/scratch buffers, completion/list/dirty kill, cursor/selection/viewport restoration, syntax/Lua/presentation/keymaps/reload, detach/reattach ownership, retained undo, graceful shutdown and restoration after connection loss')
