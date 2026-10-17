#!/usr/bin/env bash
# Ephemeral runner only. Export the exact already-qualified ARM manifest; no build.
set -euo pipefail
umask 077
test "${STANDBY_SYNC_ENABLED:-}" = true
[[ "$STANDBY_IMAGE" =~ ^registry\.fly\.io/inline-api@sha256:[a-f0-9]{64}$ ]]
test -n "$FLY_API_TOKEN"
archive=$1
authdir=$(mktemp -d "$RUNNER_TEMP/standby-registry-XXXXXX")
trap 'rm -rf "$authdir"' EXIT
# Auth file is private to this ephemeral runner and never enters the image stream.
printf '%s' "$FLY_API_TOKEN" | skopeo login --authfile "$authdir/auth.json" --username x --password-stdin registry.fly.io >/dev/null 2>&1
timeout --signal=KILL 180s skopeo copy --authfile "$authdir/auth.json" --preserve-digests \
  "docker://$STANDBY_IMAGE" "oci-archive:$archive:release" >/dev/null 2>&1
