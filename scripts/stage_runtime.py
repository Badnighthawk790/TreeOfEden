#!/usr/bin/env python3
"""Stages the built-in Windows runtime into an app bundle.

Reads runtime/runtime.json (the manifest the app reads at first launch),
downloads every component archive it lists (or reuses a cached copy),
refuses any archive whose size or SHA-256 differs from the manifest, and
copies the archives, the manifest and the license notices into
<Resources>/Runtime. Nothing downloaded is executed or unpacked here.

Usage: stage_runtime.py <repo root> <app Resources folder> <cache folder>
"""
import hashlib
import json
import os
import re
import shutil
import sys
import urllib.request

SAFE_NAME = re.compile(r"^[A-Za-z0-9_+-][A-Za-z0-9._+-]{0,127}$")


def sha256(path):
    digest = hashlib.sha256()
    with open(path, "rb") as handle:
        for chunk in iter(lambda: handle.read(4 << 20), b""):
            digest.update(chunk)
    return digest.hexdigest()


def verified(path, component):
    return (os.path.isfile(path) and os.path.getsize(path) == component["size"]
            and sha256(path) == component["sha256"])


def fetch(component, cache):
    archive = component["archive"]
    if not SAFE_NAME.match(archive):
        sys.exit(f"Unsafe archive name in manifest: {archive!r}")
    if not component["url"].startswith("https://"):
        sys.exit(f"{archive}: only https downloads are allowed")
    target = os.path.join(cache, archive)
    if verified(target, component):
        print(f"Using cached {archive}")
        return target
    partial = target + ".partial"
    print(f"Downloading {component['url']}")
    request = urllib.request.Request(component["url"], headers={"User-Agent": "SteamXBridge-packaging"})
    with urllib.request.urlopen(request, timeout=600) as response, open(partial, "wb") as out:
        shutil.copyfileobj(response, out, 4 << 20)
    if not verified(partial, component):
        os.remove(partial)
        sys.exit(f"{archive} does not match the size and SHA-256 pinned in runtime/runtime.json; refusing to bundle it.")
    os.replace(partial, target)
    return target


def main():
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    root, resources, cache = sys.argv[1:]
    with open(os.path.join(root, "runtime", "runtime.json")) as handle:
        manifest = json.load(handle)
    os.makedirs(cache, exist_ok=True)
    output = os.path.join(resources, "Runtime")
    shutil.rmtree(output, ignore_errors=True)
    os.makedirs(output)
    for component in manifest["components"]:
        shutil.copy2(fetch(component, cache), os.path.join(output, component["archive"]))
    shutil.copy2(os.path.join(root, "runtime", "runtime.json"), os.path.join(output, "runtime.json"))
    # License texts and notices for everything in the runtime.
    shutil.copy2(os.path.join(root, "runtime", "THIRD_PARTY_NOTICES.md"), os.path.join(resources, "THIRD_PARTY_NOTICES.md"))
    licenses = os.path.join(root, "runtime", "licenses")
    shutil.copytree(licenses, os.path.join(resources, "Licenses"), dirs_exist_ok=True)
    total = sum(component["size"] for component in manifest["components"])
    print(f"Staged runtime {manifest['id']} ({total / 1e6:.0f} MB in {len(manifest['components'])} archives)")


if __name__ == "__main__":
    main()
