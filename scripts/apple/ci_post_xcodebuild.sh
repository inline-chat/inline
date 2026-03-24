#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
REPO_ROOT="$(CDPATH= cd -- "$SCRIPT_DIR/.." && pwd)"

if [ "${CI_XCODEBUILD_ACTION:-}" != "archive" ]; then
  echo "Skipping Sentry dSYM upload because CI_XCODEBUILD_ACTION=${CI_XCODEBUILD_ACTION:-unset}"
  exit 0
fi

if [ -z "${CI_ARCHIVE_PATH:-}" ]; then
  echo "Skipping Sentry dSYM upload because CI_ARCHIVE_PATH is not set"
  exit 0
fi

if [ -z "${SENTRY_AUTH_TOKEN:-}" ]; then
  echo "Skipping Sentry dSYM upload because SENTRY_AUTH_TOKEN is not set"
  exit 0
fi

"$REPO_ROOT/scripts/apple/upload-dsyms.sh" \
  --search-root "$CI_ARCHIVE_PATH/dSYMs" \
  --org "${SENTRY_ORG:-usenoor}" \
  --project "${SENTRY_PROJECT:-inline-ios-macos}" \
  --api-url "${SENTRY_API_URL:-https://us.sentry.io}"
