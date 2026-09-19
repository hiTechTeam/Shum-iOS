#!/bin/sh
set -eu

repository_root=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
versions_file="$repository_root/Upstreams/versions.json"
requested=${1:-all}

read_value() {
    /usr/bin/python3 -c 'import json, sys; data=json.load(open(sys.argv[1])); print(data[sys.argv[2]][sys.argv[3]])' \
        "$versions_file" "$1" "$2"
}

fetch_source() {
    source_name=$1
    remote=$(read_value "$source_name" remote)
    url=$(read_value "$source_name" url)
    revision=$(read_value "$source_name" revision)

    if configured_url=$(git -C "$repository_root" remote get-url "$remote" 2>/dev/null); then
        if [ "$configured_url" != "$url" ]; then
            echo "$remote points to $configured_url, expected $url" >&2
            exit 65
        fi
    else
        git -C "$repository_root" remote add "$remote" "$url"
    fi

    git -C "$repository_root" fetch --no-tags --filter=blob:none --depth=1 "$remote" "$revision"
    printf '%s %s\n' "$source_name" "$revision"
}

case "$requested" in
    all)
        fetch_source bitchat
        fetch_source telegram-ios
        ;;
    bitchat|telegram-ios)
        fetch_source "$requested"
        ;;
    *)
        echo "Usage: $0 [all|bitchat|telegram-ios]" >&2
        exit 64
        ;;
esac
