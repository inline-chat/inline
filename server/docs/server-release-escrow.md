# Retained server release escrow

`scripts/docker/server-release-escrow.ts` captures existing image archives and
the exact committed server build context into a new local directory. It needs
Bun, Git for capture, and the system `tar`; verification needs Bun and `tar`
only. It does not build, run Docker, fetch packages, access credentials, upload,
migrate, deploy, or change running services. No publication workflow calls it.

This is the first preparation step toward deployment independence. It does not
establish that any two failed build systems can be bypassed.

## Capture an existing release

Supply separately produced, **uncompressed single-image Docker-save archives**:
the Linux AMD64 runtime and Linux ARM64 Coolify images of the same committed
source. Creating these archives is a separate operation; this tool never starts
Docker. Use archives from the already qualified release, rather than rebuilding
an image during recovery.

```sh
bun --no-env-file scripts/docker/server-release-escrow.ts capture \
  COMMIT /retained/runtime-amd64.tar /retained/coolify-arm64.tar \
  /retained/new-release-directory
```

Capture refuses an existing destination and symlinked image files. It exports
only committed build inputs through the existing source exporter, excluding
environment files, credential candidates and dirty/untracked source. Image
archives must carry the expected source revision label and platform. Each image
config's bytes must match its Docker config filename checksum. The two target
names describe their intended use; the archive cannot prove which Dockerfile
target was built.

The resulting `escrow.json` records source revision, every retained file's byte
count/SHA-256, image config identity and platform. `source/source.json` preserves
the commit/blob inventory. A copy of the two recovery scripts is included and
hashed separately; these tool bytes are not claimed to belong to the image's
source commit. No runtime configuration or credentials are captured.

The final JSON output includes `manifestSha256`. **Retain that checksum outside
the escrow**, in a trusted release record. A checksum stored only alongside an
altered bundle cannot authenticate it. The completion manifest is written last;
failed captures remain available for inspection and cannot be verified as a
complete escrow. Do not reuse or merge a partial destination.

## Verify after transfer or provider loss

Copy the complete directory to storage independent of GitHub, Fly and Hetzner
(for example, the existing private recovery store). This tool does not perform
that upload. Retain the current and a schema-compatible rollback release, and
record independent destination/readback evidence before calling either stored.

```sh
bun --no-env-file scripts/docker/server-release-escrow.ts verify \
  /recovered/release-directory INDEPENDENT_MANIFEST_SHA256
```

Use a trusted copy of the verifier first. The bundled copy can verify a moved
directory without the original checkout, but executing an unverified bundled
script cannot authenticate that script. Verification rejects changed archives
or source, changed manifests, missing/extra files, unsafe paths and symlinks.
It does not extract archive members onto disk or run image content.

The success label is deliberately `archive-bytes-and-image-config-only`.
Archive checksums establish retained byte identity; config identity establishes
the recorded source label and platform. They do **not** establish registry
manifest digest equivalence, ordered layer content validity, Docker import,
startup, tests, migration compatibility, safe rollback, key recovery, or serving
capacity. Keep the original qualification receipt and registry digest as
separate release provenance. Docker import and runtime checks remain required
on the intended host before deployment.

## Remaining outage gates

- Independently accessible deployment credentials, runtime keys, configuration,
  SSH/controller access and routing controls. These do not belong in this bundle.
- An independent image delivery path for Hetzner when Fly registry is down.
  Coolify Docker Image deployments pull the saved reference; importing a local
  image alone is not proof that the installed controller can redeploy it offline.
- A portable release runner that preserves target-specific preflight, explicit
  migration execution, graceful replacement and authenticated verification while
  GitHub Actions is unavailable.
- A complete current-lockfile dependency/toolchain kit for **new-source builds**:
  the patched GitHub `node-forge` dependency, Bun base, package payloads, native
  dependencies, Coolify tools and isolated test dependencies. A source archive
  alone cannot cold-build through a full GitHub outage. New dependencies require
  refreshing that kit.
- Native build/qualification capacity on the surviving executor. Retained-image
  redeployment needs no builder and is a distinct acceptance case.
- Whole Fly plus whole Hetzner loss removes both existing origin providers.
  Independent artifact preparation remains possible; serving requires a third
  compute target.

No live recovery, independent upload/readback, production rollout, or pairwise
outage drill is implied by this tooling or its synthetic tests.
