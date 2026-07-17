#!/usr/bin/env bash
#
# mayhem/build.sh — build btcdeb's fuzz harness + its own test suite.
#
# btcdeb is an autotools project (./autogen.sh && ./configure && make) that vendors secp256k1
# in-tree, so the build is fully offline (no submodules, no network). We produce, all under /mayhem:
#   btcdeb_fuzz             libFuzzer harness over the Script interpreter (EvalScript), sanitized
#   btcdeb_fuzz-standalone  run-once reproducer (same harness, StandaloneFuzzTargetMain driver)
#   test-btcdeb.oracle      the upstream Catch2 test runner, built with NORMAL flags for test.sh
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' (empty) — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"

./autogen.sh

# ── 1) TEST/ORACLE build (project's NORMAL flags) ────────────────────────────
# Build the Catch2 functional suite (test-btcdeb) with the project's normal flags so test.sh stays
# an honest oracle (not a sanitized triage artifact). btcdeb builds in-tree, so stash the runner and
# `make distclean` before the sanitized build re-uses the same tree.
./configure CC="$CC" CXX="$CXX" \
  CFLAGS="$COVERAGE_FLAGS" CXXFLAGS="$COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS"
make -j"$MAYHEM_JOBS" test-btcdeb
cp -f test-btcdeb /mayhem/test-btcdeb.oracle
make distclean

# ── 2) SANITIZED build (harness surface) ─────────────────────────────────────
# Build the project itself with $SANITIZER_FLAGS + $DEBUG_FLAGS (DWARF<4 after the sanitizer flags)
# so the fuzzed interpreter code is instrumented AND carries resolvable symbols.
./configure CC="$CC" CXX="$CXX" \
  CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" CXXFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS"
make -j"$MAYHEM_JOBS"

INCLUDES="-I. -Isecp256k1/include"
# Mutual references between libbitcoin.a and libbitcoin_deb.a (StepExtended, EvalScript) — resolve
# with a link group rather than a fragile order.
LIBS="-Wl,--start-group libbitcoin_deb.a libbitcoin.a libkerl.a \
  secp256k1/.libs/libsecp256k1.a secp256k1/.libs/libsecp256k1_precomputed.a -Wl,--end-group"
HARNESS="$SRC/mayhem/harnesses/fuzz_script.cpp"

# ── 3) Harness: fuzzer binary + standalone reproducer ────────────────────────
# shellcheck disable=SC2086
$CXX -std=c++17 $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE $INCLUDES \
  "$HARNESS" $LIBS -o /mayhem/btcdeb_fuzz

# Standalone driver is C (StandaloneFuzzTargetMain.c); compile it as a C object first so its
# LLVMFuzzerTestOneInput reference keeps C linkage (clang++ would mangle it).
# shellcheck disable=SC2086
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o
# shellcheck disable=SC2086
$CXX -std=c++17 $SANITIZER_FLAGS $DEBUG_FLAGS $INCLUDES \
  "$HARNESS" /tmp/standalone_main.o $LIBS -o /mayhem/btcdeb_fuzz-standalone

echo "build.sh: done — $(ls -1 /mayhem/btcdeb_fuzz /mayhem/btcdeb_fuzz-standalone /mayhem/test-btcdeb.oracle)"
