#!/usr/bin/env bash
# Install the controller and the SSH command gate as the head's service account.
set -euo pipefail
umask 077
source="$(cd "$(dirname "$0")" && pwd)"
target="$HOME/.local/lib/spark-switcher"
python3 "$source/sparkctl.py" check-config
expected_head=$(python3 - "$HOME/.config/spark-switcher/server.json" <<'PY'
import json, sys
from pathlib import Path
config = Path(sys.argv[1])
print(json.loads(config.read_text(encoding="utf-8"))["head"]["hostname"])
PY
)
if [[ $(hostname -s) != "$expected_head" ]]; then
    printf 'Run the installer on the head configured in server.json.\n' >&2
    exit 1
fi
bash -n "$source/ssh-command.sh"
install -d -m 0700 "$target"
for file in sparkctl.py ssh-command.sh; do
    temporary=$(mktemp "$target/.$file.XXXXXX")
    install -m 0700 "$source/$file" "$temporary"
    mv -f "$temporary" "$target/$file"
done
printf 'Installed controller and SSH command gate in %s\n' "$target"
