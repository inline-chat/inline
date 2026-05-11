# OpenClaw Main Changes To Reapply

During the `swiftui-shell` rebase onto `origin/main`, the pre-existing branch commit
`29580639 openclaw: release inline plugin 0.0.35` conflicted with `origin/main`
commit `8924bd86 openclaw: release inline metadata fix (#93)`.

Decision for this macOS migration rebase: keep the branch OpenClaw state and
override the OpenClaw changes from `origin/main`. Revisit the main-side changes
below when OpenClaw work resumes.

## Reapply Later

- Reconcile `packages/openclaw/openclaw.plugin.json` metadata from `8924bd86`:
  `channelEnvVars.inline = ["INLINE_TOKEN"]`, the generated
  `channelConfigs.inline.schema`, and the richer settings/help metadata.
- Port the native inbound-envelope behavior from `monitor.ts`: use
  `core.channel.reply.formatInboundEnvelope`, include `chatType`, `sender` or
  `senderLabel`, preserve conversation labels like `Project Room id:88`, and
  keep reaction/callback `BodyForAgent` free of actor prefixes.
- Reapply the sender-label changes in history/context formatting: prefer
  `Name (@username) id:<id>`, `@username id:<id>`, or `id:<id>` instead of the
  old `user:<id>` fallback.
- Reapply the message-action metadata fixes in `actions.ts`: tolerate missing
  button values and use the `presentation` capability for inline buttons.
- Reapply/port the test coverage added by `8924bd86`: manifest config schema
  sync, packed artifact exclusion of `tsconfig.tsbuildinfo`, native inbound
  envelope expectations, and the small action/tool expectation updates.
- Reconcile package metadata and lockfile choices. The branch kept the `0.0.35`
  package state and OpenClaw `2026.5.7`; main carried the metadata fix with the
  host requirement around `2026.4.26`.
- Regenerate `bun.lock` from the final OpenClaw package choice.
