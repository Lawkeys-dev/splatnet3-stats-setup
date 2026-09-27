"""bin/s3s-loop.py: the restart loop and the bulletToken-only refresh, without s3s or Nintendo."""

import json
import os
import sys
import tempfile
import types
import unittest
from importlib.machinery import SourceFileLoader

BIN = os.path.join(os.path.dirname(os.path.dirname(os.path.abspath(__file__))), 'bin')


def load_loop():
	module = SourceFileLoader('s3s_loop', os.path.join(BIN, 's3s-loop.py')).load_module()
	module.log = lambda msg='': None
	return module


class LoopTest(unittest.TestCase):
	"""main(): which refresh tier runs for a given sequence of s3s exits."""

	def run_loop(self, argv, rcs, uptimes, cheap_results):
		m = load_loop()
		calls = []
		rcs, uptimes, cheap_results = list(rcs), list(uptimes), list(cheap_results)
		clock = [0.0]

		def run(cmd, cwd=None):
			clock[0] += uptimes.pop(0)
			return types.SimpleNamespace(returncode=rcs.pop(0))

		m.subprocess = types.SimpleNamespace(run=run)
		m.time = types.SimpleNamespace(monotonic=lambda: clock[0])
		m.load_run_config = lambda: {'s3s_refresh_rc': '42', 's3s_update': False,
									 's3s_directory': 's3s', 'python_command': 'python'}
		m.refresh_bullettoken = lambda config: calls.append('cheap') or cheap_results.pop(0)
		m.run_emulator_extraction = lambda config, interactive: calls.append('emulator-im' if interactive else 'emulator')

		old_argv = sys.argv
		sys.argv = ['s3s-loop.py'] + argv
		try:
			with self.assertRaises(SystemExit) as exit_:
				m.main()
		finally:
			sys.argv = old_argv
		calls.append('exit {}'.format(exit_.exception.code))
		return calls

	def test_cheap_refresh(self):
		self.assertEqual(self.run_loop(['-r', '-M'], [42, 0], [3600, 1], [True]), ['cheap', 'exit 0'])

	def test_cheap_token_rejected_right_away_goes_to_emulator(self):
		self.assertEqual(self.run_loop(['-r', '-M'], [42, 42, 0], [3600, 5, 1], [True]),
						 ['cheap', 'emulator', 'exit 0'])

	def test_cheap_refresh_twice_when_far_apart(self):
		self.assertEqual(self.run_loop(['-r', '-M'], [42, 42, 0], [3600, 3600, 1], [True, True]),
						 ['cheap', 'cheap', 'exit 0'])

	def test_dead_gtoken_goes_to_emulator(self):
		self.assertEqual(self.run_loop(['-r', '-M'], [42, 0], [10, 1], [False]), ['cheap', 'emulator', 'exit 0'])

	def test_interactive_extraction(self):
		self.assertEqual(self.run_loop(['-r', '-M', '-im'], [42, 0], [10, 1], [False]),
						 ['cheap', 'emulator-im', 'exit 0'])

	def test_s3s_error_stops(self):
		self.assertEqual(self.run_loop(['-r'], [1], [1], []), ['exit 1'])


class RefreshBulletTokenTest(unittest.TestCase):
	"""refresh_bullettoken() against a fake iksm module."""

	def setUp(self):
		self.tmp = tempfile.TemporaryDirectory()
		self.s3s_dir = os.path.join(self.tmp.name, 's3s')
		self.stu_dir = os.path.join(self.tmp.name, 'splatnet3-token-util')
		os.makedirs(self.s3s_dir)
		os.makedirs(self.stu_dir)
		self.tokens = {'api_key': 'k', 'acc_loc': 'en-US|US', 'gtoken': 'G', 'bullettoken': 'OLD',
					   'session_token': 'skip', 'f_gen': 'DUMMY_VALUE'}
		for directory in (self.s3s_dir, self.stu_dir):
			with open(os.path.join(directory, 'config.txt'), 'w') as f:
				json.dump(self.tokens, f)

		self.m = load_loop()
		self.m.STU_DIR = self.stu_dir
		self.config = {'s3s_directory': self.s3s_dir, 'generated_config_filepath': 'config.txt'}
		self.home_status = 200
		self.m.home_query_status = lambda *args: self.home_status
		self.bullet = lambda *args: 'NEW'
		sys.modules['iksm'] = types.SimpleNamespace(get_bullet=lambda *args: self.bullet(*args))

	def tearDown(self):
		sys.modules.pop('iksm', None)
		self.tmp.cleanup()

	def read(self, directory):
		with open(os.path.join(directory, 'config.txt')) as f:
			return json.load(f)['bullettoken']

	def test_new_token_written_to_both_copies(self):
		self.assertTrue(self.m.refresh_bullettoken(self.config))
		self.assertEqual(self.read(self.s3s_dir), 'NEW')
		self.assertEqual(self.read(self.stu_dir), 'NEW')

	def test_dead_gtoken(self):
		def exits(*args):
			sys.exit(1)  # what iksm does on 401
		self.bullet = exits
		self.assertFalse(self.m.refresh_bullettoken(self.config))
		self.assertEqual(self.read(self.s3s_dir), 'OLD')

	def test_token_that_fails_home_query_is_not_written(self):
		self.home_status = 401
		self.assertFalse(self.m.refresh_bullettoken(self.config))
		self.assertEqual(self.read(self.s3s_dir), 'OLD')

	def test_no_gtoken(self):
		self.tokens['gtoken'] = ''
		with open(os.path.join(self.s3s_dir, 'config.txt'), 'w') as f:
			json.dump(self.tokens, f)
		self.assertFalse(self.m.refresh_bullettoken(self.config))


if __name__ == '__main__':
	unittest.main()
