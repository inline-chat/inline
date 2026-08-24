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
- `plugin/inline/__init__.py`
- `plugin/inline/adapter.py`
- `plugin/inline/cli.py`
- `plugin/inline/plugin.yaml`
- `plugin/inline/sidecar/index.mjs`
- `plugin/inline/tools.py`

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
hermes inline status
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

After manual live testing passes, commit the scoped release group and dispatch
the trusted-publishing workflow through the repository wrapper:

```sh
cd ..
bun run release:npm hermes-agent --version 0.0.8-alpha.0 --tag alpha
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
