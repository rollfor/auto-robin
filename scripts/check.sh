#!/usr/bin/env bash

# The checks scripts/test.sh cannot make. Run both before committing.
#
#   1. lua-language-server over every workspace. Annotation drift, shadowed locals, a doc
#      block left above the wrong function -- none of which a passing suite notices.
#   2. Declared test cases against the ones luaunit actually ran. A case not named
#      `should_*` is filtered out silently and subtracts from nothing, so a suite can
#      report "6 tests" for years while a seventh rots.
#
# Read the output; a non-zero exit says something was found but not which check found it.

set -o pipefail

REPO="$(cd "$(dirname "$0")/.." && pwd)"
cd "$REPO" || exit 1

# RollFor comes from the submodule; nothing runs without it.
if [[ ! -f deps/rollfor/RollFor/src/RollFor.toc ]]; then
  echo "deps/rollfor is empty. Run: git submodule update --init" >&2
  exit 1
fi

FAILED=0

# One workspace per addon, never the repo root: each addon's .luarc.json names what it can see,
# and the root would take in deps/rollfor, whose harnesses define the same types and would be
# reported as duplicates. An addon here is a directory holding <name>/src/<name>.toc.
workspaces() {
  local d name
  for d in "$REPO"/*/; do
    d="${d%/}"
    name="$(basename "$d")"
    [[ -f "$d/src/$name.toc" ]] && echo "$d"
  done
}

# Hint, not Warning: unused-local and redefined-local live there, and they are where the
# findings have been.
check_annotations() {
  echo "Checking annotations..." >&2

  local dir out tail_line label
  while read -r dir; do
    out=$(lua-language-server --check "$dir" --checklevel=Hint --logpath="$(mktemp -d)" \
      </dev/null 2>&1 |
      tr '\r' '\n' | grep -viE '^[[:space:]]*$|^(Initializing|>|=)')
    tail_line=$(echo "$out" | tail -1)

    label="$(basename "$dir")"
    printf "%-24s %s\n" "$label" "$tail_line"

    if ! echo "$tail_line" | grep -q "no problems found"; then
      echo "$out" | grep -v "^Diagnosis" | sed 's/^/    /'
      FAILED=1
    fi
  done < <(workspaces)
}

# Every case a file declares, minus luaunit's fixtures, against what luaunit ran. The Spec
# pattern allows digits -- Base64Spec is a real one.
check_unrun_cases() {
  echo >&2
  echo "Checking for cases that never run..." >&2

  local dir f declared ran
  while read -r dir; do
    [[ -d "$dir/test" ]] || continue

    for f in "$dir"/test/*_test.lua; do
      [[ -e "$f" ]] || continue

      declared=$(grep -E '^function [A-Za-z_0-9]*Spec[:.]' "$f" |
        grep -vE '[:.](setUp|tearDown)\(' | wc -l)

      ran=$(cd "$(dirname "$f")" && lua "$(basename "$f")" -T Spec -m should -o text \
        </dev/null 2>&1 |
        grep -oE 'Ran [0-9]+ tests' | grep -oE '[0-9]+')
      ran=${ran:-0}

      if [[ "$declared" -gt "$ran" ]]; then
        printf "  %s/%-40s declared %s, ran %s\n" \
          "$(basename "$dir")" "$(basename "$f")" "$declared" "$ran"
        grep -E '^function [A-Za-z_0-9]*Spec[:.]' "$f" |
          grep -vE '[:.](setUp|tearDown)\(|[:.]should_' | sed 's/^/      never runs: /'
        FAILED=1
      fi
    done
  done < <(workspaces)
}

check_annotations
check_unrun_cases

echo >&2
[[ $FAILED -eq 0 ]] && echo "Clean." >&2 || echo "Problems found. See above." >&2
exit $FAILED
