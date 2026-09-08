#!/bin/sh
set -eu

telescan_repo="${CI_PRIMARY_REPOSITORY_PATH:-$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)}"
telescan_configs="$telescan_repo/TelescaniOS/Configuration/Configs"

# Local configs stay untracked; fresh CI checkouts use the public defaults.
for configuration in Debug Release; do
    target="$telescan_configs/$configuration.xcconfig"
    if [ -e "$target" ]; then
        echo "Keeping existing $configuration.xcconfig"
    else
        cp "$telescan_configs/$configuration.example.xcconfig" "$target"
        echo "Created $configuration.xcconfig from public template"
    fi
done
