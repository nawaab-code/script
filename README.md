# Independent Ollama deployment for Ubuntu nodes

This deploys Ollama and `qwen2.5-coder:14b` on each reachable Ubuntu 24.04 machine in `172.1.44.0/24` that accepts SSH as `rit`. Each machine runs its own model and serves it on its own localhost. The management machine is only needed during deployment.

The default model is approximately 9 GB on disk ([Ollama model page](https://ollama.com/library/qwen2.5-coder:14b)). On 16 GB RAM without a GPU, expect CPU inference to be slow. Leave at least 12 GiB free on the node's root filesystem. The script stops on nodes with less free space. It uses [Ollama's official Linux installer](https://docs.ollama.com/linux).

## Before running

1. Run this from an Ubuntu machine that can reach the target machines over SSH. The nodes need outbound internet access to install Ollama and download the model.
2. Ensure `rit` can log in over SSH and use `sudo` with the same password. The script prompts once; no password is stored in the repository.
3. Install controller dependencies:

   ```bash
   sudo apt-get update
   sudo apt-get install -y openssh-client sshpass netcat-openbsd
   ```

4. Review the subnet before running. `172.1.44.0/24` is a public IPv4 range, not an RFC 1918 private range. Run the scan only on machines and networks you administer. If your actual LAN uses a different range, set `SUBNET_PREFIX` as shown below.

SSH uses `StrictHostKeyChecking=accept-new`: a first connection saves the host key, and a changed host key is rejected. For stronger identity checking, confirm each machine's SSH host-key fingerprint before first deployment.

## Deploy

```bash
chmod +x deploy-ollama.sh
./deploy-ollama.sh
```

The script scans all 254 addresses for TCP port 22, tests SSH login, then installs on up to four eligible machines at once. It prints each node's output and a success/failure summary. It exits with a nonzero status if any detected SSH host was skipped or any deployment failed. Re-running it is supported; it can update Ollama and recheck the model on each node.

Set options for a different network or concurrency:

```bash
SUBNET_PREFIX=192.168.1 MAX_PARALLEL=2 ./deploy-ollama.sh
```

Available options are `SUBNET_PREFIX` (default `172.1.44`), `SSH_USER` (default `rit`), `SSH_PORT` (default `22`), `MODEL` (default `qwen2.5-coder:14b`), `MAX_PARALLEL` (default `4`), and `SCAN_PARALLEL` (default `32`). Lower `MAX_PARALLEL` if concurrent model downloads overload the internet connection.

## Use one machine

On any deployed node:

```bash
ollama run qwen2.5-coder:14b
```

Local applications on that same node can use `http://127.0.0.1:11434`. The script does not configure a load balancer, shared memory, or LAN-facing Ollama API. The nodes keep running independently after the management machine is turned off.

Check a node with `systemctl status ollama` and `ollama list`. If the deployment summary marks it failed, inspect its output above the summary and rerun after fixing the reported issue.
