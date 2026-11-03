#!/usr/bin/env bash
# Builds (1) the sanitized fuzz harnesses (all OSS-Fuzz targets) + their standalone reproducers, and
# (2) the project's own test suite with NORMAL flags, left where mayhem/test.sh expects it.
set -euo pipefail
[ -n "${SOURCE_DATE_EPOCH:-}" ] || unset SOURCE_DATE_EPOCH

: "${SANITIZER_FLAGS=-fsanitize=address,undefined -fno-sanitize-recover=all -fno-omit-frame-pointer}"
: "${DEBUG_FLAGS:=-g -gdwarf-3}"
: "${CC:=clang}" ; : "${CXX:=clang++}" ; : "${LIB_FUZZING_ENGINE:=-fsanitize=fuzzer}"
: "${MAYHEM_JOBS:=$(nproc)}"
: "${COVERAGE_FLAGS=}"
export SANITIZER_FLAGS DEBUG_FLAGS CC CXX LIB_FUZZING_ENGINE MAYHEM_JOBS COVERAGE_FLAGS

cd "$SRC"
OBJ="$SRC/mayhem/obj"
mkdir -p "$OBJ"

FUZZERS="compress_fuzzer decompress_fuzzer round_trip_fuzzer round_trip_stream_fuzzer
 compress_hc_fuzzer round_trip_hc_fuzzer compress_frame_fuzzer compress_frame_stream_fuzzer
 round_trip_frame_fuzzer round_trip_frame_uncompressed_fuzzer decompress_frame_fuzzer file_fuzzer"

# fuzzer-no-link: SanCov-instrument the library too (SANITIZER_FLAGS carries no coverage flags).
# -DLZ4_DEBUG=1 and the XXH/FUZZING defines mirror ossfuzz/Makefile.
FUZZ_CFLAGS="$SANITIZER_FLAGS $DEBUG_FLAGS -fsanitize=fuzzer-no-link -O1 -DLZ4_DEBUG=1 -DXXH_NAMESPACE=LZ4_ -DFUZZING_BUILD_MODE_UNSAFE_FOR_PRODUCTION -I$SRC/lib -I$SRC/ossfuzz"

# 1) sanitized library + shared helpers, in a build dir separate from upstream's own objects
for f in lz4 lz4hc lz4frame lz4file xxhash; do
  $CC $FUZZ_CFLAGS -c "$SRC/lib/$f.c" -o "$OBJ/$f.o"
done
for f in lz4_helpers fuzz_data_producer; do
  $CC $FUZZ_CFLAGS -c "$SRC/ossfuzz/$f.c" -o "$OBJ/$f.o"
done
$CXX $SANITIZER_FLAGS $DEBUG_FLAGS -c "$SRC/mayhem/lsan_off.cc" -o "$OBJ/lsan_off.o"
$CC $SANITIZER_FLAGS $DEBUG_FLAGS -x c -c "$STANDALONE_FUZZ_MAIN" -o "$OBJ/standalone_main.o"
COMMON="$OBJ/lz4.o $OBJ/lz4hc.o $OBJ/lz4frame.o $OBJ/lz4file.o $OBJ/xxhash.o $OBJ/lz4_helpers.o $OBJ/fuzz_data_producer.o $OBJ/lsan_off.o"

# 2) every harness, fuzzer + standalone reproducer
for t in $FUZZERS; do
  $CC $FUZZ_CFLAGS -c "$SRC/ossfuzz/$t.c" -o "$OBJ/$t.o"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS $LIB_FUZZING_ENGINE "$OBJ/$t.o" $COMMON -o "$SRC/$t"
  $CXX $SANITIZER_FLAGS $DEBUG_FLAGS "$OBJ/$t.o" "$OBJ/standalone_main.o" $COMMON -o "$SRC/$t-standalone"
done

# 3) the project's own suite, NORMAL flags (upstream's Makefiles write to programs/, tests/, .cache/)
env -u CFLAGS -u CXXFLAGS -u LDFLAGS make -C programs -j"$MAYHEM_JOBS" lz4 CC="$CC" CFLAGS="-O2 $COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS"
env -u CFLAGS -u CXXFLAGS -u LDFLAGS make -C tests -j"$MAYHEM_JOBS" unittest CC="$CC" CFLAGS="-O2 $COVERAGE_FLAGS" LDFLAGS="$COVERAGE_FLAGS"
test -x programs/lz4 && test -x tests/unittest
