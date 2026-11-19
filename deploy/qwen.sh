#!/usr/bin/env bash
# Prepare the pinned NVFP4/vLLM recipe; never start or stop either rank.

prepare_qwen() (
    set -Eeuo pipefail
    local upstream=https://github.com/MiaAI-Lab/Qwen3.8-Flash-Next-Dual-DGX-Sparks.git
    local commit=cd839d0b62f6c737178a0c2037733420e0524ebf
    local model=nvidia/Qwen3.8-Flash-Next-NVFP4
    local revision=fc694b54fb0174e0913e6adf86691ef85a4ead47
    local registry=docker.io/vllm/vllm-openai@sha256:4864d46625cbc3307623e29ac742030655e27249feba7b97ec925ce4cc4dfb56
    local image=vllm/vllm-openai:v0.30.0
    local image_id=sha256:91d9b077589e7ebb9399ea8db07787bd40cc04ba96a767f021ffdf3e321ea9a0
    local checkout configured_cache head_cache worker_cache head_hub worker_hub
    local worker_target head_address worker_address head_interface worker_interface head_hcas worker_hcas gid
    local suffix=/models--nvidia--Qwen3.8-Flash-Next-NVFP4

    [[ "$(cfg models.qwen.revision)" == "$revision" ]] ||
        die "models.qwen.revision must match the verified NVIDIA revision: $revision"
    [[ "$(cfg models.qwen.digest)" == "$image_id" ]] ||
        die "models.qwen.digest must match the verified ARM64 vLLM image ID: $image_id"
    checkout=$(head_path "$(cfg models.qwen.cwd)")
    configured_cache=$(cfg models.qwen.cache)
    head_cache=$(head_path "$configured_cache")
    worker_cache=$(worker_path "$configured_cache")
    [[ "$head_cache" == /*"$suffix" && "$worker_cache" == /*"$suffix" ]] ||
        die "models.qwen.cache must name the NVIDIA repository directory in a Hugging Face hub"
    head_hub=${head_cache%"$suffix"}
    worker_hub=${worker_cache%"$suffix"}
    [[ "$head_hub" == /*/hub && "$worker_hub" == /*/hub ]] ||
        die "Qwen cache must use the .../hub/models--nvidia--Qwen3.8-Flash-Next-NVFP4 layout"

    worker_target=$(cfg worker.ssh_target)
    head_address=$(cfg head.roce_address)
    worker_address=$(cfg worker.roce_address)
    head_interface=$(cfg head.roce_interface)
    worker_interface=$(cfg worker.roce_interface)
    head_hcas=$(cfg head.roce_devices | paste -sd, -)
    worker_hcas=$(cfg worker.roce_devices | paste -sd, -)
    gid=$(cfg fabric.gid_index)
    [[ -n "$head_hcas" && -n "$worker_hcas" && -n "$worker_target" ]] ||
        die "Qwen requires a worker SSH target and the connected RoCE devices on both Sparks"

    say "Preparing pinned Qwen source and the Chinese/English/code MTP vocabulary."
    ensure_checkout "$upstream" "$commit" "$checkout"
    # This is an adapter for the pinned launcher, not a separate serving stack.
    # Its generated .env is shell-quoted; SSH aliases stay separate from fabric IPs.
    python3 - "$checkout" "$worker_target" "$head_address" "$worker_address" \
        "$head_interface" "$worker_interface" "=$head_hcas" "=$worker_hcas" "$gid" \
        "${head_hub%/hub}" "${worker_hub%/hub}" <<'PY_QWEN_ADAPTER'
import hashlib
import os
from pathlib import Path
import re
import shlex
import stat
import sys
import tempfile

(checkout, target, head_ip, worker_ip, head_iface, worker_iface,
 head_hcas, worker_hcas, gid, head_home, worker_home) = sys.argv[1:]
root = Path(checkout)

# The upstream heredoc writes host paths into its generated docker command.
# Refuse path characters that that pinned launcher cannot safely represent.
for value in (checkout, head_home, worker_home):
    if not re.fullmatch(r"[A-Za-z0-9/._-]+", value):
        raise SystemExit("Qwen upstream launch paths allow only ASCII letters, digits, /, ., _, and -")

generated_marker = "# Prepared by Spark Switcher deploy/qwen.sh; pinned offline runtime."
env_path = root / ".env"
if env_path.is_symlink() or (env_path.exists() and generated_marker not in
                            env_path.read_text(encoding="utf-8").splitlines()):
    raise SystemExit("Preserving manual Qwen .env: back it up and remove it before preparation")

vocab = root / "files/draft_vocab_zh_en_code_65k.txt"
vocab_bytes = vocab.read_bytes()
if (hashlib.sha256(vocab_bytes).hexdigest() !=
        "efdf7c2efbaeb23b9ad7271397b2559d016b90656285bbdfdb65d3c9a6ec016b"
        or len(vocab_bytes.splitlines()) != 65536):
    raise SystemExit("The pinned Chinese/English/code draft vocabulary differs from the verified file")

def replace_once(text, old_options, new, label):
    if text.count(new) == 1:
        return text
    matches = [old for old in old_options if text.count(old) == 1]
    if len(matches) != 1:
        raise SystemExit("Unexpected pinned Qwen launcher while applying " + label)
    return text.replace(matches[0], new, 1)

def write_atomic(path, contents, mode):
    with tempfile.NamedTemporaryFile(prefix=".spark-qwen-", dir=path.parent, delete=False) as out:
        temporary = Path(out.name)
        out.write(contents.encode("utf-8"))
    try:
        temporary.chmod(mode)
        os.replace(temporary, path)
    finally:
        temporary.unlink(missing_ok=True)

launcher = root / "start.sh"
original = launcher.read_text(encoding="utf-8")
changed = original
ssh_old = '''ssh_worker() {
    local user_prefix=""
    if [[ -n "$WORKER_USER" ]]; then
        user_prefix="${WORKER_USER}@"
    fi
    ssh -o StrictHostKeyChecking=no "${user_prefix}${WORKER_IP}" "$@"
}'''
ssh_previous = ssh_old.replace(
    "ssh -o StrictHostKeyChecking=no",
    "ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10")
ssh_new = '''ssh_worker() {
    ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 \\
        -o ServerAliveInterval=30 -o ServerAliveCountMax=3 \\
        "${SPARK_QWEN_SSH_TARGET:?missing configured worker SSH target}" "$@"
}'''
changed = replace_once(changed, [ssh_old, ssh_previous], ssh_new, "worker SSH target")
image_gate = '''
# Spark Switcher: verify staged image identity before any overlay extraction.
if $DO_LAUNCH; then
    _spark_head_image=$(docker image inspect --format '{{.Id}}' "$IMAGE" 2>/dev/null || true)
    _spark_worker_image=$(ssh_worker "docker image inspect --format '{{.Id}}' '$IMAGE' 2>/dev/null" || true)
    [[ "$_spark_head_image" == "${SPARK_QWEN_IMAGE_ID:?missing prepared image ID}" ]] ||
        err "Prepared Qwen image is missing or changed on head; rerun Spark Switcher preparation."
    [[ "$_spark_worker_image" == "$SPARK_QWEN_IMAGE_ID" ]] ||
        err "Prepared Qwen image is missing or changed on worker; rerun Spark Switcher preparation."
fi
'''
if "# Spark Switcher: verify staged image identity" in changed and image_gate not in changed:
    raise SystemExit("Unexpected existing Qwen immutable-image gate")
changed = replace_once(changed, [ssh_new], ssh_new + image_gate, "early immutable-image gate")
old_destination = "${WORKER_USER:+${WORKER_USER}@}${WORKER_IP}:"
new_destination = "${SPARK_QWEN_SSH_TARGET}:"
if changed.count(old_destination) == 5 and new_destination not in changed:
    changed = changed.replace(old_destination, new_destination)
elif old_destination in changed or changed.count(new_destination) != 5:
    raise SystemExit("Unexpected pinned Qwen scp/rsync destinations")
# scp must obey the same known-hosts and noninteractive policy as SSH.
scp_old = "scp -q "
scp_new = "scp -q -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 "
if changed.count(scp_new) == 0:
    if changed.count(scp_old) != 4:
        raise SystemExit("Unexpected pinned Qwen scp commands")
    changed = changed.replace(scp_old, scp_new)
elif changed.count(scp_new) != 4:
    raise SystemExit("Unexpected patched Qwen scp commands")
changed = replace_once(changed, ["    --host 0.0.0.0 \\\n"],
                       "    --host 127.0.0.1 \\\n", "loopback API binding")
health_old = 'HTTP_CODE=$(curl -s -o /dev/null -w \'%{http_code}\' "http://localhost:$PORT/health" 2>/dev/null || echo "000")'
health_new = 'HTTP_CODE=$(curl --noproxy \'*\' --max-time 4 -s -o /dev/null -w \'%{http_code}\' "http://127.0.0.1:$PORT/health" 2>/dev/null || echo "000")'
changed = replace_once(changed, [health_old], health_new, "proxy-independent health probe")
image_old = '''    if ! docker image inspect "$IMAGE" &>/dev/null; then
        info "Pulling $IMAGE ..."
        docker pull "$IMAGE"
    fi
    ok "Image ready on head."

    LOCAL_ID=$(docker image inspect --format '{{.Id}}' "$IMAGE" 2>/dev/null || echo "")
    REMOTE_ID=$(ssh_worker "docker image inspect --format '{{.Id}}' '$IMAGE' 2>/dev/null" || echo "")

    if [[ "$LOCAL_ID" != "$REMOTE_ID" ]]; then
        info "Pulling image on worker..."
        ssh_worker "docker pull '$IMAGE'"
        ok "Image ready on worker."
    else
        ok "Image already on worker."
    fi'''
image_new = '    ok "Verified prepared image on both Sparks; no registry access at launch."'
changed = replace_once(changed, [image_old], image_new, "offline immutable image check")
# docker create/run otherwise implicitly pull a missing tag, even with --launch.
for old, new, count in (
    ('docker create "$IMAGE" /bin/true', 'docker create --pull=never "$IMAGE" /bin/true', 3),
    ("docker run \\\n", "docker run --pull=never \\\n", 2),
    ('ssh_worker "docker run --name vllm-fn-evict-',
     'ssh_worker "docker run --pull=never --name vllm-fn-evict-', 1),
    ('DOCKER_ARGS+=(-d --name vllm-fn)', 'DOCKER_ARGS+=(--pull=never -d --name vllm-fn)', 1),
):
    if changed.count(old) == count and new not in changed:
        changed = changed.replace(old, new)
    elif old in changed or changed.count(new) != count:
        raise SystemExit("Unexpected pinned Qwen implicit-pull command")
ep_old = '        VLLM_ARGS+=("--enable-expert-parallel")\n'
ep_new = ep_old + '''        if [[ "$V030" == "true" && "${SPARK_QWEN_EP_FILTER:-true}" == "true" ]]; then
            VLLM_ARGS+=("--enable-ep-weight-filter")
        fi
'''
if ep_new not in changed and "--enable-ep-weight-filter" in changed:
    raise SystemExit("Unexpected existing Qwen EP weight-filter patch")
changed = replace_once(changed, [ep_old], ep_new, "vLLM 0.30 EP weight filtering")

stopper = root / "stop.sh"
stop_original = stopper.read_text(encoding="utf-8")
stop_old = '''ssh_cmd() {
    local user_prefix=""
    [[ -n "$WORKER_USER" ]] && user_prefix="${WORKER_USER}@"
    ssh -o StrictHostKeyChecking=no "${user_prefix}$WORKER_IP" "$@"
}'''
stop_new = ssh_new.replace("ssh_worker()", "ssh_cmd()")
stop_changed = replace_once(stop_original, [stop_old], stop_new, "stop launcher SSH target")

values = {
    "HEAD_IP": head_ip, "WORKER_IP": worker_ip, "WORKER_USER": "",
    "SPARK_QWEN_SSH_TARGET": target,
    "IFACE": head_iface, "WORKER_IFACE": worker_iface,
    "IB_HCA": head_hcas, "WORKER_IB_HCA": worker_hcas, "IB_GID_INDEX": gid,
    "MODEL_ID": "nvidia/Qwen3.8-Flash-Next-NVFP4",
    "SERVED_MODEL_NAME": "qwen3.8-flash-next", "IMAGE": "vllm/vllm-openai:v0.30.0",
    "SPARK_QWEN_IMAGE_ID": "sha256:91d9b077589e7ebb9399ea8db07787bd40cc04ba96a767f021ffdf3e321ea9a0",
    "OVERRIDE_IMAGE": "vllm/vllm-openai:v0.30.0",
    "OVERRIDE_MODEL_ID": "nvidia/Qwen3.8-Flash-Next-NVFP4",
    "OVERRIDE_SERVED_MODEL_NAME": "qwen3.8-flash-next",
    "OVERRIDE_GPU_MEMORY_UTILIZATION": "0.80", "OVERRIDE_KV_CACHE_DTYPE": "auto",
    "OVERRIDE_MAX_MODEL_LEN": "262144", "OVERRIDE_YARN_ENABLE": "false",
    "V030": "true", "SKIP_PLE_PATCH": "true",
    "HF_HOME": head_home, "WORKER_HF_HOME": worker_home,
    "PORT": "18300", "MASTER_PORT": "50000", "MAX_MODEL_LEN": "262144",
    "GPU_MEMORY_UTILIZATION": "0.80", "TENSOR_PARALLEL_SIZE": "2",
    "MAX_NUM_SEQS": "8", "KV_CACHE_DTYPE": "auto", "PLE_OFFLOAD": "false",
    "ENABLE_EXPERT_PARALLEL": "true", "SPARK_QWEN_EP_FILTER": "true",
    "MTP_NUM_SPECULATIVE_TOKENS": "3",
    "MTP_DRAFT_VOCAB": "files/draft_vocab_zh_en_code_65k.txt",
    "NFS_SHARE": "false", "YARN_ENABLE": "false", "FP8_DENSE": "false", "ABLIT": "0",
}
environment = (root / ".env.sample").read_text(encoding="utf-8").rstrip() + "\n\n"
environment += generated_marker + "\n"
environment += "".join(name + "=" + shlex.quote(value) + "\n" for name, value in values.items())
environment += "export HF_HUB_OFFLINE=1\nexport TRANSFORMERS_OFFLINE=1\nexport HF_DATASETS_OFFLINE=1\n"
if changed != original:
    write_atomic(launcher, changed, stat.S_IMODE(launcher.stat().st_mode))
if stop_changed != stop_original:
    write_atomic(stopper, stop_changed, stat.S_IMODE(stopper.stat().st_mode))
write_atomic(root / ".env", environment, 0o600)
PY_QWEN_ADAPTER
    bash -n "$checkout/start.sh"
    bash -n "$checkout/start-v030.sh"
    bash -n "$checkout/stop.sh"
    bash -n "$checkout/.env"

    say "Preparing the immutable ARM64 vLLM image on both Sparks."
    ensure_image "$registry" "$image" "$image_id"
    say "Preparing and copying the pinned NVIDIA checkpoint through the HF cache."
    ensure_hf_snapshot "$model" "$revision" "$head_hub" "$worker_hub" \
        model-fp8-mtp-ple.safetensors tokenizer.json chat_template.jinja
    say "Qwen prepared. The controller can launch both ranks with start-v030.sh --launch."
)
