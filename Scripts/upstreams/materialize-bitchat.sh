#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
versions_file="$repository_root/Upstreams/versions.json"
revision=$(/usr/bin/python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["bitchat"]["revision"])' "$versions_file")
destination="$repository_root/.upstreams/bitchat"

"$repository_root/Scripts/upstreams/fetch.sh" bitchat
/bin/rm -rf "$destination"
/bin/mkdir -p "$destination"

git -C "$repository_root" archive "$revision" \
    bitchat/Identity \
    bitchat/Models \
    bitchat/Noise \
    bitchat/Protocols \
    bitchat/Services \
    bitchat/Sync \
    bitchat/Utils | /usr/bin/tar -x -C "$destination"

printf 'Bitchat %s materialized at %s\n' "$revision" "$destination"
