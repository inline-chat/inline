# Hermes Adapter Release Checklist

Use this checklist before publishing `@inline-chat/hermes-agent-adapter`.

## Preconditions

- The package version in `package.json` is the intended release version.
- `@inline-chat/realtime-sdk` and `yaml` dependency versions are pinned.
- `inlineHermes.testedHermesCommit` matches the Hermes source commit used for
  the final compatibility smoke.
- No tokens or `.env` contents are printed, copied, or committed.

## Automated Preflight

```sh
cd hermes-agent
bun run release:preflight
```

This creates an isolated stage, installs the exact registry dependencies from
`package.json`, runs the full package check, packs one read-only tarball, and
runs `npm publish --dry-run` against that exact tarball. The output prints the
artifact path, SHA-256, and file list. Publication automation verifies the hash
and publishes the same immutable bytes; it never repacks from the monorepo.

Expected tarball shape:

- `LICENSE`
- `README.md`
- `dist/install.d.ts`
- `dist/install.js`
- `package.json`
- `plugin/inline/LICENSE`
- `plugin/inline/README.md`
- `plugin/inline/__init__.py`
- `plugin/inline/adapter.py`
- `plugin/inline/cli.py`
- `plugin/inline/plugin.yaml`
- `plugin/inline/sidecar/index.mjs`
- `plugin/inline/tools.py`

## Host Compatibility and Message Flow

PR/main CI installs official Hermes source at the minimum supported version
(`0.21.3`, tag `v2026.9.14`), the newest stable release, and upstream `main`.
Each host validates the packed plugin manifest, rejects deprecated imports,
loads the platform and tool through Hermes, and exercises inbound/reply delivery,
deduplication, and media URL rejection. Host modules are not stubbed; this fast
lane uses an offline transport and a deterministic reply handler.

The local integration lane additionally runs the packaged Python adapter and its
bundled Node sidecar against the source Inline server and verifies an inbound
message and persisted outbound reply. This needs no production credential or LLM.

`Hermes stable compatibility` runs every six hours against npm `latest` and both
the latest stable Hermes source and upstream `main`. Failures remain failed
GitHub Actions runs; enable Actions notifications to receive them. The tested
adapter version, host ref/SHA, and candidate artifact hash are logged.

The publish workflow repeats host admission against the exact immutable release
tarball before npm trusted publishing. Release checks use the adapter's pinned
registry dependencies; an unrelated workspace prerelease is not substituted.

Catalog source also carries the bundled sidecar. Source CI and npm publication
run `release-stage.mjs --verify-source-bundle` to compare that tracked bundle with
the isolated build from pinned registry dependencies. Candidate dependency
overrides cannot be combined with this check. To regenerate after an SDK or
sidecar change, run `release:stage`, copy the sidecar from the reported stage
into `plugin/inline/sidecar/index.mjs`, then rerun staging with
`--verify-source-bundle` and commit the result. A workspace build is not the
canonical catalog artifact.

These checks do not establish live provider or production messaging health.
The following live checks remain useful before broader rollout.

## Manual Live Test

Install from the locally packed tarball:

```sh
cd hermes-agent
bun run release:preflight
# Use the exact path printed as `Hermes release artifact:` above.
npm install -g "/absolute/path/to/inline-chat-hermes-agent-adapter-<version>.tgz"
inline-hermes --version
```

Install and verify the Hermes plugin:

```sh
inline-hermes install --force
hermes plugins enable inline-platform
inline-hermes doctor --json
hermes inline status --json --probe
hermes gateway status
```

Set a valid Inline token in your shell or process manager, then test live sends:

```sh
export INLINE_TOKEN="<valid Inline bot/user token>"
inline-hermes test-send --to chat:<chat_id> --text "Inline Hermes manual test" --json
hermes send --to inline:<chat_id> "Hello from Hermes"
```

Need a bot token first? Use the Inline bot creation guide:
https://inline.chat/docs/creating-a-bot

Do not paste tokens into issue comments, PR comments, or logs. Use
`platforms.inline.token: ${INLINE_TOKEN}` if the Hermes gateway reads tokens
through config env references.

Manual behavior checks:

- A DM to the bot reaches Hermes and receives a reply.
- A group mention reaches Hermes and receives a reply.
- A non-mentioned group message is ignored when mention gating is enabled.
- An Inline reply-thread turn keeps thread routing and prompt/skill bindings.
- At least one native action callback works, such as clarify, approval, slash
  confirmation, or model picker.
- Media smoke covers one local outbound upload and one inbound URL-backed media
  summary or cache path.
- Restarting Hermes preserves sidecar startup, catch-up state, and `doctor`
  health.

## Publish

After the required CI gates pass, record any live-test evidence or gap, commit the scoped release group, and dispatch
the trusted-publishing workflow through the repository wrapper:

```sh
cd ..
bun run release:npm hermes-agent --version 0.0.20 --tag latest
npm view @inline-chat/hermes-agent-adapter version
npm view @inline-chat/hermes-agent-adapter dist-tags --json
```

For prereleases, use the exact version-derived dist-tag. Never move `latest` to
an alpha build.

Never publish directly from the monorepo package directory. Bun links matching
workspace package names by default, which can make the generated sidecar consume
unreleased local SDK or protocol source even though `package.json` pins the SDK.

## Post-Publish Smoke

```sh
npm install -g @inline-chat/hermes-agent-adapter@latest
inline-hermes --version
inline-hermes install --force
inline-hermes doctor --json
```

If `doctor` reports a sidecar hash mismatch after an upgrade, rerun:

```sh
inline-hermes install --force
inline-hermes doctor --json
```
