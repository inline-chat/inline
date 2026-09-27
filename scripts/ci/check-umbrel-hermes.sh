#!/usr/bin/env bash
# CI only: starts the real Umbrel image. Do not run Docker on developer Macs.
# Argument: candidate Inline executable, --plugin-only, or absent for latest CLI.
# No account, bot token, model provider, published ports, or production volume.
set -euo pipefail
cd "$(dirname "$0")/../.."
image='ghcr.io/getumbrel/hermes-agent-umbrel:v2026.9.14@sha256:140e9c83db48ab435f83335f2060bab2f6e16e4622b388b82f6e24eeea37bdf1'
container="inline-umbrel-${GITHUB_RUN_ID:-local}-${RANDOM}"
cleanup() { docker rm -f -v "$container" >/dev/null 2>&1 || true; }
trap cleanup EXIT
# Preserve /init and the app's s6 tree; overriding ENTRYPOINT would miss Umbrel's
# permissions, profile, and service-manager behavior. The scratch volume is new.
docker run --detach --name "$container" "$image" sleep infinity >/dev/null
for attempt in {1..60}; do
  if docker exec --user hermes "$container" test -w /opt/data/home; then break; fi
  sleep 2
done
docker exec --user hermes "$container" test -w /opt/data/home
docker exec --user hermes "$container" mkdir -p /tmp/inline-smoke/scripts/ci /tmp/inline-smoke/plugins/hermes-agent/plugin/inline/sidecar /opt/data/.local/bin
# Copy only the explicit public test inputs, never the workspace or environment.
for file in __init__.py adapter.py cli.py tools.py message_actions.py telemetry.py plugin.yaml README.md LICENSE sidecar/index.mjs; do
  docker cp "plugins/hermes-agent/plugin/inline/$file" "$container:/tmp/inline-smoke/plugins/hermes-agent/plugin/inline/$file"
done
for file in check-hermes-source.mjs check-hermes-host.py check-hermes-admission.mjs; do
  docker cp "scripts/ci/$file" "$container:/tmp/inline-smoke/scripts/ci/$file"
done
docker cp cli/install.sh "$container:/tmp/inline-smoke/install.sh"
if [[ -n "${HERMES_ARTIFACT:-}" ]]; then
  docker cp "$HERMES_ARTIFACT" "$container:/tmp/inline-smoke/hermes-candidate.tgz"
fi
if [[ -n "${1:-}" && "${1:-}" != --plugin-only ]]; then
  docker cp "$1" "$container:/tmp/inline-smoke/inline-candidate"
fi
# docker cp creates root-owned files. Keep the sealed Hermes tree untouched;
# only our disposable inputs need changing ownership.
docker exec "$container" chown -R hermes:hermes /tmp/inline-smoke
docker exec --user hermes -e HOME=/opt/data/home -e INLINE_PLUGIN_TELEMETRY=0 -e DO_NOT_TRACK=1 -e "INLINE_SMOKE_MODE=${1:-latest}" \
  -w /tmp/inline-smoke "$container" bash -euc '
  test "$HERMES_HOME" = /opt/data
  test "$(id -u)" = 1000
  python -c "from hermes_cli.service_manager import detect_service_manager; assert detect_service_manager() == \"s6\""
  hermes --version
  node --version
  if test "$INLINE_SMOKE_MODE" != --plugin-only; then
    if test -f /tmp/inline-smoke/inline-candidate; then
      install -m 755 /tmp/inline-smoke/inline-candidate /opt/data/.local/bin/inline
    else
      INLINE_INSTALL_DIR=/opt/data/.local/bin sh /tmp/inline-smoke/install.sh
    fi
    inline --version
    inline auth --help
    inline agents --help
    inline agents setup --help
    inline capabilities --json > /tmp/inline-smoke/capabilities.json
    inline agents discover --json > /tmp/inline-smoke/discovery.json
    python -c "import json; d=json.load(open(\"/tmp/inline-smoke/discovery.json\")); assert any(t[\"id\"] == \"hermes\" and t[\"installed\"] for t in d[\"targets\"])"
  else
    echo "Plugin-only admission: CLI release smoke runs separately with the candidate binary."
  fi
  # Admission of the exact release artifact, or published latest on CLI gates.
  if test -f /tmp/inline-smoke/hermes-candidate.tgz; then
    node scripts/ci/check-hermes-admission.mjs --artifact /tmp/inline-smoke/hermes-candidate.tgz "$(command -v hermes)" "$(command -v python)"
  else
    node scripts/ci/check-hermes-admission.mjs --latest "$(command -v hermes)" "$(command -v python)"
  fi
  # Candidate plugin, real native admission + offline message/sidecar transport.
  node scripts/ci/check-hermes-source.mjs plugins/hermes-agent/plugin/inline "$(command -v hermes)" "$(command -v python)"
  # Require the exact runtime-status API used by setup before claiming this
  # image is compatible. A missing/older API must fail, never imply readiness.
  python -c "import importlib.util; s=importlib.util.spec_from_file_location(\"inline_smoke_cli\", \"plugins/hermes-agent/plugin/inline/cli.py\"); m=importlib.util.module_from_spec(s); s.loader.exec_module(m); r=m._gateway_status(); assert r[\"supported\"] is True, r; assert r[\"ready\"] is False, r"
  # Current s6 Hermes accepts install without attempting a host systemd service.
  hermes gateway install --no-start-now
  '
printf 'Umbrel admission passed (%s): %s\n' "${1:-latest CLI}" "$image"
