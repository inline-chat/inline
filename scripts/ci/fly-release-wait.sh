#!/usr/bin/env bash
# Fly immediate deployment can return while the Machine is still being created.
# Bound both each provider read and the whole readiness poll; emit no inventory.
set -euo pipefail
inventory=$1
count=$2
digest=$3
revision=$4
for attempt in {1..30}; do
  if timeout --signal=KILL 5s flyctl machine list --config server/fly.toml --json > "$inventory" 2>/dev/null &&
    current=$(jq -ce -f scripts/ci/fly-release-machines.jq "$inventory" 2>/dev/null) &&
    jq -e --argjson count "$count" --arg digest "$digest" --arg revision "$revision" \
      '.count == $count and .digest == $digest and .revision == $revision' <<< "$current" > /dev/null; then
    exit 0
  fi
  if [[ "$attempt" != 30 ]]; then sleep 5; fi
done
echo 'Timed out waiting for the expected image and healthy public Machines' >&2
exit 1
