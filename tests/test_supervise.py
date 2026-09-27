"""bin/supervise.pyw: log pump, restart limit, closed stdin and, on Windows, the kill-on-close job."""

import os
import subprocess
import sys
import tempfile
import time
import unittest
from importlib.machinery import SourceFileLoader

BIN = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'bin')
SUPERVISE = os.path.join(BIN, 'supervise.pyw')


def load_supervise():
	return SourceFileLoader('supervise', SUPERVISE).load_module()


class Lines:
	def __init__(self):
		self.lines = []

	def write(self, line):
		self.lines.append(line)


class Chunks:
	def __init__(self, chunks):
		self.chunks = list(chunks)

	def read1(self, size):
		return self.chunks.pop(0) if self.chunks else b''


class SuperviseTest(unittest.TestCase):
	def setUp(self):
		self.m = load_supervise()
		self.m.RESTART_SEC = 0

	def test_pump_keeps_what_a_terminal_shows(self):
		log = Lines()
		self.m.pump(Chunks([b'hello\r\n', b'wait 3\rwait 2\r', b'wait 1\r', b'\ndone\r', b'\nno newline']), log)
		self.assertEqual(log.lines, ['hello', 'wait 1', 'done', 'no newline'])

	def test_gives_up_after_five_starts(self):
		log = Lines()
		rc = self.m.supervise([sys.executable, '-c', 'import sys; sys.exit(3)'], True, log)
		self.assertEqual(rc, 1)
		self.assertEqual(sum('exited with code 3' in line for line in log.lines), 5)
		self.assertIn('giving up', log.lines[-1])

	def test_stdin_is_closed(self):
		log = Lines()
		rc = self.m.supervise([sys.executable, '-c', 'import sys; print(repr(sys.stdin.read()))'], False, log)
		self.assertEqual(rc, 0)
		self.assertIn("''", log.lines)

	def test_exit_seen_while_a_leftover_child_holds_the_output(self):
		# the adb server outlives the wrapper that started it, holding the output pipe open
		log = Lines()
		leftover = ('import subprocess, sys; '
					'subprocess.Popen([sys.executable, "-c", "import time; time.sleep(30)"]); print("wrapper done")')
		started = time.monotonic()
		rc = self.m.supervise([sys.executable, '-c', leftover], False, log)
		self.assertEqual(rc, 0)
		self.assertLess(time.monotonic() - started, 15)
		self.assertIn('wrapper done', log.lines)
		self.assertIn('exited with code 0', log.lines)

	def test_log_file(self):
		with tempfile.TemporaryDirectory() as tmp:
			path = os.path.join(tmp, 'logs', 'x.log')
			rc = subprocess.call([sys.executable, SUPERVISE, '--log', path, '--',
								  sys.executable, '-c', 'print("été")'])
			self.assertEqual(rc, 0)
			with open(path, encoding='utf-8') as f:
				text = f.read()
			self.assertIn('été', text)
			self.assertIn('exited with code 0', text)

	@unittest.skipUnless(os.name == 'nt', 'job objects are Windows-only')
	def test_killing_supervise_kills_the_whole_tree(self):
		import ctypes
		k32 = ctypes.WinDLL('kernel32', use_last_error=True)
		k32.OpenProcess.restype = ctypes.c_void_p
		k32.WaitForSingleObject.argtypes = (ctypes.c_void_p, ctypes.c_uint32)

		with tempfile.TemporaryDirectory() as tmp:
			pid_file = os.path.join(tmp, 'pid')
			# child that starts a grandchild (the emulator's role) and waits
			child = ('import subprocess, sys, time; '
					 'p = subprocess.Popen([sys.executable, "-c", "import time; time.sleep(300)"]); '
					 'open({!r}, "w").write(str(p.pid)); time.sleep(300)').format(pid_file)
			sup = subprocess.Popen([sys.executable, SUPERVISE, '--log', os.path.join(tmp, 'x.log'), '--',
									sys.executable, '-c', child])
			deadline = time.time() + 60
			while not os.path.exists(pid_file) or not open(pid_file).read():
				self.assertLess(time.time(), deadline, 'grandchild never started')
				time.sleep(0.2)
			grandchild = int(open(pid_file).read())

			SYNCHRONIZE = 0x00100000
			handle = k32.OpenProcess(SYNCHRONIZE, False, grandchild)
			self.assertTrue(handle, 'grandchild not running')
			sup.kill()  # TerminateProcess, like Stop-ScheduledTask
			sup.wait()
			# WAIT_OBJECT_0: the grandchild died with its supervisor
			self.assertEqual(k32.WaitForSingleObject(handle, 10000), 0)


if __name__ == '__main__':
	unittest.main()
