#!/usr/bin/env bash
# This file is streamed to a remote bash process by deploy-ollama.sh.

set -Eeuo pipefail

sudo_cmd() {
    printf '%s\n' "$SUDO_PASSWORD" | sudo -S -p '' "$@"
}

[[ $(uname -s) == Linux ]] || { echo 'This node is not Linux.' >&2; exit 1; }
# Ubuntu 24.04 is the target. Fail before changing another operating system.
. /etc/os-release
[[ $ID == ubuntu && $VERSION_ID == 24.04 ]] || {
    echo "Expected Ubuntu 24.04; found ${PRETTY_NAME:-unknown}." >&2
    exit 1
}

printf 'Node: %s | OS: %s | RAM: %s KiB\n' \
    "$(hostname)" "$PRETTY_NAME" "$(awk '/MemTotal:/ {print $2}' /proc/meminfo)"

# The default 14B model is about 9 GB; leave room for downloads and other files.
free_kib=$(df -Pk / | awk 'NR == 2 {print $4}')
(( free_kib >= 12 * 1024 * 1024 )) || {
    echo 'Less than 12 GiB free on the root filesystem.' >&2
    exit 1
}

echo '[1/4] Installing prerequisites'
sudo_cmd apt-get update -qq
sudo_cmd apt-get install -y curl ca-certificates >/dev/null

echo '[2/4] Installing or updating Ollama'
installer=$(mktemp)
trap 'rm -f -- "$installer"' EXIT
curl -fsSL https://ollama.com/install.sh -o "$installer"
sudo_cmd sh "$installer"

echo '[3/4] Starting the Ollama service'
sudo_cmd systemctl enable --now ollama
sudo_cmd systemctl restart ollama
ready=0
for attempt in {1..20}; do
    if ollama list >/dev/null 2>&1; then ready=1; break; fi
    sleep 2
done
(( ready == 1 )) || { echo 'Ollama service did not become ready.' >&2; exit 1; }

echo "[4/4] Pulling and testing $MODEL"
ollama pull "$MODEL" 2>&1 | tail -n 10
response=$(timeout 300 ollama run "$MODEL" 'Reply with exactly: OLLAMA_NODE_OK')
[[ $response == *OLLAMA_NODE_OK* ]] || {
    printf 'Inference check failed; response was: %s\n' "$response" >&2
    exit 1
}
printf 'Inference check passed. Ollama is available locally at http://127.0.0.1:11434\n'
