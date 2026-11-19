#!/usr/bin/env bash
set -euo pipefail
umask 077

case "${1:-all}" in
    -h|--help)
        printf 'Usage: bash deploy/prepare.sh [check|all|glm|deepseek|qwen]\n'
        printf 'Run on the head Spark after configuring ~/.config/spark-switcher/server.json.\n'
        printf 'check validates prerequisites. The model commands stage assets and install the controller.\n'
        exit 0
        ;;
    check|all|glm|deepseek|qwen) selection=${1:-all} ;;
    *) printf 'Unknown selection: %s\nUse --help for usage.\n' "$1" >&2; exit 2 ;;
esac
(( $# <= 1 )) || { printf 'Pass at most one selection.\n' >&2; exit 2; }

DEPLOY_DIR=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
PROJECT_ROOT=$(cd -- "$DEPLOY_DIR/.." && pwd)
SERVER_DIR="$PROJECT_ROOT/server"
# shellcheck source=common.sh
source "$DEPLOY_DIR/common.sh"

for program in python3 docker ssh rsync flock; do
    command -v "$program" >/dev/null || die "Missing head prerequisite: $program"
done
[[ "$(uname -m)" == aarch64 ]] || die "Run from the head DGX Spark (Linux ARM64)."
python3 "$SERVER_DIR/sparkctl.py" check-config
WORKER_TARGET=$(cfg worker.ssh_target)
SSH_OPTIONS=(-o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10
             -o ServerAliveInterval=15 -o ServerAliveCountMax=4)
RSYNC_SSH="ssh ${SSH_OPTIONS[*]}"
WORKER_HOME=$(worker printenv HOME)
[[ "$WORKER_HOME" == /* && "$WORKER_HOME" != / && "$WORKER_HOME" != *$'\n'* ]] ||
    die "Worker SSH did not return a usable home path."
[[ "$(worker uname -m)" == aarch64 ]] || die "Worker must be Linux ARM64."
worker bash -c 'for p in python3 docker rsync; do command -v "$p" >/dev/null || exit 1; done' ||
    die "Install Python, Docker and rsync on the worker."
docker info --format '{{.ServerVersion}}' >/dev/null || die "Cannot access Docker on the head."
worker docker info --format '{{.ServerVersion}}' >/dev/null || die "Cannot access Docker on the worker."
python3 "$SERVER_DIR/sparkctl.py" check-fabric
if [[ "$selection" == check ]]; then
    say "Both nodes and the configured RoCE link are ready."
    exit 0
fi

state="$HOME/.local/state/spark-switcher"
mkdir -p -- "$state"
exec 9>"$state/switch.lock"
flock -n 9 || die "A Spark Switcher operation is already running."

if [[ "$selection" == all ]]; then
    models=(glm deepseek qwen)
else
    models=("$selection")
fi
for model in "${models[@]}"; do
    say "Preparing $model on both Sparks"
    source "$DEPLOY_DIR/$model.sh"
    "prepare_$model"
    python3 "$SERVER_DIR/sparkctl.py" preflight "$model"
done
bash "$SERVER_DIR/install.sh"
say "Prepared ${models[*]}. Select a model in Spark Switcher or use sparkctl.py switch."
