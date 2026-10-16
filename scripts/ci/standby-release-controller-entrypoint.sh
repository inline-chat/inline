#!/bin/sh
# Finland only; root-owned. authorized_keys: from="91.107.255.57",restrict,
# command="/usr/local/libexec/inline-standby-controller-entrypoint"
set -eu
test "$#" = 0
test "${SSH_ORIGINAL_COMMAND:-}" = inline-standby-controller-v1
test -z "${SSH_TTY:-}"
exec /usr/bin/env -i PATH=/usr/sbin:/usr/bin:/sbin:/bin \
  /usr/bin/systemd-run --quiet --pipe --wait --collect \
  --property=Type=exec --property=RuntimeMaxSec=70 --property=TimeoutStopSec=5 \
  --property=KillMode=control-group --property=UMask=0077 --property=LimitCORE=0 \
  --property=MemoryMax=64M --property=MemorySwapMax=0 --property=CPUQuota=20% \
  --property=TasksMax=8 --property=NoNewPrivileges=yes \
  --property=LoadCredentialEncrypted=coolify:/etc/credstore.encrypted/inline-standby-coolify \
  --setenv=SSH_ORIGINAL_COMMAND=inline-standby-controller-v1 \
  /usr/bin/python3 -I /usr/local/libexec/inline-standby-controller --execute
