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

This runs `npm publish --dry-run --access public`, which invokes
`prepublishOnly`, rebuilds the installer and sidecar, runs typecheck/lint/tests,
installs the packed tarball in a temp prefix, and prints the final npm tarball
contents without publishing. The command first creates an isolated package
stage and installs the exact registry SDK declared by `package.json`, so a
dirty monorepo SDK or protocol checkout cannot leak into the bundled sidecar.
The final output prints the retained staging directory for inspection.

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
VERSION="$(node -p "require('./package.json').version")"
mkdir -p .tmp/manual-pack
npm pack --pack-destination .tmp/manual-pack
npm install -g ".tmp/manual-pack/inline-chat-hermes-agent-adapter-${VERSION}.tgz"
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

After manual live testing passes and npm auth is active:

```sh
cd hermes-agent
npm whoami
bun run release:preflight
bun run release:stage
cd <printed-hermes-release-stage>
npm publish --access public --tag alpha --otp="<otp>"
npm view @inline-chat/hermes-agent-adapter version
npm view @inline-chat/hermes-agent-adapter dist-tags --json
```

For stable releases, omit `--tag alpha`. Never publish a prerelease without an
explicit dist-tag; npm must not move `latest` to an alpha build.

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
