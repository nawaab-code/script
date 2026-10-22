#!/usr/bin/env bash
# Read-only with respect to hosts: rebuild reports from an existing run folder.
set -Eeuo pipefail
run_dir=${1:?Usage: bash report-deployment.sh RUN_FOLDER [--quiet]}
[[ -d $run_dir ]] || { echo "Run folder not found: $run_dir" >&2; exit 1; }
prefix=${SUBNET_PREFIX:-172.1.44}
controller=${CONTROLLER_IP:-LOCAL}
state=UNKNOWN
legacy=1
[[ ! -f $run_dir/scan.tsv ]] || legacy=0
[[ ! -f $run_dir/subnet-prefix ]] || prefix=$(cat "$run_dir/subnet-prefix")
[[ ! -f $run_dir/controller-ip ]] || controller=$(cat "$run_dir/controller-ip")
[[ ! -f $run_dir/run-state ]] || state=$(cat "$run_dir/run-state")
[[ $prefix =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || exit 1
files=()
for name in scan selected skipped clone-ok clone-failed ollama-started ollama-ok ollama-failed ollama-unconfirmed; do
    [[ ! -f $run_dir/$name.tsv ]] || files+=("$run_dir/$name.tsv")
done
for file in "$run_dir"/discovered-*; do
    [[ ! -f $file ]] || files+=("$file")
done
# /dev/null provides a harmless input even for an empty legacy folder.
temp=$(mktemp "$run_dir/report-XXXXXX")
trap 'rm -f -- "$temp"' EXIT
awk -F '\t' -v OFS='\t' -v prefix="$prefix" -v controller="$controller" \
    -v state="$state" -v folder="$run_dir" -v legacy="$legacy" '
function key(ip) { return ip == "LOCAL" ? controller : ip }
function row(ip, ssh, user, repo, model, result, detail, logs, id) {
    id = ip == controller ? "LOCAL" : ip
    ssh = scan[ip]
    if (ip == controller) ssh = "LOCAL"
    if (ssh == "") ssh = legacy ? "NOT_DETECTED_IN_ORIGINAL_SCAN" : "NOT_SCANNED_YET"
    user = users[ip] == "" ? "-" : users[ip]
    repo = cok[ip] ? "PASS" : (cfail[ip] ? "FAIL" : "NOT_STARTED")
    model = ook[ip] ? "PASS" : (ofail[ip] ? "FAIL" : (unknown[ip] ? "UNCONFIRMED" : (started[ip] ? "RUNNING" : "NOT_STARTED")))
    logs = folder "/" id "-detect.log; " folder "/" id "-clone.log; " folder "/" id "-ollama.log"
    if (started[ip]) logs = logs "; host: " started[ip] "/output.log"
    result = "PENDING"; detail = "Host has not been processed yet"
    if (ssh == "NO_RESPONSE" || ssh == "NOT_DETECTED_IN_ORIGINAL_SCAN") {
        result = "NOT_RUN"; detail = "SSH did not respond during scan; offline, unused, blocked, and closed-port addresses cannot be distinguished"
    } else if (skip[ip] != "") {
        result = "NOT_RUN"; detail = skip[ip]
    } else if (cfail[ip] || ofail[ip]) {
        result = "FAILED"; detail = ""
        if (cfail[ip]) detail = "Repository clone failed; inspect clone log"
        if (ofail[ip]) detail = detail (detail == "" ? "" : "; ") (ofail[ip] == "1" ? "Ollama setup failed; inspect Ollama/launch log" : ofail[ip])
    } else if (cok[ip] && ook[ip]) {
        result = "PASS"; detail = "Repository cloned and model download confirmed"
    } else if (unknown[ip] || (started[ip] && (state == "INTERRUPTED" || state == "FINISHED"))) {
        result = "UNCONFIRMED"; model = "UNCONFIRMED"; detail = "Host job may still be running; final result was not retrieved"
    } else if (started[ip]) {
        result = "RUNNING"; detail = "Host setup started; download not yet confirmed complete"
    } else if (state == "INTERRUPTED" || state == "FINISHED") {
        result = "NOT_RUN"; detail = "No host setup launch recorded"
    }
    print ip, user, ssh, repo, model, result, detail, logs
}
FILENAME ~ /\/discovered-[0-9]+$/ { scan[$1] = "OPEN"; next }
FILENAME ~ /\/scan.tsv$/ { scan[key($1)] = $2; next }
FILENAME ~ /\/selected.tsv$/ { users[key($1)] = $2; next }
FILENAME ~ /\/skipped.tsv$/ { skip[key($1)] = $2; next }
FILENAME ~ /\/clone-ok.tsv$/ { cok[key($1)] = 1; users[key($1)] = $2; next }
FILENAME ~ /\/clone-failed.tsv$/ { cfail[key($1)] = 1; users[key($1)] = $2; next }
FILENAME ~ /\/ollama-started.tsv$/ { started[key($1)] = $3; users[key($1)] = $2; next }
FILENAME ~ /\/ollama-ok.tsv$/ { ook[key($1)] = 1; users[key($1)] = $2; next }
FILENAME ~ /\/ollama-failed.tsv$/ { ofail[key($1)] = $3 == "" ? "1" : $3; users[key($1)] = $2; next }
FILENAME ~ /\/ollama-unconfirmed.tsv$/ { unknown[key($1)] = 1; next }
END {
    print "IP", "USER", "SSH", "REPO", "OLLAMA_MODEL", "RESULT", "DETAILS", "LOGS"
    for (i = 1; i <= 254; i++) row(prefix "." i)
    if (controller !~ ("^" prefix "\\.[0-9]+$")) row(controller)
}' "${files[@]}" /dev/null > "$temp"
mv -- "$temp" "$run_dir/final-report.tsv"
for kind in systems-not-run systems-failed results-unconfirmed jobs-running; do
    temp=$(mktemp "$run_dir/report-XXXXXX")
    case $kind in
        systems-not-run) result=NOT_RUN ;;
        systems-failed) result=FAILED ;;
        results-unconfirmed) result=UNCONFIRMED ;;
        jobs-running) result=RUNNING ;;
    esac
    awk -F '\t' -v result="$result" 'NR == 1 || $6 == result' "$run_dir/final-report.tsv" > "$temp"
    mv -- "$temp" "$run_dir/$kind.tsv"
done
temp=$(mktemp "$run_dir/report-XXXXXX")
awk -F '\t' 'NR == 1 || $6 == "NOT_RUN" || $6 == "FAILED" || $6 == "UNCONFIRMED"' \
    "$run_dir/final-report.tsv" > "$temp"
mv -- "$temp" "$run_dir/systems-needing-attention.tsv"
temp=$(mktemp "$run_dir/report-XXXXXX")
{
    printf 'Deployment report | run state: %s | generated: %s\n' "$state" "$(date -Is)"
    awk -F '\t' 'NR > 1 { count[$6]++; total++ } END {
        printf "Addresses: %d | PASS: %d | FAILED: %d | NOT_RUN: %d | RUNNING: %d | UNCONFIRMED: %d | PENDING: %d\n", total, count["PASS"], count["FAILED"], count["NOT_RUN"], count["RUNNING"], count["UNCONFIRMED"], count["PENDING"]
    }' "$run_dir/final-report.tsv"
    printf '\nDetected hosts needing attention (SSH-open hosts and controller):\n'
    awk -F '\t' 'BEGIN { OFS="\t"; print "IP", "RESULT", "REPO", "OLLAMA_MODEL", "DETAILS" }
        NR > 1 && ($3 == "OPEN" || $3 == "LOCAL") && ($6 == "FAILED" || $6 == "NOT_RUN" || $6 == "UNCONFIRMED") { print $1, $6, $4, $5, $7 }' "$run_dir/final-report.tsv"
    printf '\nEvery address: %s/final-report.tsv\nCombined failure/not-run/unconfirmed list: %s/systems-needing-attention.tsv\nNot run (including nonresponding addresses): %s/systems-not-run.tsv\nFailed stages: %s/systems-failed.tsv\nRunning jobs: %s/jobs-running.tsv\nUnconfirmed results: %s/results-unconfirmed.tsv\n' "$run_dir" "$run_dir" "$run_dir" "$run_dir" "$run_dir" "$run_dir"
    printf '\nNOT_RUN addresses are not proof of existing/offline computers. .0 and .255 are excluded for /24.\n'
    printf 'RUNNING/UNKNOWN reports are provisional; INTERRUPTED jobs may continue on their hosts.\n'
} > "$temp"
mv -- "$temp" "$run_dir/report.txt"
if [[ ${2:-} != --quiet ]]; then cat "$run_dir/report.txt"; fi
