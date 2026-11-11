#!/usr/bin/env python3
"""Failed PTY startup releases real descriptors and reaps any child already launched."""
import os
from pathlib import Path
import pty
import subprocess
import sys
import unittest
from unittest.mock import patch

from daemon_support import DaemonRuntime
from terminal_support import Terminal


class TerminalResources(unittest.TestCase):
    def assert_closed(self, descriptors):
        for descriptor in descriptors:
            with self.assertRaises(OSError):
                os.fstat(descriptor)

    def test_failed_spawn_closes_both_pty_descriptors(self):
        descriptors = pty.openpty()
        terminal = Terminal.__new__(Terminal)
        with DaemonRuntime() as daemon, patch('terminal_support.pty.openpty', return_value=descriptors):
            try:
                with patch('terminal_support.subprocess.Popen', side_effect=OSError('spawn failed')):
                    with self.assertRaisesRegex(OSError, 'spawn failed'):
                        terminal.__init__(Path.cwd(), daemon, 'unused')
                self.assert_closed(descriptors)
            finally:
                terminal.close()

    def test_failed_readiness_reaps_the_child_and_closes_the_pty(self):
        # Launch a real sleeping child, then force startup failure before the caller owns the Terminal.
        descriptors = pty.openpty()
        terminal = Terminal.__new__(Terminal)
        spawn = subprocess.Popen
        children = []

        def sleeping_child(_arguments, **options):
            child = spawn([sys.executable, '-c', 'import time; time.sleep(60)'], **options)
            children.append(child)
            return child

        with DaemonRuntime() as daemon, patch('terminal_support.pty.openpty', return_value=descriptors):
            try:
                with patch('terminal_support.subprocess.Popen', side_effect=sleeping_child), \
                     patch.object(Terminal, 'drain'), \
                     patch('terminal_support.wait_ready', side_effect=RuntimeError('not ready')):
                    with self.assertRaisesRegex(RuntimeError, 'not ready'):
                        terminal.__init__(Path.cwd(), daemon, 'unused')
                self.assertEqual(len(children), 1)
                self.assertIsNotNone(children[0].poll(), 'startup failure left a live child')
                self.assert_closed(descriptors)
            finally:
                terminal.close()


if __name__ == '__main__':
    unittest.main(verbosity=2)
