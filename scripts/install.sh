#!/usr/bin/env bash

# Mirrors every addon's src/ into the client's AddOns directory as <addon>/, the same shape
# scripts/bundle.sh zips. Each addon folder there becomes an exact copy: files deleted or
# renamed here are deleted there too. Nothing else in AddOns is touched, deps/rollfor included:
# RollFor is installed from its own repo.
#
#   scripts/install.sh <addons-dir>

set -o pipefail

cd "$(dirname "$0")/.." || exit 1

addons() {
  local dir name
  for dir in */; do
    name="${dir%/}"
    [[ -f "$name/src/$name.toc" ]] && echo "$name"
  done
}

# --delete is scoped to one addon's folder. Pointed at AddOns itself it would wipe every
# other addon installed there.
install_addon() {
  local name="$1"
  echo "Installing $name..." >&2
  rsync -a --delete "$name/src/" "$TARGET_DIR/$name/"
}

main() {
  TARGET_DIR="$1"

  if [[ $# -ne 1 || -z "$TARGET_DIR" ]]; then
    echo "Usage: $0 <addons-dir>" >&2
    exit 1
  fi

  if [[ ! -d "$TARGET_DIR" ]]; then
    echo "No such directory: $TARGET_DIR" >&2
    exit 1
  fi

  local name
  while read -r name; do
    install_addon "$name" || exit 1
  done < <(addons)
}

main "$@"
