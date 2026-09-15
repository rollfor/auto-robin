# RollFor - Auto Round Robin

A [RollFor](https://github.com/rollfor/rollfor) extension that hands selected items out in a
rotation instead of rolling for them. See
[RollForAutoRobin/README.md](RollForAutoRobin/README.md) for what it does.

## Installing

Download `RollForAutoRobin.zip` from the [latest release](../../releases/latest) and unpack it
into `Interface/AddOns`, next to `RollFor`.

## Developing

RollFor is a git submodule in `deps/rollfor`, pinned to a RollFor release tag; the tests and
checks run against it.

    git submodule update --init
    docker compose run --rm test
    docker compose run --rm check
    BUNDLE_DIR=<dir> docker compose run --rm bundle
    ADDONS_DIR=<dir> docker compose run --rm install

`scripts/release.sh` tags `master` with the version in
`RollForAutoRobin/src/RollForAutoRobin.toc`; the tag push builds and publishes the release.
