#!/usr/bin/env bash
# Provision a Claude Code cloud (Linux) environment for Inline.
# Covers server, packages, plugins, landing and the Rust CLI. Apple targets need macOS.
# Idempotent: safe to run on every session start.
set -euo pipefail

BUN_VERSION="1.4.0"
PG_MAJOR="15"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
SUDO=""; [ "$(id -u)" -ne 0 ] && SUDO="sudo"

# Bun, pinned to the CI version.
if ! command -v bun >/dev/null || [ "$(bun --version)" != "$BUN_VERSION" ]; then
  curl -fsSL https://bun.sh/install | bash -s "bun-v$BUN_VERSION"
fi
export PATH="$HOME/.bun/bin:$PATH"

# PostgreSQL 15 to match CI, from the PGDG apt repo.
if ! command -v "/usr/lib/postgresql/$PG_MAJOR/bin/postgres" >/dev/null; then
  $SUDO apt-get update -qq
  $SUDO apt-get install -y -qq curl ca-certificates gnupg lsb-release
  curl -fsSL https://www.postgresql.org/media/keys/ACCC4CF8.asc | $SUDO gpg --dearmor --yes -o /usr/share/keyrings/pgdg.gpg
  echo "deb [signed-by=/usr/share/keyrings/pgdg.gpg] https://apt.postgresql.org/pub/repos/apt $(lsb_release -cs)-pgdg main" \
    | $SUDO tee /etc/apt/sources.list.d/pgdg.list >/dev/null
  $SUDO apt-get update -qq
  $SUDO apt-get install -y -qq "postgresql-$PG_MAJOR"
fi
$SUDO service postgresql start || $SUDO pg_ctlcluster "$PG_MAJOR" main start
$SUDO -u postgres psql -qc "ALTER USER postgres PASSWORD 'postgres';"

# Rust toolchain from rust-toolchain.toml.
if ! command -v rustup >/dev/null; then
  curl -fsSL https://sh.rustup.rs | sh -s -- -y --profile minimal --default-toolchain none
fi
export PATH="$HOME/.cargo/bin:$PATH"
(cd "$ROOT" && rustup show active-toolchain >/dev/null)

(cd "$ROOT" && bun install --frozen-lockfile)

# Test-only database; the server test runner refuses remote hosts.
if [ -n "${CLAUDE_ENV_FILE:-}" ]; then
  {
    echo "export PATH=\"$HOME/.bun/bin:$HOME/.cargo/bin:\$PATH\""
    echo "export TEST_DATABASE_URL=postgres://postgres:postgres@127.0.0.1:5432/postgres"
  } >> "$CLAUDE_ENV_FILE"
fi
