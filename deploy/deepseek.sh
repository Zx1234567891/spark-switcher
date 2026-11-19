#!/usr/bin/env bash
# Sourced by the unified deploy command after common.sh. Preparation never starts a model.
# Checksums below are the pinned Hugging Face API's LFS hashes or Git blob IDs.
# Recipe: lucataco/DeepSeek-V4.1-Flash-2x-DGX-Spark @ 7b46f9d9d8b21357f8998ccce8bdfa857a9ef1ce

_deepseek_asset_program() {
    cat <<'PY'
import hashlib
import json
import os
from pathlib import Path
import sys
import tempfile

MANIFESTS = {
    "pack": """
git 136a40c7ed455dc4e385aaf713445259878ad022 3628 config.json
git f05a045d5221b789a7bd7edb2e129343c4d3a080 1409 exl3_k_map.json
sha256 ba5ccb4d39882d08800e856150bce42b23584f3d9943520ae4cff5647d5a3045 1323827293 model-00001-of-00043.safetensors
sha256 11ed8a0cb267169a5f3ea0ceebb24ab09fb5b84b98e4d4c86dc2f06f1f5e0d40 5322748742 model-00002-of-00043.safetensors
sha256 1de02ee6b4d909eb5936e08e7c3825cbf2fa65693c5674deade2e70bcb773462 5223069939 model-00003-of-00043.safetensors
sha256 8e68a9e396d958d6645378b44ef3419a4c0b743da0e92b354d2163a4c8bf85ce 5230054628 model-00004-of-00043.safetensors
sha256 c14a66ba26f57e9577e1a656764b3e5828e09c7630ad7404b80c6e265d03a37d 5223069939 model-00005-of-00043.safetensors
sha256 2866602c20b535eec3bb1a737f62d5d6d2dfecbf362977d3a4f5f8e701580b6d 5223069939 model-00006-of-00043.safetensors
sha256 4d12814cd25cf07fe9c6791f0050a8afbc1038bae02fb201243f9c56de8171cd 5223069939 model-00007-of-00043.safetensors
sha256 cb88f50d0ddd81b98db00a6475c356511c3c21f843b2ccd9845fb4017c3f5d15 5223069939 model-00008-of-00043.safetensors
sha256 dbebd82073a27f79dd1353d3c309255f46e577eb1c2f9d8a10a52bc38f6d8bc2 5223069939 model-00009-of-00043.safetensors
sha256 8cde4e4124614502c2950e9f3a643027eceeeedbdf3c54cf786dbf125d3d536e 5230054628 model-00010-of-00043.safetensors
sha256 c96372d73271d2c59e5a959bb81551aaacb2abe8445f5b9ea9391e2b4a033601 5223069939 model-00011-of-00043.safetensors
sha256 337345b1ca174aebcff619bbc2c2a6e33881a42ad8f638956e69b5de4fe21d41 5223074621 model-00012-of-00043.safetensors
sha256 042b4274c48e55d09bfe51ac099915f8bc3bb0c7be9b0f9d5e75a9f5c2045497 5218650941 model-00013-of-00043.safetensors
sha256 bc27a27e60bebd88ad36f4896aa027911bc5f7fbb30ad9a25f95a59a6374d957 5218650941 model-00014-of-00043.safetensors
sha256 74d3f0d12e32a658d8f6c5f9a104826e473c53299267519b46d594619756ae66 5297522070 model-00015-of-00043.safetensors
sha256 0a1b0b3ecb817f448d9fb34ebf0757d4b00042220515ecb13f1b86908cb092f3 5225635649 model-00016-of-00043.safetensors
sha256 e4b4278a51ce9daf61290d4caba5b953f5a243832ffb5c8d29a0c259807facea 5218650941 model-00017-of-00043.safetensors
sha256 07e9d048f9cefb94b9a30f41e39b9390b6bf54a763c0b7e1dcd5d81144fc0849 5218650941 model-00018-of-00043.safetensors
sha256 2c6116ee6f584af8c4027cee8f5069d0d51a4e9b487dd73027127d29f4caf274 5218650941 model-00019-of-00043.safetensors
sha256 817d948752825a739073b95bc6171a35e4677c095ac617bd6772560ae0e4b5e4 3519956829 model-00020-of-00043.safetensors
sha256 4bdda16b5a00ac5ee0e39bc81271af6155caacb7c03928876b07344e20a4ba5f 3519956829 model-00021-of-00043.safetensors
sha256 00afb7bd831cd50added9b809cc2e9cec57ab44963f152f8bc42cd6d22f0a4e4 3525291432 model-00022-of-00043.safetensors
sha256 28ba9d401e2cd556d0145b31c03ed341f009e2849162e6d9f68438a067d74a59 3519956829 model-00023-of-00043.safetensors
sha256 1240d8744902914287da94cd8e2a5d9f17e7c39167bfab20c737a34d7605e50c 3519956829 model-00024-of-00043.safetensors
sha256 a053c3dc54c4ecfe295cfa4bd7fb44f1054ade1d596e46496f6791c87ffb60df 5218650941 model-00025-of-00043.safetensors
sha256 028c44abbea066c94da7ed0e64f07f8d36ae925a4ff437ef999f5a2b5ec6c9d4 5222266717 model-00026-of-00043.safetensors
sha256 69cbb8f2f00ddcb7a83b04d34ca9151c61f3319ec742d0ac5f06abf295a91eef 5218650941 model-00027-of-00043.safetensors
sha256 451c69700eb30a9e47ec80fe219aa537985c6afa3f7391db5699fba50d93e05b 5218650941 model-00028-of-00043.safetensors
sha256 906a9525cde8176d18066d27ae9d457ff55ee3134438dadea4ee63af8dce45ad 5218650941 model-00029-of-00043.safetensors
sha256 420ad929c1efa3f90ba4a39d28159d9a29175089cd9bd4fe32f25c6fb7e473f6 5222266717 model-00030-of-00043.safetensors
sha256 0312eb9c04dbe5f538efd94a21d1f76266a8cac9ea01250084aa6513657fc5df 5220125501 model-00031-of-00043.safetensors
sha256 4653d193e28120319fe5b3508ffed537d23f57b8d31b20f3f69371fd569e59b2 5223074621 model-00032-of-00043.safetensors
sha256 3a6bfc60065324e606082ae8ad68ff403285b24e7a720b3b2274e516a247252a 5223074621 model-00033-of-00043.safetensors
sha256 b1825ddd7016d3cefea0f13ec78aff33637c68e0eb721cdb12f83104c03b3760 5226690397 model-00034-of-00043.safetensors
sha256 9b513ca99a0e8403d172df623a4c0fe7ecaaa51e09015d9574efa90bd6414a32 5223074621 model-00035-of-00043.safetensors
sha256 206ca962082e2c4de968ba4cc82cc1837dccb0b8960f493e04891b281bbfe497 5223074621 model-00036-of-00043.safetensors
sha256 6ed69fdcd3bd32762ddefae671c7fce7f9b5a212cdbe1aaee64adaa5ef0eef2c 5223074621 model-00037-of-00043.safetensors
sha256 24a61b540656dc210b3bc3215b1713f0b4bee8b724176a4f5968e24b9540035c 5226690397 model-00038-of-00043.safetensors
sha256 29e5b40a97edcb91ed6a382b39bbb4d16ce40de2d1ddce2f75a8fd75e0ad609f 5223074621 model-00039-of-00043.safetensors
sha256 5c850a3950ce68a93a24336ccc417ac660fdbdb84bcc494aa6d57ea5c28246be 5223074621 model-00040-of-00043.safetensors
sha256 5a6f5791d3f5f9635e58db5a693f68c64c6c9e14357e8386a21e5fd232af032d 5719789284 model-00041-of-00043.safetensors
sha256 2f80f4a44e4608c6da139eccf2483122ac88a240046872965d546b4fa26ded06 4854649316 model-00042-of-00043.safetensors
sha256 c5b94d519d323921baacb34b6111e518ce2c36309d06c80fe4e42e3aa9662bc5 3500776125 model-00043-of-00043.safetensors
sha256 778baeaf9fbcd351800536dc090ff1edddb72d102472b08de0edd9a52cb96656 15504210 model.safetensors.index.json
sha256 696cdad521cdebea0642a3c22d01c9152dca4e5ccbf209b5e7f2b808f359bd27 54653012 quantization_config.json
git 6a15814dd25c934028034531da744c689f87ff21 6367257 tokenizer.json
git f3dad388a2bbfd6a8605bd02754acd86d9ca5112 801 tokenizer_config.json
""",
    "engram": """
git 09917a9139b22d5bf8be52132787f435147b1020 3311 config.json
sha256 76a05106ece259be83d1bfea0dcb54f23377864ee60fd321690f35e6698a2af5 101535150936 model-00047-of-00048.safetensors
sha256 9dc51433e195bc78b5ad846b68643cc0351d3b174e5e4309222d3b7402c83afd 101537926640 model-00048-of-00048.safetensors
git 54c85064dd92c8550471302e9ae59bedbbf96ca4 7470294 model.safetensors.index.json
""",
}
root = Path(sys.argv[1])
kind = sys.argv[2]
cache = Path(sys.argv[3])
manifest = MANIFESTS[kind]
expected = {}
for line in manifest.splitlines():
    if line.strip():
        algorithm, digest, size, name = line.split()
        expected[name] = (algorithm, digest, int(size))
if kind == "pack":
    extra = sorted(path.name for path in root.glob("*.safetensors") if path.name not in expected)
    if extra:
        raise ValueError("Unexpected model shards in " + str(root) + ": " + ", ".join(extra))
stamp_key = hashlib.sha256((str(root.resolve()) + manifest).encode()).hexdigest()[:24]
stamp = cache / "spark-switcher-verification" / (kind + "-" + stamp_key + ".json")
try:
    previous = json.loads(stamp.read_text())
except (OSError, ValueError):
    previous = {}
verified = {}
repair = []
for name, (algorithm, digest, size) in expected.items():
    path = root / name
    try:
        stat = path.stat()
    except FileNotFoundError:
        repair.append(name)
        continue
    fingerprint = [stat.st_dev, stat.st_ino, stat.st_size, stat.st_mtime_ns, stat.st_ctime_ns]
    if stat.st_size != size:
        repair.append(name)
        continue
    if os.environ.get("SPARK_VERIFY_ALL") != "1" and previous.get(name) == fingerprint:
        verified[name] = fingerprint
        continue
    checksum = hashlib.sha256() if algorithm == "sha256" else hashlib.sha1()
    if algorithm == "git":
        checksum.update(b"blob " + str(size).encode() + b"\0")
    with path.open("rb") as file:
        for block in iter(lambda: file.read(8 * 1024 * 1024), b""):
            checksum.update(block)
    if checksum.hexdigest() != digest:
        repair.append(name)
        continue
    after = path.stat()
    after_fingerprint = [after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns]
    if after_fingerprint != fingerprint:
        raise ValueError("Asset changed during verification: " + str(path))
    verified[name] = fingerprint
if repair:
    print("\n".join(repair))
else:
    stamp.parent.mkdir(mode=0o700, parents=True, exist_ok=True)
    with tempfile.NamedTemporaryFile(dir=stamp.parent, delete=False) as file:
        file.write(json.dumps(verified).encode())
        temporary = Path(file.name)
    try:
        temporary.replace(stamp)
    finally:
        temporary.unlink(missing_ok=True)
PY
}

_deepseek_template_program() {
    cat <<'PY'
import hashlib
from pathlib import Path
import sys
import tempfile

OFFICIAL = "d959d804d5101b79a49b6ff1bf3c54cd5affa9a5a78c503d925f3090040b31c3"
PATCHED = "13f33e7f7d5f7f7a6fea44cde335750201acae72af9ebc018b2cf2255201cf83"
target = Path(sys.argv[1]) / "chat_template.jinja"
if target.is_file():
    current = hashlib.sha256(target.read_bytes()).hexdigest()
    if current == PATCHED:
        sys.exit(0)
    if current != OFFICIAL:
        raise ValueError("Existing chat template differs from the pinned 1017 patch: " + str(target))
    source = target.read_bytes()
elif len(sys.argv) > 2:
    source = Path(sys.argv[2]).read_bytes()
else:
    sys.exit(3)
if hashlib.sha256(source).hexdigest() != OFFICIAL:
    raise ValueError("Official V4.1 chat template checksum mismatch")
text = source.decode()
guard_string = (
    '    {%- if content is string and IMG in content -%}\n'
    '        {{- raise_exception("Message content contains image special token " ~ IMG ~ ". Images should be '
    'provided as image content blocks.") -}}\n'
    '    {%- endif -%}\n'
)
guard_block = (
    '{%- if IMG in (b.text or "") -%}{{- raise_exception("Text block contains image placeholder " ~ IMG ~ '
    '". Images should be separate content blocks.") -}}{%- endif -%}'
)
if text.count(guard_string) != 1 or text.count(guard_block) != 2:
    raise ValueError("Expected three image placeholder guards in the official template")
patched = text.replace(guard_string, "").replace(guard_block, "").encode()
if hashlib.sha256(patched).hexdigest() != PATCHED:
    raise ValueError("Patched 1017 chat template checksum mismatch")
with tempfile.NamedTemporaryFile(dir=target.parent, delete=False) as file:
    file.write(patched)
    temporary = Path(file.name)
try:
    temporary.chmod(0o644)
    temporary.replace(target)
finally:
    temporary.unlink(missing_ok=True)
PY
}

_deepseek_download_assets() {
    local directory=$1 kind=$2 cache=$3 repository=$4 revision=$5 repair
    local -a files
    mkdir -p "$directory" "$cache"
    repair=$(_deepseek_asset_program | python3 - "$directory" "$kind" "$cache") || return
    if [[ -z "$repair" ]]; then
        say "DeepSeek $kind assets already verified locally."
        return
    fi
    command -v hf >/dev/null || die "Missing hf CLI. Install it or import the pinned DeepSeek files."
    mapfile -t files <<< "$repair"
    say "Downloading ${#files[@]} missing or damaged DeepSeek $kind files."
    hf download "$repository" "${files[@]}" --revision "$revision" --local-dir "$directory" --force-download || return
    repair=$(_deepseek_asset_program | python3 - "$directory" "$kind" "$cache") || return
    [[ -z "$repair" ]] || die "DeepSeek $kind failed checksum validation after download: $repair"
}

prepare_deepseek() {
    local image expected actual weights engram cache worker_weights worker_engram worker_cache repair marker temporary
    local engine="$PROJECT_ROOT/vendor/tensorfold-deepseek"
    local template="$PROJECT_ROOT/vendor/deepseek-template/chat_template.jinja"
    image=$(cfg models.deepseek.image)
    expected=$(cfg models.deepseek.digest)
    weights=$(head_path "$(cfg models.deepseek.weights)")
    engram=$(head_path "$(cfg models.deepseek.engram)")
    cache=$(head_path "$(cfg models.deepseek.cache)")
    worker_weights=$(worker_path "$(cfg models.deepseek.weights)")
    worker_engram=$(worker_path "$(cfg models.deepseek.engram)")
    worker_cache=$(worker_path "$(cfg models.deepseek.cache)")
    mkdir -p "$cache"
    marker="$cache/spark-switcher-deepseek-built-image"

    if docker image inspect "$image" >/dev/null 2>&1; then
        actual=$(docker image inspect --format '{{.Id}}' "$image")
        if ! same_image "$image" "$expected"; then
            [[ -f "$marker" && $(cat "$marker") == "$image"$'\n'"$actual"$'\n'8e0966e2b09250abe2f6d9cc51edc20630e6eb1a ]] ||
                die "Configured DeepSeek image ID does not match the local image."
            same_image "$image" "$actual" || die "Prepared DeepSeek image must be Linux ARM64."
            say "Resuming the previously built DeepSeek image."
        fi
    elif [[ $(worker docker image inspect --format '{{.Id}} {{.Architecture}}' "$image" 2>/dev/null || true) == "$expected arm64" ]]; then
        say "Importing the verified DeepSeek image from the worker."
        worker docker save "$image" | docker load || return
        same_image "$image" "$expected" || die "Imported DeepSeek image failed verification."
        actual=$expected
    else
        [[ -f "$engine/pyproject.toml" && -f "$engine/LICENSE" ]] ||
            die "Bundled DeepSeek TensorFold source is missing. Use the complete Spark Switcher repository."
        say "Building DeepSeek from the bundled TensorFold source."
        docker build --file "$DEPLOY_DIR/deepseek.Dockerfile" --tag "$image" "$engine" || return
        actual=$(docker image inspect --format '{{.Id}}' "$image")
        same_image "$image" "$actual" || die "Built DeepSeek image failed verification."
        [[ $(docker image inspect --format '{{index .Config.Labels "org.opencontainers.image.revision"}}' "$image") == 8e0966e2b09250abe2f6d9cc51edc20630e6eb1a ]] ||
            die "Built DeepSeek image does not identify the pinned TensorFold commit."
        temporary=$(mktemp "$cache/.deepseek-built.XXXXXX")
        printf '%s\n' "$image" "$actual" 8e0966e2b09250abe2f6d9cc51edc20630e6eb1a > "$temporary"
        chmod 0600 "$temporary"
        mv -f -- "$temporary" "$marker"
    fi
    sync_image "$image" "$actual" || return
    if [[ "$actual" != "$expected" ]]; then
        record_deepseek_image "$image" "$actual" || return
    fi

    _deepseek_download_assets "$weights" pack "$cache" \
        LibertAIDAI/DeepSeek-V4.1-Flash-1017-EXL3-2.9bpw afc7aa0aab98ee735c0f54e0a122019af1ac08f1 || return
    _deepseek_download_assets "$engram" engram "$cache" \
        deepseek-ai/DeepSeek-V4.1-Flash-1017 1bae0e1088993b9b82de08f59de5be5a34e42170 || return
    _deepseek_template_program | python3 - "$weights" "$template" || return

    say "Copying verified DeepSeek assets to the worker."
    sync_tree "$weights" "$worker_weights" || return
    sync_tree "$engram" "$worker_engram" || return
    repair=$(_deepseek_asset_program | worker env SPARK_VERIFY_ALL="${SPARK_VERIFY_ALL:-0}" python3 - "$worker_weights" pack "$worker_cache") || return
    [[ -z "$repair" ]] || die "Worker DeepSeek pack checksum mismatch: $repair"
    repair=$(_deepseek_asset_program | worker env SPARK_VERIFY_ALL="${SPARK_VERIFY_ALL:-0}" python3 - "$worker_engram" engram "$worker_cache") || return
    [[ -z "$repair" ]] || die "Worker DeepSeek Engram checksum mismatch: $repair"
    _deepseek_template_program | worker python3 - "$worker_weights" || return
    say "DeepSeek is prepared on both Sparks. Start it through the switcher."
}
