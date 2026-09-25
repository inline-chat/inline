# Input: `flyctl machine list --json` (fly-go Machine[]).
# Output contains no Machine environment, check output, or credentials.
def require($valid; $message):
  if $valid then . else error($message) end;

require(type == "array"; "Expected a Fly Machine list") |
map(select(.state != "destroyed")) |
# An unreachable host can omit config: it must not disappear from baseline.
require(all(.[]; .host_status == "ok" and (.config | type) == "object");
  "Cannot establish a complete Machine baseline") |
# Same-app dark Machines have no services. Every public Machine must be a
# supported managed app Machine; Fly can silently skip detached Machines.
map(select((.config.services // [] | length) > 0)) |
require(length > 0; "No existing public Machines") |
require(all(.[];
  .config.metadata.fly_platform_version == "v2" and
  .config.metadata.fly_process_group == "app" and
  (.config.mounts // [] | length) == 0 and
  all(.config.services[]; .internal_port == 8000));
  "Public Machines must be managed app Machines on port 8000 without volumes") |
require(all(.[];
  .state == "started" and .cordoned == false and
  any(.config.services[]; any(.checks[]?; .path == "/readyz")) and
  (.checks | length) > 0 and all(.checks[]; .status == "passing"));
  "Public Machines must be started, uncordoned, and passing readiness checks") |
require(all(.[]; (.id | type) == "string" and (.id | test("^[a-z0-9]+$")) and
  (.image_ref.digest | type) == "string" and (.image_ref.digest | test("^sha256:[a-f0-9]{64}$")));
  "Public Machine identity or image digest is unavailable") |
# Fly bluegreen rejects mixed repository/tag/fly.version combinations. Digest
# equality also prevents a moved tag from concealing multiple deployed images.
require((map(.image_ref | {repository, tag, digest, version: .labels["fly.version"], revision: .labels["org.opencontainers.image.revision"]}) | unique | length) == 1;
  "Public Machines must run one existing image before release") |
require((map(.id) | unique | length) == length; "Duplicate Machine identity") |
{
  count: length,
  ids: (map(.id) | sort | join(",")),
  digest: .[0].image_ref.digest,
  revision: .[0].image_ref.labels["org.opencontainers.image.revision"]
}
