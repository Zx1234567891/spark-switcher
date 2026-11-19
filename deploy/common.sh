#!/usr/bin/env bash
# Shared by prepare.sh and the model adapters.

say() {
    printf '==> %s\n' "$*" >&2
}

die() {
    printf 'Error: %s\n' "$*" >&2
    exit 1
}

cfg() {
    python3 "$DEPLOY_DIR/config.py" get "$1"
}

record_deepseek_image() {
    python3 "$DEPLOY_DIR/config.py" record-deepseek-image "$@"
}

head_path() {
    case "$1" in
        "~/"*) printf '%s/%s\n' "$HOME" "${1#\~/}" ;;
        /*) printf '%s\n' "$1" ;;
        *) die "Expected an absolute or ~/ path: $1" ;;
    esac
}

worker_path() {
    case "$1" in
        "~/"*) printf '%s/%s\n' "$WORKER_HOME" "${1#\~/}" ;;
        /*) printf '%s\n' "$1" ;;
        *) die "Expected an absolute or ~/ path: $1" ;;
    esac
}

worker() {
    local command
    command=$(python3 -c 'import shlex, sys; print(shlex.join(sys.argv[1:]))' "$@") || return
    ssh "${SSH_OPTIONS[@]}" -- "$WORKER_TARGET" "$command"
}

sync_tree() {
    local source=$1 destination=$2
    [[ -d "$source" ]] || die "Missing local directory: $source"
    [[ "$destination" == /[!/]* && "$destination" != *'/../'* && "$destination" != */.. &&
       "$destination" != *'/./'* && "$destination" != */. ]] ||
        die "Expected an absolute worker directory beneath its filesystem root: $destination"
    worker mkdir -p -- "$destination" || return
    rsync -a -s --partial -e "$RSYNC_SSH" -- "$source/" "$WORKER_TARGET:$destination/"
}

install_source() {
    local name=$1 revision=$2 destination=$3 current staging
    local bundled="$PROJECT_ROOT/vendor/$name"
    local marker=.spark-switcher-source
    [[ -f "$bundled/LICENSE" && -f "$bundled/start.sh" ]] ||
        die "Bundled $name source is missing. Use the complete Spark Switcher repository."
    if [[ -e "$destination" ]]; then
        if [[ -f "$destination/$marker" ]]; then
            current=$(cat "$destination/$marker") || return
        elif [[ -e "$destination/.git" ]] && command -v git >/dev/null; then
            current=$(git -C "$destination" rev-parse --verify HEAD 2>/dev/null) || return
        else
            die "Use an empty destination or the matching upstream checkout: $destination"
        fi
        [[ "$current" == "$revision" && -f "$destination/start.sh" && -f "$destination/stop.sh" ]] ||
            die "Existing source at $destination differs from the bundled $name revision $revision."
        return
    fi
    say "Installing bundled $name source at $revision"
    mkdir -p -- "$(dirname -- "$destination")" || return
    staging=$(mktemp -d "$destination.spark-switcher.XXXXXX") || return
    cp -a -- "$bundled/." "$staging/" || return
    chmod u+x -- "$staging/start.sh" "$staging/stop.sh" || return
    if [[ -f "$staging/start-v030.sh" ]]; then
        chmod u+x -- "$staging/start-v030.sh" || return
    fi
    printf '%s\n' "$revision" > "$staging/$marker" || return
    mv -T -- "$staging" "$destination"
}

same_image() {
    [[ "$(docker image inspect --format '{{.Architecture}} {{.Id}}' "$1" 2>/dev/null)" == "arm64 $2" ]]
}

sync_image() {
    local tag=$1 expected=$2 existing
    same_image "$tag" "$expected" || die "Unexpected local image architecture or ID for $tag (expected ARM64 $expected)"
    existing=$(worker docker image inspect --format '{{.Architecture}} {{.Id}}' "$tag" 2>/dev/null) || existing=
    if [[ "$existing" != "arm64 $expected" ]]; then
        [[ -z "$existing" ]] || die "Worker already has a different image for $tag: $existing"
        say "Copying image $tag to the worker"
        docker save "$tag" | worker docker load || return
    fi
    [[ "$(worker docker image inspect --format '{{.Architecture}} {{.Id}}' "$tag")" == "arm64 $expected" ]] ||
        die "Worker did not receive the expected image $tag"
}

ensure_image() {
    local reference=$1 tag=$2 expected=$3
    if ! docker image inspect "$tag" >/dev/null 2>&1; then
        if ! same_image "$reference" "$expected"; then
            say "Pulling Linux ARM64 image $reference"
            docker pull --platform linux/arm64 "$reference" || return
        fi
        same_image "$reference" "$expected" || die "Registry image differs from the expected ARM64 ID for $tag"
        docker tag "$reference" "$tag" || return
    fi
    sync_image "$tag" "$expected"
}

ensure_hf_snapshot() {
    local repo=$1 revision=$2 head_hub=$3 worker_hub=$4
    shift 4
    local cache_name="models--${repo//\//--}" source snapshot ref file
    source="$head_hub/$cache_name"
    snapshot="$source/snapshots/$revision"
    if ! python3 "$DEPLOY_DIR/config.py" check-snapshot "$snapshot" "$@" 2>/dev/null; then
        command -v hf >/dev/null || die "Install the Hugging Face CLI or import the complete snapshot for $repo."
        say "Downloading $repo at $revision"
        hf download "$repo" --revision "$revision" --cache-dir "$head_hub" || return
        python3 "$DEPLOY_DIR/config.py" check-snapshot "$snapshot" "$@" || return
    fi
    mkdir -p -- "$source/refs" || return
    ref=$(mktemp "$source/refs/.main.XXXXXX") || return
    printf '%s' "$revision" > "$ref" || return
    mv -f -- "$ref" "$source/refs/main" || return
    sync_tree "$source" "$worker_hub/$cache_name" || return
    for file in config.json "$@"; do
        worker test -s "$worker_hub/$cache_name/snapshots/$revision/$file" || return
    done
}
