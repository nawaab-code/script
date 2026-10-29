# Cherry 🍒

A reusable SSH automation script for Ubuntu systems. Transfer folders, clone public Git repositories, or run commands across multiple computers by changing the configuration at the top of the script.

## Features

- Checks destination IPs sequentially, including the main computer.
- Detects logged-in Ubuntu desktop users.
- Automatically chooses shared installation or individual home folders.
- Falls back to home-folder installation if shared installation fails.
- Shows progress, destinations, results, and failure reasons in the terminal.
- Saves full results and unresolved failures as CSV files.
- Supports folder transfers, public repository cloning, and remote commands.

## Default network

| Setting | Default |
| --- | --- |
| Main computer | `172.1.44.239` |
| Destination range | `172.1.44.1–172.1.44.254` |
| SSH port | `22` |
| Accounts | `rit`, `hadoop`, `exam`, `group1` |
| Sudo accounts | `rit`, `hadoop` |
| Destination folder name | `dustbin` |

The main computer is included in the destination range. Change the network settings for another environment.

## Requirements

### Main computer

- Ubuntu with Python 3.
- Network access to the destination systems.
- Python package `paramiko`.

Install the dependency:

```bash
sudo apt update
sudo apt install python3-paramiko
```

### Destination computers

- Ubuntu with Python 3.
- SSH installed and enabled on port 22.
- Password authentication available for the configured accounts.
- Working `loginctl` desktop-session detection.
- Sudo access for `rit` or `hadoop` when shared installation is needed.
- Git and internet access when cloning repositories.

The sudo password must match the configured password for that administrator account.

## Setup

### 1. Clone the Cherry branch

```bash
git clone --branch Cherry --single-branch https://github.com/nawaab-code/script.git
cd script
```

If the repository is already cloned, open its directory and run:

```bash
git fetch origin
git switch Cherry
git pull --ff-only origin Cherry
```

### 2. Create the runnable script

The current repository file `cherry.py` contains a Bash setup block beginning with:

```bash
cat > ~/cherry.py <<'PY'
```

Run that setup block using Bash:

```bash
bash ./cherry.py
```

This creates or overwrites the runnable Python script at `~/cherry.py`. It does not start the network operation.

> Running the setup block again overwrites the settings in your home-directory copy.

### 3. Edit the configuration

```bash
nano ~/cherry.py
```

Change the settings at the top:

```python
ACTION = "folder"                     # folder | repo | command

SOURCE_FOLDER = "/home/rit/your-folder"
REPO_URL = "https://github.com/owner/repository.git"

DESTINATION_NAME = "dustbin"
EXISTING = "replace"                  # replace | skip

COMMAND = "hostname"
COMMAND_AS = "active_user"            # active_user | sudo

IP_PREFIX = "172.1.44."
FIRST_IP, LAST_IP = 1, 254
TIMEOUT = 600
```

Check the credentials in `ACCOUNTS` locally. Do not commit real passwords to the repository.

Save with **Ctrl+O**, press **Enter**, and exit with **Ctrl+X**.

### 4. Run

```bash
python3 ~/cherry.py
```

Run without `sudo`. The script requests sudo on destination computers when needed.

## Configuration reference

| Setting | Description |
| --- | --- |
| `ACTION` | Select `folder`, `repo`, or `command`. |
| `SOURCE_FOLDER` | Local folder to transfer. Used only by folder mode. |
| `REPO_URL` | Public HTTPS repository URL. Used only by repo mode. |
| `DESTINATION_NAME` | Destination folder name without slashes, such as `dustbin`. |
| `EXISTING` | Replace or skip an existing destination. |
| `COMMAND` | Terminal command to execute. Used only by command mode. |
| `COMMAND_AS` | Execute as active users or with sudo. |
| `IP_PREFIX` | IP prefix, including the trailing dot. |
| `FIRST_IP` / `LAST_IP` | Inclusive last-octet range within `1–254`. |
| `TIMEOUT` | Remote operation timeout in seconds. |
| `ACCOUNTS` | SSH usernames and passwords. |
| `ADMIN_USERS` | Accounts eligible for sudo operations. |

**Only the selected action runs.** Settings for the other actions are ignored.

## How each system is handled

1. Display the IP address.
2. Check whether SSH is reachable.
3. Authenticate using a configured account.
4. Identify logged-in local desktop users.
5. Select the installation mode or command permissions.
6. Perform the operation.
7. Display the result and reason.
8. Record the result and move to the next IP.

Locked desktops count as logged in. SSH-only sessions do not count.

If nobody is logged into a desktop, the system is marked as failed with:

```text
No logged-in desktop user
```

An SSH connection failure is reported as unreachable. It does not prove that the computer is powered off.

## Automatic installation mode

This selection applies to folder and repository actions.

| Active desktop users | Behavior |
| --- | --- |
| `rit` or `hadoop` is logged in | Try shared installation through a logged-in administrator. |
| Only `exam` and/or `group1` is logged in | Install separately into each active user's home folder. |
| Shared installation fails | Fall back to each active user's home folder. |
| Nobody is logged in | Record failure and continue. |

### Shared installation

With:

```python
DESTINATION_NAME = "dustbin"
```

The destination is:

```text
/dustbin
```

One shared copy is accessible to everyone on that computer, including users who log in later.

Shared contents are owned by root. All users can read and copy them; editing the shared copy requires sudo.

### Active-user installation

The destination is inside each active user's home:

```text
/home/exam/dustbin
/home/group1/dustbin
```

The script authenticates as each receiving user without sudo. If multiple users are logged in, it attempts every active user.

An active account without configured credentials receives a failure explaining that credentials are unavailable.

## Action: transfer a folder

Example:

```python
ACTION = "folder"
SOURCE_FOLDER = "/home/rit/Downloads/My Project"
DESTINATION_NAME = "project"
EXISTING = "replace"
```

The script:

1. Creates a snapshot of the source folder.
2. Uploads it to each selected destination.
3. Verifies the uploaded archive using SHA-256.
4. Installs its contents as `/project` or `~/project`.

The original source folder remains intact. Paths containing spaces are supported.

## Action: clone a repository

Example:

```python
ACTION = "repo"
REPO_URL = "https://github.com/owner/repository.git"
DESTINATION_NAME = "project"
EXISTING = "replace"
```

Each selected destination clones the public repository into `/project` or `~/project`.

- Use a public HTTPS URL without embedded credentials.
- Git must already be installed on the destination.
- The destination needs internet access.
- This creates a fresh clone rather than updating an existing clone with `git pull`.
- Cloning does not install dependencies or run the project.

An administrator can install Git on a destination with:

```bash
sudo apt install git
```

## Action: run a command

### As each active user

```python
ACTION = "command"
COMMAND = "whoami && hostname"
COMMAND_AS = "active_user"
```

The command runs once for each active desktop user using that user's account, without sudo.

### With sudo

```python
ACTION = "command"
COMMAND = "id && hostname"
COMMAND_AS = "sudo"
```

The script tries administrator access through `rit`, then `hadoop`, and executes the command once per computer.

For sudo command mode, the administrator account does not need its own active desktop session. At least one desktop user must still be logged in.

### Command results

The result includes:

- Exit code.
- Standard output.
- Standard error.

Exit code `0` is reported as `PASS`; a nonzero exit code is reported as `FAIL`.

Once command dispatch begins, the script does not retry through another administrator if the outcome is uncertain.

Destination settings and `EXISTING` are ignored in command mode.

## Existing destination behavior

### Replace

```python
EXISTING = "replace"
```

The script prepares the new folder or repository before moving the old destination aside.

If the final installation rename fails, it attempts to restore the old destination. After successful installation, the old backup is removed.

If backup cleanup fails, the operation remains successful and the retained backup path appears in the result.

### Skip

```python
EXISTING = "skip"
```

An existing destination is left untouched and reported as `SKIPPED`.

If a shared destination already exists, the system is skipped without creating additional home-folder copies.

## Live terminal output

Example:

```text
172.1.44.10
  Active users: rit
  Trying shared installation through rit
  Uploading through rit...
  PASS | rit | shared | /dustbin | Installed successfully
  SYSTEM: PASS

172.1.44.11
  Active users: exam, group1
  Using active-user home folders.
  PASS | exam | active_users | /home/exam/dustbin | Installed successfully
  FAIL | group1 | active_users | ~/dustbin | Authentication failed
  SYSTEM: PARTIAL

172.1.44.12
  Active users: none
  FAIL |  |  |  | No logged-in desktop user
  SYSTEM: FAIL
```

Failed shared attempts appear as `RETRY` with a reason before fallback.

If fallback succeeds for every active user, the system counts as recovered rather than failed.

## Final summary

The terminal prints system totals:

| Status | Meaning |
| --- | --- |
| `PASS` | Successful operation with no unresolved failures. |
| `PARTIAL` | Some user operations succeeded or were skipped, while others failed. |
| `FAIL` | Unresolved failures with no successful or skipped operations. |
| `SKIPPED` | Selected destinations were left unchanged. |

It also lists unresolved failed IPs, affected accounts, and failure reasons.

Totals count systems. Individual attempts and account results are recorded separately in the CSV reports.

## Saved reports

Each run creates a timestamped folder in the controller user's home:

```text
~/cherry_results_<timestamp>/
    status.csv
    failed_ips.csv
```

Both CSV files contain:

```text
IP,Active users,Account,Action,Mode,Destination,Status,Reason
```

### status.csv

Contains all recorded results, including shared attempts marked as `RETRY`.

### failed_ips.csv

Contains unresolved failures with the affected account and reason.

One IP can appear more than once if multiple users have failures.

### Failure reasons

Examples include:

- SSH connection timeout or refusal.
- Authentication failure.
- No logged-in desktop user.
- Missing account credentials.
- Sudo access denied.
- Permission denied.
- Git not installed.
- Repository cloning failure.
- Upload checksum mismatch.
- Insufficient disk space.
- Remote command failure or timeout.

## Stopping a run

Press:

```text
Ctrl+C
```

Completed CSV rows remain in the results folder.

An interrupted or timed-out operation may leave a remote process or temporary data behind. Check the destination before retrying.

## Current limitations

- Folder transfers accept regular files and directories. Symlinks and special files are rejected.
- File permissions are normalized during installation; executable status is retained.
- Archive processing requires enough memory and disk space for the new content, staging area, and existing destination.
- Repository mode clones the default branch without initializing submodules.
- Command output is displayed after completion rather than streamed continuously.
- Remote responses have an 8 MiB output limit.
- New SSH host keys are saved automatically; changed known keys are rejected.
- The script protects common operating-system directories from shared replacement.
- Use the final summary and CSV reports to determine results. The process exit code does not summarize all destination failures.
