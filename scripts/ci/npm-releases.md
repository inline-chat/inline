# npm releases

Push `<package>-vX.Y.Z` on a tested commit from `main`. The seven package keys
are `protocol`, `bot-api-types`, `bot-client`, `realtime-sdk`, `openclaw`,
`hermes-agent`, and `chat-sdk`. Stable versions publish to `latest`; prereleases
must begin with `alpha`, `beta`, or `next` and use that dist-tag.

```sh
# Check committed HEAD, without changing files or publishing.
bun run release:npm bot-api-types --version 0.1.3-alpha.1 --dry-run

# One publication action, after reviewing and qualifying the commit.
git tag bot-api-types-v0.1.3-alpha.1 QUALIFIED_MAIN_SHA
git push origin bot-api-types-v0.1.3-alpha.1
```

The optional wrapper without `--dry-run` pushes the same tag and watches its
workflow. It uses committed HEAD even if the local worktree has unrelated edits.
Do not commit release version bumps: the tag version is written into a temporary
package copy, including Hermes's runtime version carriers. Source versions and
declared internal dependency requirements stay unchanged.

The release first requires the exact commit's main-push CI jobs for shared
packages, release contracts, candidate packing, and Node 20/26 packed consumers.
It checks package identity and published internal dependency requirements before
installing. Publish a changed dependency first when a dependent package names a
version that is not on npm yet; the workflow does not rewrite those requirements.

Package source checks run before stamping. The publication build uses registry
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
