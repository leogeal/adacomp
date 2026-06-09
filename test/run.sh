#!/usr/bin/env bash
# test/run.sh - Run .adb fixtures against a compiler binary.
#
# For each test/<name>.adb, compile via the chosen compiler to C,
# then gcc the C to a binary, run it, and diff stdout/stderr against
# test/<name>.expected. Pass count and a final summary go to stdout.
#
# Usage:
#   test/run.sh [<name>...]            run named tests (or all if none given)
#   COMPILER=stage1 test/run.sh ...    run against build/stage1 instead of
#                                      the default build/bootstrap
#
# Exit code: 0 if every test passes, 1 if any failed, 2 on setup error.

set -u
cd "$(dirname "$0")/.."

COMPILER="${COMPILER:-bootstrap}"
BOOT="build/$COMPILER"
if [[ ! -x "$BOOT" ]]; then
  echo "no $BOOT binary; run 'make $COMPILER' first" >&2
  exit 2
fi

mkdir -p build

if (( $# == 0 )); then
  mapfile -t tests < <(ls test/*.adb 2>/dev/null | sort)
else
  tests=()
  for n in "$@"; do tests+=( "test/$n.adb" ); done
fi

pass=0; fail=0; missing=0
failed_names=()

for adb in "${tests[@]}"; do
  name=$(basename "$adb" .adb)
  expected="test/$name.expected"
  cfile="build/$name.c"
  bin="build/$name"

  if [[ ! -f "$expected" ]]; then
    echo "SKIP $name (no $expected)"
    missing=$((missing+1))
    continue
  fi

  if ! "$BOOT" "$adb" "$cfile" >/dev/null 2>&1; then
    echo "FAIL $name (adacomp errored)"
    failed_names+=("$name"); fail=$((fail+1)); continue
  fi
  if ! gcc -O2 -Wall -Wno-unused-function -Iruntime -o "$bin" "$cfile" 2>/dev/null; then
    echo "FAIL $name (gcc errored)"
    failed_names+=("$name"); fail=$((fail+1)); continue
  fi

  actual=$("$bin" 2>&1) || true
  want=$(cat "$expected")
  if [[ "$actual" == "$want" ]]; then
    echo "PASS $name"
    pass=$((pass+1))
  else
    echo "FAIL $name (output mismatch)"
    diff <(echo "$want") <(echo "$actual") | sed 's/^/    /'
    failed_names+=("$name"); fail=$((fail+1))
  fi
done

echo
total=$((pass+fail))
echo "$pass / $total passed via $COMPILER ($missing skipped)"
(( fail == 0 ))
