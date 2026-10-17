#!/bin/sh
# Root-owned installed path; the dedicated authorized_keys entry uses `restrict`
# and this command only. Never authorize a personal/root shell key in Actions.
set -eu
test "$#" = 0
test "${SSH_ORIGINAL_COMMAND:-}" = inline-standby-release-v1
test -z "${SSH_TTY:-}"
exec /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin \
  /usr/bin/systemd-run --quiet --pipe --wait --collect \
  --property=Type=exec --property=RuntimeMaxSec=800 --property=TimeoutStopSec=15 \
  --property=KillMode=control-group --property=UMask=0077 --property=LimitCORE=0 \
  --property=MemoryMax=256M --property=MemorySwapMax=0 --property=CPUQuota=50% \
  --property=TasksMax=32 --property=NoNewPrivileges=yes \
  --setenv=SSH_ORIGINAL_COMMAND=inline-standby-release-v1 \
  /usr/bin/python3 -I /usr/local/libexec/inline-standby-release --execute
