#!/usr/bin/env bash
# Opt-in end-to-end check of the legacy V3 upgrade: the real Swift client stack (Auth, transport
# selection, V2 and V3 transports, protocol session, connection manager) against a local server on
# :8000 backed by a throwaway inline_e2e* database. Quit Inline debug apps first; they target :8000.
#
# INLINE_E2E_SWIFT_PACKAGE overrides the Swift package to test (default apple/InlineKit).
set -euo pipefail

ROOT=$(cd "$(dirname "$0")/../.." && pwd)
SERVER="$ROOT/server"
PACKAGE=${INLINE_E2E_SWIFT_PACKAGE:-"$ROOT/apple/InlineKit"}
WORK="$ROOT/.tmp/e2e-legacy-v3"
DATABASE=${INLINE_E2E_DATABASE:-inline_e2e_v3}
export DATABASE_URL="postgres://127.0.0.1:5432/$DATABASE"
export DATABASE_DIRECT_URL="$DATABASE_URL"
export DATABASE_CONNECTION_MODE=direct
export NODE_ENV=development

if lsof -nP -iTCP:8000 -sTCP:LISTEN >/dev/null 2>&1; then
  echo "Port 8000 is in use; stop the dev server first." >&2
  exit 1
fi
if pgrep -f 'Inline Debug.app|2nd Inline' >/dev/null; then
  echo "Quit Inline debug apps first; they would connect to the throwaway server." >&2
  exit 1
fi

mkdir -p "$WORK"
cd "$SERVER"
bun scripts/e2e/legacy-v3-upgrade.ts create-db
bun scripts/migrate.ts
bun scripts/e2e/legacy-v3-upgrade.ts seed "$WORK/fixture.json"
bun scripts/e2e/legacy-v3-upgrade.ts seed "$WORK/fixture-disabled.json"

PORT=8000 bun src/index.ts >"$WORK/server.log" 2>&1 &
SERVER_PID=$!
trap 'kill "$SERVER_PID" 2>/dev/null || true' EXIT
for _ in $(seq 1 60); do
  curl -fs -o /dev/null http://localhost:8000/.well-known/inline-protocol && break
  sleep 1
done

cd "$PACKAGE"
INLINE_E2E_FIXTURE="$WORK/fixture.json" \
  INLINE_E2E_DISABLED_FIXTURE="$WORK/fixture-disabled.json" \
  INLINE_E2E_SERVER_DIR="$SERVER" \
  swift test --filter LegacyV3EndToEndTests "$@"
