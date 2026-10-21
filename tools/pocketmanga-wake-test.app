#!/bin/sh
ROOT=/mnt/ext1/applications/pocketmanga
unset LD_LIBRARY_PATH LD_PRELOAD LD_AUDIT
exec "$ROOT/bin/pocketmanga-wake-probe" >"$ROOT/wake-test.log" 2>&1
