# CLI releases

A CLI release is an existing `cli-vX.Y.Z` tag on a tested commit from `main`.
Prerelease tags such as `cli-v0.7.19-alpha.1`, `-beta.1`, and `-next.1` use the
same pipeline. Push the tag once; the CLI Release workflow builds all five
supported targets, signs and notarizes Apple silicon macOS, then publishes R2,
GitHub, and (for stable releases) Homebrew.

The release command updates and commits the Cargo workspace version, inherited
crate versions in `Cargo.lock`, and internal path dependency requirements
together. It pushes that commit, waits for its release checks, then creates and
pushes an annotated tag. CI verifies the committed versions match the tag before
building; it does not rewrite release versions. Independently versioned crates
and the private unversioned `cli/package.json` retain their source versions.

## Select and release a candidate

Review and commit the intended source changes, then prepare a release in a
checkout with clean tracked files and index. The command waits for the exact SHA's
`main` push in CI to pass **Rust workspace all targets** and **Workflow and
release contracts**. The release gate reads its tools from trusted `main`,
checks the existing tag and main ancestry, and freezes that SHA before checking
out or executing candidate code or accessing release environments. Later main
pushes do not replace the selected commit. CLI releases queue without cancelling
running or older queued releases.

```sh
# Preview the version files without committing or publishing.
bun run release:cli --version 0.7.19-alpha.1 --dry-run

# Commit the version, push main, wait for CI, then push its release tag.
bun run release:cli --version 0.7.19-alpha.1 --yes

# Resume an existing exact tag, using the current workflow on main.
gh workflow run cli-release.yml --repo inline-chat/inline --ref main \
  -f tag=cli-v0.7.19-alpha.1
```

Normal publication always uses all five targets and notarization. A tag must
already exist and resolve to the selected commit; the publishing script never
creates or moves one. The preparation command never force-pushes or moves an
existing tag; repository tag rules also prevent tag updates and deletion.
Release notes use GitHub's automatic notes. If CI or a push fails, rerun the same
preparation command to reuse its version commit. If main advances while CI runs,
the release retains the selected commit.

Credentials-only and build diagnostics can use an exact green main commit
without creating a tag. They never publish. Target overrides and signed-only
macOS builds are available only for diagnostics:

```sh
gh workflow run cli-release.yml --repo inline-chat/inline --ref main \
  -f commit=QUALIFIED_MAIN_SHA -f preflight_only=true

gh workflow run cli-release.yml --repo inline-chat/inline --ref main \
  -f commit=QUALIFIED_MAIN_SHA -f build_only=true \
  -f targets=aarch64-apple-darwin
```

An empty diagnostic `targets` input builds the normal five targets:
`aarch64-apple-darwin`, `aarch64-unknown-linux-gnu`,
`x86_64-unknown-linux-gnu`, `aarch64-unknown-linux-musl`, and
`x86_64-unknown-linux-musl`. Full hosted validation retains the CLI, installer,
Homebrew contract, agent package, and Umbrel checks. Local Rust release builds
are not required.

## Bridge runtime

CLI builds use bridge v2 by default for Codex and Claude Code, on every channel.
No local opt-in is needed. `INLINE_BRIDGE_V2=off` restores v1 for rollback; a
provider list such as `INLINE_BRIDGE_V2=codex` enables only those providers. ACP
providers (OpenCode and Amp) continue to use v1.

The first v2 start after an upgrade from v1 continues each v1 conversation in
its native session and folder; a session that no longer opens is replaced by a
fresh one. Turns v1 had queued or was running get a "send it again" reply, and
v1 approval and question cards expire.

## Codex runtime freshness

Before every Inline CLI release, update the Codex runtime used by the bridge to
the newest published Codex version. Resolve both npm `latest` and `alpha` tags
and compare versions; do not reuse the version from a previous release check.
Install the exact resolved version through that installation's package manager.
For a Bun-managed installation:

```sh
npm view @openai/codex dist-tags --json
bun add --global @openai/codex@RESOLVED_VERSION
```

Verify the exact provider executable reported by `inline bridge doctor`, its
`--version`, and the running provider separately from whichever `codex` is first
on PATH. Restart the bridge at an idle boundary after updating. Read its live
`model/list` catalog and verify that the current models reach Inline's Agent
picker and published configuration catalog before signing off the release.

Inline currently discovers an installed Codex executable (including the bundled
ChatGPT runtime as a fallback); its release archive does not contain a separate
Codex binary. This is a CLI release requirement, not a Mac-wide automatic updater.

## Verify and resume

Verify the tag's commit, five target archives and checksums, manifest version,
macOS signature/notarization, applicable Homebrew version, and the installed
binary separately. Every run reports published, already current, deferred,
blocked, or failed with a reason. A diagnostic success is reported as deferred
because it did not publish.

Each version has `cli/vVERSION/release.json`, binding its tag, source SHA, and
complete target set. Retries validate this receipt and reuse existing archives;
only missing targets are rebuilt. R2 versioned objects and existing GitHub
assets must match their recorded bytes/digests. Missing checksums or GitHub
assets can be completed; conflicting content fails without clobbering it. Older
releases without a receipt require an explicit audit rather than being claimed
by this workflow.

Every release retains `cli/vVERSION/manifest.json`. Stable releases additionally
advance `cli/manifest.json`, the installer, and the Homebrew cask after artifact
publication succeeds. Prereleases leave those stable entry points unchanged.
Resuming an older stable release also leaves a newer stable entry point in
place.

Every release, prerelease or stable, also advances the alpha channel pointer
`cli/alpha/manifest.json` when it is newer by SemVer precedence; the pointer
never moves backwards. CLIs on the `alpha` channel (`inline update --channel
alpha`, or any prerelease build without a saved choice) and the Mac app on its
Tip channel install from it, so Tip gets CLI features as soon as an alpha
publishes. Agent setup follows the same channel for the Hermes and OpenClaw
plugins: stable installs npm `latest`, alpha the newer of the `alpha` and
`latest` dist-tags. Resuming an existing tag seeds the pointer if it is missing. The bundle contains the versioned manifest and matching archives.

```sh
gh release view cli-vVERSION --repo inline-chat/inline --json assets
curl -fsSL https://public-assets.inline.chat/cli/vVERSION/manifest.json
# Stable pointer, only when checking a stable release:
curl -fsSL https://public-assets.inline.chat/cli/manifest.json
# Alpha channel pointer, after any release:
curl -fsSL https://public-assets.inline.chat/cli/alpha/manifest.json
```

For installed checks, resolve `command -v inline` and use the candidate's exact
executable if another installation shadows it on PATH. Check `inline bridge
doctor --json` for the service's installed binary and provider executable;
verify their versions separately from the shell's CLI. Readiness or `--version`
alone does not qualify an authenticated provider turn.

For an opt-in check of the transition from pre-updater releases, dispatch the
updater qualification workflow against the candidate branch:

```sh
gh workflow run cli-update-qualification.yml --ref CANDIDATE_BRANCH \
  -f published_upgrade_smoke=true
```

This exercises the actual `0.7.18` stable and `0.7.19-alpha.7` binaries upgrading
to the first signed updater, then checks candidate enrollment, saved opt-outs,
channel changes and feed failure/recovery. It uses disposable account and receipt
files on macOS and GNU/musl Linux; it never installs or restarts a service. It is
opt-in so public archive availability is not a new dependency of every main-push
release gate. Existing supervisor and store tests qualify the process handoff
and live-receipt rollback boundary separately.

For the first stable updater release, publish and read back the signed stable
feed before advancing the installer and Homebrew. The publisher already orders
these operations. Older CLI updaters can restart bridges during their manual
update: perform that transition while agents are idle, or use the Mac installer
and restart the bridge separately after work finishes. A legacy installation
enrolls with `inline update config --register` using the new executable; new
installers do this automatically. Explicit opt-outs survive enrollment.

When upgrading an existing macOS bot bridge from before 0.7.16, run `inline
bridge restart` with the newly installed binary once after the update. This
refreshes the service definition to Standard process policy; the older updater
process can retain its previous policy during the first restart. Verify the
persisted policy and actual provider readiness after this new-binary restart.

## Release authentication

All CLI jobs that consume release secrets use the `cli` GitHub environment,
after candidate qualification. Its allowed refs must include `main` and CLI
release tags. Shared signing and R2 credentials have separate copies in `cli`
and the main-only `apple` environment. The existing `APPLE_NOTARIZATION_KEY`,
`APPLE_NOTARIZATION_KEY_ID`, `APPLE_NOTARIZATION_ISSUER` and `SENTRY_AUTH_TOKEN`
repository secrets are retained until a secure migration source is available.

Homebrew uses the dedicated `INLINE_HOMEBREW_DEPLOY_KEY`, registered as a
write-enabled deploy key only on `inline-chat/homebrew-inline`. The workflow
loads it through stdin into an isolated SSH agent, ignores personal SSH config,
and pins GitHub's published Ed25519 host key. It stops the agent afterward.
Stable preflight checks Homebrew write access with a push dry run.

Deploy keys do not expire automatically. Rotate by registering a new dedicated
key, replacing `INLINE_HOMEBREW_DEPLOY_KEY`, and running credentials preflight
before revoking the old key. Never print credentials, inspect `.env`, or copy a
personal token/SSH key into CI. The retired `INLINE_HOMEBREW_TAP_TOKEN` is not a
fallback.

References: [GitHub deploy keys](https://docs.github.com/en/authentication/connecting-to-github-with-ssh/managing-deploy-keys)
and [host-key fingerprints](https://docs.github.com/en/authentication/keeping-your-account-and-data-secure/githubs-ssh-key-fingerprints).
