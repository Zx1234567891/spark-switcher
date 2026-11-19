"""Read deployment settings and pin a newly built DeepSeek image."""

import json
import os
from pathlib import Path
import re
import sys
import tempfile

sys.path.insert(0, str(Path(__file__).resolve().parents[1] / "server"))
import sparkctl


def get(path):
    (head, worker), fabric, models = sparkctl.load_config()
    value = dict(head=head, worker=worker, fabric=fabric, models=models)
    for key in path.split("."):
        value = value[key]
    if value is not None:
        entries = value if isinstance(value, list) else [value]
        for entry in entries:
            print(json.dumps(entry) if isinstance(entry, bool) else entry)


def record_deepseek_image(tag, image_id):
    path = sparkctl.CONFIG_PATH
    _, _, models = sparkctl.load_config()
    if tag != models["deepseek"]["image"]:
        raise ValueError("DeepSeek image tag differs from server.json")
    if not re.fullmatch(r"sha256:[0-9a-f]{64}", image_id):
        raise ValueError("Invalid Docker image ID")
    if image_id == models["deepseek"]["digest"]:
        return

    config = json.loads(path.read_text(encoding="utf-8"))
    config.setdefault("models", {}).setdefault("deepseek", {})["digest"] = image_id
    with tempfile.NamedTemporaryFile(mode="w", encoding="utf-8", dir=path.parent,
                                     prefix=".server-", suffix=".json", delete=False) as stream:
        temporary = Path(stream.name)
        try:
            json.dump(config, stream, ensure_ascii=False, indent=2)
            stream.write("\n")
            stream.close()
            sparkctl.load_config(temporary)
            os.replace(temporary, path)
        finally:
            temporary.unlink(missing_ok=True)


def check_snapshot(path, extra_files):
    snapshot = Path(path)
    index = snapshot / "model.safetensors.index.json"
    parts = {"model.safetensors"}
    if index.is_file():
        parts = set(json.loads(index.read_text(encoding="utf-8"))["weight_map"].values())
    if not parts:
        raise ValueError("Empty weight index")
    for file in parts.union(extra_files, {"config.json"}):
        relative = Path(file)
        asset = snapshot / relative
        if relative.is_absolute() or ".." in relative.parts or not asset.is_file() or asset.stat().st_size == 0:
            raise ValueError(f"Invalid snapshot file: {file}")


if __name__ == "__main__":
    try:
        action, *args = sys.argv[1:]
        if action == "get":
            get(*args)
        elif action == "record-deepseek-image":
            record_deepseek_image(*args)
        elif action == "check-snapshot":
            check_snapshot(args[0], args[1:])
        else:
            raise ValueError(f"Unknown action: {action}")
    except (KeyError, OSError, TypeError, ValueError) as exc:
        sys.exit(f"{exc}")
