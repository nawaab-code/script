#!/usr/bin/env bash

set -Eeuo pipefail
umask 077

(( BASH_VERSINFO[0] >= 4 )) || { echo 'Bash 4 or newer is required.' >&2; exit 1; }

SUBNET_PREFIX=${SUBNET_PREFIX:-172.1.44}
SSH_USER=${SSH_USER:-rit}
SSH_PORT=${SSH_PORT:-22}
MODEL=${MODEL:-qwen2.5-coder:14b}
MAX_PARALLEL=${MAX_PARALLEL:-4}
SCAN_PARALLEL=${SCAN_PARALLEL:-32}

SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
NODE_SCRIPT="$SCRIPT_DIR/install-node.sh"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

[[ -f $NODE_SCRIPT ]] || die "Missing $NODE_SCRIPT"
for command in ssh sshpass nc sort; do
    command -v "$command" >/dev/null 2>&1 || die "Missing $command. See README.md for prerequisites."
done
[[ $SSH_PORT =~ ^[0-9]+$ ]] && (( SSH_PORT >= 1 && SSH_PORT <= 65535 )) || die 'SSH_PORT must be a valid port.'
[[ $MAX_PARALLEL =~ ^[0-9]+$ ]] && (( MAX_PARALLEL >= 1 )) || die 'MAX_PARALLEL must be at least 1.'
[[ $SCAN_PARALLEL =~ ^[0-9]+$ ]] && (( SCAN_PARALLEL >= 1 )) || die 'SCAN_PARALLEL must be at least 1.'
[[ $SSH_USER =~ ^[a-zA-Z_][a-zA-Z0-9_-]*$ ]] || die 'SSH_USER contains unsupported characters.'
[[ $MODEL =~ ^[a-zA-Z0-9._:/-]+$ ]] || die 'MODEL contains unsupported characters.'

IFS=. read -r -a octets <<< "$SUBNET_PREFIX"
(( ${#octets[@]} == 3 )) || die 'SUBNET_PREFIX must contain three IPv4 octets.'
for octet in "${octets[@]}"; do
    [[ $octet =~ ^(0|[1-9][0-9]{0,2})$ ]] && (( octet <= 255 )) || die 'SUBNET_PREFIX is invalid.'
done

work_dir=$(mktemp -d)
trap 'rm -rf -- "$work_dir"' EXIT
discovered_file="$work_dir/discovered"
: > "$discovered_file"

printf 'Subnet: %s.0/24 | SSH user: %s | Model: %s | Deployments at once: %s\n' \
    "$SUBNET_PREFIX" "$SSH_USER" "$MODEL" "$MAX_PARALLEL"
printf 'SSH password for %s: ' "$SSH_USER"
IFS= read -r -s SSH_PASSWORD
printf '\n'
[[ -n $SSH_PASSWORD ]] || die 'Password cannot be empty.'
[[ $SSH_PASSWORD != *$'\n'* ]] || die 'Password cannot contain a newline.'

ssh_options=(
    -T -p "$SSH_PORT"
    -o StrictHostKeyChecking=accept-new
    -o ConnectTimeout=5
    -o ConnectionAttempts=1
    -o ServerAliveInterval=15
    -o ServerAliveCountMax=3
    -o NumberOfPasswordPrompts=1
)

printf '\nScanning for SSH servers...\n'
scan_pids=()
for last_octet in {1..254}; do
    ip="$SUBNET_PREFIX.$last_octet"
    ( if nc -z -w 2 "$ip" "$SSH_PORT" 2>/dev/null; then printf '%s\n' "$ip" >> "$discovered_file"; fi ) &
    scan_pids+=("$!")
    if (( ${#scan_pids[@]} >= SCAN_PARALLEL )); then
        for pid in "${scan_pids[@]}"; do wait "$pid" || true; done
        scan_pids=()
    fi
done
for pid in "${scan_pids[@]}"; do wait "$pid" || true; done
discovered=()
while IFS= read -r ip; do discovered+=("$ip"); done < <(sort -t . -k4,4n "$discovered_file")
printf 'Found %s SSH server(s).\n' "${#discovered[@]}"
(( ${#discovered[@]} > 0 )) || die 'No SSH servers found.'

valid_hosts=()
skipped_hosts=()
for ip in "${discovered[@]}"; do
    if sshpass -d 3 ssh "${ssh_options[@]}" "$SSH_USER@$ip" true 3<<< "$SSH_PASSWORD" </dev/null; then
        valid_hosts+=("$ip")
        printf '[AUTH OK] %s\n' "$ip"
    else
        skipped_hosts+=("$ip")
        printf '[SKIP] %s (authentication or SSH host-key check failed)\n' "$ip" >&2
    fi
done
(( ${#valid_hosts[@]} > 0 )) || die 'No hosts accepted SSH authentication.'

deploy_host() {
    local ip=$1
    {
        printf '%s\n' "$SSH_PASSWORD" "$MODEL"
        cat "$NODE_SCRIPT"
    } | sshpass -d 3 ssh "${ssh_options[@]}" "$SSH_USER@$ip" \
        "bash -c 'IFS= read -r SUDO_PASSWORD; IFS= read -r MODEL; source /dev/stdin'" \
        3<<< "$SSH_PASSWORD"
}

success_hosts=()
failed_hosts=()
batch_hosts=()
batch_pids=()

finish_batch() {
    local index ip pid
    for index in "${!batch_hosts[@]}"; do
        ip=${batch_hosts[$index]}
        pid=${batch_pids[$index]}
        if wait "$pid"; then
            success_hosts+=("$ip")
            printf '\n[OK] %s\n' "$ip"
        else
            failed_hosts+=("$ip")
            printf '\n[FAILED] %s\n' "$ip" >&2
        fi
        cat "$work_dir/$ip.log"
    done
    batch_hosts=()
    batch_pids=()
}

printf '\nDeploying to %s host(s)...\n' "${#valid_hosts[@]}"
for ip in "${valid_hosts[@]}"; do
    deploy_host "$ip" > "$work_dir/$ip.log" 2>&1 &
    batch_hosts+=("$ip")
    batch_pids+=("$!")
    if (( ${#batch_hosts[@]} >= MAX_PARALLEL )); then finish_batch; fi
done
if (( ${#batch_hosts[@]} > 0 )); then finish_batch; fi

printf '\nDeployment summary: %s succeeded, %s failed, %s skipped.\n' \
    "${#success_hosts[@]}" "${#failed_hosts[@]}" "${#skipped_hosts[@]}"
for ip in "${success_hosts[@]}"; do printf '  OK      %s\n' "$ip"; done
for ip in "${failed_hosts[@]}"; do printf '  FAILED  %s\n' "$ip"; done
for ip in "${skipped_hosts[@]}"; do printf '  SKIPPED %s\n' "$ip"; done

(( ${#failed_hosts[@]} == 0 && ${#skipped_hosts[@]} == 0 ))
