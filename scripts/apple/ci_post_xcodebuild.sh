#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/../.." && pwd)"

if [ "${CI_XCODEBUILD_ACTION:-}" != "archive" ]; then
  echo "Skipping Sentry dSYM upload because CI_XCODEBUILD_ACTION=${CI_XCODEBUILD_ACTION:-unset}"
  exit 0
fi

if [ -z "${CI_ARCHIVE_PATH:-}" ]; then
  echo "error: CI_ARCHIVE_PATH is required to upload archive dSYMs to Sentry" >&2
  exit 1
fi

if [ -z "${SENTRY_AUTH_TOKEN:-}" ]; then
  echo "error: SENTRY_AUTH_TOKEN is required for Xcode Cloud archive symbol uploads" >&2
  exit 1
fi

"$REPO_ROOT/scripts/apple/upload-dsyms.sh" \
  --search-root "$CI_ARCHIVE_PATH/dSYMs" \
  --required-dsym "InlineIOS.app.dSYM" \
  --org "${SENTRY_ORG:-usenoor}" \
  --project "${SENTRY_PROJECT:-inline-ios-macos}" \
  --api-url "${SENTRY_API_URL:-https://us.sentry.io}"
