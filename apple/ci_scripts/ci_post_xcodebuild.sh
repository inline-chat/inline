#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
UPLOAD_SCRIPT="$SCRIPT_DIR/ios-post-xcodebuild.sh"

if [ ! -x "$UPLOAD_SCRIPT" ]; then
  echo "warning: missing bundled Sentry dSYM upload hook at $UPLOAD_SCRIPT; continuing Xcode Cloud build" >&2
  exit 0
fi

if ! "$UPLOAD_SCRIPT"; then
  echo "warning: Sentry dSYM upload hook failed; continuing Xcode Cloud build" >&2
fi

exit 0
