#!/usr/bin/env bash
# Configure as the command= for the Windows switcher's dedicated key.
# An ssh -N forwarding connection does not open a session or call this gate.
set -euo pipefail
controller="$HOME/.local/lib/spark-switcher/sparkctl.py"
case "${SSH_ORIGINAL_COMMAND:-}" in
    'sparkctl status') exec python3 "$controller" status ;;
    'sparkctl stop') exec python3 "$controller" stop ;;
    'sparkctl switch glm') exec python3 "$controller" switch glm ;;
    'sparkctl switch deepseek') exec python3 "$controller" switch deepseek ;;
    'sparkctl switch qwen') exec python3 "$controller" switch qwen ;;
    *) printf 'Unsupported Spark Switcher command.\n' >&2; exit 1 ;;
esac
