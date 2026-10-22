#!/usr/bin/env bash
# Writes the outcome line every release workflow ends with, so a green run that
# shipped nothing never reads like a new release.
# Usage: release-summary.sh <surface> <outcome> [reason] [source-sha] [detail]
set -euo pipefail

surface="${1:?surface}"
outcome="${2:?outcome}"
reason="${3:-}"
sha="${4:-}"
detail="${5:-}"

case "$outcome" in
  published) label="Published" ;;
  already-current) label="Already current" ;;
  deferred) label="Deferred" ;;
  blocked) label="Blocked" ;;
  failed) label="Failed" ;;
  *) echo "Unknown release outcome: $outcome" >&2; exit 1 ;;
esac

line="$surface: $label"
[[ -n "$reason" ]] && line+=" — $reason"
[[ -n "$sha" ]] && line+=" (${sha:0:9})"

{
  printf '### %s\n\n' "$line"
  [[ -n "$sha" ]] && printf -- '- Source: `%s`\n' "$sha"
  [[ -n "$detail" ]] && printf -- '- %s\n' "$detail"
  printf '\n'
} >> "${GITHUB_STEP_SUMMARY:-/dev/null}"

# Annotations show on the run page without opening logs.
if [[ "$outcome" == failed || "$outcome" == blocked ]]; then
  echo "::error title=$surface $label::$line"
else
  echo "::notice title=$surface $label::$line"
fi
