#!/usr/bin/env bash
#
# mayhem/test.sh — RUN this repo's OWN functional test suite (already built by mayhem/build.sh).
# exit 0 = pass. EDIT per repo. PATCH-grade oracle: after an agent patches the source, the grader
# rebuilds (build.sh) then runs this. DELETE this file if the repo has no meaningful tests.
#
# IMPORTANT:
#  * Must assert BEHAVIOR/OUTPUT, not just exit status. The oracle has to check asserted values /
#    golden-output diffs / known-answer results — so a PATCH that "fixes" a bug by making the program
#    exit(0) (or any no-op) FAILS here. Running inputs and checking only "exit 0 / didn't crash" is
#    NOT a functional test (it's trivially reward-hackable) — use the project's real assertion suite.
#  * Do NOT build here — mayhem/build.sh already compiled the test suite (with the project's normal
#    flags). This script only RUNS the pre-built tests and reports counts. If the test runner is
#    missing, that's a build.sh bug — fail loudly rather than silently rebuilding.
#  * REQUIRED OUTPUT — a CTRF (https://ctrf.io) summary so Mayhem/the PATCH grader reads the counts:
#      - writes a CTRF JSON report to ${CTRF_REPORT:-$SRC/ctrf-report.json}, and
#      - prints a one-line `CTRF {...}` marker to stdout (same JSON, compact).
#    Only `results.summary` (with tests/passed/failed/pending/skipped/other) is required.
#    Use the emit_ctrf helper below; it computes tests = passed+failed+skipped and sets the exit
#    code (0 iff failed==0). Map your framework's output to passed/failed/skipped.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH
: "${MAYHEM_JOBS:=$(nproc)}"   # build parallelism; env-overridable, falls back to nproc (use -j"$MAYHEM_JOBS")
cd "$SRC"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
# Writes a CTRF report (file + stdout `CTRF {...}` marker) and returns non-zero iff failed>0.
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
  [ "$failed" -eq 0 ]
}

# Upstream's own unit suite (190 tests), parsed from its summary line, plus known-answer probes that
# drive the real `lz4` CLI from bash so a neutered program cannot hide behind a runner's exit code.
LZ4=programs/lz4
UNIT=tests/unittest
[ -x "$LZ4" ] || { echo "missing $LZ4 (build.sh bug)" >&2; exit 2; }
[ -x "$UNIT" ] || { echo "missing $UNIT (build.sh bug)" >&2; exit 2; }

passed=0; failed=0

sum=$(cd tests && ./unittest 2>&1 | grep -E '^\[==========\] [0-9]+ tests, [0-9]+ failed' | tail -1)
if [[ "$sum" =~ ([0-9]+)\ tests,\ ([0-9]+)\ failed ]] && [ "${BASH_REMATCH[1]}" -ge 100 ]; then
  n=${BASH_REMATCH[1]}; f=${BASH_REMATCH[2]}
  passed=$((passed + n - f)); failed=$((failed + f))
else
  echo "unittest summary line missing or too few tests: '$sum'" >&2
  failed=$((failed + 1))
fi

# probe(name, expected, actual)
probe() {
  if [ "$2" = "$3" ]; then passed=$((passed + 1)); else echo "KAT FAIL $1: expected '$2' got '$3'" >&2; failed=$((failed + 1)); fi
}

X_SHA=2e57c67a8bbe706a08d6638ec67da02b67b3743ae7d35948cbcf8d1f45cae0a5   # sha256 of `seq 1 3000`
tmp=$(mktemp -d)
seq 1 3000 > "$tmp/x"

# decompress a committed frame -> known content
probe decode-known-frame "$X_SHA" "$("$LZ4" -d -c mayhem/kat/known.lz4 | sha256sum | cut -d' ' -f1)"
# round trip at several levels, content must come back bit-exact
for lvl in 1 3 9 12; do
  "$LZ4" -$lvl -c "$tmp/x" > "$tmp/x.$lvl.lz4"
  probe roundtrip-L$lvl "$X_SHA" "$("$LZ4" -d -c "$tmp/x.$lvl.lz4" | sha256sum | cut -d' ' -f1)"
  # LZ4 frame magic 04 22 4d 18
  probe magic-L$lvl 04224d18 "$(head -c4 "$tmp/x.$lvl.lz4" | od -An -tx1 | tr -d ' \n')"
done
# repetitive data must actually compress (13893 -> ~11k at -9)
comp=$(wc -c < "$tmp/x.9.lz4")
probe compresses-smaller 1 "$([ "$comp" -gt 1000 ] && [ "$comp" -lt 13000 ] && echo 1 || echo 0)"
# corrupt frame must be rejected
head -c 100 mayhem/kat/known.lz4 > "$tmp/trunc.lz4"
"$LZ4" -d -c "$tmp/trunc.lz4" > /dev/null 2>&1; probe reject-truncated 1 "$([ $? -ne 0 ] && echo 1 || echo 0)"
rm -rf "$tmp"

emit_ctrf "lz4-unittest+kat" "$passed" "$failed" 0
