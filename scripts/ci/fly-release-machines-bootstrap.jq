# Bootstrap requires a fully observed, stopped, service-free target app.
# The snapshot must match again after DDL and before creating the first API.
def require($valid; $message): if $valid then . else error($message) end;
require(type == "array"; "Expected a Fly Machine list") |
map(select(.state != "destroyed")) |
require(all(.[]; .host_status == "ok" and (.config | type) == "object" and
  .state == "stopped" and (.config.services // [] | length) == 0 and
  .config.metadata.fly_platform_version != "v2");
  "Bootstrap requires every existing Machine stopped, observable, service-free, and unmanaged") |
require(all(.[]; (.id | type) == "string" and (.id | test("^[a-z0-9]+$")) and
  (.version | type) == "string" and (.version | length) > 0);
  "Bootstrap Machine ID or version is unavailable") |
require((map(.id) | unique | length) == length; "Duplicate Machine identity") |
sort_by(.id) |
{ids: (map(.id) | join(",")), machines: map({id, version})}
