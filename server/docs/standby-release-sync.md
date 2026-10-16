# Paired Fly and Nuremberg releases

The manual `server-deploy.yml` workflow implements a required standby gate for
ordinary production releases. Publication-only dispatches still publish both
tested architectures without deployment. The separate first-API `bootstrap`
path keeps its existing API-only and protected worker-activation gates; it does
not run standby synchronization. Bootstrap cannot adopt an existing all-role
Fly fleet and is not an ordinary-release bypass.

**Activation is separate from source implementation.** Until the reviewed
consumers, restricted keys and production environment settings below are
installed, ordinary releases fail before DDL. Committing or pushing this code
does not install anything, dispatch a release or change production.

## Ordinary release order

1. Qualify both native images and all server tests for the frozen main SHA.
   Only outputs of the successful reusable workflow are eligible.
2. Read healthy managed Fly Machines and the fixed healthy Nuremberg app before
   DDL. Bind the predecessor container/configuration to this run and attempt.
3. Apply and verify the existing migration ledger once. The production approval
   must establish additive old/new/rollback compatibility; metadata checks cannot
   prove schema or application compatibility.
4. Copy the selected ARM digest into an OCI archive without rebuilding. Re-read
   Fly immediately before sending it; its healthy baseline must still match.
   Refuse to replace the sole healthy origin during a Fly incident.
5. The restricted Nuremberg consumer verifies the transport hash/size, original
   manifest/config/compressed-layer digests, source revision, ARM64 platform and
   ordered decoded rootfs digests. It bounds both decoded tar bytes and declared
   file sizes, including sparse files, to 2 GiB. It reserves space for the local
   registry, Docker cache, expanded filesystem and another 1 GiB, plus 2 GiB
   available RAM for replacement. An unsupported image format fails before pull.
6. Mirror exact bytes only into the existing loopback registry under a unique
   SHA/run/attempt tag. Never overwrite a conflicting tag. Recheck Fly directly
   after transfer/pull, immediately before tag selection and start; its pinned
   origin address must stay current with the qualified Fly origin. The controller relay
   changes only the fixed app's image tag and starts it once. No environment,
   routing, proxy, resource-limit, database or other-app setting is written.
7. Require one healthy matching container, original ARM RepoDigest, source label,
   unchanged runtime environment, all-role/distributed/private-broker intent,
   resource caps and unpublished backend. Verify canonical-SNI public-trust TLS
   readiness directly against Nuremberg from both host and Actions, including
   database/clock/broker checks. Canonical LB readiness cannot substitute for it.
8. Read Nuremberg again immediately before Fly, retain Fly's independent exact
   baseline/image/count/service-health gates, then read Nuremberg after Fly.
   Retain the safe run-bound receipts as workflow artifacts.

This is image/configuration/readiness acceptance. It does not prove authenticated
HTTP/V2/V3, worker execution, cross-node delivery, capacity, Cloudflare pool order,
or compatible rollback. Existing qualification and origin/certificate monitoring
remain necessary. The workflow never changes Cloudflare routing.

## Restricted credential and installation boundary

Review and install root-owned, non-writable helpers through existing approved
admin access. Do not place a personal/root shell key or a broad Coolify bearer
in Actions. Do not read or export managed CLI token configuration.

| Location | Installed source / state |
| --- | --- |
| Nuremberg | `standby-release-host.py` → `/usr/local/libexec/inline-standby-release`; `standby-release-entrypoint.sh` → `/usr/local/libexec/inline-standby-release-entrypoint` |
| Nuremberg | root-only `/var/lib/inline-standby-release/`; `/etc/inline-standby-release/controller-key` and `controller-known-hosts` |
| Existing Finland controller | `standby-release-controller.py` → `/usr/local/libexec/inline-standby-controller`; `standby-release-controller-entrypoint.sh` → `/usr/local/libexec/inline-standby-controller-entrypoint` |
| Finland only | reviewed existing Coolify token encrypted as `/etc/credstore.encrypted/inline-standby-coolify`, exposed only through systemd `LoadCredentialEncrypted=coolify:...` |

The existing controller already holds management authority for these apps. Keep
its bearer there: host-key encryption would not protect a copied broader bearer
from Nuremberg root. Before installation, establish the existing token's actual
scope, provenance and approved use privately. No suitable token, stored path,
or root credential is created or asserted by this implementation.

Use two dedicated keys with distinct scopes:

- Actions → Nuremberg: `restrict,command="/usr/local/libexec/inline-standby-release-entrypoint"`.
  Only original command `inline-standby-release-v1` is accepted. No PTY,
  forwarding, shell, arbitrary argv, caller paths or provider credentials.
- Nuremberg → Finland port 6642:
  `from="91.107.255.57",restrict,command="/usr/local/libexec/inline-standby-controller-entrypoint"`.
  Only original command `inline-standby-controller-v1`; the relay accepts safe
  app metadata read, one validated release tag selection, or start of that exact
  app/tag. It returns an explicit non-secret projection. It cannot select another
  resource, change environment/configuration, access keys, run shell or forward.

Both entrypoints use clean environments and transient bounded systemd units,
core dumps disabled and control-group termination. The bearer exists only in the
Finland private credential namespace. The image stream contains no registry auth.
Private request/command/provider diagnostics are suppressed, including failures.
The deployment key is an authorization boundary: it trusts the protected workflow,
not merely a caller-supplied OCI source label. Review all workflows able to access
that environment secret and restrict production environments to main.

After helper hash/permission, native unit, host-key and fixed-target read-only
qualification, configure in the protected `production` environment:

- secret `STANDBY_RELEASE_SSH_KEY`: the dedicated forced-command key, never an
  operator key;
- variable `STANDBY_RELEASE_KNOWN_HOSTS`: independently verified pinned Nuremberg
  public host key for `91.107.255.57`, never live unauthenticated `ssh-keyscan`;
- variable `STANDBY_SYNC_ENABLED=true`, last, after an explicitly authorized
  rollout rehearsal. Production dispatch remains separately manual.

No helper/key/credential/environment setting is installed by a workflow run.
Actual transport, controller version/endpoints, systemd credential loading and
rolling replacement/drain need an authorized rehearsal before activation. The
ARM CI lane tests real daemonless OCI export/validation on its disposable image;
local synthetic tests alone do not establish provider execution.

## Uncertainty, recovery and independent deployment

The root-only journal is fsynced before controller PATCH and start. A partial or
uncertain mutation fences subsequent releases. A late successful start can close
only after exact live runtime/tag/config/readiness reconciliation; it never sends
another start request. Known successful retries only re-read. Older runs cannot
replace a newer completed run, and another run cannot overwrite an unfinished
one. Actions has one non-cancelling release concurrency group; Nuremberg also has
a non-blocking native lock. Out-of-band admin changes remain possible and are
detected by live readback, not prevented by a cross-provider transaction.

If a job fails, do not delete the journal or blindly rerun deploy. Record its
phase, exact desired/retained images, controller deployment outcome and both
runtime identities. Reconcile the provider's final state with approved admin
access; retain the journal before explicitly rearming a failed attempt. No
automatic DDL rollback or fleet rollback occurs. A failed standby gate leaves
Fly's existing deployment untouched, but DDL may already have succeeded.

The paired path intentionally needs both providers. It is **not the emergency
deployment path** when Hetzner/Coolify, Actions or Fly builders are unavailable.
Keep current and compatible rollback source/images/configuration encrypted in
the independent [release escrow](server-release-escrow.md), with its independent
credential and full readback receipts. An explicitly reviewed operator can
recover a retained qualified AMD image on an independent workstation, import it
into an available registry and deploy the immutable image to Fly using the
existing [Fly release/rollback contract](fly-deployment.md#migration-safety-and-rollback),
without this paired workflow or a new build. For Fly failure, use the retained
ARM image and existing controller or reviewed controller-bypass recovery path.
An independent new-source build additionally needs available source/dependency
mirrors and build capacity; retained-image recovery does not prove that ability.

Do not add a blind `skip_standby` switch. An emergency release records the target,
source/digest, schema/configuration/rollback evidence, unavailable provider and
mixed-fleet owner/deadline. When the provider returns, reconcile its actual
runtime before synchronizing. The normal next release fails closed on drift;
the existing origin observer watches readiness, not image freshness, so there is
no claim of a continuously active version-drift reconciler.

Implementation references: [Skopeo digest-preserving copy](https://github.com/podman-container-tools/skopeo/blob/main/docs/skopeo-copy.1.md),
[Coolify app update](https://coolify.io/docs/api/endpoints/applications/update-application-by-uuid),
[Coolify app start](https://coolify.io/docs/api/endpoints/applications/start-application-by-uuid).
