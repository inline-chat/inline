# Hetzner standby and Cloudflare proxy bypass

As of October 16, 2026, `api.inline.chat` has a running Nuremberg fallback behind
Cloudflare load balancing, with Fly preferred. Verify current provider inventory
and dated qualification receipts before a change. Finland remains a prepared
third-origin option; this document's three-origin examples do not establish that
it is active or qualified. Keep Cloudflare authoritative DNS. The preferred order is
**Fly → Nuremberg → Finland**: Fly serves normally, Nuremberg is the first
fallback, and the existing Finland host is the second fallback. A second Fly
Machine can later join the same app without another Cloudflare pool.

```text
api.inline.chat — Cloudflare DNS + optional proxy
  normal: Fly app → one healthy API Machine (temporary deployment overlap)
  first fallback: Nuremberg → private API container behind its qualified TLS proxy
  second fallback: existing Finland → Traefik → private API container
  all APIs → same PostgreSQL, object storage and key rings

Cloudflare proxy incident: same hostname, DNS-only A/AAAA → qualified origin
```

Qualify running fallback containers and direct authenticated access before
adding automatic routing. A stopped container is manual recovery capacity.
The [three-origin proposal](../ha/cloudflare-three-origin.example.json) contains
non-secret release intent and Cloudflare request templates with unresolved
identities. It is local data, not an apply script or a live configuration.
Confirm the actual three-origin subscription quote before enabling it. No new
VM, Redis cluster, database replica or failover controller is required for this
option; check the existing hosts' capacity independently.

## Shared-host boundary

The existing Finland host also serves unrelated production applications. Scope
changes to the Inline API resource and its uniquely named Traefik routers,
service and middleware. Preserve shared entrypoints, networks, certificate
storage and other applications. A shared proxy restart or host-level change
requires a separate reviewed operation; it is not part of this rollout.

Build and qualify the appropriate architecture in GitHub Actions, then deploy
the tested image by digest. The current ARM64 Nuremberg and Finland candidates
use the native ARM64 Coolify artifact; verify each host's actual architecture.
Fly uses the amd64 runtime artifact from the same source commit. Do not build
on the shared host or run host-wide Docker cleanup. Confirm pull access before changing the resource
from its historical source-build configuration.

Use the prepared [host profile](../deploy/ha-node-profile.json): initially cap
Nuremberg at two CPUs/1536 MiB and Finland at two CPUs/2 GiB per container, with
matching total memory-plus-swap caps. These are isolation limits, not measured
capacity. Qualify actual failover load within them; do not automatically raise
them when the host is busy. Budget two containers on each host for its rolling
overlap. The host qualifier consumes sanitized metadata; passing it does not
establish application, TLS, broker or worker acceptance.
Retain verified bounded Docker logging: the Nuremberg canary uses 10 MiB × 3 files; the retained Finland resource uses 2 MiB × 2 files. The installed Coolify single-container path does not support per-app JSON log limits through custom Docker options. Do not change a shared Docker daemon or switch deployment methods merely to reduce these small caps. Capture the current API
configuration and a baseline of the other public applications before starting,
then check their availability during qualification. Roll back only the API
resource if it harms host headroom or unrelated services.

## Server modes

| Mode | Configuration | Behavior |
| --- | --- | --- |
| Standalone | No Redis/Valkey URL; omit `INLINE_REALTIME_DISTRIBUTED` or set `0` | Local delivery, no recent-bucket publication/discovery overhead |
| Multiple APIs with broker | `INLINE_REALTIME_DISTRIBUTED=1`, same private Redis URL and encryption key | Immediate local delivery and encrypted remote fanout |
| Multiple APIs without broker | `INLINE_REALTIME_DISTRIBUTED=1`, Redis/Valkey URL absent | Local delivery plus bounded PostgreSQL discovery and client catch-up |

All writers must agree on distributed mode. The private Fly Redis endpoint is
not reachable from Hetzner without a separately configured private network.
Initially Hetzner can use the third mode; do not expose Redis publicly or make
the standby depend on a Fly-hosted tunnel merely to get faster live fanout.
Presence and other ephemeral broker features degrade while durable message
recovery remains available. Broker failure reports degradation but does not
make a database-healthy API unready.

For a complete standby use `INLINE_PROCESS_ROLE=all`. `api` is suitable for
isolated qualification but omits background workers and is not complete failover.
An `all` fallback starts workers immediately, even before user traffic reaches
it. User ingress is ordered failover; background execution is concurrent.
Concurrent workers rely on existing PostgreSQL claims, leases and fencing.
Qualify those mechanisms and broker/recovery behavior across all intended
nodes; routing does not fence workers. External side effects retain their
existing delivery/idempotency contracts.

## Hetzner ingress

The source supports direct profiles on all origins without a provider admission
secret. Keep
application authentication and canonical Host enforcement. The optional
Cloudflare secret authenticates client-IP attribution only.

```text
INLINE_PROCESS_ROLE=all
INLINE_REALTIME_DISTRIBUTED=1
INLINE_DATABASE_QUERY_POOL_MAX=3
INLINE_INGRESS_MODE=cloudflare-optional
INLINE_INGRESS_HOST=api.inline.chat
INLINE_TRUSTED_CLIENT_IP_HEADER=cf-connecting-ip
INLINE_INGRESS_DIRECT_IP_SOURCE=x-real-ip
```

Use `fly-client-ip` for the Fly profile and `x-real-ip` behind the qualified
Hetzner reverse proxy. `socket` is safe without trusting forwarding headers,
but behind a proxy it groups clients under that proxy's rate-limit identity.
Existing strict `cloudflare` ingress remains compatible until the optional
profile is qualified and deliberately deployed. Changing source does not
update the running origin's configuration.

For the Hetzner profile, verify the **running** entrypoint has
`forwardedHeaders.insecure=false`, no untrusted `forwardedHeaders.trustedIPs`,
and no untrusted PROXY-protocol support. Traefik must strip caller-supplied
`x-real-ip` and derive it from the network peer. Keep the backend port unpublished
and attach only through the private container network. Do not change the shared
proxy's global settings blindly; other applications use that proxy too.

A configured valid Cloudflare attribution proof wins; otherwise only the chosen
proxy-owned IP is retained. Missing/invalid fallback identity uses the socket
peer. The API strips admission credentials and competing IP headers before HTTP,
protocol verification and both WebSocket upgrades, preserving Bun's original
request. An ordinary GET/HEAD `/readyz` probe remains exempt from canonical Host
checking. Real proxy header overwrite and port isolation are deployment gates,
not facts established by a local listener test.

Install and renew a public-trust certificate for **api.inline.chat** at Hetzner.
A Cloudflare Origin CA certificate is insufficient for direct clients. Renewal
must continue while normal DNS points at Cloudflare/Fly; qualify DNS validation
or another renewal arrangement rather than relying on HTTP challenges always
reaching Hetzner. Never use insecure TLS for the load-balancer monitor or clients.

The monitor's `allow_insecure=false` protects only health probes. Before cutover,
verify the **effective customer-to-origin path** uses HTTPS/443 with Full (strict)
(`ssl=strict`) or a reviewed equivalent certificate-validation policy for
`api.inline.chat`. Full without strict validation does not validate the origin
certificate. Inspect matching Origin Rules, Configuration Rules and legacy Page
Rules for SSL-mode, scheme, port, Host or SNI overrides; a zone default alone is
not enough. Do not change zone-wide SSL settings blindly on a shared zone.
See [Full (strict)](https://developers.cloudflare.com/ssl/origin-configuration/ssl-modes/full-strict/)
and [Full](https://developers.cloudflare.com/ssl/origin-configuration/ssl-modes/full/).

## Release and qualification

The [paired manual release workflow](standby-release-sync.md) implements exact
ARM standby synchronization before ordinary Fly replacement. Its restricted
consumer installation and activation are separate; these must be qualified
before enabling future releases. It does not change DNS/LB configuration.

1. Qualify one committed source revision in the amd64 runtime and native ARM64
   Coolify CI lanes. After all jobs pass, retain the `runtime_image` and
   `standby_image` immutable digests, source revision and workflow run URL.
   These are **different architecture-specific digests from the same source
   commit**, not interchangeable images. The manual `publish_only` workflow
   publishes this pair without production preflight, migrations or deployment;
   publication itself is a separate authorized action. Never select a digest
   from a partly failed run. Do not rebuild on the target host.
2. Run the explicit packaged migration and verification commands once, using
   the migration role, when the selected release requires schema changes.
   Startup checks compatibility but never migrates. Use tested additive
   migrations during overlap, and qualify the retained rollback release on the
   resulting schema. Image smoke proves packaging, native dependencies, HTTP,
   a legacy socket and shutdown in API-only mode; it does not qualify V3,
   multi-node delivery or concurrent `all` workers.
3. Keep automatic deploys disabled on fallback resources and pin the qualified
   digest. Transfer runtime credentials through managed authentication and
   stdin/in-memory transport. Verify key-ring byte parity and semantic parity
   for PostgreSQL/R2/provider endpoints without printing values. Use the DML-only
   database role, never a migration/owner credential. Retain pullable current
   and compatible rollback artifacts independently of a failed primary provider.
4. Confirm each origin has independent access to PostgreSQL, storage and required
   providers. Set query cap 3 plus the separate health cap 1 per process. Three
   steady APIs budget 12 direct connections; replacing one at a time budgets
   16 during overlap, before administration, exports, migrations and other
   clients. Verify actual provider limits/usage and reserve headroom rather than
   treating this arithmetic as capacity proof. Keep deployments sequential; do
   not overlap replacements across the three locations. PgBouncer needs explicit mode
   and successful role-timeout qualification. An omitted query cap retains the
   historical default 10; invalid values fail startup.
5. Configure each supervisor's `/readyz` probe, bounded timeout/startup grace,
   SIGTERM and stop grace longer than the 40-second application drain (at least
   Fly's 45 seconds). Check effective image revision, role, resource limits and
   proxy isolation. Capture unrelated shared-host service health before and
   after the scoped candidate; do not restart the shared proxy.
6. Before customer routing, qualify canonical public TLS/SNI and direct
   authenticated HTTP, V2/V3, exact upload readback, cross-origin sync/revocation,
   drain/reconnect and worker handoff. Verify forged CF/X-Real-IP/Fly-Client-IP/XFF
   headers through the real proxy boundary. A `200 /readyz` alone proves none
   of those user paths. Perform test mutations only in an authorized account/chat.
7. Rehearse the ordered selection on a nonproduction hostname only after its
   separate purchase/routing authorization. Remove the test Fly origin, verify
   Nuremberg; remove test Nuremberg too, verify Finland; recover Nuremberg and
   Fly in order and verify failback. Measure detection, routing, first
   authenticated success, socket catch-up and job recovery separately. Use
   isolated fixtures for DB-only network loss while the process remains alive;
   do not interrupt production dependencies to prepare the rollout.

### Rolling upgrades and removing a node

Qualify the fallback candidates before changing the preferred Fly origin. For
the current two-origin fleet, update Nuremberg, then Fly. If Finland is later
qualified and enabled, update Finland, then Nuremberg, then Fly, one
host at a time. On each host start the new immutable container on a separate
private backend, qualify it, switch only that API's proxy upstream, then SIGTERM
the old container and wait for its real exit/drain. Keep the other origins ready.
Source changes, image publication and local examples alone change no routing.

For Fly, retain the existing exact-fleet preflight, migration and blue-green
workflow; `--ha=false` preserves the selected public Machine count. It does not
update either Hetzner origin. Before the next selected `main` release reaches
Fly, require Nuremberg to pass direct authenticated HTTP/V2/V3, effective
image/configuration and schema checks for that SHA's qualified ARM64 image.
Record both architecture-specific digests, the compatible rollback release,
and all enabled origins' effective identities before calling the fleet release
complete. Keep the existing Cloudflare LB/pool identities and priority order;
an application release does not authorize deleting or replacing fallback
routing. Recheck routing and origin health after the rollout. Mixed releases
are acceptable only for deliberately qualified additive overlap with a named
owner and completion deadline, not indefinitely stale fallbacks.

The checked-in Fly workflow currently has no Nuremberg deployment/readback or
freshness gate. Until a reviewed release guard is added, the operator must
complete and record the standby prerequisite before dispatching the Fly
release. Automatic Git deployment remains disabled on the standby; enabling
it would bypass exact-image qualification rather than solve release coordination.

Before a planned node stop, verify a ready alternative, withdraw that node from
new ingress (its pool/endpoint or scoped reverse-proxy routing), then send
SIGTERM and wait for the supervisor to observe exit. Disabling a Cloudflare
pool does **not** stop its workers or prove its WebSockets drained. Existing
sockets reconnect or close through application shutdown; the optional CF
session-affinity drain feature is not part of this no-affinity topology.
Stopping a node also removes one readiness/worker participant. Keep the shared
database and remaining writers intact; provider failure alone is no reason to
restore or promote a database.

To restore a node, verify retained image/config/keys and schema compatibility,
start it, prove direct readiness and authenticated operation, then return it to
its original priority after stable health. Existing sockets on other nodes need
not be forcibly disconnected. If a fallback is intentionally cold/stopped,
document manual startup recovery instead of advertising automatic third-origin
availability. An unhealthy last-resort fallback is still a possible routing
target, so do not treat pool disablement alone as an admission fence.

## Optional automatic Cloudflare routing

Use three ordered pools, one direct origin address per location:

| Priority | Pool | Normal destination |
| --- | --- | --- |
| 1 | Fly | Fly Proxy → healthy public API Machine(s) |
| 2 | Nuremberg | Qualified Nuremberg TLS proxy → API container |
| 3 | Finland | Existing shared-host Traefik → API container |

Use `minimum_origins=1`, `steering_policy=off`, `session_affinity=none`, no
geographic/rule overrides, and ordered `default_pools=[fly, nuremberg, finland]`.
Set Finland as `fallback_pool`. Origin addresses must resolve directly to the
origin, never back to the Cloudflare-proxied hostname. Preserve canonical Host,
verified SNI/TLS and the existing attribution-proof handling.

The [example](../ha/cloudflare-three-origin.example.json) separates release
intent, monitor/pool create templates and the production LB create template.
Replace every sentinel from actual inventory/qualified receipts and review the
resolved plan. No tool in this preparation applies it. **Creating a load
balancer named `api.inline.chat` takes precedence over the existing A record and
is a production cutover.** The current Create LB schema has no `enabled` field;
do not create it assuming `enabled=false` is a staging fence. Disabled pools
are not a safe substitute. Keep payloads local until routing is authorized;
use a separate test hostname for a later authorized rehearsal.

The initial monitor is HTTPS `/readyz`, canonical Host, expected HTTP 200,
verified TLS, no redirects, interval 60s, timeout 5s, one retry, two consecutive
failures and three successes. Check plan entitlement; faster intervals are not
assumed. Broker degradation with HTTP 200 is acceptable, so do not require the
JSON status to be `ok`. DB/schema, clock and lifecycle failures must remove an
origin. Cloudflare sends probes from multiple locations and combines health;
keep health polling bounded and coalesced. These settings target a few minutes
of recovery, not instantaneous failover or a measured guarantee.

When Fly is unhealthy, new connections use Nuremberg; when both are unhealthy,
new connections use Finland. Standard ordered steering automatically returns
new traffic to the highest-priority healthy pool. Recovery hysteresis reduces
flapping. Existing WebSockets stay with their current process until reconnect
or drain. V3 temporary keys can require a fresh handshake at a different node;
permanent authority remains shared. Health recovery does not stop any API or
its workers. If all pools fail, Cloudflare still uses `fallback_pool` without
regard to health; independent user-path monitoring must report the failure.

Cloudflare's public non-Enterprise price page lists $5/month for two origins
and $5/month per additional origin: **three origins budget $10/month base**,
plus DNS-query usage, optional features and tax. First 500,000 DNS queries are
included, then $0.50 per additional 500,000. A proxied WebSocket frame is not a
DNS query. The live public rate card was retrieved October 15, 2026; verify the
actual account quote and 60s monitor entitlement before purchase. No geo-steering
add-on is needed for this order. See the [published rate card][cf-pricing].

## Bypass Cloudflare's proxy

Keep the DNS zone at Cloudflare. Qualify public TLS and ordinary authenticated
traffic without an origin secret on Fly and Hetzner before selecting a bypass.

Without a load balancer, capture the API A/AAAA records, replace them with the
verified target origin's public addresses and set `proxied=false`. Check both
address families so an old AAAA record cannot route clients to an unavailable
origin. Verify DNS answers and a recovered authenticated client operation.
Restore the captured records only after the normal path is healthy.

If an optional load balancer exists and **both the Cloudflare proxy and load
balancing must be bypassed**, capture its configuration and the ordinary DNS
records, disable the load balancer, then use ordinary DNS-only A/AAAA records
(`proxied=false`) pointing to the verified direct origin. Prepare the fallback
addresses first and require a valid public-trust certificate for
`api.inline.chat` at that origin. Verify both address families, DNS propagation
and an authenticated operation before considering the bypass complete. This
requires the Cloudflare management API/dashboard and DNS updates to remain
available; healthy authoritative DNS alone does not provide that control.

A DNS-only **load balancer** still uses Cloudflare's health and steering logic.
When only the proxy must be bypassed and the LB remains available, the following
single-pool DNS-only LB procedure is an alternative.

The load balancer takes precedence over an A/AAAA record with the same name.
Editing only the old A record or its orange-cloud state does not bypass the LB.
For this three-pool proposal, first choose and verify a healthy direct origin
(for example Nuremberg, then Finland), capture its pool identity, and deliberately
PATCH the **load balancer** to that one verified pool:

```json
{
  "proxied": false,
  "ttl": 60,
  "steering_policy": "off",
  "default_pools": ["<verified-direct-origin-pool-id>"],
  "fallback_pool": "<verified-direct-origin-pool-id>"
}
```

Capture the live configuration before changing it and verify there are no
steering rules/region overrides that could reintroduce Fly. Check authoritative
and recursive answers, then authenticate through the public hostname. Previously
cached Cloudflare addresses may remain for their old TTL (normally 300 seconds)
and existing sockets need recovery. Restore the saved proxied ordered-pool
configuration only after Cloudflare and the intended origins have stable health.

This emergency operation requires Cloudflare's management API/dashboard and DNS
updates to work. Healthy authoritative DNS alone does not guarantee that. The
first slice retains Cloudflare DNS; independent registrar/nameserver recovery
is a separate procedure. Direct traffic also bypasses Cloudflare WAF/DDoS protection, so application
authentication, rate limits and resource bounds must remain effective.

## Remaining shared failure domains

The shared PostgreSQL service, object storage, credentials and application
release remain common dependencies. An API failover cannot repair a database
outage, R2 outage or a bad release on all origins. Nuremberg and Finland still
share the Hetzner provider, while Fly adds provider diversity; Finland also
shares execution capacity with other applications and backups. Database HA and restore
drills are separate changes. Optional Redis does not make PostgreSQL optional.

References: [Cloudflare DNS precedence](https://developers.cloudflare.com/load-balancing/load-balancers/dns-records/),
[proxy modes](https://developers.cloudflare.com/load-balancing/understand-basics/proxy-modes/),
[standard steering](https://developers.cloudflare.com/load-balancing/understand-basics/traffic-steering/steering-policies/standard-options/),
[Origin CA limitations](https://developers.cloudflare.com/ssl/origin-configuration/origin-ca/),
[Traefik 2.10 forwarding source](https://github.com/traefik/traefik/blob/v2.10/pkg/middlewares/forwardedheaders/forwarded_header.go).

[cf-pricing]: https://www.cloudflare.com/sv-se/application-services/products/website-optimization/
