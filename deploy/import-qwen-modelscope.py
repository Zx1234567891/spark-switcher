#!/usr/bin/env python3
"""Verify a completed ModelScope download and import the pinned NVIDIA HF cache.

The 24 model files must match NVIDIA's manifest. NVIDIA's canonical
.gitattributes is supplied here because mirrors can replace that metadata.
No network requests are made. Completed verified blobs are reused on retries.
"""

import argparse
from contextlib import contextmanager
import hashlib
import io
import json
import os
from pathlib import Path
import shutil
import stat
import sys
import tempfile


MANIFEST_PATH = Path(__file__).with_name("qwen-nvidia-manifest.json")
NVIDIA_GITATTRIBUTES = "".join(
    pattern + " filter=lfs diff=lfs merge=lfs -text\n"
    for pattern in (
        "*.7z *.arrow *.bin *.bz2 *.ckpt *.ftz *.gz *.h5 *.joblib *.lfs.* "
        "*.mlmodel *.model *.msgpack *.npy *.npz *.onnx *.ot *.parquet *.pb "
        "*.pickle *.pkl *.pt *.pth *.rar *.safetensors saved_model/**/* *.tar.* "
        "*.tar *.tflite *.tgz *.wasm *.xz *.zip *.zst *tfevents* "
        "tokenizer.json model.safetensors.index.json"
    ).split()
).encode("ascii")


def digest_name(entry):
    return entry.get("sha256") or entry["blob_id"]


def verify_stream(source, entry, output=None):
    """Check content while optionally writing an independent temporary copy."""
    if isinstance(source, bytes):
        incoming = io.BytesIO(source)
    else:
        incoming = source.open("rb")
    with incoming:
        if not isinstance(source, bytes):
            info = os.fstat(incoming.fileno())
            if not stat.S_ISREG(info.st_mode) or info.st_size != entry["size"]:
                raise ValueError("Size or file type differs: " + str(source))
        digest = hashlib.sha256() if entry.get("sha256") else hashlib.sha1()
        if not entry.get("sha256"):
            digest.update(f"blob {entry['size']}\0".encode("ascii"))
        size = 0
        while chunk := incoming.read(4 * 1024 * 1024):
            size += len(chunk)
            digest.update(chunk)
            if output is not None:
                output.write(chunk)
        if size != entry["size"] or digest.hexdigest() != digest_name(entry):
            raise ValueError("Content differs from NVIDIA's pinned manifest: " + entry["name"])


def ensure_directory(path):
    if path.is_symlink():
        raise ValueError("Cache directory must not be a symlink: " + str(path))
    path.mkdir(parents=True, exist_ok=True)


def sync_directory(path):
    if os.name != "nt":
        descriptor = os.open(path, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)


@contextmanager
def import_lock(path):
    """The OS releases this advisory lock if an import is interrupted."""
    if path.is_symlink():
        raise ValueError("Import lock must not be a symlink: " + str(path))
    with path.open("a+b") as handle:
        if handle.tell() == 0:
            handle.write(b"0")
            handle.flush()
        handle.seek(0)
        if os.name == "nt":
            import msvcrt
            msvcrt.locking(handle.fileno(), msvcrt.LK_NBLCK, 1)
        else:
            import fcntl
            fcntl.flock(handle.fileno(), fcntl.LOCK_EX | fcntl.LOCK_NB)
        try:
            yield
        finally:
            handle.seek(0)
            if os.name == "nt":
                msvcrt.locking(handle.fileno(), msvcrt.LK_UNLCK, 1)
            else:
                fcntl.flock(handle.fileno(), fcntl.LOCK_UN)


def publish_file(temporary, destination):
    """Publish without replacing a pre-existing destination."""
    try:
        os.link(temporary, destination)
    except FileExistsError:
        return False
    except OSError:
        # Both files are on the same filesystem. The per-repository lock
        # serializes imports where a filesystem cannot create hard links.
        if destination.exists() or destination.is_symlink():
            return False
        os.rename(temporary, destination)
    sync_directory(destination.parent)
    return True


def install_blob(source, entry, blobs):
    destination = blobs / digest_name(entry)
    if destination.is_symlink():
        raise ValueError("Content-addressed blob must be a regular file: " + str(destination))
    if destination.exists():
        verify_stream(destination, entry)
        verify_stream(source, entry)
        return
    descriptor, name = tempfile.mkstemp(prefix=".spark-import-", dir=blobs)
    temporary = Path(name)
    try:
        with os.fdopen(descriptor, "wb") as output:
            verify_stream(source, entry, output)
            output.flush()
            os.fsync(output.fileno())
        if not publish_file(temporary, destination):
            verify_stream(destination, entry)
    finally:
        temporary.unlink(missing_ok=True)


def verify_snapshot(snapshot, files, blobs):
    if snapshot.is_symlink() or not snapshot.is_dir():
        raise ValueError("Existing snapshot must be a directory: " + str(snapshot))
    if {entry.name for entry in snapshot.iterdir()} != {entry["name"] for entry in files}:
        raise ValueError("Existing snapshot has a different file list: " + str(snapshot))
    for entry in files:
        path = snapshot / entry["name"]
        blob = blobs / digest_name(entry)
        if path.is_symlink():
            if path.resolve(strict=True) != blob.resolve(strict=True):
                raise ValueError("Snapshot link points outside its expected blob: " + str(path))
        elif not path.samefile(blob):
            verify_stream(path, entry)


def install_snapshot(snapshot, files, blobs):
    if snapshot.exists() or snapshot.is_symlink():
        verify_snapshot(snapshot, files, blobs)
        return
    staging = Path(tempfile.mkdtemp(prefix=".spark-import-", dir=snapshot.parent))
    try:
        for entry in files:
            name = digest_name(entry)
            path = staging / entry["name"]
            blob = blobs / name
            try:
                path.symlink_to("../../blobs/" + name)
            except OSError:
                try:
                    os.link(blob, path)
                except OSError:
                    with blob.open("rb") as incoming, path.open("xb") as output:
                        shutil.copyfileobj(incoming, output, length=4 * 1024 * 1024)
                        output.flush()
                        os.fsync(output.fileno())
        sync_directory(staging)
        if snapshot.exists() or snapshot.is_symlink():
            verify_snapshot(snapshot, files, blobs)
        else:
            staging.rename(snapshot)
            sync_directory(snapshot.parent)
    finally:
        if staging.exists():
            # staging is created by mkdtemp inside this exact snapshots directory.
            if staging.resolve().parent != snapshot.parent.resolve():
                raise ValueError("Unexpected snapshot staging path")
            shutil.rmtree(staging)


def check_reference(path, revision):
    if path.is_symlink():
        raise ValueError("refs/main must not be a symlink: " + str(path))
    if path.exists() and path.read_text(encoding="ascii").strip() != revision:
        raise ValueError("Existing refs/main names another revision: " + str(path))


def import_snapshot(source, hub, manifest):
    source = source.expanduser().resolve(strict=True)
    if not source.is_dir():
        raise ValueError("ModelScope source must be a completed download directory")
    files = manifest["files"]
    names = [entry["name"] for entry in files]
    if len(names) != len(set(names)) or any(Path(name).name != name or name in (".", "..") for name in names):
        raise ValueError("Manifest contains an unsafe or duplicate filename")
    for entry in files:
        if entry["name"] != ".gitattributes" and not (source / entry["name"]).is_file():
            raise ValueError("Missing official file: " + entry["name"])
    hub = hub.expanduser().resolve()
    ensure_directory(hub)
    repository = hub / ("models--" + manifest["repo"].replace("/", "--"))
    ensure_directory(repository)
    with import_lock(repository / ".spark-import.lock"):
        blobs = repository / "blobs"
        snapshots = repository / "snapshots"
        refs = repository / "refs"
        for directory in (blobs, snapshots, refs):
            ensure_directory(directory)
        reference = refs / "main"
        revision = manifest["revision"]
        check_reference(reference, revision)
        for index, entry in enumerate(files, 1):
            print(f"[{index}/{len(files)}] Verify {entry['name']}", flush=True)
            incoming = NVIDIA_GITATTRIBUTES if entry["name"] == ".gitattributes" else source / entry["name"]
            install_blob(incoming, entry, blobs)
        snapshot = snapshots / revision
        install_snapshot(snapshot, files, blobs)
        check_reference(reference, revision)
        descriptor, name = tempfile.mkstemp(prefix=".spark-import-", dir=refs)
        temporary = Path(name)
        try:
            with os.fdopen(descriptor, "wb") as output:
                output.write(revision.encode("ascii"))
                output.flush()
                os.fsync(output.fileno())
            if not publish_file(temporary, reference):
                check_reference(reference, revision)
        finally:
            temporary.unlink(missing_ok=True)
    return snapshot


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("source", type=Path, help="completed ModelScope model directory")
    parser.add_argument("--hub-root", type=Path, default=Path("~/.cache/huggingface/hub"))
    arguments = parser.parse_args()
    try:
        manifest = json.loads(MANIFEST_PATH.read_text(encoding="utf-8"))
        if (manifest["repo"] != "nvidia/Qwen3.8-Flash-Next-NVFP4"
                or manifest["revision"] != "fc694b54fb0174e0913e6adf86691ef85a4ead47"
                or len(manifest["files"]) != 25):
            raise ValueError("Expected the bundled NVIDIA Qwen manifest and its 25 files")
        snapshot = import_snapshot(arguments.source, arguments.hub_root, manifest)
    except (OSError, ValueError, KeyError) as error:
        print("Import failed: " + str(error), file=sys.stderr)
        return 1
    print("Verified snapshot: " + str(snapshot))
    return 0


if __name__ == "__main__":
    sys.exit(main())
