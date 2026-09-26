# Hetzner standby and Cloudflare proxy bypass

This is the deployment contract, not a statement that the standby is already
qualified. Keep Cloudflare authoritative DNS. Start with one Fly API and one
warm API on the existing Hetzner host. A second Fly Machine can later join the
same app without changing clients or adding another load-balancer pool.

```text
api.inline.chat — Cloudflare DNS + proxied load balancer
  priority 1: Fly app → one or two healthy API Machines
  priority 2: existing Hetzner → Traefik → private API container
                   all APIs → same PostgreSQL, object storage and key rings

Cloudflare proxy incident: same hostname, DNS-only LB → Hetzner directly
```

The incremental infrastructure is a Cloudflare load balancer and a running
container on the existing host. Do not create a new VM, Redis cluster, database
replica, ingress daemon or failover controller as part of this deployment.
Cloudflare Load Balancing billing/entitlement must be confirmed before activation.

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
| Standalone | No Redis/Valkey URL; omit `REALTIME_DISTRIBUTED` or set `0` | Local delivery, no recent-bucket publication/discovery overhead |
| Multiple APIs with broker | `REALTIME_DISTRIBUTED=1`, same private Redis URL and encryption key | Immediate local delivery and encrypted remote fanout |
| Multiple APIs without broker | `REALTIME_DISTRIBUTED=1`, Redis/Valkey URL absent | Local delivery plus bounded PostgreSQL discovery and client catch-up |

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

Fly retains its Cloudflare-only ingress initially. Hetzner accepts either the
existing Cloudflare origin proof or an independently authenticated local proxy.

```text
INLINE_PROCESS_ROLE=all
REALTIME_DISTRIBUTED=1
INLINE_INGRESS_MODE=cloudflare-or-proxy
INLINE_INGRESS_HOST=api.inline.chat
INLINE_TRUSTED_CLIENT_IP_HEADER=x-real-ip
INLINE_ORIGIN_SECRET=<same managed Cloudflare origin secret as Fly>
INLINE_PROXY_SECRET=<distinct managed random 32-byte lowercase hex secret>
```

Both credentials must stay out of source, command arguments and logs. Traefik's
API route overwrites `x-inline-proxy-secret` on every request. For this mode,
verify the **running** entrypoint has `forwardedHeaders.insecure=false`, no
untrusted `forwardedHeaders.trustedIPs`, and no untrusted PROXY-protocol support.
Traefik must strip caller-supplied `x-real-ip` and derive it from the network
peer. Keep the backend port unpublished and attach only through the private
container network. Do not change the shared proxy's global settings blindly;
other applications use that proxy too.

The API always enforces the canonical Host. A valid Cloudflare secret plus a
single valid CF client IP wins. Otherwise a valid proxy secret plus the proxy's
single valid `x-real-ip` is required. The API strips both credentials and all
competing IP headers, then retains only the selected canonical IP. This applies
before HTTP, protocol verification and both WebSocket upgrades, while preserving
Bun's original request. Only an ordinary GET/HEAD `/readyz` probe is exempt.

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
3. Confirm independent Hetzner access to pooled and direct PostgreSQL endpoints,
   object storage, keys and required providers. Query clients use PgBouncer, with
   one direct health connection per process. Budget the shared pool and direct
   connections for normal fleet plus temporary rolling-deploy overlap.
4. Set Coolify's health path to `/readyz` (not `/healthz`), five-second probes,
   a bounded timeout, and enough startup grace. Configure a stop grace longer
   than the API drain deadline. Verify source/image revision and worker role.
5. Before adding the pool, test the real Hetzner route with public TLS/SNI and
   the canonical Host. Prove authenticated HTTP, V2/V3, upload/read-back,
   cross-origin message recovery, revocation, drain/reconnect and worker handoff.
   Send forged CF/X-Real-IP/XFF/proxy-secret headers to prove the real proxy
   boundary. A `200 /readyz` is insufficient evidence.
6. Rehearse Fly origin removal from routing while keeping shared PostgreSQL.
   Measure detection, routing, socket reconnect/catch-up and job recovery. Never
   restore a database or stop the old writer just because a health check failed.

## Cloudflare routing

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

Keep the DNS zone at Cloudflare. Preselect Hetzner as the direct-capable target;
the initial Fly ingress deliberately remains Cloudflare-only.

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
user accepts this dependency; this design adds no second DNS provider or client
endpoint. Direct traffic also bypasses Cloudflare WAF/DDoS protection, so origin
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
