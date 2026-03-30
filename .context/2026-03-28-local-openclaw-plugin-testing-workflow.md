# Local OpenClaw Plugin Testing Workflow

Use this when testing the local `packages/openclaw-inline` plugin against the user's installed OpenClaw gateway.

## Current local install shape

- Installed plugin path: `/Users/mo/.openclaw/extensions/inline`
- Active runtime file: `/Users/mo/.openclaw/extensions/inline/dist/index.js`
- This install is a copied plugin directory, not a symlink.
- Because of that, `openclaw plugins install --link /Users/mo/dev/inline/packages/openclaw-inline` currently fails with:
  - `plugin already exists: /Users/mo/.openclaw/extensions/inline (delete it first)`

## Fast local test loop

From `/Users/mo/dev/inline`:

```bash
cd packages/openclaw-inline && bun run build
cp -R /Users/mo/dev/inline/packages/openclaw-inline/dist/. /Users/mo/.openclaw/extensions/inline/dist/
openclaw gateway restart
```

## Verification

Confirm the installed gateway plugin matches the freshly built repo artifact:

```bash
shasum -a 256 /Users/mo/dev/inline/packages/openclaw-inline/dist/index.js /Users/mo/.openclaw/extensions/inline/dist/index.js
```

The two hashes should be identical.

Optional timestamp check:

```bash
stat -f '%Sm %N' -t '%Y-%m-%d %H:%M:%S' /Users/mo/dev/inline/packages/openclaw-inline/dist/index.js /Users/mo/.openclaw/extensions/inline/dist/index.js
```

## Notes

- `openclaw gateway restart` is the correct command for the background LaunchAgent-managed gateway on this machine.
- The gateway restart currently emits an unrelated warning about Telegram `groupAllowFrom` being empty. That warning does not block the Inline plugin reload.
- If you want true linked-install development later, remove or rename `/Users/mo/.openclaw/extensions/inline` first, then reinstall with:

```bash
openclaw plugins install --link /Users/mo/dev/inline/packages/openclaw-inline
openclaw gateway restart
```
