#!/bin/sh
set -eu

shum_repo="${CI_PRIMARY_REPOSITORY_PATH:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
shum_configs="$shum_repo/ShumiOS/Configuration/Configs"

# Local configs stay untracked; fresh CI checkouts use the public defaults.
for configuration in Debug Release; do
    target="$shum_configs/$configuration.xcconfig"
    if [ -e "$target" ]; then
        echo "Keeping existing $configuration.xcconfig"
    else
        cp "$shum_configs/$configuration.example.xcconfig" "$target"
        echo "Created $configuration.xcconfig from public template"
    fi
done
