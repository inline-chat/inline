#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"
UPLOAD_SCRIPT="$REPO_ROOT/scripts/apple/ci_post_xcodebuild.sh"

if [ ! -x "$UPLOAD_SCRIPT" ]; then
  echo "error: missing executable Sentry dSYM upload hook at $UPLOAD_SCRIPT" >&2
  exit 1
fi

exec "$UPLOAD_SCRIPT"
