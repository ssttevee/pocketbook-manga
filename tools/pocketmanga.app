#!/bin/sh
ROOT=/mnt/ext1/applications/pocketmanga
export JAVA_HOME="$ROOT/runtime/jre"
export LD_LIBRARY_PATH="$ROOT/runtime/lib:$JAVA_HOME/lib:$JAVA_HOME/lib/server${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export GLIBC_TUNABLES="${GLIBC_TUNABLES:+$GLIBC_TUNABLES:}glibc.rtld.execstack=2"
exec "$ROOT/bin/pocketmanga" "$ROOT"
