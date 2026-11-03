"""Windows-only, isolated real-process tests. No Codex/account/model calls.
Run: python tool/test_codex_owned_launcher.py --helper PATH/BaocodeCodexLauncher.exe
"""
import argparse
import ctypes
from ctypes import wintypes
import json
import os
from pathlib import Path
import queue
import struct
import subprocess
import sys
import tempfile
import threading
import time
import unittest

HELPER = None
REJECT_JOB_HELPER = None
REJECT_MEMBERSHIP_HELPER = None


def read_exact(stream, count):
    result = b''
    while len(result) < count:
        data = stream.read(count - len(result))
        if not data:
            raise EOFError()
        result += data
    return result


class Run:
    def __init__(self, exe, args, cwd, env=None, helper=None, drain=True):
        clean = {key: os.environ[key] for key in ('SystemRoot', 'WINDIR', 'TEMP', 'TMP', 'PATH') if key in os.environ}
        clean.update(env or {})
        self.proc = subprocess.Popen([helper or HELPER], stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.PIPE,
                                     cwd=cwd, env=clean)
        self.read_gate = threading.Event()
        if drain:
            self.read_gate.set()
        self.events = queue.Queue()
        self.seen = []
        self.out = b''
        self.err = b''
        self.reader = threading.Thread(target=self._read, daemon=True)
        self.reader.start()
        header = b'BCJ1'
        for value in (str(exe), str(cwd), subprocess.list2cmdline([str(exe), *args])):
            data = value.encode('utf-8')
            header += struct.pack('<I', len(data)) + data
        self.proc.stdin.write(header)
        self.proc.stdin.flush()

    def _read(self):
        try:
            while True:
                self.read_gate.wait()
                kind, length = struct.unpack('<BI', read_exact(self.proc.stdout, 5))
                if kind not in (1, 2, 3) or length > 1024 * 1024:
                    raise AssertionError('Malformed launcher frame')
                self.events.put((kind, read_exact(self.proc.stdout, length)))
        except EOFError:
            self.events.put((0, b''))
        except BaseException as error:
            self.events.put((-1, error))

    def wait(self, predicate, timeout=12):
        deadline = time.monotonic() + timeout
        while not predicate(self):
            remaining = deadline - time.monotonic()
            if remaining <= 0:
                raise AssertionError('Launcher condition timed out: ' + repr(self.seen))
            try:
                kind, data = self.events.get(timeout=remaining)
            except queue.Empty:
                raise AssertionError('Launcher condition timed out: ' + repr(self.seen))
            if kind == -1:
                raise data
            if kind == 0:
                raise AssertionError('Unexpected launcher EOF: ' + repr(self.seen))
            if kind == 1:
                self.out += data
            elif kind == 2:
                self.err += data
            else:
                self.seen.append(data.decode('ascii'))

    def close_input(self):
        if not self.proc.stdin.closed:
            self.proc.stdin.close()

    def cleanup(self):
        self.read_gate.set()
        self.close_input()
        try:
            self.proc.wait(timeout=8)
        except subprocess.TimeoutExpired:
            # This Popen object retains the handle to exactly our fixture helper.
            # Its non-inherited Job handle closes and cleans only its own tree.
            self.proc.kill()
            self.proc.wait(timeout=5)
        self.reader.join(timeout=3)
        self.proc.stdout.close()
        self.proc.stderr.close()


@unittest.skipUnless(sys.platform == 'win32', 'requires real Windows Job Objects')
class OwnedLauncherTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='bao owned & % ! 雪 ')
        self.home = Path(self.temp.name)
        self.script = self.home / 'fixture.py'
        self.script.write_text('''import os,subprocess,sys,time
from pathlib import Path
mode=sys.argv[1]
if mode == 'tree':
 p=subprocess.Popen([sys.executable,__file__,'sleeper'])
 print('PID='+str(p.pid),flush=True)
elif mode == 'sleeper':
 time.sleep(60)
elif mode == 'blockedout':
 sys.stdout.buffer.write(b'x'*(4*1024*1024))
 sys.stdout.buffer.flush()
 Path('owned-pid').write_text(str(os.getpid()))
 sys.stdin.buffer.read()
elif mode == 'blocked':
 print('READY',flush=True)
 time.sleep(60)
elif mode == 'grace':
 print('READY',flush=True)
 sys.stdin.buffer.read()
 print('FINAL',flush=True)
elif mode == 'echo':
 print(os.environ.get('BAO_TEST_TOKEN','missing'),flush=True)
 print('job_empty',flush=True)
''', encoding='utf-8')
        self.runs = []
        self.handles = []
        kernel = ctypes.WinDLL('kernel32', use_last_error=True)
        self.open_process = kernel.OpenProcess
        self.open_process.argtypes = [wintypes.DWORD, wintypes.BOOL, wintypes.DWORD]
        self.open_process.restype = wintypes.HANDLE
        self.wait_handle = kernel.WaitForSingleObject
        self.wait_handle.argtypes = [wintypes.HANDLE, wintypes.DWORD]
        self.wait_handle.restype = wintypes.DWORD
        self.close_handle = kernel.CloseHandle
        self.close_handle.argtypes = [wintypes.HANDLE]

    def tearDown(self):
        for run in self.runs:
            run.cleanup()
        for handle in self.handles:
            self.close_handle(handle)
        self.temp.cleanup()

    def launch(self, mode, **kwargs):
        run = Run(sys.executable, [str(self.script), mode], self.home, **kwargs)
        self.runs.append(run)
        return run

    def child_handle(self, run):
        run.wait(lambda r: b'PID=' in r.out and b'\n' in r.out)
        pid = int(run.out.split(b'PID=', 1)[1].splitlines()[0])
        handle = self.open_process(0x100000, False, pid)  # SYNCHRONIZE only.
        self.assertTrue(handle, 'Capture live fixture handle before any shutdown')
        self.handles.append(handle)
        return handle

    def test_graceful_final_output(self):
        run = self.launch('grace')
        run.wait(lambda r: b'READY' in r.out)
        run.close_input()
        run.wait(lambda r: 'job_empty' in r.seen)
        self.assertIn(b'FINAL', run.out)
        self.assertEqual(run.proc.wait(timeout=5), 0)

    def test_root_exit_does_not_release_descendant(self):
        run = self.launch('tree')
        handle = self.child_handle(run)
        run.wait(lambda r: any(s.startswith('root_exited:') for s in r.seen))
        self.assertNotIn('job_empty', run.seen)
        self.assertEqual(self.wait_handle(handle, 0), 258)  # STILL_RUNNING.
        run.close_input()
        run.wait(lambda r: 'job_empty' in r.seen)
        self.assertEqual(self.wait_handle(handle, 5000), 0)

    def test_parent_eof_terminates_tree_while_output_delivery_is_paused(self):
        run = Run(sys.executable, [str(self.script), 'blockedout'], self.home,
                  drain=False)
        self.runs.append(run)
        marker = self.home / 'owned-pid'
        deadline = time.monotonic() + 5
        while not marker.exists() and time.monotonic() < deadline:
            time.sleep(0.01)
        self.assertTrue(marker.exists())
        # Read until the writer has completed its tiny PID marker.
        pid_text = ''
        while not pid_text and time.monotonic() < deadline:
            pid_text = marker.read_text()
            if not pid_text:
                time.sleep(0.01)
        handle = self.open_process(0x100000, False, int(pid_text))
        self.assertTrue(handle)
        self.handles.append(handle)
        run.close_input()
        self.assertEqual(self.wait_handle(handle, 5000), 0,
                         'Paused output must not hide parent EOF from owner')
        self.assertIsNone(run.proc.poll(), 'Final output still needs draining')
        run.read_gate.set()
        run.wait(lambda r: 'job_empty' in r.seen)
        self.assertEqual(len(run.out), 4 * 1024 * 1024)

    def test_parent_eof_reaches_owner_when_child_stdin_is_blocked(self):
        run = self.launch('blocked')
        run.wait(lambda r: b'READY' in r.out)
        write_errors = []
        def write_then_close():
            try:
                run.proc.stdin.write(b'x' * (8 * 1024 * 1024))
                run.proc.stdin.flush()
                run.close_input()
            except BaseException as error:
                write_errors.append(error)
        writer = threading.Thread(target=write_then_close, daemon=True)
        writer.start()
        writer.join(timeout=5)
        if writer.is_alive():
            run.proc.kill()  # Own helper handle; close its Job on failure.
            run.proc.wait(timeout=5)
            writer.join(timeout=5)
            self.fail('Child stdin backpressure blocked parent EOF')
        self.assertFalse(write_errors)
        run.wait(lambda r: 'job_empty' in r.seen)
        self.assertIn('job_terminated', run.seen)

    def test_parent_helper_crash_only_kills_owned_tree(self):
        sentinel = subprocess.Popen([sys.executable, '-c', 'import time;time.sleep(60)'])
        try:
            run = self.launch('tree')
            handle = self.child_handle(run)
            run.proc.kill()  # Retained helper handle, never a PID lookup.
            run.proc.wait(timeout=5)
            self.assertEqual(self.wait_handle(handle, 5000), 0)
            self.assertIsNone(sentinel.poll())
        finally:
            sentinel.terminate()
            sentinel.wait(timeout=5)

    def test_repeated_nonzero_exit_is_preserved(self):
        for _ in range(3):
            run = Run(sys.executable, ['-c', 'import sys;sys.exit(7)'], self.home)
            self.runs.append(run)
            run.wait(lambda r: 'job_empty' in r.seen)
            self.assertIn('root_exited:7', run.seen)
            self.assertEqual(run.proc.wait(timeout=5), 7)

    def test_missing_executable_fails_closed(self):
        run = Run(self.home / 'missing.exe', [], self.home)
        self.runs.append(run)
        run.wait(lambda r: any(s.startswith('launch_failed:') for s in r.seen))
        self.assertNotEqual(run.proc.wait(timeout=5), 0)

    def test_injected_assignment_failures_never_resume_child(self):
        for helper in (REJECT_JOB_HELPER, REJECT_MEMBERSHIP_HELPER):
            if not helper:
                self.skipTest('compile-only failure variant not supplied')
            marker = self.home / 'must-not-exist'
            code = 'from pathlib import Path;Path(' + repr(str(marker)) + ').touch()'
            run = Run(sys.executable, ['-c', code], self.home, helper=helper)
            self.runs.append(run)
            run.wait(lambda r: any(s.startswith('launch_failed:') for s in r.seen))
            self.assertNotEqual(run.proc.wait(timeout=5), 0)
            self.assertFalse(marker.exists(), 'Suspended child must never run')

    def test_cmd_environment_expansion_preserves_special_path(self):
        shim = self.home / 'shim & % ! 雪.cmd'
        # Paths expand from environment values after cmd's initial parsing,
        # matching BaoCode's production shim launch strategy.
        shim.write_text('@echo off\r\n%BAO_TEST_PYTHON% %BAO_TEST_SCRIPT% echo\r\n', encoding='utf-8')
        cmd = Path(os.environ['SystemRoot']) / 'System32' / 'cmd.exe'
        run = Run(cmd, ['/d', '/v:off', '/c', '%baocode_codex_executable%'], self.home,
                  {'baocode_codex_executable': '"' + str(shim) + '"',
                   'BAO_TEST_PYTHON': '"' + sys.executable + '"',
                   'BAO_TEST_SCRIPT': '"' + str(self.script) + '"',
                   'BAO_TEST_TOKEN': 'fixture-only-token'})
        self.runs.append(run)
        run.wait(lambda r: 'job_empty' in r.seen)
        self.assertIn(b'fixture-only-token', run.out)
        self.assertIn(b'job_empty', run.out)
        self.assertNotIn('fixture-only-token', ' '.join(run.seen))
        self.assertEqual(run.proc.wait(timeout=5), 0)


if __name__ == '__main__':
    parser = argparse.ArgumentParser()
    parser.add_argument('--helper', required=True)
    parser.add_argument('--reject-job-helper')
    parser.add_argument('--reject-membership-helper')
    args, remaining = parser.parse_known_args()
    HELPER = str(Path(args.helper).resolve())
    REJECT_JOB_HELPER = (str(Path(args.reject_job_helper).resolve())
                         if args.reject_job_helper else None)
    REJECT_MEMBERSHIP_HELPER = (str(Path(args.reject_membership_helper).resolve())
                                if args.reject_membership_helper else None)
    unittest.main(argv=[sys.argv[0], *remaining])
