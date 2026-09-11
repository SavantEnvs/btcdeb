#!/usr/bin/env bash
#
# mayhem/build.sh — backport btcdeb-buggy-mhh-run-21: build an INSTRUMENTED stand-in for the
# surface mayhemheroes run 21 fuzzed (btcdeb's CLI reading one line on stdin) + its own test suite.
#
# btcdeb is an autotools project (./autogen.sh && ./configure && make) that vendors secp256k1
# in-tree, so the build is fully offline (no submodules, no network). We produce, all under /mayhem:
#   btcdeb                       the plain CLI binary, sanitized — the original surface, kept as a
#                                reference reproducer (`/mayhem/btcdeb < input`)
#   btcdeb_cli_fuzz              libFuzzer harness replaying that CLI's stdin path in process
#                                (mayhem/harnesses/fuzz_cli_stdin.cpp) — the fuzzed target
#   btcdeb_cli_fuzz-standalone   run-once reproducer for the same harness
#   test-btcdeb.oracle           the upstream Catch2 test runner, built with NORMAL flags for test.sh
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

# ── 2) SANITIZED build of the plain CLI (the fuzzed surface) ─────────────────
# Build the project itself with $SANITIZER_FLAGS + $DEBUG_FLAGS (DWARF<4 after the sanitizer flags) so
# the fuzzed interpreter code is instrumented AND carries resolvable symbols. Build the FULL default
# target (all of bin_PROGRAMS), not just btcdeb: a targeted `make btcdeb` leaves test-btcdeb unbuilt,
# so a later plain `make test-btcdeb` (the item-9 idempotent-rerun check re-invokes this script from
# the top) relinks a freshly-compiled, unsanitized test-btcdeb.o against the secp256k1/libbitcoin
# archives this step already built SANITIZED — undefined `__asan_report_load8` at link time. Building
# everything here leaves every bin_PROGRAMS binary up to date, so that later `make test-btcdeb` is a
# true no-op. `make` lands btcdeb at $SRC/btcdeb, i.e. /mayhem/btcdeb — exactly the Mayhemfile's cmd:.
./configure CC="$CC" CXX="$CXX" \
  CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS" CXXFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS"
make -j"$MAYHEM_JOBS"

# ── 3) The fuzzed harness: instrumented stand-in for the CLI's stdin path ────
# Run 21 fuzzed the bare CLI, but Mayhem no longer derives edge coverage from an uninstrumented
# black-box command (two 1200s runs of `cmd: /mayhem/btcdeb` on this branch reported
# edges_covered: 0), which SPEC.md §6.2 item 11 rejects. fuzz_cli_stdin.cpp replays btcdeb.cpp's
# `pipe_in` branch in process — same bytes in, same parse_script → setup_environment →
# ContinueScript path out — so run 21's testsuite replays unchanged and the same uncaught
# scriptnum_error fires, but under libFuzzer instrumentation.
#
# instance.cpp is compiled into the btcdeb/tap programs by Makefile.am, not into any archive, so it
# is listed explicitly here; the mutual references between libbitcoin_deb.a and libbitcoin.a
# (StepExtended, EvalScript) are resolved with a link group rather than a fragile order.
INCLUDES="-I. -Isecp256k1/include"
LIBS="-Wl,--start-group libbitcoin_deb.a libbitcoin.a libkerl.a \
  secp256k1/.libs/libsecp256k1.a secp256k1/.libs/libsecp256k1_precomputed.a -Wl,--end-group"
SOURCES="$SRC/mayhem/harnesses/fuzz_cli_stdin.cpp $SRC/instance.cpp $SRC/mayhem/lsan_off.cc"

# shellcheck disable=SC2086
$CXX -std=c++17 $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE $INCLUDES \
  $SOURCES $LIBS -o /mayhem/btcdeb_cli_fuzz

# Standalone driver is C (StandaloneFuzzTargetMain.c); compile it as a C object first so its
# LLVMFuzzerTestOneInput reference keeps C linkage (clang++ would mangle it).
# shellcheck disable=SC2086
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o /tmp/standalone_main.o
# shellcheck disable=SC2086
$CXX -std=c++17 $SANITIZER_FLAGS $DEBUG_FLAGS $INCLUDES \
  $SOURCES /tmp/standalone_main.o $LIBS -o /mayhem/btcdeb_cli_fuzz-standalone

echo "build.sh: done — $(ls -1 /mayhem/btcdeb /mayhem/btcdeb_cli_fuzz /mayhem/btcdeb_cli_fuzz-standalone /mayhem/test-btcdeb.oracle)"
