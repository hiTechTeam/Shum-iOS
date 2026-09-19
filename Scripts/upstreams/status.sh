#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
versions_file="$repository_root/Upstreams/versions.json"

/usr/bin/python3 - "$versions_file" <<'PY'
import json
import subprocess
import sys

with open(sys.argv[1], encoding="utf-8") as stream:
    sources = json.load(stream)

for name, source in sources.items():
    ref = f"refs/heads/{source['branch']}"
    result = subprocess.run(
        ["git", "-C", sys.argv[1].rsplit("/Upstreams/", 1)[0], "ls-remote", source["remote"], ref],
        check=True,
        capture_output=True,
        text=True,
    )
    current = result.stdout.split()[0]
    pinned = source["revision"]
    state = "current" if current == pinned else "update available"
    print(f"{name}: {state}\n  pinned: {pinned}\n  remote: {current}")
PY
