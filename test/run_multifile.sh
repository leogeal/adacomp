#!/usr/bin/env bash
# test/run_multifile.sh - exercise separate compilation of a package.
#
# Compiles the package spec -> .h, body -> .c, and a main unit -> .c with
# the chosen compiler, links the two .c files, runs the result, and checks
# it against test/mf/mfmain.expected. This is the multi-file analogue of
# run.sh (which only handles single-file fixtures).
#
# Usage: test/run_multifile.sh
#        COMPILER=stage1 test/run_multifile.sh
#
# Exit code: 0 if it builds, links, runs, and matches; non-zero otherwise.

set -u
cd "$(dirname "$0")/.."

COMPILER="${COMPILER:-bootstrap}"
BOOT="build/$COMPILER"
if [[ ! -x "$BOOT" ]]; then
  echo "no $BOOT binary; run 'make $COMPILER' first" >&2
  exit 2
fi

OUT=build/mf
mkdir -p "$OUT"

"$BOOT" test/mf/mathpkg.ads "$OUT/mathpkg.h" >/dev/null 2>&1 || { echo "FAIL multifile (spec -> .h)"; exit 1; }
"$BOOT" test/mf/mathpkg.adb "$OUT/mathpkg.c" >/dev/null 2>&1 || { echo "FAIL multifile (body -> .c)"; exit 1; }
"$BOOT" test/mf/mfmain.adb  "$OUT/mfmain.c"  >/dev/null 2>&1 || { echo "FAIL multifile (main -> .c)"; exit 1; }

if ! gcc -O2 -Wall -Wno-unused-function -Iruntime -I"$OUT" \
        -o "$OUT/prog" "$OUT/mfmain.c" "$OUT/mathpkg.c" 2>/dev/null; then
  echo "FAIL multifile (link)"; exit 1
fi

got=$("$OUT/prog" 2>&1) || true
want=$(cat test/mf/mfmain.expected)
if [[ "$got" == "$want" ]]; then
  echo "PASS multifile via $COMPILER (spec->.h, body->.c, main, link)"
else
  echo "FAIL multifile (output mismatch)"
  diff <(echo "$want") <(echo "$got") | sed 's/^/    /'
  exit 1
fi
