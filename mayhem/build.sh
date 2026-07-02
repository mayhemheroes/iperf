#!/usr/bin/env bash
#
# iperf/mayhem/build.sh — build esnet/iperf's two OSS-Fuzz harnesses as sanitized libFuzzer
# targets (+ standalone reproducers), AND iperf's OWN self-contained unit tests for mayhem/test.sh.
#
# The fuzzed surface is two attacker-reachable parsers inside iperf3:
#   cjson_fuzzer — iperf's bundled cJSON parser (src/cjson.c cJSON_Parse). iperf3 exchanges its
#                  entire control protocol + results as JSON; cJSON_Parse runs on bytes received
#                  from the peer (a malicious server/client).
#   auth_fuzzer  — Base64Decode (src/iperf_auth.c). iperf3's --authorized-users / auth-token path
#                  base64-decodes peer-supplied strings before RSA-decrypting them.
# Inputs are: raw JSON text (cjson) and base64 text (auth) — both null-terminated by the harness.
#
# Build contract comes from the org base ENV (CC/CXX/SANITIZER_FLAGS/LIB_FUZZING_ENGINE/SRC/
# STANDALONE_FUZZ_MAIN). We compile the fuzzed iperf sources (cjson.c / iperf_auth.c) WITH
# $SANITIZER_FLAGS so the parsers themselves — not just the harness — are instrumented.
set -euo pipefail

# clang rejects SOURCE_DATE_EPOCH='' — must be unset or a valid integer.
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

# `=` (not `:=`) for SANITIZER_FLAGS so an explicit empty --build-arg builds with NO sanitizers.
: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
# DEBUG_FLAGS: DWARF ≤ 3 required by Mayhem's triage (§6.2 item 10); clang-19 plain -g emits DWARF-5.
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${STANDALONE_FUZZ_MAIN:=/opt/mayhem/StandaloneFuzzTargetMain.c}"
: "${MAYHEM_JOBS:=$(nproc)}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS

cd "$SRC"

HARNESS_DIR="$SRC/mayhem/harnesses"
OUT="${OUT:-/mayhem}"
mkdir -p "$OUT"

# ── 1) Generate the autotools build system + iperf_config.h (headers the sources need) ────────────
# iperf is autotools; ./configure produces src/iperf_config.h (HAVE_SSL etc). Build the project once
# so any generated headers exist, then we recompile the fuzzed translation units with sanitizers.
[ -x ./configure ] || autoreconf -fi
./configure --enable-static --disable-shared >/dev/null
make -j"$MAYHEM_JOBS" >/dev/null 2>&1 || make -j"$MAYHEM_JOBS"

INC="-Isrc"

# Standalone driver (no libFuzzer runtime; replays one input file) — compile once.
BUILD="$SRC/mayhem-build"
mkdir -p "$BUILD"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -c "$STANDALONE_FUZZ_MAIN" -o "$BUILD/standalone_main.o"

build_target() {  # <name> <harness.c> <extra-cflags> <project-srcs...> -- <libs...>
  local name="$1" harness="$2" extra="$3"; shift 3
  local srcs=() libs=()
  while [ "$1" != "--" ]; do srcs+=("$1"); shift; done
  shift
  libs=("$@")

  # Compile the instrumented project translation units fresh for this target.
  # -fsanitize=fuzzer-no-link adds SanitizerCoverage edge tables to the FUZZED code (cjson.c /
  # iperf_auth.c) WITHOUT pulling in libFuzzer's main(), so the same objects link into both the
  # libFuzzer target and the standalone reproducer. Without it only the harness is instrumented and
  # the fuzzer is blind to the parser's edges (cov stays flat regardless of input).
  local objs=()
  for s in "${srcs[@]}"; do
    local o="$BUILD/${name}_$(basename "${s%.c}").o"
    $CC $SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link $INC $extra -c "$s" -o "$o"
    objs+=("$o")
  done

  # libFuzzer target -> $OUT/<name>
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS $INC $extra \
      "$HARNESS_DIR/$name.c" $LIB_FUZZING_ENGINE "${objs[@]}" "${libs[@]}" \
      -o "$OUT/$name"

  # standalone reproducer (no libFuzzer runtime) -> $OUT/<name>-standalone
  $CC $SANITIZER_FLAGS $DEBUG_FLAGS $INC $extra \
      "$HARNESS_DIR/$name.c" "$BUILD/standalone_main.o" "${objs[@]}" "${libs[@]}" \
      -o "$OUT/$name-standalone"

  echo "built $name (+ standalone)"
}

# ── 2) cjson_fuzzer: cJSON_Parse over src/cjson.c ─────────────────────────────────────────────────
build_target cjson_fuzzer "$HARNESS_DIR/cjson_fuzzer.c" "" \
  src/cjson.c -- -lm

# ── 3) auth_fuzzer: Base64Decode over src/iperf_auth.c (needs -DHAVE_SSL + libssl/libcrypto) ──────
build_target auth_fuzzer "$HARNESS_DIR/auth_fuzzer.c" "-DHAVE_SSL" \
  src/iperf_auth.c -- -lssl -lcrypto

# ── 4) Build iperf's OWN self-contained unit tests with NORMAL flags (clean tree) so test.sh only
#       RUNS them. `make check` builds t_timer/t_units/t_uuid/t_api/t_auth (all self-contained — no
#       server pair). We build them but do not run here; test.sh runs + scores them. ───────────────
env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS \
  make -C src -j"$MAYHEM_JOBS" t_timer t_units t_uuid t_api t_auth >/dev/null 2>&1 \
  || env -u CFLAGS -u CXXFLAGS -u SANITIZER_FLAGS make -C src t_timer t_units t_uuid t_api t_auth
echo "built iperf self-contained unit tests (t_timer t_units t_uuid t_api t_auth)"

# ── 5) Build behavioral oracle binaries — normal (no sanitizers) so test.sh can run them without
#       the ASan runtime and grep their output for expected values (anti-reward-hack oracle, §6.3).
#       These are NOT fuzz targets; they are repro helpers for test.sh only. ─────────────────────
$CC $DEBUG_FLAGS $INC \
    "$HARNESS_DIR/cjson_oracle.c" src/cjson.c \
    -lm -o "$OUT/cjson_oracle"
echo "built cjson_oracle"

$CC $DEBUG_FLAGS $INC -DHAVE_SSL \
    "$HARNESS_DIR/auth_oracle.c" src/iperf_auth.c \
    -lssl -lcrypto -o "$OUT/auth_oracle"
echo "built auth_oracle"

echo "build.sh complete:"
ls -la "$OUT/cjson_fuzzer" "$OUT/auth_fuzzer" \
       "$OUT/cjson_fuzzer-standalone" "$OUT/auth_fuzzer-standalone" \
       "$OUT/cjson_oracle" "$OUT/auth_oracle" 2>&1 || true
