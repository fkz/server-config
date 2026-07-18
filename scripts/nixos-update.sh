set -eu

config_dir=${NIXOS_CONFIG_DIR:-/etc/nixos}
state_file=${NIXOS_UPDATE_STATE_FILE:-/var/lib/nixos-update/deployed-commit}

cd "$config_dir"

old_commit=$(git rev-parse HEAD)
git fetch origin
remote_commit=$(git rev-parse '@{u}')

if [ "$old_commit" != "$remote_commit" ]; then
    echo "New commit detected. Updating checkout..."
    git pull --ff-only
fi

target_commit=$(git rev-parse HEAD)
deployed_commit=
if [ -f "$state_file" ]; then
    deployed_commit=$(cat "$state_file")
fi

if [ "$deployed_commit" = "$target_commit" ]; then
    echo "No update needed."
    exit 0
fi

echo "Activating NixOS configuration at $target_commit..."
nixos-rebuild switch

mkdir -p "$(dirname "$state_file")"
printf '%s\n' "$target_commit" >"$state_file.tmp"
mv "$state_file.tmp" "$state_file"
