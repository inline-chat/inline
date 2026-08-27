#!/bin/bash
set -euo pipefail

export PATH="/opt/homebrew/bin:/usr/local/bin:$PATH"

usage() {
  cat <<'EOF'
Usage: scripts/apple/upload-dsyms.sh [options]

Options:
  --archive-path <path>  Path to an .xcarchive bundle. Uploads dSYMs from <path>/dSYMs.
  --search-root <path>   Directory to scan recursively for .dSYM bundles.
  --required-dsym <name> Require a named dSYM bundle, such as InlineIOS.app.dSYM.
  --org <slug>           Sentry org slug. Default: usenoor
  --project <slug>       Sentry project slug. Default: inline-ios-macos
  --api-url <url>        Sentry base URL. Default: https://us.sentry.io
  --dry-run              Print the dSYM bundles that would be uploaded.
  --help                 Show this help text.
EOF
}

archive_path=""
search_root=""
required_dsym=""
auth_token="${SENTRY_AUTH_TOKEN:-}"
org="${SENTRY_ORG:-usenoor}"
project="${SENTRY_PROJECT:-inline-ios-macos}"
api_url="${SENTRY_API_URL:-https://us.sentry.io}"
dry_run=0

while [ "$#" -gt 0 ]; do
  case "$1" in
    --archive-path)
      archive_path="${2:-}"
      shift 2
      ;;
    --search-root)
      search_root="${2:-}"
      shift 2
      ;;
    --required-dsym)
      required_dsym="${2:-}"
      shift 2
      ;;
    --org)
      org="${2:-}"
      shift 2
      ;;
    --project)
      project="${2:-}"
      shift 2
      ;;
    --api-url)
      api_url="${2:-}"
      shift 2
      ;;
    --dry-run)
      dry_run=1
      shift
      ;;
    --help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown argument: $1" >&2
      usage >&2
      exit 1
      ;;
  esac
done

if [ -n "$archive_path" ] && [ -n "$search_root" ]; then
  echo "Pass either --archive-path or --search-root, not both." >&2
  exit 1
fi

if [ -n "$archive_path" ]; then
  search_root="$archive_path/dSYMs"
fi

if [ -z "$search_root" ]; then
  if [ -n "${CI_ARCHIVE_PATH:-}" ]; then
    search_root="$CI_ARCHIVE_PATH/dSYMs"
  elif [ -n "${DWARF_DSYM_FOLDER_PATH:-}" ]; then
    search_root="$DWARF_DSYM_FOLDER_PATH"
  else
    echo "Missing dSYM location. Pass --archive-path/--search-root or set CI_ARCHIVE_PATH." >&2
    exit 1
  fi
fi

if [ ! -d "$search_root" ]; then
  echo "dSYM search root does not exist: $search_root" >&2
  exit 1
fi

if [ -n "$required_dsym" ] && ! find "$search_root" -type d -name "$required_dsym" -print -quit | grep -q .; then
  echo "Required dSYM bundle was not found under $search_root: $required_dsym" >&2
  exit 1
fi

if [ -z "$auth_token" ] && [ "$dry_run" -ne 1 ] && command -v sentry >/dev/null 2>&1; then
  auth_token="$(sentry auth token 2>/dev/null | tr -d '\r' | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
fi

if [ -z "$auth_token" ] && [ "$dry_run" -ne 1 ]; then
  echo "Missing Sentry auth. Set SENTRY_AUTH_TOKEN or log in with the modern \`sentry\` CLI." >&2
  exit 1
fi

if ! command -v curl >/dev/null 2>&1; then
  echo "curl is required." >&2
  exit 1
fi

if ! command -v ditto >/dev/null 2>&1; then
  echo "ditto is required." >&2
  exit 1
fi

tmp_dir=""
if [ "$dry_run" -ne 1 ]; then
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/inline-sentry-dsyms.XXXXXX")"
fi

sentry_curl() {
  printf 'Authorization: Bearer %s\n' "$auth_token" | curl --header @- "$@"
}

verify_uuid() {
  local uuid="$1"
  local normalized_uuid
  local attempt=1
  local response
  local normalized_response
  normalized_uuid="$(printf '%s' "$uuid" | tr '[:upper:]' '[:lower:]' | tr -d '-')"
  while [ "$attempt" -le 6 ]; do
    if response="$(sentry_curl --fail-with-body --silent --show-error --get \
      "$api_url/api/0/projects/$org/$project/files/dsyms/" \
      --data-urlencode "query=$uuid")"; then
      normalized_response="$(printf '%s' "$response" | tr '[:upper:]' '[:lower:]' | tr -d '-')"
      if printf '%s' "$normalized_response" | grep -q "$normalized_uuid"; then
        echo "Verified $uuid"
        return 0
      fi
    fi
    if [ "$attempt" -lt 6 ]; then
      sleep 2
    fi
    attempt=$((attempt + 1))
  done
  echo "Sentry did not expose uploaded dSYM UUID $uuid after 12 seconds" >&2
  return 1
}

count=0

while IFS= read -r -d '' dsym; do
  base_name="$(basename "$dsym")"
  uuids=""

  if command -v xcrun >/dev/null 2>&1; then
    if ! uuids="$(xcrun dwarfdump --uuid "$dsym" 2>&1)"; then
      echo "Failed to read UUIDs from $dsym: $uuids" >&2
      exit 1
    fi
    echo "$base_name UUIDs:"
    echo "$uuids"
  fi

  if [ "$dry_run" -eq 1 ]; then
    echo "Would upload $base_name to $org/$project"
    count=$((count + 1))
    continue
  fi

  echo "Uploading $base_name to $org/$project"
  zip_path="$tmp_dir/$base_name.zip"
  ditto -c -k --sequesterRsrc --keepParent "$dsym" "$zip_path"

  sentry_curl --fail-with-body --silent --show-error \
    -X POST \
    -F "file=@$zip_path;type=application/zip" \
    "$api_url/api/0/projects/$org/$project/files/dsyms/" >/dev/null

  if [ -n "$uuids" ]; then
    printf '%s\n' "$uuids" | awk '/UUID:/ { print $2 }' | while IFS= read -r uuid; do
      verify_uuid "$uuid"
    done
  fi

  count=$((count + 1))
done < <(find "$search_root" -type d -name '*.dSYM' -print0)

if [ "$count" -eq 0 ]; then
  echo "No .dSYM bundles found under $search_root" >&2
  exit 1
fi

if [ "$dry_run" -eq 1 ]; then
  echo "Found $count dSYM bundle(s) under $search_root"
else
  echo "Uploaded $count dSYM bundle(s) from $search_root"
  echo "Upload archives retained at $tmp_dir"
fi
