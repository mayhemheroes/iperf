#!/usr/bin/env bash
#
# iperf/mayhem/test.sh — RUN behavioral oracle tests (built by mayhem/build.sh) and emit CTRF.
# exit 0 iff every test passed. Never compiles — fail loudly if binaries are missing.
#
# Oracle design (§6.3 anti-reward-hacking):
#   Every test asserts concrete OUTPUT, not just exit code.  When the program is
#   sabotaged to exit(0) with no output, grep finds nothing → FAIL.  A no-op patch
#   cannot pass this suite.
#
# Tests:
#   cjson_oracle  — calls cJSON_Parse on a known object; prints "duration=10 num_streams=1 OK".
#                   grep verifies the printed values match.  Exercises the cjson_fuzzer surface.
#   auth_oracle   — calls Base64Decode("aGVsbG8="); prints "hello len=5 OK".
#                   grep verifies the decoded string.  Exercises the auth_fuzzer surface.
#   t_uuid        — make_cookie() must produce a 36-char cookie (UUID-format string); grep for
#                   'cookie:' in stdout confirms the generator ran and produced output at all.
set -uo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

OUT="${OUT:-/mayhem}"
SRC_DIR="${SRC:-/mayhem}"

# emit_ctrf <tool> <passed> <failed> [skipped] [pending] [other]
emit_ctrf() {
  local tool="$1" passed="$2" failed="$3" skipped="${4:-0}" pending="${5:-0}" other="${6:-0}"
  local tests=$(( passed + failed + skipped + pending + other ))
  cat > "${CTRF_REPORT:-${SRC_DIR}/ctrf-report.json}" <<JSON
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

PASS=0; FAIL=0

# ── run_oracle <label> <binary> <grep-pattern> ─────────────────────────────────────────────────────
# Runs the binary, captures stdout+stderr, greps for expected output.  A binary that exits(0) with no
# output (sabotage scenario) produces nothing and grep fails → FAIL.
run_oracle() {
  local label="$1" bin="$2" pattern="$3"
  if [ ! -x "$bin" ]; then
    echo "MISSING $bin — run mayhem/build.sh first" >&2
    FAIL=$((FAIL+1)); return
  fi
  echo "=== $label ==="
  local out
  out="$("$bin" 2>&1)" || true
  echo "$out"
  if echo "$out" | grep -qF "$pattern"; then
    echo "PASS $label"
    PASS=$((PASS+1))
  else
    echo "FAIL $label — expected pattern '$pattern' not found in output"
    FAIL=$((FAIL+1))
  fi
}

# ── 1) cjson_oracle: parse a known JSON object; verify field values in printed output ──────────────
run_oracle "cjson_oracle" "$OUT/cjson_oracle" "duration=10 num_streams=1 OK"

# ── 2) auth_oracle: Base64Decode a known string; verify decoded text in printed output ─────────────
run_oracle "auth_oracle" "$OUT/auth_oracle" "Base64Decode(aGVsbG8=)=hello len=5 OK"

# ── 3) t_uuid: make_cookie() must emit a 36-char UUID-format cookie string ─────────────────────────
#    t_uuid prints "cookie: '<value>'" to stdout; grep for 'cookie:' confirms the generator ran.
#    A no-op exit(0) produces no output → grep fails.
UUID_BIN="${SRC_DIR}/src/t_uuid"
if [ ! -x "$UUID_BIN" ]; then
  echo "MISSING $UUID_BIN — run mayhem/build.sh first" >&2
  FAIL=$((FAIL+1))
else
  echo "=== t_uuid ==="
  uuid_out="$("$UUID_BIN" 2>&1)" || true
  echo "$uuid_out"
  if echo "$uuid_out" | grep -q 'cookie:'; then
    # Also verify the cookie is exactly 36 chars (UUID format: 8-4-4-4-12)
    cookie="$(echo "$uuid_out" | grep -o "cookie: '.[^']*'" | sed "s/cookie: '//;s/'//")"
    clen="${#cookie}"
    if [ "$clen" -eq 36 ]; then
      echo "PASS t_uuid (cookie len=$clen)"
      PASS=$((PASS+1))
    else
      echo "FAIL t_uuid — cookie length $clen != 36 (cookie='$cookie')"
      FAIL=$((FAIL+1))
    fi
  else
    echo "FAIL t_uuid — 'cookie:' not found in output"
    FAIL=$((FAIL+1))
  fi
fi

emit_ctrf "iperf-behavioral-oracle" "$PASS" "$FAIL" 0
