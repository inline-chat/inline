# First bootstrap or resume: unchanged stopped rehearsal cohort and at most one
# healthy, managed API-only Machine. Never adopt a worker-bearing deployment.
def require($valid; $message): if $valid then . else error($message) end;
require(type == "array"; "Expected a Fly Machine list") |
map(select(.state != "destroyed")) |
require(all(.[]; .host_status == "ok" and (.config | type) == "object");
  "Bootstrap requires complete, observable Machine configuration") |
require(all(.[]; (.id | type) == "string" and (.id | test("^[a-z0-9]+$")) and
  (.version | type) == "string" and (.version | length) > 0);
  "Bootstrap Machine ID or version is unavailable") |
require((map(.id) | unique | length) == length; "Duplicate Machine identity") |
map(select((.config.services // [] | length) > 0)) as $api |
require(($api | length) <= 1; "Bootstrap permits at most one existing API") |
require(all($api[];
  .config.metadata.fly_platform_version == "v2" and .config.metadata.fly_process_group == "app" and
  (.config.mounts // [] | length) == 0 and all(.config.services[]; .internal_port == 8000) and
  .config.env.INLINE_PROCESS_ROLE == "api" and .config.env.INLINE_INGRESS_HOST == "api.inline.chat" and
  .config.guest.cpu_kind == "shared" and .config.guest.cpus == 6 and .config.guest.memory_mb == 1536 and
  .state == "started" and .cordoned == false and
  any(.config.services[]; any(.checks[]?; .path == "/readyz")) and
  (.checks | length) > 0 and all(.checks[]; .status == "passing") and
  (.image_ref.digest | type) == "string" and (.image_ref.digest | test("^sha256:[a-f0-9]{64}$")) and
  (.image_ref.labels["org.opencontainers.image.revision"] | type) == "string" and
  (.image_ref.labels["org.opencontainers.image.revision"] | test("^[a-f0-9]{40}$")));
  "Existing bootstrap API must be managed, API-only, correctly sized, and healthy with a known image") |
map(select((.config.services // [] | length) == 0)) |
require(all(.[]; .state == "stopped" and .config.metadata.fly_platform_version != "v2");
  "Bootstrap rehearsal Machines must be stopped, service-free, and unmanaged") |
sort_by(.id) |
{ids: (map(.id) | join(",")), machines: map({id, version})} +
(if ($api | length) == 1 then {api: ($api[0] | {id, version, digest: .image_ref.digest,
  revision: .image_ref.labels["org.opencontainers.image.revision"]})} else {} end)
