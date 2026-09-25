# $predecessor is the explicit old serving Machine ID. Read-only worker fence.
# fly-go MachineService exposes the boolean as `autostart`, not fly.toml's name.
def require($valid; $message): if $valid then . else error($message) end;
require(type == "array"; "Expected a predecessor Machine list") |
map(select(.state != "destroyed")) |
require(any(.[]; .id == $predecessor); "Expected predecessor Machine is missing") |
require(all(.[]; .host_status == "ok" and (.config | type) == "object" and .state == "stopped");
  "Every predecessor Machine, including detached workers, must be observed stopped") |
require(all(.[]; all(.config.services[]?; .autostart == false));
  "Predecessor services must explicitly disable autostart before worker activation") |
true
