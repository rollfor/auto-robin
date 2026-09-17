# CLAUDE.md

## Reference
- **RollFor** (core and the shared test harness): the submodule in `deps/rollfor`, pinned to
  a release tag of [rollfor/rollfor](https://github.com/rollfor/rollfor), currently
  `v5.0.8-beta1`. Its `CLAUDE.md` holds the conventions this repo follows.
- **Client UI source** (BCC, `2.5.6.68502`), the authority on what an API
  returns: `$HOME/.projects/lua/wow-ui-source.git/classic_anniversary`
- **Other addons**: `$HOME/.projects/lua/wow-2.5.x-addons.git/master`


## Layout
Same shape as the rollfor repo. `RollForAutoRobin/src/` is exactly what ships (the `.toc`, the
main file, and the modules in its own `src/`), `test/` is its tests, and editor config sits
beside the two.

The folder is not installable as it stands, on purpose. Players get the zip
`scripts/bundle.sh` builds; `scripts/install.sh` mirrors the same into a local AddOns
directory. Neither includes `deps/`.

`deps/` is never copied into: RollFor is referenced, not vendored. Pin it to a release tag,
not a branch head. To bump it:

    git -C deps/rollfor fetch --tags
    git -C deps/rollfor checkout <tag>
    # run the tests and checks, then commit deps/rollfor and the tag named above


## Running the scripts
Every script runs in Docker, one service each in `docker-compose.yaml`, images
in `docker/`. The submodule has to be checked out first:

    git submodule update --init
    docker compose run --rm test
    docker compose run --rm check
    BUNDLE_DIR=<dir> docker compose run --rm bundle
    ADDONS_DIR=<dir> docker compose run --rm install

Tests find RollFor through `package.path` entries under `../../deps/rollfor/`. The harness
is this addon's own, the way core's bundled extensions each have one: `test/utils.lua` is
vendored from core's, and every intentional difference is marked `EXTENSION:`. Require
names:

- **This addon's harness by addon-qualified name:**
  `require( "RollForAutoRobin/test/utils" )`, never `"test/utils"`, and the same for
  `"RollForAutoRobin/test/IntegrationTestBuilder"`.
- **Shared ones by `test/common/`**, from the submodule: `"test/common/luaunit"`,
  `"test/common/mocks/Chat"`.
- **Mocks that differ per addon** as `"mocks/ChatApi"`, found relative to the test directory.


## Checks: scripts/check.sh
Run it alongside the tests, never instead of them. It runs `lua-language-server` at Hint
level over the addon's workspace and lists test cases luaunit never ran (any case not named
`should_*`). Run it after any change to `---@` annotations, any rename, and any moved or
inserted function.

The workspace is the addon directory, never the repo root, which would take in
`deps/rollfor` and report its harnesses' types as duplicates. `.luarc.json` names what the
addon can see: `RollFor/src` and `test/common` under `deps/rollfor`.
