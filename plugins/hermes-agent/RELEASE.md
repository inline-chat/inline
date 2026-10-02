# Hermes Adapter Release Checklist

Use this checklist before publishing `@inline-chat/hermes-agent-adapter`.

## Preconditions

- The package version in `package.json` is the intended release version.
- `@inline-chat/realtime-sdk` and `yaml` dependency versions are pinned.
- Publish the immutable protocol `0.0.11-alpha.1` prerequisite first, then
  realtime SDK `0.0.19-alpha.1`, before running this candidate's registry-only
  preflight. These candidate versions are currently unpublished; local tarball
  qualification does not establish their registry availability. Recheck version
  availability before an authorized publication and never overwrite an existing
  version.
- The additive REST graph has its own prerequisites: publish Bot API types
  `0.1.3-alpha.1` before Bot client `0.1.2-alpha.1`, which pins those types.
  Hermes `0.0.22` and OpenClaw `0.0.71-alpha.1` pin the new realtime SDK.
- Unchanged ChatSDK `0.1.0-alpha.0` retains its published Bot client
  `0.1.2-alpha.0` and Bot API types `0.1.3-alpha.0` dependency graph. Its existing
  behavior is a separate legacy lane; it does not qualify the new provenance,
  forwarding receipt, or emoji APIs.
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
Before this candidate can be published, these stock-host lanes must distinguish
plugin loader/send-only compatibility from receiving qualification. Stock hosts
without the durable-intake patch must prove actionable receive refusal before
connection; an offline handler or `_gateway_accepted` flag cannot qualify SDK ACK
durability. Receiving requires the matching patched host, its wired gateway
handlers, and the physical profile StateDB. Record the exact patched core revision
alongside the package artifact. The older supported-host inbound check is not
receiving evidence for this candidate.

The matching-core local integration lane must additionally run the packaged
Python adapter and bundled Node sidecar against the source Inline server, verify
durable adoption and a persisted outbound reply, and recover an acknowledged
pending input after process death. Test deleted/edited inputs, revoked access,
receiver/profile mismatch, controls excluded from replay, and atomic user-row
consumption. These tests need no production credential or LLM.

This receiving lane uses an already configured DM home. First-use home
onboarding requires separate qualification.

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

For local validation that requires unreleased SDK/protocol wire fields, pack
both dependency candidates and pass their exact paths to the same isolated
stage:

```sh
node scripts/release-stage.mjs --prepare-only \
  --candidate-sdk-tarball /absolute/path/to/realtime-sdk-candidate.tgz \
  --candidate-protocol-tarball /absolute/path/to/protocol-candidate.tgz
```

The stage checks installed dependency versions against the manifests, then
checks and packs the adapter. Copy its built sidecar back to the catalog source
only after those checks pass. This candidate lane validates local immutable
artifacts; it does not establish registry availability. Registry publication
still requires the pinned dependency releases and registry preflight above.

Runtime qualification includes one managed receiver per SDK/settings file,
separate profile endpoints, stateless standalone sends, selected-Agent lookup
failure, and terminal authentication/stream loss. External receiving with
`sidecar_autostart: false` is intentionally refused before the gateway reports
connected; external endpoints remain available for send-only fallback. POSIX
child processes inherit the writer lease across a parent crash. Windows
hard-parent-crash lease behavior still needs separate qualification. Untagged
legacy state/settings files keep their existing content; their original
account provenance cannot be reconstructed. Chat metadata still refreshes per
accepted event to avoid stale routing; this is a performance follow-up.

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
bun run release:npm hermes-agent --version 0.0.22 --tag latest
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

The existing real-server CI lane installs the exact reviewed core from
`inlineHermes.testedHermesRepository` and `testedHermesCommit`. The selected
repository is `morajabi/hermes-agent`, pinned to the reviewed and pushed
`cd7f349d7aa072f45fce5d2721869ba59c5bbfa2` (source-derived base version `0.21.5`).
The pin still needs exact packaged receiving qualification. PM-capable source
uses its own `pm.build_env`, frozen lock and isolated build state; stock source
without PM keeps its existing installer path. Source ancestry and tags preserve
actual version provenance, while checkout verification preserves the exact SHA.
Missing pins, unavailable commits, incorrect checkout
or missing durable-intake v1 fail closed. The historical minimum and official
tag/latest/main/Umbrel stock checks describe loader/tool/send compatibility and
receive refusal, not working durable receiving.

The receiving receipt records actual core repository/SHA, intake version 1,
Inline source SHA and adapter tarball SHA-256 from an explicit observed report
produced by the packaged Python flow using normal gateway initialization and
startup. A successful child exit or normal reply alone cannot qualify receiving.
The report and release receipt must contain each of these scenarios once, passed:

- `hermes-real-host-inbound-and-persisted-reply`
- `hermes-acknowledged-pending-process-death-recovery`
- `hermes-pending-edited-current-source`
- `hermes-pending-deleted-source-settlement`
- `hermes-pending-revoked-access-settlement`
- `hermes-receiver-profile-mismatch-refused`
- `hermes-control-command-excluded-from-replay`
- `hermes-atomic-user-row-consumption-and-no-replay`

Missing, failed, repeated or foreign-identity evidence blocks receipt creation
and publication. The report is retained beside the receipt in the existing CI
artifact. The publication workflow retrieves
the existing receipt from successful trusted-main CI for that exact Inline SHA
and requires the release tarball bytes and core pin to match. An absent receipt,
expired artifact or different repack blocks publication; qualify those exact
bytes rather than borrowing stock or candidate evidence. No workflow is
automatically dispatched by this comparison. A complete observed matrix qualifies
the tested packaged process-death and authority cases; it does not claim a live
provider response, deployed service health or patched Umbrel receiving acceptance.
