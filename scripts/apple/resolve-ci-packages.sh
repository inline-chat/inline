#!/usr/bin/env bash
set -euo pipefail

if [[ $# -ne 4 ]]; then
  echo 'usage: resolve-ci-packages.sh project scheme derived-data log-path' >&2
  exit 2
fi

project="$1"
scheme="$2"
derived_data="$3"
log_path="$4"
mkdir -p "$(dirname "$log_path")"

# Retry only resolution; compilation errors must still fail on the first build.
for attempt in 1 2 3; do
  echo "Resolving $scheme packages (attempt $attempt/3)"
  if xcodebuild \
    -project "$project" \
    -scheme "$scheme" \
    -derivedDataPath "$derived_data" \
    -resolvePackageDependencies 2>&1 | tee -a "$log_path"; then
    exit 0
  fi
  if [[ "$attempt" == 3 ]]; then
    echo "error: $scheme package resolution failed after three attempts" >&2
    exit 1
  fi
  sleep "$((attempt * 5))"
done
