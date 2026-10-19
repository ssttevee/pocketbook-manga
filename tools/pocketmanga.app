#!/bin/sh
ROOT=/mnt/ext1/applications/pocketmanga
# UI uses the firmware loader/libc and the firmware InkView libraries.
unset LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT
export GLIBC_TUNABLES="${GLIBC_TUNABLES:+$GLIBC_TUNABLES:}glibc.rtld.execstack=2"
exec "$ROOT/bin/pocketmanga" "$ROOT"
