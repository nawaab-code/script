#!/usr/bin/env bash
set -Eeuo pipefail
umask 077
SUBNET_PREFIX=${SUBNET_PREFIX:-172.1.44}
SSH_PORT=${SSH_PORT:-22}
MODEL=${MODEL:-qwen2.5-coder:14b}
MONITOR_TIMEOUT=${MONITOR_TIMEOUT:-14400}
SCRIPT_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
for cmd in ssh sshpass nc sort; do
    command -v "$cmd" >/dev/null || { echo "Missing dependency: $cmd" >&2; exit 1; }
done
[[ -f $SCRIPT_DIR/node-setup.sh && -f $SCRIPT_DIR/launch-node.sh ]] || { echo 'Missing node-setup.sh or launch-node.sh' >&2; exit 1; }
[[ $SSH_PORT =~ ^[0-9]+$ ]] && (( SSH_PORT > 0 && SSH_PORT < 65536 )) || exit 1
[[ $MONITOR_TIMEOUT =~ ^[1-9][0-9]*$ ]] || exit 1
[[ $MODEL =~ ^[a-zA-Z0-9._:/-]+$ ]] || exit 1
IFS=. read -r -a octets <<< "$SUBNET_PREFIX"
(( ${#octets[@]} == 3 )) || exit 1
for octet in "${octets[@]}"; do
    [[ $octet =~ ^(0|[1-9][0-9]{0,2})$ ]] && (( octet <= 255 )) || exit 1
done
[[ $(uname -s) == Linux ]] || { echo 'Run this on the Ubuntu controller.' >&2; exit 1; }
declare -A passwords accounts
for user in rit exam hadoop; do
    read -r -s -p "SSH/sudo password for $user: " "passwords[$user]"
    printf '\n'
    [[ -n ${passwords[$user]} ]] || { echo 'Passwords cannot be empty.' >&2; exit 1; }
done
run_dir=$(mktemp -d "$SCRIPT_DIR/deployment-$(date +%Y%m%d-%H%M%S)-XXXXXX")
printf 'Logs and results: %s\n' "$run_dir"
ssh_options=(-T -p "$SSH_PORT" -o StrictHostKeyChecking=accept-new
    -o ConnectTimeout=5 -o ConnectionAttempts=1 -o ServerAliveInterval=15
    -o ServerAliveCountMax=3 -o NumberOfPasswordPrompts=1
    -o PreferredAuthentications=password,keyboard-interactive -o PubkeyAuthentication=no)
remote() {
    local ip=$1 user=$2
    shift 2
    sshpass -d 3 ssh "${ssh_options[@]}" "$user@$ip" "$@" 3<<< "${passwords[$user]}"
}
# Only foreground local sessions count. SSH sessions do not select the account.
detect_script='set -eu
. /etc/os-release
[ "$ID" = ubuntu ] || { echo "Unsupported OS: $ID" >&2; exit 1; }
command -v loginctl >/dev/null || { echo "loginctl missing" >&2; exit 1; }
loginctl list-sessions --no-legend --no-pager | while read -r sid rest; do
    active=$(loginctl show-session "$sid" -p Active --value)
    remote=$(loginctl show-session "$sid" -p Remote --value)
    class=$(loginctl show-session "$sid" -p Class --value)
    if [ "$active" = yes ] && [ "$remote" = no ] && [ "$class" = user ]; then
        loginctl show-session "$sid" -p Name --value
    fi
done'
printf 'Scanning %s.1 through %s.254 for SSH...\n' "$SUBNET_PREFIX" "$SUBNET_PREFIX"
pids=()
for last in {1..254}; do
    ip="$SUBNET_PREFIX.$last"
    (if nc -z -w 2 "$ip" "$SSH_PORT" 2>/dev/null; then echo "$ip" > "$run_dir/discovered-$last"; fi) &
    pids+=("$!")
    if (( ${#pids[@]} >= 32 )); then
        for pid in "${pids[@]}"; do wait "$pid" || true; done
        pids=()
    fi
done
for pid in "${pids[@]}"; do wait "$pid" || true; done
hosts=()
for file in "$run_dir"/discovered-*; do
    if [[ -f $file ]]; then hosts+=("$(cat "$file")"); fi
done
# Include the controller even if its own SSH server is disabled.
if (( ${#hosts[@]} > 0 )); then
    mapfile -t hosts < <(printf '%s\n' "${hosts[@]}" | sort -t . -k4,4n)
fi
hosts+=(LOCAL)
controller_address=''
for address in $(hostname -I); do
    if [[ $address == "$SUBNET_PREFIX".* ]]; then controller_address=$address; break; fi
    if [[ -z $controller_address && $address == *.* ]]; then controller_address=$address; fi
done
host_label() {
    if [[ $1 == LOCAL ]]; then printf '%s (controller)' "${controller_address:-LOCAL}";
    else printf '%s' "$1"; fi
}
run_node() {
    local ip=$1 phase=$2 user=${accounts[$1]}
    if [[ $ip == LOCAL ]]; then
        {
            printf '%s\n' "${passwords[$user]}" "$MODEL" "$phase"
            cat "$SCRIPT_DIR/node-setup.sh"
        } | sudo -n -H -u "$user" bash -c 'IFS= read -r SUDO_PASSWORD; IFS= read -r MODEL; IFS= read -r PHASE; source /dev/stdin'
    else
        {
            printf '%s\n' "${passwords[$user]}" "$MODEL" "$phase"
            cat "$SCRIPT_DIR/node-setup.sh"
        } | remote "$ip" "$user" "bash -c 'IFS= read -r SUDO_PASSWORD; IFS= read -r MODEL; IFS= read -r PHASE; source /dev/stdin'"
    fi
}
stream_node() {
    local ip=$1 log=$2 line label
    label=$(host_label "$ip")
    while IFS= read -r line || [[ -n $line ]]; do
        printf '%s\n' "$line" >> "$log"
        if [[ $line == '@@STATUS@@ '* ]]; then
            printf '[IP %s] %s\n' "$label" "${line#'@@STATUS@@ '}"
        fi
    done
}
deploy_one() {
    local ip=$1 phase=$2 label
    label=$(host_label "$ip")
    printf '[IP %s] %s stage started\n' "$label" "$phase"
    if run_node "$ip" "$phase" 2>&1 | stream_node "$ip" "$run_dir/$ip-$phase.log"; then
        if [[ $phase == clone ]]; then
            printf '[IP %s] Repo cloned: PASS\n' "$label"
        else
            printf '[IP %s] Ollama/model setup: PASS\n' "$label"
        fi
    else
        if [[ $phase == clone ]]; then
            printf '[IP %s] Repo cloned: FAIL\n' "$label"
        else
            printf '[IP %s] Ollama/model setup: FAIL\n' "$label"
        fi
        printf '[IP %s] Failure details: %s/%s-%s.log\n' "$label" "$run_dir" "$ip" "$phase"
        return 1
    fi
}

shell_quote() { printf "'%s'" "${1//\'/\'\\\'\'}"; }
launch_node() {
    local ip=$1 user=${accounts[$1]} launcher
    launcher=$(cat "$SCRIPT_DIR/launch-node.sh")
    if [[ $ip == LOCAL ]]; then
        { printf '%s\n' "${passwords[$user]}" "$MODEL"; cat "$SCRIPT_DIR/node-setup.sh"; } |
            sudo -n -H -u "$user" bash -c "$launcher"
    else
        { printf '%s\n' "${passwords[$user]}" "$MODEL"; cat "$SCRIPT_DIR/node-setup.sh"; } |
            remote "$ip" "$user" "bash -c $(shell_quote "$launcher")"
    fi
}
read_task() {
    local ip=$1 task=$2 user=${accounts[$1]} command
    command="cat '$task/output.log'; if [ -f '$task/result' ]; then printf '\\n@@DONE@@ '; cat '$task/result'; fi"
    if [[ $ip == LOCAL ]]; then
        sudo -n -H -u "$user" bash -c "$command"
    else
        remote "$ip" "$user" "$command" </dev/null
    fi
}
monitor_host() {
    local ip=$1 task=$2 label snapshot line count=0 seen=0 errors=0 start=$SECONDS code
    label=$(host_label "$ip")
    while (( SECONDS - start < MONITOR_TIMEOUT )); do
        if snapshot=$(read_task "$ip" "$task" 2>> "$run_dir/$ip-monitor.log"); then
            errors=0
            printf '%s\n' "$snapshot" > "$run_dir/$ip-ollama.log"
            count=0
            while IFS= read -r line; do
                count=$((count + 1))
                if (( count > seen )) && [[ $line == '@@STATUS@@ '* ]]; then
                    printf '[IP %s] %s\n' "$label" "${line#'@@STATUS@@ '}"
                fi
                if [[ $line == '@@DONE@@ '* ]]; then
                    code=${line#'@@DONE@@ '}
                    if [[ $code == 0 ]]; then
                        printf '[IP %s] Ollama/model setup: PASS\n' "$label"
                        printf '%s\t%s\n' "$ip" "${accounts[$ip]}" >> "$run_dir/ollama-ok.tsv"
                        return 0
                    fi
                    printf '[IP %s] Ollama/model setup: FAIL; host log: %s/output.log\n' "$label" "$task"
                    printf '%s\t%s\n' "$ip" "${accounts[$ip]}" >> "$run_dir/ollama-failed.tsv"
                    return 1
                fi
            done <<< "$snapshot"
            seen=$count
        else
            errors=$((errors + 1))
            if (( errors >= 3 )); then break; fi
        fi
        sleep 5
    done
    printf '[IP %s] Monitoring unavailable; host job may still be running. Log: %s/output.log\n' "$label" "$task"
    printf '%s\t%s\n' "$ip" "$task" >> "$run_dir/ollama-unconfirmed.tsv"
    return 1
}
failed=0
selected=0
monitor_pids=()
for report in skipped clone-failed clone-ok ollama-failed ollama-ok ollama-started ollama-unconfirmed; do
    : > "$run_dir/$report.tsv"
done
for ip in "${hosts[@]}"; do
    # The controller is handled locally, so do not also deploy via its LAN IP.
    if [[ $ip != LOCAL ]] && hostname -I | tr ' ' '\n' | grep -Fxq "$ip"; then continue; fi
    printf '[IP %s] Targeted; checking active user and SSH access\n' "$(host_label "$ip")"
    active_users=''
    detected=0
    if [[ $ip == LOCAL ]]; then
        if active_users=$(bash -c "$detect_script" 2> "$run_dir/$ip-detect.log"); then detected=1; fi
    else
        for user in rit exam hadoop; do
            if active_users=$(remote "$ip" "$user" 'bash -s' <<< "$detect_script" 2>> "$run_dir/$ip-detect.log"); then
                detected=1
                break
            fi
        done
    fi
    candidates=()
    while IFS= read -r user; do
        if [[ $user == rit || $user == exam || $user == hadoop ]]; then candidates+=("$user"); fi
    done < <(printf '%s\n' "$active_users" | sort -u)
    if (( ! detected || ${#candidates[@]} != 1 )); then
        printf '%s\tCannot identify exactly one active local rit/exam/hadoop user\n' "$ip" | tee -a "$run_dir/skipped.tsv"
        continue
    fi
    user=${candidates[0]}
    if [[ $ip != LOCAL ]] && ! remote "$ip" "$user" true </dev/null 2>> "$run_dir/$ip-detect.log"; then
        printf '%s\tActive user %s did not accept SSH login\n' "$ip" "$user" | tee -a "$run_dir/skipped.tsv"
        continue
    fi
    accounts[$ip]=$user
    selected=$((selected + 1))
    printf '[IP %s] Active user: %s\n' "$(host_label "$ip")" "$user"

    if [[ $ip == LOCAL ]]; then
        echo 'Authorize local account switching on the controller:'
        if ! sudo -v; then
            printf '%s\tController sudo authorization failed\n' "$ip" >> "$run_dir/skipped.tsv"
            failed=1
            continue
        fi
    fi
    if deploy_one "$ip" clone; then
        printf '%s\t%s\n' "$ip" "$user" >> "$run_dir/clone-ok.tsv"
    else
        printf '%s\t%s\n' "$ip" "$user" >> "$run_dir/clone-failed.tsv"
        failed=1
    fi
    # Continue with Ollama even after a failed clone, as previously requested.
    if launch_output=$(launch_node "$ip" 2> "$run_dir/$ip-launch.log"); then
        task=''
        while IFS= read -r line; do
            if [[ $line == '@@TASK@@ '* ]]; then task=${line#'@@TASK@@ '}; fi
        done <<< "$launch_output"
        if [[ $task =~ ^/home/$user/\.local/state/university-ollama/task-[a-zA-Z0-9]+$ ]]; then
            printf '[IP %s] Ollama script saved and started on host; proceeding to next computer\n' "$(host_label "$ip")"
            printf '%s\t%s\t%s\n' "$ip" "$user" "$task" >> "$run_dir/ollama-started.tsv"
            monitor_host "$ip" "$task" &
            monitor_pids+=("$!")
            continue
        fi
    fi
    printf '[IP %s] Ollama script launch: FAIL; see %s/%s-launch.log\n' "$(host_label "$ip")" "$run_dir" "$ip"
    printf '%s\t%s\n' "$ip" "$user" >> "$run_dir/ollama-failed.tsv"
    failed=1
done
printf '\nAll host handoffs attempted. Monitoring jobs already running on hosts...\n'
for pid in "${monitor_pids[@]}"; do
    if ! wait "$pid"; then failed=1; fi
done
printf '\nClone failures:\n'; cat "$run_dir/clone-failed.tsv"
printf '\nOllama/model failures:\n'; cat "$run_dir/ollama-failed.tsv"
printf '\nOllama results not confirmed:\n'; cat "$run_dir/ollama-unconfirmed.tsv"
printf '\nSkipped computers:\n'; cat "$run_dir/skipped.tsv"
printf '\nFull results: %s\n' "$run_dir"
(( selected > 0 )) || failed=1
[[ ! -s $run_dir/skipped.tsv ]] || failed=1
exit "$failed"
