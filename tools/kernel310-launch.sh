#!/bin/sh
# Prefix the shipped UI command with the developer emulator. The worker
# client separately prefixes its loader through POCKETMANGA_WORKER_EMULATOR.
if [ "$1" = /mnt/ext1/applications/pocketmanga-log.app ]; then
    exec /bin/sh "$0" /mnt/ext1/applications/pocketmanga.app >> /mnt/ext1/applications/pocketmanga.log 2>&1
fi
alias exec='command exec /qemu-arm'
. "$1"
