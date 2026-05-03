#!/bin/bash
# SPDX-License-Identifier: Apache-2.0 OR MIT
# Copyright (c) Status Research & Development GmbH 

root=$(dirname "$0")
sources=${root}/libs

rm -f lsquic/lsquic_ffi.nim

# assemble list of C files to be compiled
toCompile=(
  # "${sources}/path/to/file.c"
)

# futhark is required by generate_lsquic_ffi.nim
nimble install futhark@0.15.0

nim c --maxLoopIterationsVM:100000000 generate_lsquic_ffi.nim

cat "${root}/prelude.nim" > lsquic/lsquic_ffi.nim

echo >> lsquic/lsquic_ffi.nim # linebreak

for file in "${toCompile[@]}"; do
    echo "{.compile: \"$file\".}" >> lsquic/lsquic_ffi.nim
done

# correct casing for SockAddr
sed -i 's/Sockaddr/SockAddr/g' tmp_lsquic_ffi.nim

cat tmp_lsquic_ffi.nim >> lsquic/lsquic_ffi.nim

echo >> lsquic/lsquic_ffi.nim # linebreak

cat "${root}/extras.nim" >> lsquic/lsquic_ffi.nim

rm -f tmp_lsquic_ffi.nim