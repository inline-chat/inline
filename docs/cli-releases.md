# CLI releases

The public repository owns `scripts/release-cli.ts` and
`.github/workflows/cli-release.yml`. The root Cargo workspace version, internal
path-dependency requirements, and lockfile must agree before release. Prepare
only the intended source changes; unrelated uncommitted work is not a release
candidate. Do not reuse an already published version.

Run the CLI checks, release-script tests, Homebrew validation, and external
agent-package contract check before committing the candidate:

```sh
bun run --cwd cli ci
bun test scripts/release-cli.test.ts
INLINE_HOMEBREW_TAP_PATH=/path/to/homebrew-inline bun run scripts/release-cli.ts validate-homebrew
node scripts/check-agent-release-group.mjs
```

Push the reviewed candidate, then pass its exact commit SHA as `ref` below.
The workflow definition comes from `main`. An empty `targets` input builds all
five supported targets in CI, including signed and notarized Apple-silicon
macOS. Do not skip notarization for a normal stable release.

```sh
# Credentials only; no build or publication.
gh workflow run cli-release.yml --repo inline-chat/inline --ref main \
  -f ref=PUBLIC_CANDIDATE_SHA -f preflight_only=true

# After the candidate is approved for publication:
gh workflow run cli-release.yml --repo inline-chat/inline --ref main \
  -f ref=PUBLIC_CANDIDATE_SHA
```

The full workflow validates the CLI and integration packages before building,
then publishes GitHub/R2 artifacts and the stable manifest/install script and
Homebrew cask. Prereleases leave stable/Homebrew unchanged. Verify the tag's
commit, manifest version and checksums, five assets, macOS signature/notarization,
Homebrew version, and installed binary separately. Build-only runs retain CI
artifacts without publishing. Local release builds are not required.

Keep human release notes in a reviewed file; the script creates generic notes.
After publication, attach the reviewed text with `gh release edit cli-vVERSION
--repo inline-chat/inline --notes-file PATH`. The 0.7.7 draft is in
[cli-v0.7.7.md](cli-v0.7.7.md).

## Release authentication

The CLI Release workflow publishes GitHub/R2 artifacts and updates the separate
`inline-chat/homebrew-inline` repository. Homebrew publishing uses the dedicated
`INLINE_HOMEBREW_DEPLOY_KEY` Actions secret in `inline-chat/inline`.

The public Ed25519 key is registered as a write-enabled deploy key only on the
Homebrew repository. The private key goes into an isolated SSH agent through
stdin; the workflow never writes it to a key file. SSH ignores personal config,
uses only that identity, and pins GitHub's published Ed25519 host key. The agent
is stopped after the operation. No personal GitHub token is copied into CI.

Stable releases that update Homebrew verify SSH write authentication before
building, using a push dry run that does not change repository contents. The
same authentication script is reused during publication. It lives in the
workflow so releasing an older source ref does not require a new helper file.

To check credentials without building or publishing:

```sh
gh workflow run cli-release.yml --repo inline-chat/inline --ref main \
  -f ref=main -f preflight_only=true
```

Wait for the preflight job to succeed. Validation, build, and publication jobs
must be skipped. For full stable credentials, leave `targets` empty and
`build_only` false. No new release or version bump is needed for this check.

Deploy keys do not expire automatically. To rotate, register a new dedicated
key, replace `INLINE_HOMEBREW_DEPLOY_KEY`, and run the preflight check before
revoking the previous key. GitHub may also remove a deploy key when the GitHub
authorization used to create it is revoked. Never paste private keys into logs,
commit them, or reuse a developer's general-purpose SSH key.

The former `INLINE_HOMEBREW_TAP_TOKEN` secret is no longer used by this workflow.
Its presence does not imply it is still valid; do not reuse it as a fallback.

References: [GitHub deploy keys](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/managing-deploy-keys)
and [host-key fingerprints](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints).
