#!/bin/sh
export GLIBC_TUNABLES="${GLIBC_TUNABLES:+$GLIBC_TUNABLES:}glibc.rtld.execstack=2"
exec /mnt/ext1/applications/pocketmanga.app "$@" >> /mnt/ext1/applications/pocketmanga.log 2>&1
