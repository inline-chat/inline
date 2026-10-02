# Hetzner standby and Cloudflare proxy bypass

This is the deployment contract, not a statement that the standby is already
qualified. Keep Cloudflare authoritative DNS. Start with one Fly API and one
warm API on the existing Hetzner host. A second Fly Machine can later join the
same app without changing clients or adding another load-balancer pool.

```text
api.inline.chat — Cloudflare DNS + optional proxy
  normal: Fly app → one healthy API Machine (temporary deployment overlap)
  manual fallback: existing Hetzner → Traefik → private API container
                   all APIs → same PostgreSQL, object storage and key rings

Cloudflare proxy incident: same hostname, DNS-only A/AAAA → qualified origin
```

The minimum is a running container on the existing host and tested manual
cutover. Automatic Cloudflare Load Balancing is optional after this gate passes;
confirm billing/entitlement before enabling it. No new VM, Redis cluster,
database replica, ingress daemon or failover controller is required.

## Shared-host boundary

The existing Hetzner host also serves unrelated production applications. Scope
changes to the Inline API resource and its uniquely named Traefik routers,
service and middleware. Preserve shared entrypoints, networks, certificate
storage and other applications. A shared proxy restart or host-level change
requires a separate reviewed operation; it is not part of this rollout.

Build and qualify the ARM64 Coolify image on the native GitHub Actions runner,
then deploy the qualified image by digest. Do not build on the shared host or
run host-wide Docker cleanup. Confirm pull access before changing the resource
from its historical source-build configuration.

Initially cap the API container at two CPUs and 2 GiB RAM, with total
memory-plus-swap also capped at 2 GiB. These are isolation limits, not measured
capacity. Qualify actual failover load within them; do not automatically raise
them when the host is busy. Budget two such containers for rolling overlap.
Keep Docker log retention bounded for this resource. Capture the current API
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
Concurrent workers rely on existing PostgreSQL claims, leases and fencing.
External side effects retain their existing delivery/idempotency contracts.

## Hetzner ingress

The source supports direct profiles on both origins without a provider admission
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

## Release and qualification

1. Qualify the exact source/image in both the amd64 Fly and native ARM64 Coolify
   Linux CI lanes. Apply additive migration
   `0152_recent-realtime-buckets` with the migration role, then verify the ledger.
   API startup checks schema compatibility; it never performs migrations.
   A manual publish-only release records `runtime_image` and `standby_image`
   digests in its summary without deploying either provider. The ARM container
   smoke proves packaging, native dependencies, migrations, HTTP, a legacy socket
   and shutdown in API-only mode. It does not qualify distributed delivery, V3
   authentication or the `all` worker role; retain the later runtime gates.
2. Keep Coolify automatic deploys disabled and pin the qualified release. Copy
   runtime application credentials using managed authentication and stdin/in-memory
   transport. Verify byte parity for encryption/session/native-protocol key rings
   and semantic parity for PostgreSQL/R2/provider endpoints without printing values.
   Use the DML-only database role; do not copy a migration/owner credential.
3. Confirm independent Hetzner access to PostgreSQL, object storage, keys and
   required providers. Set `INLINE_DATABASE_QUERY_POOL_MAX=3` on each Fly and Hetzner
   process; the separate direct health pool remains capped at one connection.
   Three overlapping processes therefore use at most 12 direct connections.
   With 22 usable database slots, reserve at least four for administration,
   exports, migrations and other clients, and inspect actual usage before
   starting overlap. During the first upgrade, keep Hetzner stopped while the
   legacy Fly process with 11 slots and new Fly process with four slots coexist.
   Start standby only after the old process is stopped. Query clients may use the direct
   endpoint within this budget; PgBouncer requires explicit mode and successful
   role timeout qualification. The omitted query cap retains the historical
   default 10; invalid values fail startup rather than silently changing it.
4. Set Coolify's health path to `/readyz` (not `/healthz`), five-second probes,
   a bounded timeout, and enough startup grace. Configure a stop grace longer
   than the API drain deadline. Verify source/image revision and worker role.
5. Before directing user traffic, test the real Hetzner route with public TLS/SNI and
   the canonical Host. Prove authenticated HTTP, V2/V3, upload/read-back,
   cross-origin message recovery, revocation, drain/reconnect and worker handoff.
   Send forged CF/X-Real-IP/Fly-Client-IP/XFF headers to prove the real proxy
   boundary. A `200 /readyz` is insufficient evidence.
6. Rehearse Fly origin removal from routing while keeping shared PostgreSQL.
   Measure detection, routing, socket reconnect/catch-up and job recovery. Never
   restore a database or stop the old writer just because a health check failed.

## Optional automatic Cloudflare routing

Use two ordered pools, one direct origin address per provider, `minimum_origins=1`,
`steering_policy=off`, and no geographic overrides or session affinity. The Fly
pool targets its Fly Proxy address, which can route to two healthy Machines.
Origin addresses must not resolve back to Cloudflare's proxy. Preserve
`Host: api.inline.chat`, verified SNI/TLS and the existing origin-secret rule.

Start with this HTTPS monitor, subject to the purchased plan:

```json
{
  "type": "https", "method": "GET", "path": "/readyz",
  "header": { "Host": ["api.inline.chat"] },
  "expected_codes": "200", "allow_insecure": false,
  "follow_redirects": false, "interval": 60, "timeout": 5,
  "retries": 1, "consecutive_down": 2, "consecutive_up": 3
}
```

Use Fly then Hetzner in `default_pools`; use Hetzner as `fallback_pool`.
The fallback pool is used even if every pool is unhealthy, so it is a last
attempt, not evidence of health. Monitor serving behavior independently.
These settings target recovery in a few minutes; only a measured drill can
establish the actual recovery time. Traffic switching affects new requests and
connections. Existing WebSockets must reconnect or drain naturally. Health
recovery may automatically return new traffic to Fly; it does not stop either
API or its workers.

## Bypass Cloudflare's proxy

Keep the DNS zone at Cloudflare. Qualify public TLS and ordinary authenticated
traffic without an origin secret on Fly and Hetzner before selecting a bypass.

Without a load balancer, capture the API A/AAAA records, replace them with the
verified target origin's public addresses and set `proxied=false`. Check both
address families so an old AAAA record cannot route clients to an unavailable
origin. Verify DNS answers and a recovered authenticated client operation.
Restore the captured records only after the normal path is healthy.

If an optional load balancer exists, use the following LB-specific procedure.

The load balancer takes precedence over an A/AAAA record with the same name.
Editing only the old A record or its orange-cloud state does not bypass the LB.
For this simple two-pool configuration, first verify direct Hetzner TLS and
authenticated service, then PATCH the **load balancer**:

```json
{
  "proxied": false,
  "ttl": 60,
  "steering_policy": "off",
  "default_pools": ["<verified-hetzner-pool-id>"],
  "fallback_pool": "<verified-hetzner-pool-id>"
}
```

Capture the live configuration before changing it and verify there are no
steering rules/region overrides that could reintroduce Fly. Check authoritative
and recursive answers, then authenticate through the public hostname. Previously
cached Cloudflare addresses may remain for their old TTL (normally 300 seconds)
and existing sockets need recovery. Restore the saved proxied ordered-pool
configuration only after Cloudflare and Fly have stable health.

This emergency operation requires Cloudflare's management API/dashboard and DNS
updates to work. Healthy authoritative DNS alone does not guarantee that. The
first slice retains Cloudflare DNS; independent registrar/nameserver recovery
is a separate procedure. Direct traffic also bypasses Cloudflare WAF/DDoS protection, so application
authentication, rate limits and resource bounds must remain effective.

## Remaining shared failure domains

The shared PostgreSQL service, object storage, credentials and application
release remain common dependencies. An API failover cannot repair a database
outage, R2 outage or a bad release on both origins. Database HA and restore
drills are separate changes. Optional Redis does not make PostgreSQL optional.

References: [Cloudflare DNS precedence](https://developers.cloudflare.com/load-balancing/load-balancers/dns-records/),
[proxy modes](https://developers.cloudflare.com/load-balancing/understand-basics/proxy-modes/),
[standard steering](https://developers.cloudflare.com/load-balancing/understand-basics/traffic-steering/steering-policies/standard-options/),
[Origin CA limitations](https://developers.cloudflare.com/ssl/origin-configuration/origin-ca/),
[Traefik 2.10 forwarding source](https://github.com/traefik/traefik/blob/v2.10/pkg/middlewares/forwardedheaders/forwarded_header.go).
