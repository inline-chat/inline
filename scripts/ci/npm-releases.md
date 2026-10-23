# npm releases

Prepare `<package>-vX.Y.Z` with an automated version commit on `main`. The seven package keys
are `protocol`, `bot-api-types`, `bot-client`, `realtime-sdk`, `openclaw`,
`hermes-agent`, and `chat-sdk`. Stable versions publish to `latest`; prereleases
must begin with `alpha`, `beta`, or `next` and use that dist-tag.

```sh
# Preview the version files, without changing files or publishing.
bun run release:npm bot-api-types --version 0.1.4-alpha.1 --dry-run

# Commit the version, push main, wait for CI, then tag and watch publication.
bun run release:npm bot-api-types --version 0.1.4-alpha.1 --yes
```

Use a checkout with clean tracked files and index. The command updates only the
selected package's version and Bun workspace lock entry, plus Hermes's runtime
version carriers or OpenClaw's bounded compatibility table when applicable. It
commits those files, pushes that commit to main, waits for its release checks,
then creates and pushes an annotated `<package>-vX.Y.Z` tag. It never force-pushes
or moves a tag. Existing repository tag rules prevent release-tag deletion and
updates; use a new version for a different release.

If CI or a push fails, the version commit remains available. Rerun the same
command to resume without another version commit. If main advances while CI is
running, the tag still targets the selected version commit. Do not manually edit
version numbers. Declared internal dependency requirements stay unchanged.

The release first requires the exact commit's main-push CI jobs for shared
packages, release contracts, candidate packing, and Node 20/26 packed consumers.
It checks package identity and published internal dependency requirements before
installing. Publish a changed dependency first when a dependent package names a
version that is not on npm yet; the workflow does not rewrite those requirements.

The publisher requires the committed package version to match the tag. Package
source checks run before artifact identity is added. The publication build uses registry
dependencies outside the workspace, then installs and imports the packed
artifact. Hermes retains its real-host, source-install, and Umbrel checks.
The checked tarball and its source/tag/integrity receipt are retained together.

Only a separate publisher job has npm OIDC and GitHub release permissions. It
uses the `npm-publish` environment, publishes the retained bytes without running
package lifecycle scripts, verifies the public tarball, and creates automatic
GitHub release notes. Each package's publications queue; later pushes do not
cancel an existing release.

## Verification and retries

```sh
npm view @inline-chat/bot-api-types@0.1.3-alpha.1 dist.integrity dist.tarball
npm view @inline-chat/bot-api-types dist-tags --json
# If preparation succeeded, retry only failed jobs to reuse its retained bytes.
gh run rerun RUN_ID --failed --repo inline-chat/inline
```

An identical existing version is verified and skipped. Missing notes or a
missing channel update can be repaired; a newer channel is never moved backward.
Conflicting bytes or a moved tag fail. If preparation is rerun and creates
different bytes for an already published version, that mismatch also fails;
reuse the original retained artifact rather than overwriting the version.

Trusted publishers must name `inline-chat/inline`, `npm-publish.yml`, and the
`npm-publish` environment. OIDC channel repair additionally needs npm's
**Allow npm dist-tag** setting and npm 11.21.0 or newer; the workflow pins that
version. No npm token fallback is used. Every run ends with a publication,
already-current, deferred, blocked, or failed outcome and reason.
