#!/bin/sh
exec >> /mnt/ext1/applications/pocketmanga.log 2>&1
printf '\nPocketManga launcher diagnostics\n'
ls -l /bin/sh /bin/ash /mnt/ext1/applications/pocketmanga.app /mnt/ext1/applications/pocketmanga/bin/pocketmanga
# The firmware already selected a shell for this entry. Reuse it rather than
# asking exec to resolve the normal launcher's shebang interpreter again.
. /mnt/ext1/applications/pocketmanga.app
