#!/usr/bin/env bash

# Tags HEAD with the version in RollForAutoRobin.toc and pushes only the tag. master has to be pushed
# already, so a release is always of a commit on origin/master. The tag push triggers
# .github/workflows/release.yml, which runs the tests, bundles the zip from the tagged commit
# and publishes the release. Nothing is built here.
#
#   scripts/release.sh

set -o pipefail

cd "$(dirname "$0")/.." || exit 1

main() {
  local version tag
  version=$(sed -n 's/^## Version: *//p' RollForAutoRobin/src/RollForAutoRobin.toc)
  tag="v$version"

  if [[ -z "$version" ]]; then
    echo "No version in RollForAutoRobin/src/RollForAutoRobin.toc" >&2
    exit 1
  fi

  if [[ "$(git branch --show-current)" != "master" ]]; then
    echo "Not on master" >&2
    exit 1
  fi

  if [[ -n "$(git status --porcelain)" ]]; then
    echo "Working tree is dirty" >&2
    exit 1
  fi

  git fetch --tags origin master || exit 1

  if git rev-parse -q --verify "refs/tags/$tag" >/dev/null; then
    echo "$tag already exists" >&2
    exit 1
  fi

  if [[ "$(git rev-parse HEAD)" != "$(git rev-parse origin/master)" ]]; then
    echo "master and origin/master differ; push or pull first" >&2
    exit 1
  fi

  git tag -a "$tag" -m "Version $version." || exit 1

  if ! git push origin "refs/tags/$tag"; then
    git tag -d "$tag" >/dev/null
    exit 1
  fi
}

main "$@"
