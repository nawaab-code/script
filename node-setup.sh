#!/usr/bin/env bash
# Streamed by deploy-network.sh; not a standalone entry point.
set -Eeuo pipefail
sudo_cmd() { printf '%s\n' "$SUDO_PASSWORD" | sudo -S -p '' "$@"; }
. /etc/os-release
[[ $ID == ubuntu ]] || { echo "Ubuntu required; found $ID" >&2; exit 1; }
user=$(id -un)
[[ $user == rit || $user == exam || $user == hadoop ]] || exit 1
# Resolve the account's real home rather than inheriting the controller's HOME.
account_home=$(getent passwd "$user" | cut -d: -f6)
[[ $account_home == "/home/$user" && -d $account_home ]] || {
    echo "Unexpected home directory: $account_home; no files deleted." >&2; exit 1;
}
export HOME="$account_home"
sudo_cmd -k true
if [[ $PHASE == clone ]]; then
    if ! command -v git >/dev/null; then
        sudo_cmd apt-get -o DPkg::Lock::Timeout=300 update -qq
        sudo_cmd apt-get -o DPkg::Lock::Timeout=300 install -y git ca-certificates
    fi
    destination="$account_home/university-code"
    printf 'Replacing %s on %s as %s\n' "$destination" "$(hostname)" "$user"
    rm -rf -- "$destination"
    GIT_TERMINAL_PROMPT=0 git clone -- https://github.com/nawaab-code/university-code.git "$destination"
    exit 0
fi
[[ $PHASE == ollama ]] || exit 1
printf 'Host: %s | OS: %s | RAM: %s KiB\n' "$(hostname)" "$PRETTY_NAME" "$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"
if ! command -v ollama >/dev/null; then
    echo '@@STATUS@@ Ollama available: NO'
    free_kib=$(df -Pk / | awk 'NR == 2 {print $4}')
    (( free_kib >= 12 * 1024 * 1024 )) || { echo 'Less than 12 GiB free on /.' >&2; exit 1; }
    sudo_cmd apt-get -o DPkg::Lock::Timeout=300 update -qq
    sudo_cmd apt-get -o DPkg::Lock::Timeout=300 install -y curl ca-certificates
    installer=$(mktemp)
    trap 'rm -f -- "$installer"' EXIT
    echo '@@STATUS@@ Downloading Ollama'
    curl -fsSL https://ollama.com/install.sh -o "$installer"
    sudo_cmd sh "$installer"
else
    echo '@@STATUS@@ Ollama available: YES — skipping Ollama installation'
fi
sudo_cmd systemctl cat ollama >/dev/null
sudo_cmd mkdir -p /etc/systemd/system/ollama.service.d
printf '[Service]\nEnvironment="OLLAMA_HOST=127.0.0.1:11434"\n' | {
    config=$(mktemp)
    cat > "$config"
    sudo_cmd install -m 644 "$config" /etc/systemd/system/ollama.service.d/99-local-only.conf
    rm -f -- "$config"
}
sudo_cmd systemctl daemon-reload
sudo_cmd systemctl enable ollama
sudo_cmd systemctl restart ollama
export OLLAMA_HOST=127.0.0.1:11434
ready=0
for attempt in {1..30}; do
    if ollama list >/dev/null 2>&1; then ready=1; break; fi
    sleep 2
done
(( ready )) || { echo 'Ollama service did not become ready.' >&2; exit 1; }
printf '@@STATUS@@ Downloading/checking model: %s\n' "$MODEL"
ollama pull "$MODEL"
printf '@@STATUS@@ Model ready: %s (not launched)\n' "$MODEL"
