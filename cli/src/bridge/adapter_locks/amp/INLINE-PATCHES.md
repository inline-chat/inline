# Inline Amp ACP patches

Source: `tao12345666333/amp-acp` at `e4ccce1b57c7ae92d75e8ba97fc03b92d414c06a`.

The embedded `dist/index.js` is built with Bun while keeping
`@agentclientprotocol/sdk` and `@ampcode/sdk` external. Inline adds `--no-ide`
to Amp's direct CLI transport. A managed background bridge has no IDE session,
and current Amp builds can otherwise block before producing stream output.

Equivalent source patch:

```diff
--- a/src/amp-transport.ts
+++ b/src/amp-transport.ts
@@
-  args.push('--execute', '--stream-json', '--no-archive-after-execute');
+  args.push('--execute', '--stream-json', '--no-archive-after-execute', '--no-ide');
```
