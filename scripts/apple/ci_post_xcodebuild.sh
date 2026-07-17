#!/bin/sh
set -eu

SCRIPT_DIR="$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)"
UPLOAD_SCRIPT="$SCRIPT_DIR/upload-dsyms.sh"

if [ "${CI_XCODEBUILD_ACTION:-}" != "archive" ]; then
  echo "Skipping Sentry dSYM upload because CI_XCODEBUILD_ACTION=${CI_XCODEBUILD_ACTION:-unset}"
  exit 0
fi

if [ "${CI_PRODUCT_PLATFORM:-}" != "iOS" ]; then
  echo "Skipping iOS Sentry dSYM upload because CI_PRODUCT_PLATFORM=${CI_PRODUCT_PLATFORM:-unset}"
  exit 0
fi

if [ -z "${CI_ARCHIVE_PATH:-}" ]; then
  echo "warning: CI_ARCHIVE_PATH is unavailable; skipping Sentry dSYM upload" >&2
  exit 0
fi

if [ -z "${SENTRY_AUTH_TOKEN:-}" ]; then
  echo "warning: SENTRY_AUTH_TOKEN is unavailable; skipping Sentry dSYM upload" >&2
  exit 0
fi

if [ ! -x "$UPLOAD_SCRIPT" ]; then
  echo "warning: missing executable dSYM uploader at $UPLOAD_SCRIPT; skipping Sentry dSYM upload" >&2
  exit 0
fi

if ! "$UPLOAD_SCRIPT" \
  --search-root "$CI_ARCHIVE_PATH/dSYMs" \
  --required-dsym "InlineIOS.app.dSYM" \
  --org "${SENTRY_ORG:-usenoor}" \
  --project "${SENTRY_PROJECT:-inline-ios-macos}" \
  --api-url "${SENTRY_API_URL:-https://us.sentry.io}"; then
  echo "warning: failed to upload iOS dSYMs to Sentry; continuing Xcode Cloud build" >&2
  exit 0
fi

echo "Sentry dSYM upload completed."
