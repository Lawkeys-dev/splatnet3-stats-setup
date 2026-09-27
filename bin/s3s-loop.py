#!/usr/bin/env python3
"""s3s runner with on-demand, tiered token refresh.

Replacement for splatnet3-token-util's run_s3s.py. Same idea - run s3s with
--norefresh so it exits with RC 42 instead of refreshing tokens itself, then
refresh and restart it - but with a cheap tier first:

  1. s3s says the tokens are dead (RC 42)
  2. try to mint a new bulletToken from the stored gtoken. One HTTPS call to
     Nintendo, no emulator, no session_token, no third-party f-gen API.
     The gtoken lives ~6h, the bulletToken ~2h, so this covers most expiries.
  3. only if that fails (gtoken really expired) boot the emulator and run the
     full splatnet3-token-util extraction.

Configuration is shared with run_s3s.py: splatnet3-token-util/config_run_s3s.json.
"""

import json
import os
import shutil
import subprocess
import sys
import time

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
STU_DIR = os.path.join(ROOT, 'splatnet3-token-util')
RUN_CONFIG = os.path.join(STU_DIR, 'config_run_s3s.json')

# emulator config used for the full extraction: no window for the automatic path,
# the windowed one when the user asked for interactive mode
HEADLESS_CONFIG = './config/config-headless.json'
WINDOWED_CONFIG = './config/config.json'

# s3s must stay up this long after a bulletToken-only refresh, otherwise the next
# RC 42 goes straight to the emulator instead of looping on the cheap path
CHEAP_MIN_UPTIME_SECONDS = 60

DEFAULT_USER_AGENT = ('Mozilla/5.0 (Linux; Android 14; Pixel 7a) '
                      'AppleWebKit/537.36 (KHTML, like Gecko) '
                      'Chrome/120.0.6099.230 Mobile Safari/537.36')


def log(msg=''):
	print(msg, flush=True)


def load_run_config():
	if not os.path.exists(RUN_CONFIG):
		log('ERROR: {} does not exist. Run install.sh (install.ps1 on Windows) to generate it.'.format(RUN_CONFIG))
		sys.exit(3)

	with open(RUN_CONFIG, 'r') as f:
		config = json.load(f)

	if not os.path.isdir(config.get('s3s_directory', '')):
		log('ERROR: s3s_directory does not exist, exiting.')
		sys.exit(3)

	config.setdefault('s3s_refresh_rc', '42')
	config.setdefault('s3s_update', False)
	config.setdefault('generated_config_filepath', 'config.txt')
	config.setdefault('git_command', 'git')
	config.setdefault('pip_command', 'pip3')
	config.setdefault('python_command', 'python3')
	return config


def read_json(path):
	with open(path, 'r') as f:
		return json.load(f)


def write_json(path, data):
	with open(path, 'w') as f:
		json.dump(data, f, indent=4, sort_keys=False, separators=(',', ': '))
		f.write('\n')


def home_query_status(s3s_dir, gtoken, bullettoken, lang, country, user_agent):
	"""Ask SplatNet 3 for the homepage - 200 means the token pair works."""
	sys.path.insert(0, s3s_dir)
	import iksm
	import utils
	import requests

	head = {
		'Authorization':    'Bearer {}'.format(bullettoken),
		'Accept-Language':  lang,
		'User-Agent':       user_agent,
		'X-Web-View-Ver':   iksm.get_web_view_ver(),
		'Content-Type':     'application/json',
		'Accept':           '*/*',
		'Origin':           iksm.SPLATNET3_URL,
		'X-Requested-With': 'com.nintendo.znca',
		'Referer':          '{}?lang={}&na_country={}&na_lang={}'.format(iksm.SPLATNET3_URL, lang, country, lang),
		'Accept-Encoding':  'gzip, deflate'
	}
	body = utils.gen_graphql_body(utils.translate_rid['HomeQuery'], 'naCountry', country)
	return requests.post(iksm.GRAPHQL_URL, data=body, headers=head, cookies=dict(_gtoken=gtoken)).status_code


def refresh_bullettoken(config):
	"""Mint a new bulletToken from the stored gtoken. True if s3s now has working tokens."""
	s3s_dir = config['s3s_directory']
	s3s_config_path = os.path.join(s3s_dir, 'config.txt')

	try:
		tokens = read_json(s3s_config_path)
	except (IOError, ValueError) as e:
		log('could not read {}: {}'.format(s3s_config_path, e))
		return False

	gtoken = tokens.get('gtoken', '')
	acc_loc = tokens.get('acc_loc', '')
	if not gtoken or len(acc_loc) < 7:
		log('no usable gtoken in config.txt - emulator extraction needed')
		return False

	lang, country = acc_loc[:5], acc_loc[-2:]
	user_agent = str(tokens.get('app_user_agent', DEFAULT_USER_AGENT))

	sys.path.insert(0, s3s_dir)
	import iksm
	iksm.WEB_VIEW_VERSION = 'unknown'  # re-fetch, this process can run for days

	try:
		bullettoken = iksm.get_bullet(gtoken, user_agent, lang, country)
	except SystemExit:  # iksm exits the process on 401/403/204 - the gtoken is dead
		bullettoken = ''
	except Exception as e:
		log('bulletToken request failed: {}'.format(e))
		bullettoken = ''

	if not bullettoken:
		log('could not get a bulletToken from the stored gtoken - emulator extraction needed')
		return False

	try:
		status = home_query_status(s3s_dir, gtoken, bullettoken, lang, country, user_agent)
	except Exception as e:
		log('could not validate the new bulletToken: {}'.format(e))
		return False

	if status != 200:
		log('new bulletToken does not work (HomeQuery returned {}) - emulator extraction needed'.format(status))
		return False

	tokens['bullettoken'] = bullettoken
	write_json(s3s_config_path, tokens)

	# keep splatnet3-token-util's copy in sync so a manual `stu-s3s`/`stu` run
	# does not start from a stale token
	stu_config_path = os.path.join(STU_DIR, config['generated_config_filepath'])
	try:
		stu_tokens = read_json(stu_config_path)
		if stu_tokens.get('gtoken') == gtoken:
			stu_tokens['bullettoken'] = bullettoken
			write_json(stu_config_path, stu_tokens)
	except (IOError, ValueError):
		pass

	log('new bulletToken written to config.txt (gtoken still valid, emulator not needed)')
	return True


def run_emulator_extraction(config, interactive):
	"""Full splatnet3-token-util run: boot the emulator, dump RAM, extract both tokens."""
	log('##############################')
	log('running splatnet3-token-util')
	log('##############################')
	log()

	cmd = [config['python_command'], 'main.py',
		   '--config', WINDOWED_CONFIG if interactive else HEADLESS_CONFIG,
		   '--disable-update-check']
	if interactive:
		cmd.append('-im')

	proc = subprocess.run(cmd, cwd=STU_DIR)
	log()

	if proc.returncode != 0:
		log('ERROR DURING TOKEN EXTRACTION!!!')
		log('exiting the script')
		sys.exit(2)

	shutil.copyfile(os.path.join(STU_DIR, config['generated_config_filepath']),
					os.path.join(config['s3s_directory'], 'config.txt'))
	log('config.txt written into s3s folder')
	log()


def pip_install_command(config):
	"""pip from config if it exists, else uv (this venv is a uv venv and has no pip)."""
	pip = config['pip_command']
	if os.path.isabs(pip) and not os.path.exists(pip):
		uv = shutil.which('uv')
		if uv is None:
			return None
		return [uv, 'pip', 'install', '--python', config['python_command'], '-r', 'requirements.txt']
	return [pip, 'install', '-r', 'requirements.txt']


def update_s3s(config):
	log('1/2 Running s3s update with command `{} pull`'.format(config['git_command']))
	try:
		subprocess.run([config['git_command'], 'pull'], cwd=config['s3s_directory'])
	except OSError as e:
		log('s3s git pull failed: {} (continuing)'.format(e))
	log()

	cmd = pip_install_command(config)
	if cmd is None:
		log('2/2 Skipping dependency update: neither {} nor uv is available.'.format(config['pip_command']))
	else:
		log('2/2 Running s3s update with command `{}`'.format(' '.join(cmd)))
		try:
			subprocess.run(cmd, cwd=config['s3s_directory'])
		except OSError as e:
			log('dependency update failed: {} (continuing)'.format(e))
	log()


def main():
	config = load_run_config()
	refresh_rc = int(config['s3s_refresh_rc'])

	args = sys.argv[1:]
	if not args:
		log('Using "--help" as command line args since you did not provide any.')
		args = ['--help']

	interactive = '-im' in args
	args = [a for a in args if a != '-im']
	s3s_args = ['--norefresh', str(refresh_rc)] + args
	s3s_script = os.path.join(config['s3s_directory'], 's3s.py')

	pending_update = bool(config['s3s_update'])
	last_refresh_was_cheap = False

	while True:
		log('###########')
		log('running s3s')
		log('###########')
		log()

		if pending_update:
			update_s3s(config)
			pending_update = False

		log('Running s3s with command `{} {} {}`'.format(config['python_command'], s3s_script, ' '.join(s3s_args)))
		log()

		started = time.monotonic()
		proc = subprocess.run([config['python_command'], s3s_script] + s3s_args, cwd=config['s3s_directory'])
		uptime = time.monotonic() - started

		log()
		log('s3s finished. Return code: {} (ran for {:.0f}s)'.format(proc.returncode, uptime))

		if proc.returncode == 0:
			log('s3s finished successful -> exiting script.')
			sys.exit(0)

		if proc.returncode != refresh_rc:
			log('ERROR DURING s3s!!!')
			log('exiting script.')
			sys.exit(1)

		log()
		log('#####################')
		log('token refresh needed')
		log('#####################')
		log()

		if last_refresh_was_cheap and uptime < CHEAP_MIN_UPTIME_SECONDS:
			log('s3s asked for tokens again {:.0f}s after a bulletToken-only refresh '
				'-> going straight to the emulator'.format(uptime))
			cheap_ok = False
		else:
			cheap_ok = refresh_bullettoken(config)

		if cheap_ok:
			last_refresh_was_cheap = True
			continue

		run_emulator_extraction(config, interactive)
		last_refresh_was_cheap = False


if __name__ == '__main__':
	main()
