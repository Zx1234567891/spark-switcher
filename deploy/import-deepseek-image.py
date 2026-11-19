#!/usr/bin/env python3
"""Import the pinned DeepSeek runtime from its official base plus a delta.

Usage: python3 deploy/import-deepseek-image.py DELTA.tar.gz [--temp-dir PATH]

The delta contains exactly config.json and layer.bin, both regular files.
No build, package installation, model download, or GPU work is performed.
An already installed base is reused offline. Otherwise Docker pulls its pinned
linux/arm64 manifest. Allow about 25 GB of temporary disk space for its save.
"""

import argparse
import gzip
import hashlib
import io
import json
import os
from pathlib import Path, PurePosixPath
import shutil
import subprocess
import sys
import tarfile
import tempfile


BASE_REF = "nvcr.io/nvidia/pytorch@sha256:7531d90bcbe0e43e1f7363029c7e145ce90eebeb494a7b4695fdba0329d7c3c3"
BASE_ID = "sha256:15b8de8baabe68e46afc51e88f3ccad5042013bafe8f244ec082ce0bb06d47e3"
TARGET_ID = "sha256:193ec8579b0c3dd5bf6b122f6fd4f0cc8cfd225273d86f537892203ddff91f6e"
TARGET_TAG = "tensorfold-dsv41:8e0966e"
ADDED_DIFF_ID = "sha256:08ec80539493ccf1d013647ca3fff577362a2e4983ab9bdde6793b8963e2080f"
BASE_LAYERS = 67
BUFFER = 4 * 1024 * 1024
MAX_JSON = 4 * 1024 * 1024


def say(message):
    print(message, flush=True)


def docker(*args):
    result = subprocess.run(["docker", *args], stdout=subprocess.PIPE,
                            stderr=subprocess.PIPE, text=True)
    if result.returncode:
        raise RuntimeError("docker {} failed: {}".format(
            args[0], result.stderr.strip() or result.stdout.strip()))
    return result.stdout


def inspect_image(reference):
    result = subprocess.run(["docker", "image", "inspect", reference],
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    if result.returncode:
        if "no such image" in result.stderr.lower() or "not found" in result.stderr.lower():
            return None
        raise RuntimeError("Cannot inspect Docker image: " + result.stderr.strip())
    images = json.loads(result.stdout)
    if len(images) != 1:
        raise RuntimeError("Expected exactly one image for " + reference)
    return images[0]


def check_tag():
    image = inspect_image(TARGET_TAG)
    if image is not None and image.get("Id") != TARGET_ID:
        raise RuntimeError("Refusing to replace {}: it points to {}".format(TARGET_TAG, image.get("Id")))
    return image


def digest(data):
    return "sha256:" + hashlib.sha256(data).hexdigest()


def diff_id(stream):
    """Hash the original uncompressed layer tar; never extract or re-tar it."""
    magic = stream.read(4)
    stream.seek(0)
    if magic.startswith(b"\x1f\x8b"):
        source = gzip.GzipFile(fileobj=stream, mode="rb")
    elif magic.startswith((b"\x28\xb5\x2f\xfd", b"\xfd7zX", b"BZh")):
        raise RuntimeError("Unsupported layer compression; this importer accepts raw tar or gzip")
    else:
        source = stream
    hasher = hashlib.sha256()
    try:
        while True:
            data = source.read(BUFFER)
            if not data:
                break
            hasher.update(data)
    finally:
        if source is not stream:
            source.close()
    return "sha256:" + hasher.hexdigest()


def read_small(archive, name):
    member = archive.getmember(name)
    with archive.extractfile(member) as stream:
        data = stream.read(MAX_JSON + 1)
    if len(data) > MAX_JSON:
        raise RuntimeError("Oversized image metadata: " + name)
    return data


def validate_config(raw):
    if digest(raw) != TARGET_ID:
        raise RuntimeError("Delta config.json does not match the pinned target image ID")
    config = json.loads(raw)
    ids = config.get("rootfs", {}).get("diff_ids")
    if config.get("os") != "linux" or config.get("architecture") != "arm64":
        raise RuntimeError("Target must be linux/arm64")
    if (config.get("rootfs", {}).get("type") != "layers"
            or not isinstance(ids, list) or len(ids) != BASE_LAYERS + 1
            or ids[-1] != ADDED_DIFF_ID):
        raise RuntimeError("Target must contain the 67 base layers and the one pinned added layer")
    return config


def stage_delta(filename, directory):
    seen = set()
    config_raw = None
    layer_path = directory / "layer.bin"
    with tarfile.open(filename, "r|gz") as archive:
        for member in archive:
            if member.name not in {"config.json", "layer.bin"} or member.name in seen or not member.isfile():
                raise RuntimeError("Delta must contain only regular config.json and layer.bin members")
            seen.add(member.name)
            if member.name == "config.json":
                if member.size > MAX_JSON:
                    raise RuntimeError("Oversized config.json")
                with archive.extractfile(member) as stream:
                    config_raw = stream.read(MAX_JSON + 1)
            else:
                if shutil.disk_usage(directory).free < member.size + 64 * 1024 * 1024:
                    raise RuntimeError("Not enough temporary disk space for layer.bin")
                with archive.extractfile(member) as source, layer_path.open("wb") as destination:
                    shutil.copyfileobj(source, destination, BUFFER)
                if layer_path.stat().st_size != member.size:
                    raise RuntimeError("Truncated layer.bin")
    if seen != {"config.json", "layer.bin"}:
        raise RuntimeError("Delta is missing config.json or layer.bin")
    config = validate_config(config_raw)
    with layer_path.open("rb") as stream:
        if diff_id(stream) != ADDED_DIFF_ID:
            raise RuntimeError("Added layer uncompressed SHA-256 does not match the pinned diffID")
    return config_raw, config, layer_path


def validate_image(image, expected_id, expected_layers):
    if (image is None or image.get("Id") != expected_id or image.get("Os") != "linux"
            or image.get("Architecture") != "arm64"
            or image.get("RootFS", {}).get("Layers") != expected_layers):
        raise RuntimeError("Image ID, platform or ordered rootfs layers do not match: " + expected_id)


def member_path(name):
    if not isinstance(name, str):
        raise RuntimeError("Unsafe path inside base image archive")
    path = PurePosixPath(name)
    if path.is_absolute() or ".." in path.parts:
        raise RuntimeError("Unsafe path inside base image archive")
    return name


def validate_base_archive(archive, expected_layers):
    manifest = json.loads(read_small(archive, "manifest.json"))
    selected = None
    for entry in manifest:
        raw = read_small(archive, member_path(entry["Config"]))
        if digest(raw) == BASE_ID:
            selected = entry
            config = json.loads(raw)
            break
    if selected is None:
        raise RuntimeError("Saved archive does not contain the pinned base config")
    if (config.get("architecture") != "arm64" or config.get("os") != "linux"
            or config.get("rootfs", {}).get("diff_ids") != expected_layers
            or len(selected["Layers"]) != BASE_LAYERS):
        raise RuntimeError("Saved base config does not match the target's ordered 67-layer prefix")
    paths = [member_path(name) for name in selected["Layers"]]
    say("Checking all 67 base layer diffIDs before importing...")
    for index, (name, expected) in enumerate(zip(paths, expected_layers)):
        with archive.extractfile(name) as stream:
            if diff_id(stream) != expected:
                raise RuntimeError("Saved base layer {} failed its uncompressed SHA-256".format(index))
    return paths


def add_file(archive, name, source, size):
    entry = tarfile.TarInfo(name)
    entry.size = size
    entry.mode = 0o644
    entry.mtime = 0
    archive.addfile(entry, source)


def write_complete_archive(destination, base, base_paths, config_raw, layer_path):
    """Write a complete Docker archive, including cached base bytes, to a pipe."""
    config_name = TARGET_ID.split(":", 1)[1] + ".json"
    layer_names = ["layers/{:03d}/layer.tar".format(i) for i in range(BASE_LAYERS + 1)]
    with tarfile.open(fileobj=destination, mode="w|", format=tarfile.PAX_FORMAT) as output:
        add_file(output, config_name, io.BytesIO(config_raw), len(config_raw))
        for name, source_name in zip(layer_names, base_paths):
            with base.extractfile(source_name) as source:
                size = source.seek(0, 2)
                source.seek(0)
                add_file(output, name, source, size)
        with layer_path.open("rb") as source:
            add_file(output, layer_names[-1], source, layer_path.stat().st_size)
        # Import by ID first. A conflicting pre-existing tag is never overwritten by docker load.
        manifest = [{"Config": config_name, "RepoTags": [], "Layers": layer_names}]
        raw = json.dumps(manifest, separators=(",", ":")).encode("utf-8")
        add_file(output, "manifest.json", io.BytesIO(raw), len(raw))


def load_image(base, paths, config_raw, layer_path, directory):
    say("Streaming the complete archive into docker load (no build)...")
    log_path = directory / "docker-load.log"
    with log_path.open("w+b") as log:
        process = subprocess.Popen(["docker", "image", "load"], stdin=subprocess.PIPE,
                                   stdout=log, stderr=subprocess.STDOUT)
        try:
            try:
                write_complete_archive(process.stdin, base, paths, config_raw, layer_path)
                process.stdin.close()
            except BrokenPipeError:
                if not process.stdin.closed:
                    try:
                        process.stdin.close()
                    except BrokenPipeError:
                        pass
            code = process.wait()
        except BaseException:
            if process.poll() is None:
                process.terminate()
                try:
                    process.wait(timeout=10)
                except subprocess.TimeoutExpired:
                    process.kill()
                    process.wait()
            raise
        log.seek(max(0, log.tell() - 16384))
        message = log.read().decode("utf-8", "replace").strip()
        if message:
            say(message)
        if code:
            raise RuntimeError("docker load failed (exit {})".format(code))


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path, help="deepseek-8e0966e-linux-arm64-delta.tar.gz")
    parser.add_argument("--temp-dir", type=Path, default=Path(os.environ.get("TMPDIR") or Path.cwd()),
                        help="Existing disk directory with about 25 GB free (default: TMPDIR or current directory)")
    args = parser.parse_args(argv)
    if not args.archive.is_file():
        parser.error("delta archive does not exist")
    try:
        with tempfile.TemporaryDirectory(prefix="deepseek-image-", dir=args.temp_dir) as temp:
            directory = Path(temp)
            say("Checking the delta's exact config and added layer...")
            config_raw, config, layer_path = stage_delta(args.archive, directory)
            target_layers = config["rootfs"]["diff_ids"]
            existing = check_tag()
            if existing is not None:
                validate_image(existing, TARGET_ID, target_layers)
                say("Already installed: " + TARGET_TAG + " (" + TARGET_ID + ")")
                return 0
            base_image = inspect_image(BASE_ID)
            if base_image is None:
                say("The exact base is not installed; pulling " + BASE_REF)
                docker("image", "pull", "--platform=linux/arm64", BASE_REF)
                base_image = inspect_image(BASE_ID)
            validate_image(base_image, BASE_ID, target_layers[:BASE_LAYERS])
            if shutil.disk_usage(directory).free < base_image.get("Size", 0) + 64 * 1024 * 1024:
                raise RuntimeError("Not enough temporary disk space for docker save; use --temp-dir")
            base_path = directory / "base.tar"
            say("Saving the verified local base to " + str(base_path))
            docker("image", "save", "--output", str(base_path), BASE_ID)
            with tarfile.open(base_path, "r:*") as archive:
                paths = validate_base_archive(archive, target_layers[:BASE_LAYERS])
                check_tag()
                load_image(archive, paths, config_raw, layer_path, directory)
            validate_image(inspect_image(TARGET_ID), TARGET_ID, target_layers)
            check_tag()
            docker("image", "tag", TARGET_ID, TARGET_TAG)
            validate_image(inspect_image(TARGET_TAG), TARGET_ID, target_layers)
            say("Verified: " + TARGET_TAG + " (" + TARGET_ID + ")")
            return 0
    except (OSError, ValueError, KeyError, TypeError, tarfile.TarError, RuntimeError) as exc:
        print("ERROR: " + str(exc), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
