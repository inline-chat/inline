# Input: `flyctl machine list --json` (fly-go Machine[]).
# Rollback inventory: the release fleet filter without its health requirement.
# rollback_to_plan replaces whatever public Machines exist, including ones a bad
# release left failing readiness; the post-deploy wait still requires passing
# checks. Output contains no Machine environment, check output, or credentials.
def require($valid; $message):
  if $valid then . else error($message) end;

require(type == "array"; "Expected a Fly Machine list") |
map(select(.state != "destroyed")) |
require(all(.[]; .host_status == "ok" and (.config | type) == "object");
  "Cannot establish a complete Machine inventory") |
map(select((.config.services // [] | length) > 0)) |
require(length > 0; "No existing public Machines") |
require(all(.[];
  .config.metadata.fly_platform_version == "v2" and
  .config.metadata.fly_process_group == "app" and
  (.config.mounts // [] | length) == 0 and
  all(.config.services[]; .internal_port == 8000));
  "Public Machines must be managed app Machines on port 8000 without volumes") |
require(all(.[]; (.id | type) == "string" and (.id | test("^[a-z0-9]+$")) and
  (.image_ref.digest | type) == "string" and (.image_ref.digest | test("^sha256:[a-f0-9]{64}$")));
  "Public Machine identity or image digest is unavailable") |
# Fly bluegreen rejects mixed repository/tag/fly.version combinations.
require((map(.image_ref | {repository, tag, digest, version: .labels["fly.version"], revision: .labels["org.opencontainers.image.revision"]}) | unique | length) == 1;
  "Public Machines run more than one image; reconcile the fleet before rolling back") |
require((map(.id) | unique | length) == length; "Duplicate Machine identity") |
{
  count: length,
  ids: (map(.id) | sort | join(",")),
  digest: .[0].image_ref.digest,
  revision: .[0].image_ref.labels["org.opencontainers.image.revision"]
}
