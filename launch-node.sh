#!/usr/bin/env bash
# The controller executes this launcher as the selected account.
set -Eeuo pipefail
umask 077
IFS= read -r SUDO_PASSWORD
IFS= read -r MODEL
user=$(id -un)
[[ $user == rit || $user == exam || $user == hadoop ]] || exit 1
account_home=$(getent passwd "$user" | cut -d: -f6)
[[ $account_home == "/home/$user" ]] || exit 1
state_dir="$account_home/.local/state/university-ollama"
mkdir -p -- "$state_dir"
task_dir=$(mktemp -d "$state_dir/task-XXXXXXXX")
cat > "$task_dir/node-setup.sh"
cat > "$task_dir/worker.sh" <<'WORKER'
#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
task_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
trap 'code=$?; printf "%s\n" "$code" > "$task_dir/result.tmp"; mv -- "$task_dir/result.tmp" "$task_dir/result"' EXIT
IFS= read -r SUDO_PASSWORD
IFS= read -r MODEL
PHASE=ollama
source "$task_dir/node-setup.sh"
WORKER
# Credentials go through stdin, never command-line arguments or saved files.
nohup bash "$task_dir/worker.sh" > "$task_dir/output.log" 2>&1 \
    <<< "$(printf '%s\n' "$SUDO_PASSWORD" "$MODEL")" &
printf '%s\n' "$!" > "$task_dir/pid"
printf '@@TASK@@ %s\n' "$task_dir"
