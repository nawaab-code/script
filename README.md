# University repository and Ollama deployment

Run these files on the Ubuntu controller. No deployment has been run from this Windows chat.

## Defaults

- Scan `172.1.44.1` through `172.1.44.254`, SSH port 22, retaining the original script's /24 network assumption. `.255` is the broadcast address for /24.
- Include the controller locally, even if it has no SSH server.
- Detect exactly one foreground local session belonging to `rit`, `exam`, or `hadoop`. Remote SSH sessions do not count. Skip and report ambiguous sessions or computers without a matching active local session.
- Try candidate SSH accounts to read session information, then authenticate as the detected active user for deployment. This can cause failed login attempts for accounts whose credentials do not match; account lockout policies may apply.
- Ask once for each account's supplied SSH/sudo password. Passwords are not embedded in these files or written to logs.
- Replace `/home/ACTIVE_USER/university-code`, deleting that folder and all its existing contents, including uncommitted work. A failed subsequent clone can leave it absent or incomplete.
- Clone the full default branch of `https://github.com/nawaab-code/university-code.git`, including Git history and all semester folders. External Git LFS objects and submodules are not explicitly fetched.
- Process each reachable IP in order: detect its active user, clone its repository, save an Ollama setup script on that host, and launch it there in the background. Then immediately proceed to the next host while the first host downloads independently.
- A failed clone is reported separately; Ollama setup is still attempted on that host, and the controller continues to the next host.
- There is no global wait for all repositories to finish before starting Ollama. Downloads overlap as each host is handed off.
- The saved host script runs under `nohup`, with its own local log and result file. Closing the controller or losing SSH does not by itself stop that host job. A shutdown or host policy that kills logged-out user processes can still interrupt it.
- Background monitors show live IP-labelled status while the controller handles subsequent hosts. After the last handoff, the controller waits for reports from the jobs already running. Three consecutive monitoring connection failures or the monitoring timeout produces an unconfirmed result; this does not mean the host job stopped.
- Accept the installed Ubuntu version rather than enforce Ubuntu 24.04. Actual support still depends on Ollama's installer and the installed system tools.
- Install Ollama only when its command is missing. Existing installations are not upgraded. A systemd `ollama` service is required; an existing installation without that service is reported as failed.
- Configure the Ollama service for `127.0.0.1:11434`, start it automatically, and download `qwen2.5-coder:14b`. No inference or chat is launched. Existing service configuration is supplemented with a local-address override.
- For a new Ollama installation, retain the original minimum 12 GiB free on `/`. RAM is reported without a minimum check. Hardware suitability is not verified, and download success does not prove the model will run well.

## Run

Keep `deploy-network.sh`, `launch-node.sh`, `node-setup.sh`, and `report-deployment.sh` together in a folder writable by the controller user. No other package manager or Ollama work should be running on the targets during deployment.

Install controller prerequisites:

```bash
sudo apt-get update
sudo apt-get install -y openssh-client sshpass netcat-openbsd
```

Then run:

```bash
bash deploy-network.sh
```

Enter the three account passwords when prompted. The controller may also request its own sudo authorization to switch to its detected active account. Each selected account needs working sudo privileges with the supplied account password, an ordinary `/home/USERNAME` home directory, and permission to remove its existing repository folder. Root-owned contents can cause that computer's clone stage to fail.

SSH must be enabled on targets and permit password authentication. Targets need outbound HTTPS access to GitHub, Ubuntu package mirrors, Ollama's installer, and the model registry. `loginctl` and systemd must work on every selected machine. New SSH host keys are saved; changed keys are rejected and reported.

The script creates a dated deployment folder beside itself with per-computer logs and these separate reports:

- `clone-failed.tsv`
- `ollama-failed.tsv`
- `skipped.tsv`
- `clone-ok.tsv` and `ollama-ok.tsv`
- `ollama-started.tsv` (host, account, saved task folder)
- `ollama-unconfirmed.tsv` (jobs whose final result could not be retrieved)

## Complete and live reports

Every tested IP is printed during the SSH scan, including nonresponding addresses. The controller saves reports immediately, refreshes them every five seconds during deployment, prints a snapshot after all host handoffs, and prints the final report when monitoring ends. A normal Ctrl+C/termination saves an INTERRUPTED report; host jobs already launched may keep running. A power loss or forced kill cannot run the final cleanup, but the last saved snapshot remains.

- `final-report.tsv`: every address `.1` through `.254`, with IP, selected account, SSH result, clone result, Ollama/model result, overall result, explanation, and log locations. `.0` and `.255` are not host addresses for /24.
- `systems-needing-attention.tsv`: one combined list of addresses that did not run, failed a stage, or have an unconfirmed result, with the categories distinguished in each row.
- `systems-not-run.tsv`: addresses where deployment could not start, including SSH-no-response candidates and detected hosts skipped due to authentication/session checks. This is not proof that every address belongs to an actual computer.
- `systems-failed.tsv`: detected hosts with a failed clone or Ollama stage, even if another stage succeeded.
- `jobs-running.tsv`: launched host jobs without a final result yet.
- `results-unconfirmed.tsv`: host jobs whose final result could not be retrieved.
- `report.txt`: readable counts, detected hosts needing attention, and paths to the complete lists. Its run state identifies a provisional or interrupted report.

View the live readable report from another terminal:

```bash
cat deployment-YYYYMMDD-HHMMSS-XXXXXX/report.txt
```

### Report an existing run without deploying again

The report helper only reads saved results and writes report files. It does not connect to hosts, delete code, start installers, or download models. It also supports run folders from the earlier script, using their `discovered-*` files when no scan table exists. Historical folders need their controller IP supplied so `LOCAL` can be mapped to a real IP:

```bash
CONTROLLER_IP=172.1.44.239 bash report-deployment.sh \
  deployment-20261022-102120-vhxBnr
```

Run this in the controller repository directory after updating the branch. An older run without a saved lifecycle state is marked UNKNOWN. A host with a launch record but no recorded final result remains RUNNING/unconfirmed in that snapshot; it is not reported as successful. The helper cannot recover job outcomes or detailed failure causes absent from the saved files. Consult the individual clone, detection, launch, and Ollama logs linked in the report.

The controller also shows live IP-labelled updates while computers work in parallel:

```text
[IP 172.1.44.10] Targeted; checking active user and SSH access
[IP 172.1.44.10] Active user: rit
[IP 172.1.44.10] Repo cloned: PASS
[IP 172.1.44.11] Repo cloned: FAIL
[IP 172.1.44.10] Ollama available: YES â€” skipping Ollama installation
[IP 172.1.44.11] Ollama available: NO
[IP 172.1.44.11] Downloading Ollama
[IP 172.1.44.10] Downloading/checking model: qwen2.5-coder:14b
[IP 172.1.44.10] Model ready: qwen2.5-coder:14b (not launched)
```

These are examples, not actual deployment results. Each completed clone is reported immediately. Full installer/download output stays in the per-computer log. Existing Ollama skips only installation; its local service and model are still prepared. If a computer fails before availability can be checked, setup is reported as failed rather than displaying an invented yes/no result. The controller is displayed with its network IPv4 address and `(controller)`; reports still use `LOCAL`.

`LOCAL` identifies the controller in reports. A nonzero exit status means a computer failed or was skipped. Every IP in the /24 host range now appears in the report. Offline machines, unused addresses, filtered ports, and computers with closed SSH ports cannot be distinguished by this scan; they are listed as NOT_RUN with an SSH-no-response explanation, rather than incorrectly called clone failures. Each detected computer has its own independent model; there is no shared computation.

Each host saves its setup script, worker script, output log, PID, and final exit code in `/home/ACTIVE_USER/.local/state/university-ollama/task-XXXXXXXX/`. Passwords are passed through standard input and are not saved in these files. A job being started does not mean its installation has passed; only its final result confirms success.

Network prefix, SSH port, and model can be overridden through `SUBNET_PREFIX`, `SSH_PORT`, and `MODEL`. `MONITOR_TIMEOUT` sets the maximum monitoring duration per host in seconds (default 14400, or four hours). It limits monitoring only, not host execution. The previous `MAX_PARALLEL` batching option is no longer used: handoffs proceed one host at a time while host jobs overlap.

After deployment, users can start the downloaded model on their own computer:

```bash
ollama run qwen2.5-coder:14b
```

## Verification status

Shell syntax and simulated orchestration checks are performed during preparation. Real SSH authentication, active-session visibility, deletion, installation, downloads, and model operation require verification on the Ubuntu network. This package does not certify every reachable computer's configuration.
