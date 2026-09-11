#!/usr/bin/env bash
#
# mayhem/test.sh — RUN btcdeb's own Catch2 functional suite (built by build.sh as test-btcdeb.oracle).
#
# This is the ENTIRE upstream suite (`make check` builds a single Catch2 runner, test-btcdeb: 13 test
# cases / ~1070 assertions covering signing, Value parsing, and script utils). Catch2 asserts concrete
# values, so a PATCH that neuters the program to a no-op produces no results and FAILS this oracle
# (the anti-reward-hack sabotage check). We RUN it via the XML reporter and map its OverallResults
# (assertion successes/failures) to CTRF counts; a missing/empty report is treated as a failure.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
cd "$SRC"

RUNNER=/mayhem/test-btcdeb.oracle
XML=/tmp/btcdeb-catch.xml

emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-$SRC/ctrf-report.json}" <<JSON
{
  "results": {
    "tool": { "name": "$tool" },
    "summary": {
      "tests": $tests,
      "passed": $passed,
      "failed": $failed,
      "pending": $pending,
      "skipped": $skipped,
      "other": $other
    }
  }
}
JSON
  printf 'CTRF {"results":{"tool":{"name":"%s"},"summary":{"tests":%d,"passed":%d,"failed":%d,"pending":%d,"skipped":%d,"other":%d}}}\n' \
    "$tool" "$tests" "$passed" "$failed" "$pending" "$skipped" "$other"
  [ "$failed" -eq 0 ] && [ "$tests" -gt 0 ]
}

if [ ! -x "$RUNNER" ]; then
  echo "test.sh: $RUNNER missing — build.sh did not produce the test runner" >&2
  emit_ctrf "catch2" 0 1; exit 1
fi

rm -f "$XML"
"$RUNNER" -r xml -o "$XML"; rc=$?
echo "test.sh: test-btcdeb exit=$rc"

# Root <OverallResults> is the LAST such line (per-test-case ones precede it). A neutered no-op
# writes no usable XML, so an absent line ⇒ passed=0 ⇒ emit_ctrf fails (sabotage detected).
line=$(grep -oE '<OverallResults successes="[0-9]+" failures="[0-9]+"[^/]*/>' "$XML" 2>/dev/null | tail -1)
passed=$(sed -nE 's/.*successes="([0-9]+)".*/\1/p' <<<"$line")
failed=$(sed -nE 's/.*failures="([0-9]+)".*/\1/p' <<<"$line")
passed=${passed:-0}; failed=${failed:-0}

# A non-zero process exit with no reported failures means the runner died abnormally — count as failed.
if [ "$rc" -ne 0 ] && [ "$failed" -eq 0 ]; then failed=1; fi

emit_ctrf "catch2" "$passed" "$failed"
