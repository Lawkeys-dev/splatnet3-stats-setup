"""Task Scheduler entry point: runs a bin\\*.cmd wrapper the way systemd runs a unit.

Started with pythonw.exe, so no console window ever shows up. It gives the
wrapper what the Linux setup gets from systemd:

  - no window: the wrapper starts with CREATE_NO_WINDOW and its whole process
    tree shares that hidden console
  - StandardInput=null: stdin is closed, so s3s's "update now?" prompt raises
    EOFError instead of hanging forever
  - the journal: stdout/stderr go to a timestamped log file, rotated at 5 MB.
    s3s redraws a countdown with carriage returns every second; only what a
    terminal would end up showing is kept. The wrapper's exit is what counts,
    not the end of its output: the adb server it may leave running holds that open
  - KillMode=control-group: the tree runs in a job object that is killed when
    this process dies, so Stop-ScheduledTask does not leave an emulator behind
  - Restart=always, RestartSec=60, StartLimitBurst=5 per 600 s (with --restart)

  pythonw.exe supervise.pyw [--restart] --log FILE -- WRAPPER.cmd [ARGS...]
"""

import argparse
import collections
import ctypes
import os
import subprocess
import sys
import threading
import time
import traceback

RESTART_SEC = 60
START_LIMIT_INTERVAL_SEC = 600
START_LIMIT_BURST = 5
MAX_LOG_BYTES = 5 * 1024 * 1024
# how long to keep reading output after the wrapper exits (see run_once)
OUTPUT_GRACE_SEC = 5


class Log:
	"""Timestamped append-only log, rotated to FILE.1 once it reaches MAX_LOG_BYTES."""

	def __init__(self, path):
		self.path = path
		os.makedirs(os.path.dirname(os.path.abspath(path)), exist_ok=True)
		self.file = open(path, 'a', encoding='utf-8')
		self.rotate_at = MAX_LOG_BYTES
		self.lock = threading.Lock()

	def write(self, line):
		with self.lock:  # the output pump and the supervisor both write
			self.file.write('{} {}\n'.format(time.strftime('%Y-%m-%d %H:%M:%S'), line))
			self.file.flush()
			if self.file.tell() >= self.rotate_at:
				self.rotate()

	def rotate(self):
		self.file.close()
		try:
			os.replace(self.path, self.path + '.1')
		except OSError:
			pass  # open in another program (Get-Content -Wait): retry a bit later
		self.file = open(self.path, 'a', encoding='utf-8')
		self.rotate_at = max(MAX_LOG_BYTES, self.file.tell() + MAX_LOG_BYTES // 5)


class KillOnCloseJob:
	"""Windows job object that kills every process in it when its last handle closes,
	i.e. when this process exits or Task Scheduler terminates it."""

	JOB_OBJECT_EXTENDED_LIMIT_INFORMATION = 9
	JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000
	PROCESS_TERMINATE = 0x0001
	PROCESS_SET_QUOTA = 0x0100

	def __init__(self):
		from ctypes import wintypes

		class IO_COUNTERS(ctypes.Structure):
			_fields_ = [(name, ctypes.c_uint64) for name in (
				'ReadOperationCount', 'WriteOperationCount', 'OtherOperationCount',
				'ReadTransferCount', 'WriteTransferCount', 'OtherTransferCount')]

		class JOBOBJECT_BASIC_LIMIT_INFORMATION(ctypes.Structure):
			_fields_ = [('PerProcessUserTimeLimit', ctypes.c_int64),
						('PerJobUserTimeLimit', ctypes.c_int64),
						('LimitFlags', wintypes.DWORD),
						('MinimumWorkingSetSize', ctypes.c_size_t),
						('MaximumWorkingSetSize', ctypes.c_size_t),
						('ActiveProcessLimit', wintypes.DWORD),
						('Affinity', ctypes.c_size_t),
						('PriorityClass', wintypes.DWORD),
						('SchedulingClass', wintypes.DWORD)]

		class JOBOBJECT_EXTENDED_LIMIT_INFORMATION(ctypes.Structure):
			_fields_ = [('BasicLimitInformation', JOBOBJECT_BASIC_LIMIT_INFORMATION),
						('IoInfo', IO_COUNTERS),
						('ProcessMemoryLimit', ctypes.c_size_t),
						('JobMemoryLimit', ctypes.c_size_t),
						('PeakProcessMemoryUsed', ctypes.c_size_t),
						('PeakJobMemoryUsed', ctypes.c_size_t)]

		k32 = ctypes.WinDLL('kernel32', use_last_error=True)
		k32.CreateJobObjectW.restype = wintypes.HANDLE
		k32.CreateJobObjectW.argtypes = (wintypes.LPVOID, wintypes.LPCWSTR)
		k32.SetInformationJobObject.argtypes = (wintypes.HANDLE, ctypes.c_int, wintypes.LPVOID, wintypes.DWORD)
		k32.OpenProcess.restype = wintypes.HANDLE
		k32.OpenProcess.argtypes = (wintypes.DWORD, wintypes.BOOL, wintypes.DWORD)
		k32.AssignProcessToJobObject.argtypes = (wintypes.HANDLE, wintypes.HANDLE)
		k32.CloseHandle.argtypes = (wintypes.HANDLE,)
		self.k32 = k32

		# the handle is never closed on purpose: it lives exactly as long as this process
		self.handle = k32.CreateJobObjectW(None, None)
		if not self.handle:
			raise ctypes.WinError(ctypes.get_last_error())

		info = JOBOBJECT_EXTENDED_LIMIT_INFORMATION()
		info.BasicLimitInformation.LimitFlags = self.JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
		if not k32.SetInformationJobObject(self.handle, self.JOB_OBJECT_EXTENDED_LIMIT_INFORMATION,
										   ctypes.byref(info), ctypes.sizeof(info)):
			raise ctypes.WinError(ctypes.get_last_error())

	def add(self, pid):
		"""Put a freshly started process in the job; the processes it starts inherit it."""
		process = self.k32.OpenProcess(self.PROCESS_SET_QUOTA | self.PROCESS_TERMINATE, False, pid)
		if not process:
			raise ctypes.WinError(ctypes.get_last_error())
		try:
			if not self.k32.AssignProcessToJobObject(self.handle, process):
				raise ctypes.WinError(ctypes.get_last_error())
		finally:
			self.k32.CloseHandle(process)


def terminal_text(line):
	"""What a terminal shows for one line of output: the text after the last \\r."""
	line = line.rstrip()
	return line[line.rfind(b'\r') + 1:].rstrip()


def pump(stream, log):
	"""Copy the child's output into the log line by line until it closes its end."""
	pending = b''
	while True:
		chunk = stream.read1(65536)
		if not chunk:
			break
		*lines, pending = (pending + chunk).split(b'\n')
		for line in lines:
			log.write(terminal_text(line).decode('utf-8', 'replace'))
		# a countdown without newline would grow forever: keep only its current redraw
		# (a trailing \r may be the first half of a \r\n split across two reads)
		pending = pending[pending.rfind(b'\r', 0, len(pending) - 1) + 1:]
	if pending.strip():
		log.write(terminal_text(pending).decode('utf-8', 'replace'))


def run_once(command, log, job):
	log.write('starting: {}'.format(subprocess.list2cmdline(command)))
	env = dict(os.environ, PYTHONUTF8='1', PYTHONUNBUFFERED='1')
	flags = subprocess.CREATE_NO_WINDOW if os.name == 'nt' else 0
	proc = subprocess.Popen(command, stdin=subprocess.DEVNULL, stdout=subprocess.PIPE,
							stderr=subprocess.STDOUT, env=env, creationflags=flags)
	if job is not None:
		try:
			job.add(proc.pid)
		except OSError as e:
			log.write('could not put the process in the job object ({}); '
					  'stopping the task may leave the emulator running'.format(e))
	pumper = threading.Thread(target=pump, args=(proc.stdout, log), daemon=True)
	pumper.start()
	rc = proc.wait()
	# a process the wrapper leaves behind (the adb server) inherits the pipe and keeps it
	# open: waiting for EOF would never see the wrapper exit, so stop reading shortly after
	pumper.join(OUTPUT_GRACE_SEC)
	if not pumper.is_alive():
		proc.stdout.close()
	log.write('exited with code {}'.format(rc))
	return rc


def supervise(command, restart, log):
	try:
		job = KillOnCloseJob() if os.name == 'nt' else None
	except OSError as e:
		log.write('no job object ({}); stopping the task may leave the emulator running'.format(e))
		job = None

	starts = collections.deque()
	while True:
		now = time.monotonic()
		while starts and now - starts[0] > START_LIMIT_INTERVAL_SEC:
			starts.popleft()
		if len(starts) >= START_LIMIT_BURST:
			log.write('started {} times within {} s, giving up; Start-ScheduledTask to try again'.format(
				START_LIMIT_BURST, START_LIMIT_INTERVAL_SEC))
			return 1
		starts.append(now)

		try:
			rc = run_once(command, log, job)
		except OSError as e:
			log.write('could not start {}: {}'.format(command[0], e))
			rc = 1

		if not restart:
			return rc
		log.write('restarting in {} s'.format(RESTART_SEC))
		time.sleep(RESTART_SEC)


def main(argv):
	split = argv.index('--') if '--' in argv else len(argv)
	parser = argparse.ArgumentParser(prog='supervise.pyw')
	parser.add_argument('--log', required=True, help='log file (created, appended to, rotated)')
	parser.add_argument('--restart', action='store_true', help='restart the command whenever it exits')
	args = parser.parse_args(argv[:split])
	command = argv[split + 1:]
	if not command:
		parser.error('no command given after --')

	log = Log(args.log)
	try:
		return supervise(command, args.restart, log)
	except Exception:
		# pythonw has no stderr: a traceback that is not in the log is lost
		log.write('supervise.pyw crashed:\n' + traceback.format_exc())
		return 1


if __name__ == '__main__':
	sys.exit(main(sys.argv[1:]))
