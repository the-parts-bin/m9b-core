#!/usr/bin/env bash
# Builds midirender (and libADLMIDI, fetched the first time) into build/.
# Needs git, cmake and a C/C++ compiler.
set -euo pipefail
HERE=$(dirname "$(realpath "$0")")
B=$HERE/build
LIB=$B/libADLMIDI
mkdir -p "$B"
# libADLMIDI's master of 2026-10-16: the renders the ports were tested with
# (another version can change them).
COMMIT=ef98fab8c36f5f9324be9cc6b98af7c1f701cc60
if [ ! -e "$LIB/build/libADLMIDI.a" ] || [ "$(git -C "$LIB" rev-parse HEAD 2>/dev/null)" != $COMMIT ]; then
    rm -rf "$LIB"
    git init -q "$LIB"
    git -C "$LIB" fetch -q --depth 1 https://github.com/Wohlstand/libADLMIDI.git $COMMIT
    git -C "$LIB" checkout -q FETCH_HEAD
    cmake -S "$LIB" -B "$LIB/build" -DCMAKE_BUILD_TYPE=Release -DUSE_NUKED_EMULATOR=ON \
          -DlibADLMIDI_SHARED=OFF -DlibADLMIDI_STATIC=ON >/dev/null
    cmake --build "$LIB/build" -j"$(nproc)" --target ADLMIDI_static >/dev/null
fi
cc -O2 -Wall "$HERE/midirender.c" -I"$LIB/include" "$LIB/build/libADLMIDI.a" -lstdc++ -lm -o "$B/midirender"
echo "$B/midirender"
