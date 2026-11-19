#!/usr/bin/env python3
"""Switch the three locally provisioned two-rank Spark model services."""
from __future__ import annotations

import argparse
from concurrent.futures import ThreadPoolExecutor
import datetime
import fcntl
import ipaddress
import json
import os
from pathlib import Path
import re
import shlex
import socket
import subprocess
import sys
import time
import urllib.error
import urllib.request
import uuid

HOME = Path.home()
HERE = Path(__file__).resolve().parent
DATA = HOME / ".local/state/spark-switcher"
SSH = ("ssh", "-o", "BatchMode=yes", "-o", "StrictHostKeyChecking=yes",
       "-o", "ConnectTimeout=5", "-o", "ServerAliveInterval=5",
       "-o", "ServerAliveCountMax=2")
CONFIG_PATH = HOME / ".config/spark-switcher/server.json"
NODES = ()
FABRIC = {}
OPENER = urllib.request.build_opener(urllib.request.ProxyHandler({}))
DS_WEIGHTS = "~/models/DeepSeek-V4.1-Flash-1017-EXL3-2.9bpw"
DS_ENGRAM = "~/models/DeepSeek-V4.1-Flash-1017-engram"
DS_CACHE = "~/.cache/ds41-1017-tf"
GLM_CACHE = "~/.cache/huggingface/hub/models--Mia-AiLab--GLM-5.3-Flash-EXL3-4bpw-TensorFold/snapshots/078455ffe6472f9a52fbc1139f58b9db2881b25c"
GLM_DRAFT = "~/.cache/huggingface/hub/models--incoai--GLM-5.3-Flash-DFlash2/snapshots/bf582e4eacc1810f76656d1811693ff6c6737d2a"
QWEN_CACHE = "~/.cache/huggingface/hub/models--nvidia--Qwen3.8-Flash-Next-NVFP4"
QWEN_PIN = "fc694b54fb0174e0913e6adf86691ef85a4ead47"
DEFAULT_MODELS = {
    "glm": dict(port=8888, model_id="GLM-5.3-Flash-EXL3", context=1048576, max_output=131072,
                container="glm53-flash-tf", image="tensorfold-glm53:v0.6.0",
                digest="sha256:b925352f3515caddc1dde8abf33a621afad8133d2964a091184ad4842bfff7b6",
                cwd="~/GLM-5.3-Flash-EXL3-2x-DGX-Sparks-TensorFold", wait=1200,
                snapshot=GLM_CACHE, draft=GLM_DRAFT, venv=None),
    "deepseek": dict(port=18888, model_id="deepseek-v4.1-flash", context=1048576, max_output=393216,
                     container="spark-switch-deepseek", image="tensorfold-dsv41:8e0966e",
                     digest="sha256:193ec8579b0c3dd5bf6b122f6fd4f0cc8cfd225273d86f537892203ddff91f6e",
                     cwd=str(HERE), wait=1200, weights=DS_WEIGHTS, engram=DS_ENGRAM, cache=DS_CACHE),
    "qwen": dict(port=18300, model_id="qwen3.8-flash-next", context=262144,
                 container="vllm-fn", image="vllm/vllm-openai:v0.30.0",
                 digest="sha256:91d9b077589e7ebb9399ea8db07787bd40cc04ba96a767f021ffdf3e321ea9a0",
                 cwd="~/Qwen3.8-Flash-Next-Dual-DGX-Sparks", wait=1800, cache=QWEN_CACHE, revision=QWEN_PIN),
}
MODELS = DEFAULT_MODELS
LEGACY = ("ds41-1017-tf", "ds41-1017-tf-1m4", "ds41-tf")
TOOLS_BLOCKERS = (*LEGACY, "qwen-serve", "qwen-tp2", "qwen-tp2-before-autotune-fix")
_SAFE_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]*")
_SAFE_SSH_TARGET = re.compile(r"(?:[A-Za-z_][A-Za-z0-9_.-]*@)?[A-Za-z0-9][A-Za-z0-9_.-]*")
_MODEL_OPTIONS = {
    "glm": {"cwd", "snapshot", "draft", "venv", "digest"},
    "deepseek": {"weights", "engram", "cache", "image", "digest"},
    "qwen": {"cwd", "cache", "revision", "digest"},
}


def local_path(value):
    return Path(value).expanduser()


def load_config(path=CONFIG_PATH):
    def options(object_, allowed, label):
        if not isinstance(object_, dict) or set(object_) - allowed:
            raise ValueError(f"Invalid keys in {label}. See server.example.json.")
        return object_

    try:
        config = json.loads(path.read_text(encoding="utf-8"))
    except FileNotFoundError as exc:
        raise ValueError(f"Missing {path}. Copy and edit server.example.json.") from exc
    options(config, {"head", "worker", "fabric", "models"}, "server config")
    nodes = []
    for label in ("head", "worker"):
        fields = {"hostname", "roce_address", "roce_interface", "roce_devices"}
        if label == "worker":
            fields.add("ssh_target")
        node = options(config.get(label), fields, label).copy()
        if node.keys() != fields:
            raise ValueError(f"Missing required fields in {label}.")
        for key in ("hostname", "roce_interface"):
            if not isinstance(node[key], str) or not _SAFE_NAME.fullmatch(node[key]):
                raise ValueError(f"Invalid {label}.{key}.")
        devices = node["roce_devices"]
        if not isinstance(devices, list) or not devices or any(
            not isinstance(device, str) or not _SAFE_NAME.fullmatch(device) for device in devices
        ):
            raise ValueError(f"Invalid {label}.roce_devices.")
        if not isinstance(node["roce_address"], str):
            raise ValueError(f"Invalid {label}.roce_address.")
        node["roce_address"] = str(ipaddress.IPv4Address(node["roce_address"]))
        if label == "worker" and (
            not isinstance(node["ssh_target"], str) or not _SAFE_SSH_TARGET.fullmatch(node["ssh_target"])
        ):
            raise ValueError("Invalid worker.ssh_target. Use a hostname, SSH alias, or user@host.")
        nodes.append(node)
    if any(nodes[0][key] == nodes[1][key] for key in ("hostname", "roce_address")):
        raise ValueError("Head and worker must be different Spark hosts.")

    defaults = dict(mtu=9000, gid_index=3, require_kho_off=True)
    fabric = defaults | options(config.get("fabric", {}), set(defaults), "fabric")
    if (type(fabric["mtu"]) is not int or fabric["mtu"] < 576
            or type(fabric["gid_index"]) is not int or fabric["gid_index"] < 0
            or type(fabric["require_kho_off"]) is not bool):
        raise ValueError("Invalid fabric MTU, GID or boot setting.")

    overrides = options(config.get("models", {}), set(DEFAULT_MODELS), "models")
    models = {}
    for name, model in DEFAULT_MODELS.items():
        override = options(overrides.get(name, {}), _MODEL_OPTIONS[name], f"models.{name}")
        for key, value in override.items():
            if key == "venv" and value is None:
                continue
            if not isinstance(value, str) or not value or any(c in value for c in "\r\n\x00"):
                raise ValueError(f"Invalid models.{name}.{key}.")
            if key == "digest" and not re.fullmatch(r"sha256:[a-f0-9]{64}", value):
                raise ValueError(f"Invalid models.{name}.digest.")
            if key == "revision" and not re.fullmatch(r"[a-f0-9]{40}", value):
                raise ValueError(f"Invalid models.{name}.revision.")
            if key in {"cwd", "snapshot", "draft", "venv", "weights", "engram", "cache"} and (
                not value.startswith(("/", "~/")) or ":" in value
            ):
                raise ValueError(f"Use an absolute or ~/ path for models.{name}.{key}.")
            if key == "image" and value.startswith("-"):
                raise ValueError(f"Invalid models.{name}.image.")
        models[name] = model | override
    return tuple(nodes), fabric, models


def now():
    return datetime.datetime.now(datetime.timezone.utc).isoformat(timespec="seconds")


def run(argv, *, remote=False, timeout=20, check=True, **kwargs):
    command = (
        (*SSH, "--", NODES[1]["ssh_target"], shlex.join(str(x) for x in argv))
        if remote else list(argv)
    )
    return subprocess.run(command, timeout=timeout, check=check, text=True,
                          encoding="utf-8", errors="replace", **kwargs)


def checknode(remote):
    return run(("docker", "ps", "--format", "{{.Names}}"), remote=remote,
               stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=12).stdout.splitlines()


def request(name, path, data=None, timeout=3):
    m = MODELS[name]
    base = f"http://127.0.0.1:{m['port']}"
    headers = {"Content-Type": "application/json"}
    body = json.dumps(data).encode() if data is not None else None
    with OPENER.open(urllib.request.Request(base + path, data=body, headers=headers), timeout=timeout) as response:
        return response.read()


def ready(name):
    try:
        response = request(name, "/health")
        if response.strip().startswith(b"{"):
            health = json.loads(response)
            if health.get("ok") is False or health.get("status") in ("loading", "error"):
                return False
        models = json.loads(request(name, "/v1/models"))
        return any(x.get("id") == MODELS[name]["model_id"] for x in models.get("data", ()))
    except Exception:
        return False


def in_flight(name):
    if name == "qwen":
        metrics = request(name, "/metrics").decode()
        values = re.findall(r"^vllm:num_requests_(?:running|waiting)(?:\{[^}]*\})?\s+([\d.eE+-]+)\s*$", metrics,
                            re.MULTILINE)
        if not values:
            raise RuntimeError("Qwen request counters unavailable")
        return sum(float(x) for x in values)
    health = json.loads(request(name, "/health"))
    if "requests_running" not in health:
        raise RuntimeError(f"{name} request counters unavailable")
    return int(health["requests_running"])


def inspection():
    with ThreadPoolExecutor(max_workers=2) as pool:
        reports = tuple(pool.submit(checknode, x) for x in (False, True))
        result = []
        errors = []
        for node, future in zip(("head", "worker"), reports):
            try:
                result.append(set(future.result()))
            except Exception:
                errors.append(node)
                result.append(None)
    return result, errors


def job_state():
    path = DATA / "job.json"
    if not path.is_file():
        return None
    result = json.loads(path.read_text())
    if result.get("state") == "running":
        with (DATA / "switch.lock").open("a") as descriptor:
            try:
                fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                pass
            else:
                result = dict(result, state="interrupted", message="Previous switch worker stopped. Inspect both nodes before retrying.")
    return result


def update(job, **kwargs):
    job.update(updated_at=now(), **kwargs)
    dst = DATA / "job.json"
    tmp = DATA / f".job-{job['id']}.tmp"
    tmp.write_text(json.dumps(job) + "\n", encoding="utf-8")
    tmp.replace(dst)
    print(f"{job['updated_at']} [{job['phase']}] {job['message']}", flush=True)


def status():
    inventory, errors = inspection()
    response = dict(ok=not errors, active=None, models={}, job=job_state(),
                    unreachable=errors, blockers=[])
    active_count = 0
    for name, m in MODELS.items():
        ranks = [(m["container"] in x) if x is not None else None for x in inventory]
        okay = all(ranks) and ready(name)
        state = ("unknown" if None in ranks else "ready" if okay else "starting" if all(ranks)
                 else "partial" if any(ranks) else "stopped")
        response["models"][name] = dict(state=state, ready=bool(okay), port=m["port"],
                                        model_id=m["model_id"], context=m["context"],
                                        head=ranks[0], worker=ranks[1])
        if any(ranks):
            active_count += 1
        if okay:
            response["active"] = name
    blocked = set().union(*(x or set() for x in inventory)) & set(TOOLS_BLOCKERS)
    response["blockers"] = sorted(blocked)
    if active_count > 1 or errors or blocked:
        response["active"] = None
    return response


def inventory_checked():
    nodes, errors = inspection()
    if errors:
        raise RuntimeError("Cannot verify both Sparks: " + ", ".join(errors))
    return nodes


def ensure_offline_assets(name):
    m = MODELS[name]
    if name == "glm":
        snapshots = (m["snapshot"], m["draft"])
        refs = ()
        scripts = ("./start.sh", "./stop.sh")
    elif name == "qwen":
        snapshots = (m["cache"] + "/snapshots/" + m["revision"],)
        refs = ((m["cache"] + "/refs/main", m["revision"]),)
        scripts = ("./start-v030.sh", "./stop.sh")
    else:
        snapshots = (m["weights"], m["engram"])
        refs = ()
        scripts = ()
    for script in scripts:
        if not (local_path(m["cwd"]) / script).is_file():
            raise RuntimeError(f"Missing offline launcher: {m['cwd']}/{script}")
    code = r"""
import json, pathlib, subprocess, sys
image, digest, args = sys.argv[1:4]
snapshots, refs = json.loads(args)
present = subprocess.check_output(["docker","image","inspect","-f","{{.Id}}",image],text=True).strip()
if present != digest:
    raise RuntimeError("Pinned image not present: " + image)
for ref, rev in refs:
    if pathlib.Path(ref).expanduser().read_text().strip() != rev:
        raise RuntimeError("Unexpected model revision: " + ref)
for index, val in enumerate(snapshots):
    p = pathlib.Path(val).expanduser()
    if not (p/"config.json").is_file():
        raise RuntimeError("Local config missing: " + val)
    idx=p/"model.safetensors.index.json"
    parts = set(json.loads(idx.read_text())["weight_map"].values()) if idx.is_file() else set()
    if sys.argv[4] == "deepseek" and index == 1:
        # Its copied global index lists more than the two deliberately retained engram shards.
        parts = {"model-00047-of-00048.safetensors","model-00048-of-00048.safetensors"}
    if not parts and (p/"model.safetensors").is_file():
        parts={"model.safetensors"}
    if not parts:
        parts={x.name for x in p.glob("*.safetensors")}
    if not parts or any(not (p/x).is_file() or (p/x).stat().st_size<=0 for x in parts):
        raise RuntimeError("Local weights incomplete: " + val)
"""
    payload = json.dumps([snapshots, refs])
    args = ("python3", "-c", code, m["image"], m["digest"], payload, name)
    for peer in (False, True):
        node = "worker" if peer else "head"
        try:
            run(args, remote=peer, timeout=45, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
        except (subprocess.SubprocessError, OSError) as exc:
            note = str(getattr(exc, "stderr", "") or "").strip().splitlines()
            raise RuntimeError(f"{node}: offline files or image not ready" + (f": {note[-1]}" if note else "")) from exc


def topology():
    head = run(("hostname", "-s"), stdout=subprocess.PIPE, timeout=5).stdout.strip()
    worker = run(("hostname", "-s"), remote=True, stdout=subprocess.PIPE, timeout=10).stdout.strip()
    if (head, worker) != tuple(node["hostname"] for node in NODES):
        raise RuntimeError("Unexpected Spark pair, refusing to control services")
    code = r"""
from pathlib import Path
import subprocess, sys
src,dst,interface,mtu,gid,require_kho_off,*devices=sys.argv[1:]
route=subprocess.check_output(["ip","-4","route","get",dst],text=True)
fields = route.split()
if "src" not in fields or fields[fields.index("src") + 1] != src or "dev" not in fields or fields[fields.index("dev") + 1] != interface:
    raise RuntimeError("Unexpected RoCE route")
if (Path("/sys/class/net") / interface / "mtu").read_text().strip() != mtu:
    raise RuntimeError("Unexpected RoCE MTU")
for nic in devices:
    base=Path("/sys/class/infiniband")/nic/"ports/1"
    if "ACTIVE" not in (base/"state").read_text() or "RoCE v2" not in (base/"gid_attrs/types"/gid).read_text():
        raise RuntimeError("RoCE link or GID offline: " + nic)
if require_kho_off == "True" and "kho=off" not in Path("/proc/cmdline").read_text().split():
    raise RuntimeError("Expected pinned-memory boot parameter kho=off")
"""
    for rank, node in enumerate(NODES):
        peer = NODES[1 - rank]
        run(("python3", "-c", code, node["roce_address"], peer["roce_address"],
             node["roce_interface"], str(FABRIC["mtu"]), str(FABRIC["gid_index"]),
             str(FABRIC["require_kho_off"]), *node["roce_devices"]), remote=bool(rank), timeout=15)


def launch_ds():
    m = MODELS["deepseek"]
    env = {
        "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1", "TENSORFOLD_NO_UPDATE_CHECK": "1",
        "TF_DS_REPLAY": "1", "TF_DS_REPLAY_FLOOR": "1", "TF_DS_PREFILL_CHUNK": "2048",
        "TF_DS_RANK_CACHE": "/root/.cache/tf-ds-rank", "TF_DS_RANK_CACHE_READERS": "32",
        "TF_DS_WARM_LENGTHS": "1,17,33,131,514,1024,2113", "TF_DS_ENGRAM": "/engram",
    }
    for rank, node in enumerate(NODES):
        devices = ",".join(node["roce_devices"])
        rank_env = env | dict(NCCL_IB_HCA=devices, TF_RDMA_DEVICES=devices,
                              NCCL_IB_GID_INDEX=str(FABRIC["gid_index"]),
                              NCCL_SOCKET_IFNAME=node["roce_interface"])
        env_args = [arg for k, v in rank_env.items() for arg in ("-e", f"{k}={v}")]
        paths = (m["weights"], m["engram"], m["cache"])
        if rank == 0:
            paths = tuple(str(local_path(path)) for path in paths)
        else:
            code = "import json, pathlib, sys; print(json.dumps([str(pathlib.Path(p).expanduser()) for p in sys.argv[1:]]))"
            paths = json.loads(run(("python3", "-c", code, *paths), remote=True,
                                   stdout=subprocess.PIPE).stdout)
        weights, engram, cache = paths
        if m["container"] in checknode(bool(rank)):
            raise RuntimeError("Unexpected existing DeepSeek rank")
        lookup = run(("docker", "container", "inspect", "-f", "{{.State.Status}}", m["container"]),
                     remote=bool(rank), check=False, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL)
        if lookup.returncode == 0:
            if lookup.stdout.strip() not in ("created", "exited", "dead"):
                raise RuntimeError("DeepSeek container not safe to replace")
            run(("docker", "rm", m["container"]), remote=bool(rank), timeout=25)
        run(("docker", "run", "-d", "--pull=never", "--name", m["container"],
             "--gpus", "all", "--network", "host", "--ipc", "host", "--ulimit", "memlock=-1",
             "--ulimit", "stack=67108864", "--cap-add", "IPC_LOCK", "--device", "/dev/infiniband",
             "--restart", "no", "-v", f"{weights}:/model:ro", "-v", f"{engram}:/engram:ro",
             "-v", f"{cache}:/root/.cache", *env_args, m["image"], "tensorfold", "serve", "/model",
             "--tp", "2", "--rank", str(rank), "--master", NODES[0]["roce_address"],
             "--master-port", "29551", "--host", "127.0.0.1", "--port", str(m["port"]),
             "--name", m["model_id"], "--context", str(m["context"]),
             "--max-tokens", str(m["max_output"]), "--vision", "--parallel", "1",
             "--mtp-drafts", "5", "--no-update-check"), remote=bool(rank), timeout=55)
        if rank == 0:
            deadline = time.monotonic() + 90
            while time.monotonic() < deadline:
                if m["container"] not in checknode(False):
                    raise RuntimeError("DeepSeek head rank exited before rank rendezvous")
                sockets = run(("ss", "-H", "-ltn", "( sport = :29551 )"), stdout=subprocess.PIPE)
                if sockets.stdout.strip():
                    break
                time.sleep(2)
            else:
                raise RuntimeError("DeepSeek rank rendezvous did not open")


def occupied(port):
    with socket.socket() as sock:
        sock.settimeout(1)
        return sock.connect_ex(("127.0.0.1", port)) == 0


def launch(name):
    m = MODELS[name]
    if occupied(m["port"]):
        raise RuntimeError(f"Port {m['port']} is owned by a different server")
    if name == "deepseek":
        launch_ds()
    else:
        env = os.environ.copy()
        env.update(HF_HUB_OFFLINE="1", TRANSFORMERS_OFFLINE="1", HF_DATASETS_OFFLINE="1")
        command = ("./start-v030.sh", "--launch")
        if name == "glm":
            env.update(PREPARE="0", PULL="0", PORT=str(m["port"]), HOST="127.0.0.1",
                       MAX_TOKENS=str(m["max_output"]), TENSORFOLD_NO_UPDATE_CHECK="1")
            if m["venv"]:
                env["PATH"] = str(local_path(m["venv"]) / "bin") + ":" + env["PATH"]
            command = ("./start.sh",)
        run(("timeout", "--signal=TERM", "--kill-after=15s", str(m["wait"]), *command),
            cwd=local_path(m["cwd"]), env=env, timeout=m["wait"]+30)
    deadline = time.monotonic() + m["wait"]
    while time.monotonic() < deadline:
        nodes = inventory_checked()
        if any(m["container"] not in node for node in nodes):
            raise RuntimeError(f"One {name} rank exited")
        if ready(name):
            return
        time.sleep(3)
    raise RuntimeError(f"{name} never became ready")


def stop_model(name):
    m = MODELS[name]
    if name == "glm":
        run(("./stop.sh",), cwd=local_path(m["cwd"]), check=False, timeout=100)
    else:
        def stop_rank(remote):
            if m["container"] in checknode(remote):
                run(("docker", "stop", "--time", "30", m["container"]), remote=remote, timeout=50)
        with ThreadPoolExecutor(max_workers=2) as pool:
            list(pool.map(stop_rank, (False, True)))
    nodes = inventory_checked()
    if any(m["container"] in node for node in nodes):
        raise RuntimeError(f"{name} is still running on at least one Spark")


def smoke(name):
    data = dict(model=MODELS[name]["model_id"], messages=[dict(role="user", content="Reply with the digit 7 only.")],
                max_tokens=128, temperature=0, stream=False,
                chat_template_kwargs={"enable_thinking": False})
    raw = json.loads(request(name, "/v1/chat/completions", data, timeout=90))
    content = raw["choices"][0]["message"].get("content")
    if not isinstance(content, str) or "7" not in content:
        raise RuntimeError(f"{name} did not answer its API smoke test")


def perform(job, force):
    target = job["target"]
    previous = None
    attempted = False
    try:
        update(job, phase="validating", message="Checking both Sparks and local artifacts.")
        topology()
        nodes = inventory_checked()
        combined = set.union(*nodes)
        blocked = combined & set(TOOLS_BLOCKERS)
        if blocked:
            raise RuntimeError("Unmanaged model containers are running: " + ", ".join(sorted(blocked)))
        occupants = [name for name, m in MODELS.items() if m["container"] in combined]
        if len(occupants) > 1:
            raise RuntimeError("Multiple model services detected. Manual inspection required.")
        previous = occupants[0] if occupants else None
        update(job, previous=previous)
        if target == previous and target and all(MODELS[target]["container"] in n for n in nodes) and ready(target):
            update(job, state="succeeded", phase="completed", message="Selected model is already serving.")
            return
        if target:
            ensure_offline_assets(target)
            if previous != target and occupied(MODELS[target]["port"]):
                raise RuntimeError(f"Target port {MODELS[target]['port']} is already in use")
        if previous:
            if target and previous != target:
                ensure_offline_assets(previous)
            update(job, phase="draining", message=f"Waiting for {previous} requests to finish.")
            if all(MODELS[previous]["container"] in n for n in nodes) and ready(previous) and not force:
                deadline = time.monotonic() + 120
                idle = 0
                while time.monotonic() < deadline:
                    idle = idle + 1 if in_flight(previous) == 0 else 0
                    if idle >= 2:
                        break
                    time.sleep(2)
                else:
                    raise RuntimeError("Model is still busy; wait for its request to finish and retry.")
            elif not force:
                raise RuntimeError("Current service is incomplete or unhealthy; inspect it before forcing a stop.")
            update(job, phase="stopping", message=f"Stopping {previous} on both Sparks.")
            stop_model(previous)
        if not target:
            update(job, state="succeeded", phase="completed", message="No managed model is running.")
            return
        nodes = inventory_checked()
        if set.union(*nodes) & {m["container"] for m in MODELS.values()}:
            raise RuntimeError("Cannot start another model while a model rank is still running.")
        attempted = True
        update(job, phase="starting", message=f"Starting {target} across both Sparks.")
        launch(target)
        update(job, phase="verifying", message=f"Verifying both {target} ranks and testing the API.")
        smoke(target)
        update(job, state="succeeded", phase="completed", message=f"{target} is ready and answered the API test.")
    except Exception as exc:
        detail = (str(exc).splitlines() or ["Unknown error"])[0][:300]
        if attempted:
            try:
                update(job, phase="rollback", message=f"{target} failed. Stopping any target ranks before recovery.", error=detail)
                stop_model(target)
                if previous and previous != target:
                    nodes = inventory_checked()
                    if set.union(*nodes) & {m["container"] for m in MODELS.values()}:
                        raise RuntimeError("A model rank is still running; rollback not safe")
                    launch(previous)
                    smoke(previous)
                    update(job, state="rolled_back", phase="completed", message=f"Restored {previous}.", error=detail)
                    return
            except Exception as rollback:
                update(job, state="failed", phase="completed", message="Rollback failed; inspect both Spark nodes.",
                       error=detail, rollback_error=(str(rollback).splitlines() or ["Unknown error"])[0][:300])
                return
        update(job, state="failed", phase="completed", message=detail, error=detail)


def enqueue(target, force):
    with (DATA / "switch.lock").open("a") as lockfile:
        fcntl.flock(lockfile, fcntl.LOCK_EX | fcntl.LOCK_NB)
        job = dict(id=uuid.uuid4().hex[:12], target=target, previous=None, state="running",
                   phase="queued", message="Switch requested.", created_at=now(), updated_at=now())
        dst = DATA / "job.json"
        tmp = DATA / f".job-{job['id']}.tmp"
        tmp.write_text(json.dumps(job) + "\n", encoding="utf-8")
        tmp.replace(dst)
        log = DATA / f"{job['id']}.log"
        with log.open("a") as output:
            subprocess.Popen((sys.executable, str(Path(__file__).resolve()), "_worker",
                              job["id"], str(lockfile.fileno()), "1" if force else "0"),
                             stdin=subprocess.DEVNULL, stdout=output, stderr=subprocess.STDOUT,
                             start_new_session=True, pass_fds=(lockfile.fileno(),))
    return dict(ok=True, job=job)


def tail_log(lines):
    job = job_state()
    if not job:
        return dict(ok=True, lines=[])
    path = DATA / f"{job['id']}.log"
    if not path.is_file():
        return dict(ok=True, lines=[])
    with path.open("rb") as stream:
        stream.seek(max(0, path.stat().st_size - 65536))
        tail = stream.read().decode("utf-8", "replace")
    # Redact credential-bearing arguments accidentally printed by a launcher.
    tail = re.sub(r"(?i)(bearer\s+|(?:api[_-]?key|token)[=: ]+)\S+", r"\1[redacted]", tail)
    return dict(ok=True, lines=tail.splitlines()[-min(max(lines,1),100):])


def main():
    global NODES, FABRIC, MODELS
    os.umask(0o077)
    if len(sys.argv) == 5 and sys.argv[1] == "_worker":
        ident, fd, force = sys.argv[2:]
        lockfd = int(fd)
        os.fstat(lockfd)
        os.set_inheritable(lockfd, False)
        job = json.loads((DATA / "job.json").read_text())
        if job["id"] != ident:
            return 2
        try:
            NODES, FABRIC, MODELS = load_config()
            perform(job, force == "1")
        except (OSError, ValueError) as exc:
            detail = (str(exc).splitlines() or ["Invalid configuration"])[0][:300]
            update(job, state="failed", phase="completed", message=detail, error=detail)
        os.close(lockfd)
        return 0
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest="command", required=True)
    commands.add_parser("check-config")
    commands.add_parser("check-fabric")
    commands.add_parser("status")
    check = commands.add_parser("preflight")
    check.add_argument("target", choices=MODELS)
    switch = commands.add_parser("switch")
    switch.add_argument("target", choices=MODELS)
    switch.add_argument("--force", action="store_true")
    stop = commands.add_parser("stop")
    stop.add_argument("--force", action="store_true")
    logs = commands.add_parser("logs")
    logs.add_argument("--lines", type=int, default=45)
    args = parser.parse_args()
    try:
        NODES, FABRIC, MODELS = load_config()
        if args.command not in {"check-config", "check-fabric"}:
            DATA.mkdir(mode=0o700, parents=True, exist_ok=True)
        if args.command == "check-config":
            result = dict(ok=True)
        elif args.command == "check-fabric":
            topology()
            result = dict(ok=True)
        elif args.command == "status":
            result = status()
        elif args.command == "preflight":
            topology()
            ensure_offline_assets(args.target)
            result = dict(ok=True, target=args.target)
        elif args.command == "logs":
            result = tail_log(args.lines)
        else:
            result = enqueue(getattr(args, "target", None), args.force)
    except BlockingIOError:
        result = dict(ok=False, error="A model switch is already running.", job=job_state())
    except Exception as exc:
        result = dict(ok=False, error=(str(exc).splitlines() or ["Unknown error"])[0][:300])
    print(json.dumps(result, ensure_ascii=True))
    return 0 if result.get("ok") else 1


if __name__ == "__main__":
    sys.exit(main())
