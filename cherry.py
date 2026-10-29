cat > ~/cherry.py <<'PY'
#!/usr/bin/env python3
"""Cherry: reusable SSH folder transfers, public Git cloning, and commands."""

# ================= EDIT THESE SETTINGS =================
ACTION = "folder"                     # folder | repo | command

SOURCE_FOLDER = "/home/rit/your-folder"
REPO_URL = "https://github.com/owner/repository.git"

DESTINATION_NAME = "dustbin"           # /dustbin or ~/dustbin
EXISTING = "replace"                   # replace | skip

COMMAND = "hostname"
COMMAND_AS = "active_user"             # active_user | sudo

IP_PREFIX = "172.1.44."
FIRST_IP, LAST_IP = 1, 254             # Includes the main computer
TIMEOUT = 600                         # Seconds per remote operation

ACCOUNTS = {
    "rit": "rit@2025",
    "hadoop": "hadoop",
    "exam": "exam",
    "group1": "group1",
}
ADMIN_USERS = ("rit", "hadoop")
# =======================================================

import base64
import csv
from datetime import datetime
import hashlib
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import socket
import subprocess
import sys
import tarfile
import tempfile
import time
from urllib.parse import urlsplit

try:
    import paramiko
except ImportError:
    sys.exit("Install dependency: sudo apt install python3-paramiko")


DETECT = '''
import subprocess

def desktop_users():
    p = subprocess.run(
        ['loginctl', 'list-sessions', '--no-legend', '--no-pager'],
        capture_output=True, text=True, timeout=15, check=True)
    users = set()
    for row in p.stdout.splitlines():
        q = subprocess.run(
            ['loginctl', 'show-session', row.split()[0], '--no-pager'],
            capture_output=True, text=True, timeout=10, check=True)
        d = dict(line.split('=', 1)
                 for line in q.stdout.splitlines() if '=' in line)
        if (d.get('Type') in ('x11', 'wayland')
                and d.get('Remote') == 'no'
                and d.get('Class') == 'user'
                and d.get('State') in ('active', 'online')):
            users.add(d['Name'])
    return sorted(users)
'''


WORKER = DETECT + '''
import hashlib, io, json, os, pathlib, pwd, shutil, tarfile, tempfile, uuid

c = CONFIG
users = desktop_users()
if not users:
    raise RuntimeError('No desktop user remains logged in')

shared = c['mode'] == 'shared'
if shared:
    if os.geteuid() != 0:
        raise RuntimeError('Sudo did not grant root access')
    if not any(u in users for u in c['admins']):
        raise RuntimeError('No administrator desktop user remains logged in')
    parent = pathlib.Path('/')
else:
    user = pwd.getpwuid(os.getuid())
    if user.pw_name not in users:
        raise RuntimeError('User is no longer logged into a desktop')
    parent = pathlib.Path(user.pw_dir)

protected = {
    'bin', 'boot', 'dev', 'etc', 'home', 'lib', 'lib32', 'lib64',
    'libx32', 'lost+found', 'media', 'mnt', 'opt', 'proc', 'root',
    'run', 'sbin', 'snap', 'srv', 'sys', 'tmp', 'usr', 'var'
}
if shared and c['name'] in protected:
    raise RuntimeError('Refusing to replace an operating-system directory')

target = parent / c['name']

if c.get('local_source'):
    source = pathlib.Path(c['local_source']).resolve()
    resolved = target.resolve()
    if source == resolved or resolved in source.parents:
        raise RuntimeError('Destination would replace the source or its parent')

if os.path.lexists(target) and c['existing'] == 'skip':
    print(json.dumps({
        'status': 'SKIPPED',
        'destination': str(target),
        'reason': 'Destination already exists'
    }))
    raise SystemExit(0)

stage = pathlib.Path(tempfile.mkdtemp(
    prefix='.cherry-stage-', dir=str(parent)))
backup = parent / ('.cherry-backup-' + uuid.uuid4().hex)
prepared = stage / c['name']

try:
    if c['action'] == 'folder':
        with open(c['archive'], 'rb') as f:
            data = f.read()
        if hashlib.sha256(data).hexdigest() != c['checksum']:
            raise RuntimeError('Uploaded archive checksum mismatch')

        with tarfile.open(fileobj=io.BytesIO(data), mode='r:gz') as tf:
            members = tf.getmembers()
            for m in members:
                p = pathlib.PurePosixPath(m.name)
                if (p.is_absolute() or '..' in p.parts or not p.parts
                        or p.parts[0] != c['name']
                        or not (m.isfile() or m.isdir())):
                    raise RuntimeError('Unsafe archive entry: ' + m.name)
                m.uid = os.getuid()
                m.gid = os.getgid()
                m.uname = m.gname = ''
                m.pax_headers = {}
                m.mode = (
                    0o755 if m.isdir() or m.mode & 0o111 else 0o644
                )
            tf.extractall(stage, members=members)

    else:
        if not shutil.which('git'):
            raise RuntimeError('Git is not installed on this computer')

        env = dict(os.environ, GIT_TERMINAL_PROMPT='0')
        p = subprocess.run(
            ['git', '-c', 'credential.helper=',
             '-c', 'protocol.file.allow=never',
             'clone', '--', c['repo'], str(prepared)],
            capture_output=True, text=True,
            timeout=c['timeout'] - 20, env=env)

        if p.returncode:
            raise RuntimeError(
                'Git clone failed: ' +
                (p.stderr.strip() or p.stdout.strip()))

    if not prepared.is_dir():
        raise RuntimeError('Prepared destination folder is missing')

    # Make shared contents readable without following repository symlinks.
    if shared:
        for root, dirs, files in os.walk(prepared, followlinks=False):
            os.chmod(root, 0o755)
            for name in files:
                p = pathlib.Path(root) / name
                if not p.is_symlink():
                    os.chmod(
                        p, 0o755 if p.stat().st_mode & 0o111 else 0o644)

    current = desktop_users()
    if not current or (not shared and user.pw_name not in current):
        raise RuntimeError('Desktop user logged out during preparation')
    if shared and not any(u in current for u in c['admins']):
        raise RuntimeError(
            'Administrator desktop user logged out during preparation')

    had_old = os.path.lexists(target)
    if had_old:
        target.rename(backup)

    try:
        prepared.rename(target)
    except BaseException:
        if had_old:
            backup.rename(target)
        raise

    reason = 'Installed successfully'
    if had_old:
        try:
            if backup.is_symlink() or not backup.is_dir():
                backup.unlink()
            else:
                shutil.rmtree(backup)
        except OSError as e:
            reason += (
                '; old backup retained at ' + str(backup) + ': ' + str(e))

    print(json.dumps({
        'status': 'PASS',
        'destination': str(target),
        'reason': reason
    }))
finally:
    shutil.rmtree(stage, ignore_errors=True)
'''


def clean(error):
    text = ' '.join(str(error).split()) or type(error).__name__
    return text[:4000]


def remote(client, code, password=None):
    encoded = base64.b64encode(code.encode()).decode()
    cmd = 'python3 -c ' + shlex.quote(
        'import base64;exec(base64.b64decode(' + repr(encoded) + '))')

    if password is not None:
        cmd = "sudo -k -S -p '' -- " + cmd

    stdin, out, err = client.exec_command(cmd, timeout=TIMEOUT)
    if password is not None:
        stdin.write(password + '\n')
        stdin.flush()
    stdin.channel.shutdown_write()

    channel = out.channel
    chunks, errors = [], []
    total = 0
    deadline = time.monotonic() + TIMEOUT

    try:
        while True:
            streams = (
                (channel.recv_ready, channel.recv, chunks),
                (channel.recv_stderr_ready, channel.recv_stderr, errors),
            )
            for ready, receive, destination in streams:
                while ready():
                    piece = receive(65536)
                    total += len(piece)
                    if total > 8 * 1024 * 1024:
                        raise RuntimeError(
                            'Remote output exceeded 8 MiB limit')
                    destination.append(piece)

            if (channel.exit_status_ready()
                    and not channel.recv_ready()
                    and not channel.recv_stderr_ready()):
                break

            if time.monotonic() > deadline:
                raise TimeoutError(
                    'Remote operation timed out; '
                    'check destination before retrying')
            time.sleep(0.05)

        result = b''.join(chunks).decode(errors='replace').strip()
        error = b''.join(errors).decode(errors='replace').strip()

        if channel.recv_exit_status():
            raise RuntimeError(
                error or result or 'Remote command failed')
        return result
    finally:
        channel.close()


def connect(ip, user, known):
    client = paramiko.SSHClient()
    client.load_system_host_keys()
    client.load_host_keys(str(known))
    client.set_missing_host_key_policy(paramiko.AutoAddPolicy())

    try:
        client.connect(
            ip, username=user, password=ACCOUNTS[user],
            timeout=4, banner_timeout=6, auth_timeout=6,
            look_for_keys=False, allow_agent=False)
        client.get_transport().set_keepalive(15)
        return client
    except BaseException:
        client.close()
        raise


def main():
    if os.geteuid() == 0:
        sys.exit('Run cherry.py without sudo.')

    if ACTION not in ('folder', 'repo', 'command'):
        sys.exit('ACTION must be folder, repo, or command.')

    if not 1 <= FIRST_IP <= LAST_IP <= 254:
        sys.exit('IP range must be within 1..254.')

    ips = [
        str(ipaddress.IPv4Address(IP_PREFIX + str(n)))
        for n in range(FIRST_IP, LAST_IP + 1)
    ]

    if ACTION != 'command':
        if not re.fullmatch(
                r'[A-Za-z0-9][A-Za-z0-9_.-]{0,79}', DESTINATION_NAME):
            sys.exit(
                'DESTINATION_NAME must be one simple folder name, '
                'without slashes.')
        if EXISTING not in ('replace', 'skip'):
            sys.exit('EXISTING must be replace or skip.')

    if ACTION == 'command':
        if (COMMAND_AS not in ('sudo', 'active_user')
                or not COMMAND.strip()):
            sys.exit('Set COMMAND and COMMAND_AS correctly.')

    if ACTION == 'repo':
        url = urlsplit(REPO_URL)
        if (url.scheme != 'https' or not url.hostname
                or url.username or url.password):
            sys.exit(
                'Use a public HTTPS repository URL without credentials.')

    source = (
        Path(SOURCE_FOLDER).expanduser().resolve()
        if ACTION == 'folder' else None
    )
    if source and not source.is_dir():
        sys.exit('Source folder not found: ' + str(source))

    own_ips = set(subprocess.check_output(
        ['hostname', '-I'], text=True).split())

    known = Path.home() / '.ssh' / 'known_hosts'
    known.parent.mkdir(mode=0o700, exist_ok=True)
    known.touch(mode=0o600, exist_ok=True)

    logs = Path.home() / (
        'cherry_results_' +
        datetime.now().strftime('%Y%m%d_%H%M%S_%f'))
    logs.mkdir(mode=0o700)
    print('Results:', logs, flush=True)

    summary = {}
    unresolved = []

    with tempfile.TemporaryDirectory(prefix='cherry-') as tmp, \
            (logs / 'status.csv').open(
                'w', newline='', buffering=1) as sf, \
            (logs / 'failed_ips.csv').open(
                'w', newline='', buffering=1) as ff:

        status, failed = csv.writer(sf), csv.writer(ff)
        header = [
            'IP', 'Active users', 'Account', 'Action',
            'Mode', 'Destination', 'Status', 'Reason'
        ]
        status.writerow(header)
        failed.writerow(header)

        archive = Path(tmp) / 'payload.tar.gz'
        checksum = ''

        if ACTION == 'folder':
            print('Preparing folder snapshot...', flush=True)

            def regular(member):
                if not (member.isfile() or member.isdir()):
                    raise RuntimeError(
                        'Source contains a symlink/special file: ' +
                        member.name)
                member.mode &= 0o777
                return member

            with tarfile.open(
                    archive, 'w:gz', dereference=False) as tf:
                tf.add(
                    source, arcname=DESTINATION_NAME, filter=regular)
            checksum = hashlib.sha256(archive.read_bytes()).hexdigest()

        for ip in ips:
            print('\n' + ip, flush=True)
            users = []
            outcomes = []

            def record(account, mode, destination, state, reason):
                print(
                    '  ' + state + ' | ' + account + ' | ' + mode +
                    ' | ' + destination + ' | ' + reason,
                    flush=True)
                row = [
                    ip, ', '.join(users), account, ACTION,
                    mode, destination, state, reason
                ]
                status.writerow(row)

                if state != 'RETRY':
                    outcomes.append(state)
                if state == 'FAIL':
                    failed.writerow(row)
                    unresolved.append((ip, account, reason))

            try:
                try:
                    with socket.create_connection(
                            (ip, 22), timeout=2):
                        pass
                except OSError as e:
                    raise RuntimeError(
                        'SSH unreachable; power state unknown: ' +
                        clean(e)) from e

                errors = []
                for account in ACCOUNTS:
                    client = None
                    try:
                        client = connect(ip, account, known)
                        users = json.loads(remote(
                            client, DETECT +
                            '\nimport json;'
                            'print(json.dumps(desktop_users()))'))
                        break
                    except paramiko.BadHostKeyException:
                        raise
                    except Exception as e:
                        errors.append(account + ': ' + clean(e))
                    finally:
                        if client:
                            client.close()
                else:
                    raise RuntimeError(
                        'Cannot detect desktop users: ' +
                        '; '.join(errors))

                print(
                    '  Active users: ' + (', '.join(users) or 'none'),
                    flush=True)

                if not users:
                    raise RuntimeError('No logged-in desktop user')

                command_started = False

                def execute(account, mode):
                    nonlocal command_started

                    if account not in ACCOUNTS:
                        raise RuntimeError(
                            'No credentials supplied for ' + account)

                    client = connect(ip, account, known)
                    uploaded = None
                    password = (
                        ACCOUNTS[account] if mode == 'shared' else None)

                    try:
                        if mode == 'shared':
                            remote(
                                client,
                                'import os;assert os.geteuid()==0',
                                password)

                        if ACTION == 'command':
                            code = (
                                DETECT +
                                '\nimport subprocess,json\n'
                                'u=desktop_users()\n'
                            )
                            if mode == 'shared':
                                code += (
                                    'assert u, '
                                    '"No logged-in desktop user"\n')
                            else:
                                code += (
                                    'assert ' + repr(account) +
                                    ' in u, "Desktop user logged out"\n')

                            code += (
                                'p=subprocess.run(' + repr(COMMAND) +
                                ',shell=True,executable="/bin/bash",'
                                'capture_output=True,text=True,timeout=' +
                                str(TIMEOUT - 20) + ')\n'
                                'print(json.dumps({'
                                '"status":"PASS" if p.returncode==0 '
                                'else "FAIL",'
                                '"destination":"",'
                                '"reason":"Exit code: "+str(p.returncode)'
                                '+"; stdout: "+p.stdout'
                                '+"; stderr: "+p.stderr}))'
                            )
                            command_started = True
                            return json.loads(
                                remote(client, code, password))

                        if ACTION == 'folder':
                            uploaded = remote(
                                client,
                                "import tempfile,os;"
                                "fd,p=tempfile.mkstemp("
                                "prefix='.cherry-upload-');"
                                "os.close(fd);print(p)")
                            print(
                                '  Uploading through ' + account + '...',
                                flush=True)
                            with client.open_sftp() as sftp:
                                sftp.get_channel().settimeout(TIMEOUT)
                                sftp.put(str(archive), uploaded)

                        config = dict(
                            action=ACTION,
                            mode=mode,
                            name=DESTINATION_NAME,
                            existing=EXISTING,
                            archive=uploaded,
                            checksum=checksum,
                            repo=REPO_URL,
                            timeout=TIMEOUT,
                            admins=ADMIN_USERS,
                            local_source=(
                                str(source)
                                if source and ip in own_ips else '')
                        )
                        return json.loads(remote(
                            client,
                            'CONFIG = ' + repr(config) + '\n' + WORKER,
                            password))
                    finally:
                        if uploaded:
                            try:
                                with client.open_sftp() as sftp:
                                    sftp.remove(uploaded)
                            except Exception:
                                print(
                                    '  Note: temporary upload remains at ' +
                                    uploaded, flush=True)
                        client.close()

                if ACTION == 'command':
                    if COMMAND_AS == 'active_user':
                        for account in users:
                            try:
                                result = execute(account, 'active_users')
                                record(
                                    account, 'active_users', '',
                                    result['status'], result['reason'])
                            except Exception as e:
                                record(
                                    account, 'active_users', '',
                                    'FAIL', clean(e))
                    else:
                        admin_errors = []
                        for account in ADMIN_USERS:
                            try:
                                result = execute(account, 'shared')
                            except Exception as e:
                                if command_started:
                                    record(
                                        account, 'sudo', '', 'FAIL',
                                        'Command outcome may be incomplete: ' +
                                        clean(e))
                                    break
                                admin_errors.append(
                                    account + ': ' + clean(e))
                                record(
                                    account, 'sudo', '',
                                    'RETRY', clean(e))
                                continue

                            # Do not repeat a command after it has run.
                            record(
                                account, 'sudo', '',
                                result['status'], result['reason'])
                            break
                        else:
                            record(
                                '', 'sudo', '', 'FAIL',
                                'Neither administrator could execute '
                                'the command: ' +
                                '; '.join(admin_errors))
                else:
                    shared_done = False

                    for account in ADMIN_USERS:
                        if account not in users:
                            continue

                        print(
                            '  Trying shared installation through ' +
                            account, flush=True)
                        try:
                            result = execute(account, 'shared')
                            record(
                                account, 'shared',
                                result['destination'],
                                result['status'], result['reason'])
                            shared_done = True
                            break
                        except Exception as e:
                            record(
                                account, 'shared',
                                '/' + DESTINATION_NAME,
                                'RETRY', clean(e))

                    if not shared_done:
                        print(
                            '  Using active-user home folders.',
                            flush=True)

                        for account in users:
                            try:
                                result = execute(
                                    account, 'active_users')
                                record(
                                    account, 'active_users',
                                    result['destination'],
                                    result['status'], result['reason'])
                            except Exception as e:
                                record(
                                    account, 'active_users',
                                    '~/' + DESTINATION_NAME,
                                    'FAIL', clean(e))

            except Exception as e:
                record('', '', '', 'FAIL', clean(e))

            if 'FAIL' in outcomes:
                summary[ip] = (
                    'PARTIAL'
                    if any(x in outcomes for x in ('PASS', 'SKIPPED'))
                    else 'FAIL'
                )
            else:
                summary[ip] = (
                    'PASS' if 'PASS' in outcomes else 'SKIPPED')

            print('  SYSTEM: ' + summary[ip], flush=True)

    print('\nFINAL STATUS', flush=True)
    for state in ('PASS', 'PARTIAL', 'FAIL', 'SKIPPED'):
        print(state + ': ' +
              str(list(summary.values()).count(state)))

    if unresolved:
        print('\nUnresolved failures:')
        for ip, account, reason in unresolved:
            print(ip + ' | ' + account + ' | ' + reason)

    print('\nFull report:', logs / 'status.csv')
    print('Failure report:', logs / 'failed_ips.csv')


if __name__ == '__main__':
    try:
        main()
    except KeyboardInterrupt:
        sys.exit(
            '\nStopped. Completed rows remain in the results folder.')
    except Exception as e:
        sys.exit('FAIL: ' + clean(e))
PY
chmod 600 ~/cherry.py
