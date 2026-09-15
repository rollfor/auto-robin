#!/usr/bin/env bash

# Zips every addon in the repo -- a directory holding <name>/src/<name>.toc -- into
# <output-dir>/RollForAutoRobin.zip. Each addon's src/ is exactly what ships, staged as <name>/ so it
# unpacks to its own folder in Interface/AddOns. No folder in the repo is installable as it
# stands; this zip is the only thing that is. RollFor itself is not in it: deps/ is where the
# tests find it, and players install it from its own release.
#
#   scripts/bundle.sh <output-dir>

set -o pipefail

cd "$(dirname "$0")/.." || exit 1

main() {
  if [[ $# -ne 1 || -z "$1" ]]; then
    echo "Usage: $0 <output-dir>" >&2
    exit 1
  fi

  if [[ ! -d "$1" ]]; then
    echo "No such directory: $1" >&2
    exit 1
  fi

  local zip_file
  zip_file="$(cd "$1" && pwd)/RollForAutoRobin.zip"

  local stage addons=() dir name
  stage=$(mktemp -d)
  trap 'rm -rf "$stage"' EXIT

  for dir in */; do
    name="${dir%/}"
    [[ -f "$name/src/$name.toc" ]] || continue
    cp -r "$name/src" "$stage/$name"
    addons+=("$name")
  done

  # zip adds to an existing archive rather than replacing it, which would keep files
  # deleted since the last bundle.
  rm -f "$zip_file"
  (cd "$stage" && zip -qr "$zip_file" "${addons[@]}") || exit 1

  echo "$zip_file" >&2
}

main "$@"
