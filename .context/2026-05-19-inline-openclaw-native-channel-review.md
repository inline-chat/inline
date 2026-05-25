# Inline OpenClaw Native Channel Review

Date: 2026-05-19

Goal: update local OpenClaw to 2026.5.18, update `~/dev/openclaw`, then do a ground-up comparison of the Inline plugin against native channel plugins, mainly Telegram and Slack, to find bugs, inconsistent behavior, confusing copy, prompt drift, and production polish gaps.

## Update Status

- Local `openclaw` CLI is updated:
  - `openclaw --version` -> `OpenClaw 2026.5.18 (50a2481)`.
  - Stock Telegram in the installed OpenClaw package is `2026.5.18`.
  - Installed Inline plugin is `0.0.36`, installed from the locally packed artifact.
  - Active Inline source: `/Users/mo/.openclaw/extensions/inline/dist/index.js`.
- `~/dev/openclaw` clone is updated and clean:
  - HEAD -> `50a2481652b6a62d573ece3cead60400dc77020d`.
  - Release commit subject: `chore(release): prepare 2026.5.18 stable`.
  - `git -C /Users/mo/dev/openclaw status --short` -> clean.
  - Note: the clone is shallow/blobless. Checkout required letting Git fetch missing promisor objects and disabling the unavailable global Git LFS filter for the switch command.
- Comparison baseline:
  - Telegram: installed OpenClaw `2026.5.18` dist and updated `~/dev/openclaw`.
  - Slack: updated `~/dev/openclaw` at `v2026.5.18` plus installed OpenClaw dist for metadata/runtime checks.

## Implementation Progress

Fixed in the working tree after this review started:

- `commands.native: false` now skips Inline startup command sync instead of clearing the bot command menu.
- Startup command sync now calls `setMyCommands` directly instead of delete-then-set.
- Startup command sync truncates overlong command descriptions before calling the Inline Bot API.
- Rich `sendPayload` responses now pass `threadId` through so media/presentation replies can route into Inline reply-thread chats.
- README/tool copy no longer describes Inline command lists as Telegram-style or claims startup sync clears commands.
- Package/runtime/plugin metadata now use consistent `Inline (Bot API)` / `Inline Bot` copy, aligned blurb text, markdown capability, native command defaults, system image, and `INLINE_TOKEN` / `INLINE_BOT_TOKEN` env configured-state metadata.
- Package metadata now includes a setup entry (`./dist/setup-entry.js`) and the npm artifact ships `setup-entry.js`, `setup-plugin-api.js`, and `configured-state.js`.
- Setup onboarding now loads a narrow setup-only plugin entry instead of bundling the realtime monitor/tools into setup paths.
- Runtime account resolution now honors `INLINE_TOKEN` and `INLINE_BOT_TOKEN` for the default account, matching setup/configured-state behavior.
- Setup wizard now uses native-style status copy, includes clearer Inline bot-token help, includes an Inline DM allowlist section, exposes DM policy setup, and warns when pairing mode has no allowlist.
- Package dependency metadata now targets OpenClaw `2026.5.18`: dev dependency, peer dependency, install min host, and lockfile.
- Native command sync and native command-menu resolution now use the `inline` provider identity instead of `telegram`.
- Inline now exposes its own command UI builders for `/commands`, `/model`, and `/models`, returning `channelData.inline` buttons while keeping `channelData.telegram` as a compatibility fallback.
- Inline now handles paginated `/commands` button callbacks directly, so the new command-list pagination controls are not dead buttons.
- Setup now prepares a wildcard group mention gate (`groups["*"].requireMention=true`) like native Telegram, exposes native-style group access configuration, and warns for empty group allowlists or broad open group access without a mention requirement.
- Runtime group allowlist checks now honor `channels.inline.groups` route allowlists independently from `groupAllowFrom` sender filters. A configured group chat no longer gets dropped just because no sender allowlist exists.
- Inline group config now accepts mention-only setup defaults, for example `groups: { "*": { requireMention: true } }`.
- Inline formatting guidance now uses OpenClaw's structured `agentPrompt.inboundFormattingHints` response-format hook. `GroupSystemPrompt` now carries only configured custom Inline guidance.
- Generic fallback error copy is centralized and clearer about OpenClaw processing failures.
- README/setup docs now include a user-facing access policy table for DMs, groups, sender allowlists, and mention requirements.
- Local development install docs now use the packed artifact flow that worked with OpenClaw's package-root safety checks.
- Sanitizer tests now include the current OpenClaw 2026.5.18 runtime event and legacy runtime-context preface forms.
- Local OpenClaw runtime now has the packed Inline plugin installed and the gateway restarted.
- Gateway health is OK and Inline connects from the new package.
- Package metadata no longer ships the legacy `moltbot` extension block; OpenClaw 2026.5.18 now sees only the `openclaw` metadata path.
- Inline command/model buttons now match Telegram's native compact labels for pagination and current model state (`◀ Prev`, `Next ▶`, `✓`, leading ellipsis) while still emitting `channelData.inline`.
- Package metadata now includes the external-plugin release contract used by production OpenClaw channel plugins: optional OpenClaw peer metadata, `openclaw.compat.pluginApi >=2026.5.18`, `openclaw.build.openclawVersion = 2026.5.18`, and npm/ClawHub release flags.
- Manifest setup help no longer says "realtime bot tokens" and now mentions both `INLINE_TOKEN` and `INLINE_BOT_TOKEN`.
- Package metadata now advertises `quickstartAllowFrom: true`, matching runtime metadata and native chat providers that participate in OpenClaw's standard quickstart allowlist flow.
- Inline now has a channel doctor adapter and package `doctorCapabilities` matching its hybrid route/sender group model, so OpenClaw doctor does not fall back to generic sender-only warnings.
- Generic Inline formatting instructions moved out of per-turn `GroupSystemPrompt` and into `agentPrompt.inboundFormattingHints`, matching Slack's native prompt contract.
- Native command sync now treats OpenClaw's native command registry as the source of truth instead of maintaining a stale Inline-local base command list.
- Native skill command sync is scoped per Inline account route, so multi-account installs can expose the correct skill commands for each bound agent.
- Plugin command specs are now resolved with the active OpenClaw config, matching Telegram's current native command integration pattern.
- Inline-visible command/callback copy now adapts shared Discord/Telegram wording and generic thread/topic variants into Inline conversation wording before syncing native commands or sending text.
- Direct package dependencies and OpenClaw-facing dev dependencies are pinned exactly for the 2026.5.18 release baseline.
- Setup docs and config UI hints now use explicit gateway commands and clearer `dmPolicy` / `groupAllowFrom` wording.
- Manifest, README, tool descriptions, and tool parameter schema copy now use Inline bot-command wording instead of user-facing "slash command" or "native command" jargon.
- Manifest streaming compatibility hints now describe shared OpenClaw streaming config rather than telling Inline users about "native channels".
- Reply-thread tool hints now describe both enabled native reply-thread behavior and disabled compatibility-mode behavior.
- Inline now advertises the `inlineButtons` message-tool capability when configured actions can render buttons/selects, avoiding a misleading generic prompt that said Inline buttons were disabled.
- Inline status account snapshots now use the same credential inspector as setup/config, so unavailable token files show as unconfigured instead of suppressing status issues.
- Inline now blocks duplicate concrete bot-token ownership across accounts, matching Telegram's one-owner-per-token guard and preventing duplicate realtime monitors or duplicate command-menu sync for the same bot credential.
- Inline message-tool action discovery and `inlineButtons` prompt capability are now scoped to the active account instead of unioning actions across every configured account.
- Inline realtime status now reports `connected`, `lastConnectedAt`, `lastEventAt`, and `lastTransportActivityAt` like native channels, with startup-grace status issues for monitors that keep running without connecting.
- Inline group control-command gating now consults OpenClaw's standard command authorization helper, so `commands.allowFrom.inline` can authorize command users and `commands.ownerAllowFrom` can restrict otherwise allowlisted group senders before agent dispatch.
- Inline DM and group sender allowlists now expand OpenClaw `accessGroup:<name>` entries like native Telegram, and the security audit no longer reports access-group allowlist entries as invalid non-numeric senders.
- Interactive-only Inline replies and message-tool sends now derive visible fallback text from shared interactive/presentation labels, matching Telegram's button-only fallback behavior and Slack's block fallback behavior instead of dropping or sending empty-text controls.
- Inline live reply delivery, command/model callback edits, message actions, and plugin messaging transforms now share the same Inline visible-text sanitizer as direct outbound sends, so bare URLs are not accidentally rendered as code and shared Discord/Telegram command copy is adapted before users see it.
- Inline now exposes a native-style outbound session route resolver, so explicit `chat:<id>`, `inline:<id>`, `user:<id>`, resolved bare user ids, and reply-thread ids produce canonical session metadata instead of falling through to OpenClaw's generic target parser.
- Inline now handles message edit/delete realtime events as native-style lifecycle system events instead of dropping them. Edits are sender-authorized, self-edits are ignored, and delete events use the direct chat peer or allowed group route without triggering immediate replies or pairing side effects.
- Inline reply-thread-disabled agent hints no longer say "native reply-thread chat"; the copy now describes a "dedicated Inline reply-thread chat" to avoid native-channel leakage.
- Inline reaction add/remove events on bot messages now queue native-style system events instead of triggering immediate agent replies, aligning the behavior with Telegram/Slack reaction notifications.
- Inline now exposes `reactionNotifications: "off" | "own" | "all"`, matching native reaction notification controls so operators can suppress reaction events or opt into all authorized message reactions.
- Inline now advertises `messaging.targetPrefixes = ["inline"]`, so OpenClaw can recognize `inline:` as an Inline provider prefix during cross-channel target validation.
- Inline now exposes heartbeat typing hooks for chat and reply-thread destinations, reusing Inline's existing typing transport for cron/heartbeat replies.
- Inline now exposes native-style minimal reaction prompt guidance when `react` is enabled, and suppresses it when `channels.inline.actions.reactions=false`.
- Inline now exposes OpenClaw's newer `message` adapter over its existing outbound send paths, matching Telegram/Slack/Discord channel contracts.
- Inline target-display formatting now falls back to the raw target instead of throwing for unresolved or invalid target strings.
- Inline-specific nudge/forward tools now default to the child reply-thread chat when invoked from an Inline reply-thread session.
- Inline's static manifest now advertises account-level `reactionNotifications`, matching the runtime schema and preventing config UI/schema drift for multi-account users.
- Inline now supports Slack-style selective reaction notifications with `reactionNotifications: "allowlist"` and `reactionAllowlist`, while preserving the Telegram-compatible `"own"` default.
- Inline account inspection, account descriptions, and status snapshots now surface the effective reaction notification mode and reaction allowlist like Slack account surfaces do.
- Inline security audit now validates `reactionAllowlist` entries so invalid display names are flagged instead of silently never matching reaction senders.
- Inline config and manifest schemas now accept numeric sender IDs as either strings or numbers for `allowFrom`, `groupAllowFrom`, and `reactionAllowlist`, matching native Telegram/Slack allowlist ergonomics.
- Inline now supports native-style `defaultTo` outbound targets at top level and per named account, so `openclaw message send --channel inline` can use configured fallback destinations like Telegram and Slack.
- README/setup docs now mention Inline `defaultTo`, including top-level and named-account examples, so the new native-style outbound fallback is discoverable.
- Inline now maps OpenClaw session-derived group/channel targets back to `chat:<id>`, matching the native `resolveSessionTarget` hook used by Telegram/Slack for session announce delivery.
- Inline now maps OpenClaw conversation delivery targets to Inline `chat:<id>` targets, including parent chat plus reply-thread chat id handling for child conversations.
- Inline now strips the active bot username mention from agent-facing prompt bodies for native-mentioned group messages, while preserving `RawBody` and command parsing.
- Inline now passes native-style mention facts into group prompt context, including explicit bot mention state, mentioned Inline user IDs, implicit wake reasons, and mention source.

The findings below record the ground-up audit. Some are intentionally left in original form even after fixes so the review preserves what was found and why the change was made.

## High Priority Findings

### 1. Package metadata and runtime metadata disagree

Status: fixed in the working tree. `package.json`, runtime `inlineMeta`, setup plugin metadata, the external manifest channel description, and the root plugin manifest now use `Inline (Bot API)` and `Use OpenClaw from Inline DMs and chats with an Inline bot token.` with order `30`.

Inline package metadata says:

- `selectionLabel`: `Inline (realtime bot)`
- `blurb`: `Interact with OpenClaw via Inline DMs and chats.`
- `order`: `115`

Runtime channel metadata says:

- `selectionLabel`: `Inline (native)`
- `blurb`: `Inline Chat via realtime RPC (bot token).`
- `order`: `30`

Refs:

- `packages/openclaw/package.json:45`
- `packages/openclaw/src/inline/channel.ts:51`

Why it matters:

- The setup/plugin picker can show different copy before and after load.
- `Inline (native)` is misleading: this is the external Inline plugin, not a bundled native provider.
- Native providers keep this metadata consistent. Telegram uses `Telegram (Bot API)`, Slack uses `Slack (Socket Mode)`.

Fix:

- Pick one label/copy set and use it in package metadata, runtime meta, plugin manifest, README, and docs.
- Suggested selection label: `Inline (Bot API)`.
- Suggested blurb: `Use OpenClaw from Inline DMs and chats with an Inline bot token.`

### 2. Inline lacks native provider setup metadata

Status: fixed in the working tree. Inline now declares a split `setupEntry`, `detailLabel`, `systemImage`, `markdownCapable`, command auto-enable metadata, `configuredState` for `INLINE_TOKEN`/`INLINE_BOT_TOKEN`, and setup-only sidecars for configured-state, secrets, runtime registration, and account inspection.

Native Telegram package metadata includes:

- `setupEntry`
- `setupFeatures`
- `channel.detailLabel`
- `channel.systemImage`
- `channel.markdownCapable`
- `channel.commands.nativeCommandsAutoEnabled`
- `channel.commands.nativeSkillsAutoEnabled`
- `channel.configuredState`

Slack has similar setup/discovery metadata.

Inline package metadata only has `extensions`, `channel`, and `install`.

Refs:

- Inline: `packages/openclaw/package.json:41`
- Telegram: `/opt/homebrew/lib/node_modules/openclaw/dist/extensions/telegram/package.json:17`
- Slack 2026.5.18: `https://raw.githubusercontent.com/openclaw/openclaw/v2026.5.18/extensions/slack/package.json`

Why it matters:

- The plugin chooser/setup flow cannot pre-detect configuration the way native providers can.
- Users lose the richer setup surfaces and confidence indicators that make Telegram/Slack feel first-class.
- `markdownCapable` is missing even though Inline has markdown handling and formatting prompts.

Fix:

- Add `setupEntry` if external plugin setup entries are supported for npm plugins.
- Add `detailLabel`, `systemImage`, `markdownCapable`, command auto-enable metadata, and configured state.
- Add configured-state support for `INLINE_TOKEN`, and consider accepting `INLINE_BOT_TOKEN` as an alias while preserving `INLINE_TOKEN`.

### 3. Setup wizard is too thin compared with native providers

Status: fixed in the working tree. Inline now uses a full setup surface with token help, env shortcut, inspected credential status, allowlist and DM policy sections, group access prompts, account-scoped behavior, and final warnings for pairing/no-allowlist and blocked group access.

Inline setup wizard only covers status, one token credential, and disable.

Native Telegram setup covers:

- Standard status copy
- `prepare` step that sets a safer default group mention gate
- Credential help
- Allowlist section
- DM policy section
- Final warning when DMs are in pairing mode with no allowlist

Native Slack setup covers:

- Intro note and manifest
- Env shortcut
- Two credentials
- DM policy
- Allowlist
- Group/channel access
- Final interactive replies prompt/default

Refs:

- Inline: `packages/openclaw/src/inline/setup-surface.ts:11`
- Telegram: `/opt/homebrew/lib/node_modules/openclaw/dist/channel.setup-DOFx9Q1W.js:252`
- Slack 2026.5.18: `https://raw.githubusercontent.com/openclaw/openclaw/v2026.5.18/extensions/slack/src/setup-core.ts`

Why it matters:

- Users paste a token and still do not understand DM pairing, who can talk to the bot, why groups may silently drop, or how to allow themselves.
- This is probably one of the biggest UX gaps versus Telegram/Slack.

Fix:

- Add a full setup wizard:
  - Token help with exact Inline bot creation steps.
  - Env shortcut for `INLINE_TOKEN`.
  - DM policy prompt.
  - Allowlist prompt that can accept Inline user ids, `user:<id>`, and possibly handles/usernames if the API can resolve them.
  - Group access prompt or at least a clear final note when `groupPolicy` is `allowlist` and there are no groups.
  - Final pairing/access warning similar to Telegram.

### 4. Unsafe or confusing group defaults are only warned later

Status: fixed in the working tree. Inline setup now mirrors Telegram's fresh-setup behavior by preparing `groups["*"].requireMention = true` when no wildcard mention rule exists, plus final group access warnings and docs/UI copy explaining `groupPolicy`, `groups`, `groupAllowFrom`, and `requireMention`.

Inline resolves group mention default to `false` when not configured:

- `requireMentionDefault: resolved.config.requireMention ?? false`

Inline warns only when `groupPolicy` is `open`, but setup does not teach the user what group policy means.

Refs:

- `packages/openclaw/src/inline/channel.ts:951`
- `packages/openclaw/src/inline/channel.ts:887`

Why it matters:

- If a user opens group policy without understanding mention requirements, any group message can reach the agent.
- Native Telegram explicitly prepares a default group mention gate.

Fix:

- Add setup `prepare` or finalize logic for group safety.
- Consider defaulting wildcard group mention behavior to `true` when setup enables group access.
- Improve setup copy around `groupPolicy`, `groupAllowFrom`, and `requireMention`.

### 5. `commands.native: false` clears bot commands instead of disabling sync

Status: fixed in the working tree. Startup command sync now returns without Bot API calls when `commands.native` resolves to `false`; README copy states disabled startup sync does not modify existing bot commands.

Current behavior:

- If native commands are disabled, Inline builds `commands = []`.
- It still calls `deleteMyCommands`.
- It then calls `setMyCommands` with an empty command list.
- Tests explicitly lock in this behavior.

Docs say:

- "Disable startup sync globally with `commands.native: false`..."

Refs:

- `packages/openclaw/src/inline/bot-commands-sync.ts:122`
- `packages/openclaw/src/inline/bot-commands-sync.ts:156`
- `packages/openclaw/src/inline/bot-commands-sync.test.ts:73`
- `packages/openclaw/README.md:225`

Why it matters:

- "Disable sync" should usually mean "do not touch my commands", not "clear my bot menu".
- Users with custom Inline bot commands can lose them on gateway start.
- This is a production footgun.

Fix:

- Change `commands.native: false` to skip startup command API calls.
- If clearing is wanted, add an explicit `commands.native: "clear"` or dedicated tool action.
- Update tests and docs.

### 6. Startup command sync deletes before setting

Status: fixed in the working tree. Startup command sync now calls `setMyCommands` directly for non-empty resolved commands and does not call `deleteMyCommands` as part of normal sync; deletion remains explicit through the `inline_bot_commands` tool.

Current behavior:

- For each account, Inline calls `deleteMyCommands`.
- Then it calls `setMyCommands`.

Refs:

- `packages/openclaw/src/inline/bot-commands-sync.ts:156`

Why it matters:

- If `deleteMyCommands` succeeds and `setMyCommands` fails, the bot is left with no commands.
- If `setMyCommands` already replaces the command list, the delete is unnecessary risk.

Fix:

- Prefer `setMyCommands` directly when syncing non-empty commands.
- Only delete when explicitly clearing.
- Add a regression test where set fails after delete would have caused data loss.

### 7. Inline command sync and command menus use Telegram provider identity

Status: fixed in the working tree. Inline now requests native specs with `provider: "inline"`, resolves command menus with `findCommandByNativeName(..., "inline")`, passes `Surface: "inline"` for `/model` and `/models`, and exposes Inline-specific command UI builders. `channelData.telegram.buttons` remains only as a compatibility fallback for previously emitted or third-party Telegram-shaped button payloads.

Examples:

- Native command specs are requested with `provider: "telegram"`.
- Command menus resolve with `findCommandByNativeName(..., "telegram")`.
- `/model` and `/models` force `effectiveSurface = "telegram"`.
- Tests refer to "Telegram-style reasoning mode choices".

Refs:

- `packages/openclaw/src/inline/bot-commands-sync.ts:95`
- `packages/openclaw/src/inline/monitor.ts:615`
- `packages/openclaw/src/inline/monitor.ts:884`
- `packages/openclaw/src/inline/monitor.ts:2368`
- `packages/openclaw/src/inline/monitor.test.ts:1166`

Why it matters:

- Inline inherits Telegram command naming, menu behavior, and channel data by accident.
- This can create confusing UI, wrong prompts, or future breakage if Telegram command behavior diverges.
- Native Slack uses `provider: "slack"` and resolves Slack-specific command names.

Fix:

- Add a first-class `inline` native command provider/surface in OpenClaw if possible.
- Otherwise create a shared generic "button-capable chat" command UI surface instead of pretending Inline is Telegram.
- Rename tests and copy away from "Telegram-style".

### 8. Native command list is hand-maintained and can drift

Status: fixed in the working tree and installed local artifact. Inline no longer has a local `INLINE_BASE_NATIVE_COMMANDS` list. It uses OpenClaw's native registry for base commands, then appends plugin command specs.

Inline has a static `INLINE_BASE_NATIVE_COMMANDS`, then appends native registry commands and plugin commands.

Refs:

- `packages/openclaw/src/inline/bot-commands-sync.ts:8`

Why it matters:

- Descriptions, enablement, and command presence can drift from OpenClaw's real native command registry.
- Some descriptions are terse or inconsistent, for example "Set send policy." and "Set exec defaults for this session."

Fix:

- Use registry data as the source of truth.
- Keep only Inline-specific additions in Inline code.
- Add tests that compare expected base command names against the native registry for `inline` or the shared generic surface.

### 9. Command description constraints are not enforced in startup sync

Status: fixed in the working tree. Startup sync now normalizes command names, skips invalid/empty descriptions, truncates descriptions to Inline's 256-character limit with a warning, de-duplicates command names, and caps the Bot API command list at 100.

The `inline_bot_commands` tool validates description length to 1..256.

Startup sync only trims descriptions and validates command names. It does not enforce description length.

Refs:

- Startup sync: `packages/openclaw/src/inline/bot-commands-sync.ts:50`
- Tool validation: `packages/openclaw/src/inline/bot-commands-tool.ts:101`

Why it matters:

- A long plugin/native command description can make startup command registration fail.
- The README claims Inline Bot API limits apply.

Fix:

- Share command validation between the tool and startup sync.
- Truncate or skip invalid commands with a clear warning.
- Test overlong descriptions and duplicate command names.

### 10. Thread capability is advertised unconditionally but native reply threads are disabled by default

Status: clarified after re-checking OpenClaw 2026.5.18. Static `capabilities.threads: true` is consistent with Telegram and Slack: it means the channel has thread-capable surfaces/hooks, not that every account config currently uses native thread delivery. The real remaining mismatch was prompt/copy clarity for the always-exposed `thread-reply` and `thread-create` actions when `replyThreads` is disabled; that is now fixed in the working tree.

Inline channel capabilities always include `threads: true`.

Docs and runtime config say native reply-thread support is behind `channels.inline.capabilities.replyThreads`.

Refs:

- Capability: `packages/openclaw/src/inline/channel.ts:804`
- Config: `packages/openclaw/src/inline/reply-threads.ts:47`
- README: `packages/openclaw/README.md:185`

Why it matters:

- OpenClaw and agents may assume thread semantics are available even when Inline is in compatibility mode.
- The visible tool guidance is correctly conditional, but the capability contract is not.

Fix:

- Keep static `threads: true`, matching Telegram and Slack.
- Keep runtime `threading.resolveReplyTransport` config-aware.
- Tell the agent what `thread-reply` and `thread-create` do in disabled compatibility mode so it does not infer native reply-thread semantics from the action names.

### 11. `sendPayload` ignores thread routing

Status: fixed in the working tree. `sendPayload` now accepts and forwards `threadId` for text, media, and fallback sends, with regression coverage for multi-media reply-thread payloads.

`sendText` and `sendMedia` accept `threadId`.

`sendPayload` does not destructure `threadId` and passes `threadId: null` for text, media, and fallback sends.

Refs:

- `packages/openclaw/src/inline/channel.ts:1217`
- `packages/openclaw/src/inline/channel.ts:1236`
- `packages/openclaw/src/inline/channel.ts:1254`
- Tests do not pass a thread id in the `sendPayload` media test: `packages/openclaw/src/inline/channel.test.ts:1491`

Why it matters:

- Presentation payloads with buttons/selects/media can fail to route into native Inline reply-thread chats.
- This creates a subtle inconsistency: plain text threads work, rich replies may not.

Fix:

- Accept and pass `threadId` through `sendPayload`.
- Add tests for presentation payloads and multi-media payloads inside reply threads.

### 12. Inline accepts `channelData.telegram.buttons`

Inline first looks for `channelData.inline.buttons`, then falls back to `channelData.telegram.buttons`.

Refs:

- `packages/openclaw/src/inline/monitor.ts:805`

Why it matters:

- Compatibility is useful, but this reinforces Telegram leakage.
- It can hide missing Inline-specific command/channel data until a Telegram change breaks Inline.

Fix:

- Keep compatibility if needed, but prefer explicit Inline channel data everywhere.
- Add logging or tests that ensure first-class Inline payloads are generated for Inline.

## Medium Priority Findings

### 13. Setup token copy is vague and less helpful than native providers

Status: fixed in the working tree. Setup help now says `Inline token`, gives exact Inline bot creation/reveal commands, links to Inline bot and OpenClaw docs, and accepts `INLINE_BOT_TOKEN` as a compatibility alias.

Inline setup help:

- "Open Inline and generate a bot token for your workspace/account"
- "Copy the token"
- "Paste it here, or set INLINE_TOKEN in your environment"

Refs:

- `packages/openclaw/src/inline/setup-core.ts:6`

Why it matters:

- Telegram tells users exactly to use BotFather.
- Slack emits a manifest and exact token prompts.
- Inline users need direct, concrete steps and links.

Fix:

- Link both:
  - `https://inline.chat/docs/openclaw`
  - `https://inline.chat/docs/creating-a-bot`
- Use "Inline bot token" consistently.
- Consider adding `INLINE_BOT_TOKEN` alias for clarity.

### 14. Setup status copy is less polished

Status: fixed in the working tree. Inline now uses `createStandardChannelSetupStatus` with `recommended · configured`, `recommended · bot token`, and `needs bot token`, backed by read-only account inspection.

Inline status labels:

- configured hint: `configured`
- unconfigured hint: `recommended`
- unconfigured label: `needs token`

Telegram:

- `recommended · configured`
- `recommended · newcomer-friendly`

Slack:

- `needs tokens`

Refs:

- Inline: `packages/openclaw/src/inline/setup-surface.ts:13`
- Telegram: `/opt/homebrew/lib/node_modules/openclaw/dist/channel.setup-DOFx9Q1W.js:254`
- Slack 2026.5.18: `https://raw.githubusercontent.com/openclaw/openclaw/v2026.5.18/extensions/slack/src/setup-core.ts`

Fix:

- Use standard setup status helper if available.
- Use "needs bot token" instead of "needs token".

### 15. Bot command tool copy says "Telegram-style"

Status: fixed in the working tree. User-facing tool and README copy now refer to Inline Bot API command lists and explicit `getMyCommands`/`setMyCommands`/`deleteMyCommands` actions, without Telegram-style wording.

Refs:

- `packages/openclaw/src/inline/bot-commands-tool.ts:31`
- README: `packages/openclaw/README.md:221`

Why it matters:

- Users should not need to understand Telegram to operate Inline.

Fix:

- Replace with "Inline Bot API command list".
- If the shape is Telegram-compatible, mention that only in implementation docs, not user-facing tool copy.

### 16. Formatting instructions are duplicated and heavy

Status: fixed in the working tree. Formatting guidance is now only included through `buildInlineSystemPrompt`; inbound message bodies no longer repeat the same Inline formatting note.

There are two long formatting strings:

- `INLINE_FORMATTING_NOTE`
- `INLINE_SYSTEM_PROMPT_BASE`

They repeat the same rules about bullet lists, markdown tables, bare URLs, and inline code.

Refs:

- `packages/openclaw/src/inline/message-formatting.ts:1`
- `packages/openclaw/src/inline/monitor.ts:2323`

Why it matters:

- Repeated prompt text increases context noise.
- It can over-steer the model and make replies feel more artificial.

Fix:

- Keep one concise channel formatting contract.
- Prefer centralized inbound formatting hints if OpenClaw supports them, like Slack does for mrkdwn.

### 17. Sanitizer is copied around current OpenClaw internal strings

Status: partially addressed. Current OpenClaw 2026.5.18 runtime-context strings were re-checked against the updated OpenClaw clone/dist, and tests now cover delimited context, next-turn context, runtime event prefaces, legacy prefaces, and heartbeat acknowledgements. The longer-term ideal is still an upstream non-visible/internal-message contract.

Inline strips:

- `HEARTBEAT_OK`
- `OpenClaw runtime context...`
- `<<<BEGIN_OPENCLAW_INTERNAL_CONTEXT>>>`

Refs:

- `packages/openclaw/src/inline/outbound-sanitize.ts:1`

Why it matters:

- This protects users from internal-context leaks, but it is brittle if OpenClaw 2026.5.18 changed internal context wording.
- The fact Inline needs this sanitizer means there may still be dispatch paths that expose internal prompts.

Fix:

- Re-check against 2026.5.18 OpenClaw runtime output.
- Prefer an upstream flag/event field that marks internal messages non-visible instead of string stripping.
- Keep tests but add current 2026.5.18 fixtures.

### 18. Generic fallback error copy is duplicated

Status: fixed in the working tree. Fallback copy now uses centralized constants for dispatch/request errors and debounced-message failures.

Inline sends:

- "Something went wrong while processing your request. Please try again."
- "Something went wrong while processing your message. Please try again."

Refs:

- `packages/openclaw/src/inline/monitor.ts:2851`
- `packages/openclaw/src/inline/monitor.ts:2933`

Why it matters:

- The copy is acceptable but generic.
- It can be confusing when the failure is a callback/action failure, stream failure, or empty response.

Fix:

- Centralize fallback copy.
- Distinguish "message failed to send" from "OpenClaw failed while processing".
- Avoid sending fallback messages for intentionally silent skips.

### 19. The plugin manifest and package metadata are not aligned

Status: fixed in the working tree. The root external plugin manifest description, channel config manifest description, package `openclaw.channel.blurb`, and runtime metadata now use the same production blurb; manifest tests assert the root description as well.

Plugin manifest description:

- `Inline channel plugin (realtime RPC bot token; DMs + chats).`

Runtime plugin description:

- `Inline Chat channel plugin (realtime RPC)`

Package metadata blurb:

- `Interact with OpenClaw via Inline DMs and chats.`

Refs:

- `packages/openclaw/openclaw.plugin.json:4`
- `packages/openclaw/src/index.ts:22`
- `packages/openclaw/package.json:51`

Fix:

- Use one product name and one phrase:
  - Product: `Inline`
  - Transport: `Inline Bot API`
  - Description: `Inline channel plugin for OpenClaw bots.`

### 20. Docs mention stale config in confusing terms

Status: fixed in the working tree and installed local artifact. README/setup docs now include an update/restart/verify path, env-token aliases, packed local install flow, a plain-language access policy table, and Inline-specific reply-thread/media wording instead of implementation-style "native" copy.

README troubleshooting says:

- `plugin not found: inline`
- `doctor --fix` suggests Inline changes...
- `Plugin entry id should be inline.`

Landing docs reportedly include "If a stale config appears, keep `plugins.entries.inline`."

Why it matters:

- Users need exact migration/update steps, not internal config hints.

Fix:

- Add an "Update existing install" section:
  - `openclaw plugins update inline`
  - verify `openclaw plugins list`
  - restart gateway
  - verify `/status` or `inline_bot_commands action:get`
- Explain what to do with old `moltbot` config only if still relevant.

### 21. Dev dependency is pinned to an older OpenClaw than the target baseline

Status: fixed in the working tree. Inline now targets OpenClaw `2026.5.18` across dev dependency, peer dependency, install min host, plugin API compatibility metadata, build metadata, and lockfile. The OpenClaw peer is marked optional like production external channel plugins.

Inline package devDependency:

- `openclaw: "2026.5.7"`

Target local OpenClaw:

- `2026.5.18`

Refs:

- `packages/openclaw/package.json:37`

Why it matters:

- Typechecking/tests may not match the production OpenClaw users will run after the update.
- Slack's 2026.5.18 package declares `peerDependencies.openclaw >=2026.5.18`, `compat.pluginApi >=2026.5.18`, and build metadata for OpenClaw `2026.5.18`. Inline should make an intentional compatibility claim instead of accidentally testing against one host version and advertising another.

Fix:

- Update devDependency to `2026.5.18`.
- Keep peer dependency floor only if compatibility with `>=2026.4.26` is actually tested.

### 22. Native command provider support should be checked against peer floor

Status: fixed in the working tree by raising the floor instead of trying to keep an unproven older compatibility claim. `peerDependencies.openclaw`, `openclaw.install.minHostVersion`, and `openclaw.compat.pluginApi` all now require `>=2026.5.18`.

Inline imports newer-looking SDK entry points:

- `plugin-runtime`
- `skill-commands-runtime`
- `allowlist-config-edit`
- `status-helpers`

Refs:

- `packages/openclaw/src/inline/channel.ts:10`
- `packages/openclaw/src/inline/bot-commands-sync.ts:2`

Why it matters:

- Peer dependency allows `openclaw >=2026.4.26`.
- If any export was added after that, older hosts can fail at runtime.
- Native Slack tightened its own peer/compat metadata in 2026.5.18, so Inline should not be looser unless we actively verify the lower host range.

Fix:

- Run a compatibility check against `openclaw@2026.4.26`, or raise the peer/min host version.
- Align `peerDependencies.openclaw` and `openclaw.install.minHostVersion`.

### 23. Capability docs expose too much internal shape

Status: improved in the working tree. The command-sync docs no longer use Telegram-style/native-defaults copy, and the access model is documented in user terms. Native reply-thread docs still intentionally describe `threadId` because that is part of the OpenClaw-facing behavior.

README has several highly technical details:

- "Telegram-style startup behavior"
- "OpenClaw native defaults"
- "threadId maps to child reply-thread chat id"

Refs:

- `packages/openclaw/README.md:185`
- `packages/openclaw/README.md:225`

Why it matters:

- Production users need operational clarity first.
- Internal compatibility details should move to developer notes.

Fix:

- Split docs:
  - User setup
  - Admin/security config
  - Developer/internal behavior

## Lower Priority / Polish Findings

### 24. Runtime meta order differs from package order

Status: fixed in the working tree. Package and runtime metadata both use `order: 30`, keeping Inline near first-class chat providers consistently across picker and runtime surfaces.

This is part of the metadata mismatch, but the order difference is especially visible in channel pickers.

Fix:

- Decide whether Inline should sit near native chat providers or installed external plugins.
- Use the same order in both places.

### 25. `docsPath` points to `/channels/inline`, but Inline docs live under Inline docs URLs too

Native provider docs are under OpenClaw `/channels/...`.

Inline user docs also live at `https://inline.chat/docs/openclaw`.

Fix:

- Keep OpenClaw `docsPath` if the OpenClaw UI expects it.
- Add setup help links to Inline docs.
- Avoid implying `/channels/inline` exists if the OpenClaw docs page is not present.

### 26. Tool names are Inline-specific, but command surfaces are not

Inline has `inline_members`, `inline_update_profile`, `inline_bot_commands`, `inline_nudge`, and `inline_forward`, which is good.

But command UI still routes through Telegram. This inconsistency will confuse maintainers.

Fix:

- Keep tool names Inline-specific.
- Make native command/UI surfaces Inline-specific too.

### 27. Tests encode product-copy issues

Examples:

- `renders Telegram-style reasoning mode choices in the native command menu`
- `clears native commands when commands.native is disabled`

Refs:

- `packages/openclaw/src/inline/monitor.test.ts:1166`
- `packages/openclaw/src/inline/bot-commands-sync.test.ts:73`

Fix:

- Rename tests after behavior is corrected.
- Add tests for intended production semantics, not copied compatibility labels.

### 28. Multi-account setup lacks guided account naming

Inline supports accounts, but setup only prompts token and env only for default account.

Refs:

- `packages/openclaw/src/inline/setup-surface.ts:36`
- `packages/openclaw/README.md:233`

Fix:

- Add account-scoped setup copy.
- Make it clear when env vars can only configure the default account.

### 29. Open/insecure DM modes need stronger user-facing warnings

Config schema enforces `dmPolicy="open"` requires `allowFrom` including `*`.

Refs:

- `packages/openclaw/src/inline/config-schema.ts:165`

Why it matters:

- The schema prevents accidental open without wildcard, but setup does not explain what pairing, allowlist, open, or disabled mean.

Fix:

- Add setup DM policy section and final warnings.
- Add docs examples for private-only bot, team bot, and public/demo bot.

### 30. Group allowlist and DM allowlist names are easy to confuse

Current config names:

- `allowFrom`
- `groupAllowFrom`
- `groups`
- `groupPolicy`

These are consistent with other channels but require docs.

Fix:

- Add a short "Who can talk to the bot?" docs table:
  - DMs: `dmPolicy`, `allowFrom`
  - Groups: `groupPolicy`, `groupAllowFrom`, `groups`
  - Mentions: `requireMention`, `replyToBotWithoutMention`

### 31. OpenClaw `message send --help` omits external Inline channels

Status: host/discoverability gap, not a current Inline send-path blocker. `openclaw message send --help` lists the built-in/static channel choices and does not include `inline`, even though Inline is installed and configured. A dry-run send with `--channel inline` succeeds, so the path accepts Inline but the help text misleads users. Inline README now includes a `--channel inline` example and notes that OpenClaw 2026.5.18 CLI help may omit installed plugin channel ids.

Refs:

- `openclaw message send --help`
- `openclaw message send --channel inline --target chat:0 --message "inline dry run" --dry-run --json`

Why it matters:

- Users trying to smoke-test or script Inline from the CLI may assume Inline is unsupported.
- Native/bundled channels get clearer CLI discoverability than this external channel.

Fix:

- Upstream OpenClaw should build message-send channel help from active/installed channel registry data or mention that installed plugin channel ids are accepted.
- Inline docs now use a `--channel inline` example with a note that older/static help may omit external channels.

### 32. Package metadata omitted quickstart allowlist opt-in

Status: fixed in the working tree. `package.json` now includes `openclaw.channel.quickstartAllowFrom: true`, and the installed packed artifact exposes the same field.

Refs:

- `packages/openclaw/package.json`
- `/Users/mo/dev/openclaw/docs/plugins/sdk-setup.md`
- `/Users/mo/dev/openclaw/src/wizard/setup.ts`

Why it matters:

- Runtime Inline metadata already had `quickstartAllowFrom: true`, but package metadata is what OpenClaw setup/discovery can see before loading the channel runtime.
- Native chat providers such as Telegram, WhatsApp, Feishu, Matrix, and others advertise this field at the package/manifest level when they support the standard allowlist quickstart.
- Without this, Inline could look less first-class during initial setup than it does after runtime load.

Fix:

- Keep `quickstartAllowFrom: true` in both runtime metadata and package metadata.
- Keep a manifest regression test so release metadata does not drift again.

### 33. Doctor metadata did not describe Inline's group access model

Status: fixed in the working tree. Inline now exposes `doctorCapabilities` in package metadata and a runtime/setup doctor adapter. The adapter skips OpenClaw's generic sender-only empty-group warning for Inline and emits an Inline-specific warning when `groupPolicy: "allowlist"` has neither configured group chats nor group sender ids.

Refs:

- `packages/openclaw/package.json`
- `packages/openclaw/src/inline/doctor.ts`
- `/Users/mo/dev/openclaw/src/commands/doctor/channel-capabilities.ts`
- `/Users/mo/dev/openclaw/src/commands/doctor/shared/empty-allowlist-policy.ts`

Why it matters:

- Inline now supports route allowlists through `channels.inline.groups` independently from `groupAllowFrom`.
- Without channel-specific doctor metadata, OpenClaw's doctor can assume the generic sender-allowlist model and warn in confusing terms, or miss the distinction between "no groups configured" and "groups configured with optional sender filtering".
- Native and production external channels expose doctor semantics through a doctor adapter and/or package metadata when generic defaults do not match their ingress model.

Fix:

- Add `dmAllowFromMode: "topOrNested"`, `groupModel: "hybrid"`, `groupAllowFromFallbackToAllowFrom: false`, and `warnOnEmptyGroupSenderAllowlist: true`.
- Add an Inline-specific empty group allowlist warning and skip the default generic one.
- Include the doctor adapter in the setup-only plugin too, so read-only setup/doctor paths do not need the heavy runtime plugin.

### 34. Formatting prompt lived in `GroupSystemPrompt` instead of channel metadata

Status: fixed in the working tree. Inline now exposes `agentPrompt.inboundFormattingHints` with `text_markup: "inline_markdown"` and keeps `GroupSystemPrompt` for user/admin `systemPrompt` values only.

Refs:

- `packages/openclaw/src/inline/channel.ts`
- `packages/openclaw/src/inline/message-formatting.ts`
- `/Users/mo/dev/openclaw/extensions/slack/src/shared.ts`
- `/Users/mo/dev/openclaw/src/auto-reply/reply/inbound-meta.ts`

Why it matters:

- Slack describes channel formatting through OpenClaw's structured inbound `response_format` metadata rather than appending generic formatting copy to every channel-specific system prompt.
- Inline's previous approach mixed transport formatting rules with configured behavior prompts, making user/admin `systemPrompt` harder to reason about and increasing prompt noise on every turn.
- The centralized hook lets OpenClaw include formatting hints consistently in inbound metadata while keeping Inline-specific custom prompts narrow.

Fix:

- Add Inline `inboundFormattingHints`.
- Keep `buildInlineSystemPrompt` as a custom-prompt normalizer only.
- Preserve outbound URL sanitization as a final delivery guard.

### 35. Inline tokens were not registered with OpenClaw SecretRef flows

Status: fixed in the working tree and installed local artifact. Inline now exposes `secrets.secretTargetRegistryEntries` and a `dist/secret-contract-api.js` sidecar for `channels.inline.token` and `channels.inline.accounts.*.token`. Runtime config parsing also accepts SecretRef-shaped `token` values, and read-only account inspection resolves env-backed SecretRefs when provider policy permits it.

Refs:

- `packages/openclaw/src/inline/secret-contract.ts`
- `packages/openclaw/src/secret-contract-api.ts`
- `packages/openclaw/src/inline/accounts.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/src/secret-contract.ts`
- `/Users/mo/dev/openclaw/extensions/slack/src/secret-contract.ts`
- `/Users/mo/dev/openclaw/src/secrets/channel-contract-api.ts`

Why it matters:

- Telegram and Slack participate in `openclaw secrets` planning/materialization through channel secret adapters; Inline previously only had env-var metadata.
- Users moving production credentials into SecretRef providers would get a first-class native-channel path but no equivalent Inline token target.
- Without the sidecar, pre-runtime OpenClaw secret collection could not discover Inline token surfaces from the packed external plugin.

Fix:

- Add the Inline secret adapter and sidecar build entry.
- Accept SecretRef `token` values in the channel schema and manifest schema.
- Keep `tokenFile` as a path field, matching native channel behavior rather than treating file paths themselves as SecretRefs.
- Add tests for target registration, active/inactive assignment collection, env SecretRef resolution, and package artifact contents.

### 36. Inline followed symlinked `tokenFile` paths

Status: fixed in the working tree. Inline now reads token files through OpenClaw's secret-file helper with `rejectSymlink: true`, matching Telegram's safer token-file behavior.

Refs:

- `packages/openclaw/src/inline/accounts.ts`
- `packages/openclaw/src/inline/accounts.test.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/src/token.ts`
- `/Users/mo/dev/openclaw/src/infra/secret-file.test.ts`

Why it matters:

- Native Telegram rejects symlinked bot token files, reducing accidental credential exposure through redirected paths.
- Inline previously used a plain async file read, so `channels.inline.tokenFile` would follow symlinks even though this field contains bot credentials.

Fix:

- Use `tryReadSecretFileSync(..., { rejectSymlink: true })` for Inline token files.
- Keep a regression test that a symlinked token file is rejected on Unix-like platforms.

### 37. Unknown multi-account ids fell back to the top-level Inline token

Status: fixed in the working tree. When `channels.inline.accounts` is configured and a non-default account id is requested but not present, Inline now returns an unconfigured account instead of inheriting the top-level token.

Refs:

- `packages/openclaw/src/inline/accounts.ts`
- `packages/openclaw/src/inline/accounts.test.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/src/token.ts`

Why it matters:

- Telegram blocks channel-level credential fallback for unknown account ids once explicit accounts exist, preventing a typo or stale binding from sending through the wrong bot token.
- Inline previously kept using the base token in that shape, which made multi-bot setups less predictable and less safe than native providers.

Fix:

- Detect explicit account maps and suppress credential fallback for unknown non-default account ids.
- Preserve single-bot fallback when there is no explicit `accounts` map.

### 38. Missing Inline credentials used non-native `tokenSource: "missing"`

Status: fixed in the working tree. Inline now reports missing token sources as `"none"` like native channels and OpenClaw status helpers expect. SecretRef-shaped token config that cannot be resolved is treated as configured input but not as a usable runtime credential.

Refs:

- `packages/openclaw/src/inline/accounts.ts`
- `packages/openclaw/src/inline/status-issues.ts`
- `packages/openclaw/src/inline/shared.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/src/shared.ts`
- `/Users/mo/dev/openclaw/src/infra/channel-summary.ts`

Why it matters:

- OpenClaw status summaries suppress `"none"` but would display unfamiliar strings such as `token:missing`.
- Native channel adapters use `"none"` for absent credentials and provide a separate reason when a configured SecretRef/token surface is unavailable.
- Inline previously considered an unresolved SecretRef as fully configured, so startup paths could reach token resolution and fail later instead of reporting a config issue cleanly.

Fix:

- Rename the absent token source to `"none"`.
- Keep a separate `tokenConfigured` flag for configured-but-unavailable SecretRef input.
- Report unavailable configured tokens distinctly in status issues and config `unconfiguredReason`.

### 39. Setup-only Inline plugin omitted secret metadata

Status: fixed in the working tree. The narrow setup plugin now exposes the same `secrets` adapter as the runtime channel plugin without importing monitor/tool code.

Refs:

- `packages/openclaw/src/inline/setup-plugin.ts`
- `packages/openclaw/src/inline/package-artifact.test.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/src/shared.ts`
- `/Users/mo/dev/openclaw/extensions/slack/src/shared.ts`

Why it matters:

- Native channel shared definitions expose setup/config/secrets together, so read-only setup and registry paths can discover credential surfaces without loading the heavy runtime.
- Inline had the sidecar and runtime adapter, but the setup-only plugin shape still lagged behind.

Fix:

- Add `secrets: inlineSecrets` to the setup-only channel plugin.
- Keep package artifact coverage ensuring the setup bundle includes the token secret target but not monitor startup symbols.

### 40. Logout copy misreported SecretRef credential clearing

Status: fixed in the working tree. `logoutAccount` now treats SecretRef-shaped token objects as real configured credentials when deciding whether credentials were cleared/logged out.

Refs:

- `packages/openclaw/src/inline/channel.ts`
- `packages/openclaw/src/inline/channel.test.ts`

Why it matters:

- After SecretRef support, deleting `channels.inline.token` could remove a real credential reference while returning `cleared: false`.
- That makes CLI/setup copy confusing and less trustworthy than native credential flows.

Fix:

- Count non-empty strings and SecretRef-like objects as configured credential values during logout cleanup.
- Keep empty string cleanup behavior separate: remove stale fields but do not claim a real credential was cleared.

### 41. Group sender filtering still fell back to DM `allowFrom`

Status: fixed in the working tree. Inline group sender checks now use `groupAllowFrom` only. DM `allowFrom` and the pairing store no longer become implicit group sender allowlists.

Refs:

- `packages/openclaw/src/inline/monitor.ts`
- `packages/openclaw/src/inline/monitor.test.ts`
- `packages/openclaw/src/inline/doctor.ts`
- `packages/openclaw/README.md`

Why it matters:

- Docs and doctor metadata explicitly say `groupAllowFrom` is optional and does not fall back to DM `allowFrom`.
- Runtime still used `allowFrom` and the pairing store as `effectiveGroupAllowFrom`, so a group listed in `channels.inline.groups` could silently drop messages from senders who were not also DM-allowlisted.
- This made Inline group access less predictable than the setup UI and docs described.

Fix:

- Derive group sender filters from `channels.inline.groupAllowFrom` only.
- Extend the group allowlist routing test so a configured DM `allowFrom` entry does not block another sender in an allowed group.

### 42. Group route keys accepted by setup were not accepted by runtime policy

Status: fixed in the working tree. Inline group route, mention, tool, and group prompt policy now normalize `chat:<id>` and `inline:<id>` keys the same way setup does.

Refs:

- `packages/openclaw/src/inline/policy.ts`
- `packages/openclaw/src/inline/monitor.ts`
- `packages/openclaw/src/inline/channel.test.ts`
- `packages/openclaw/src/inline/monitor.test.ts`
- `packages/openclaw/src/inline/setup-surface.ts`

Why it matters:

- Setup help says Inline group IDs can be numeric, `chat:<id>`, `inline:<id>`, or `*`.
- Setup-normalized entries worked, but manually edited config such as `channels.inline.groups.chat:88` did not match runtime group routing, mention overrides, tool policy, or group-specific prompt text.
- Native channel plugins accept documented target forms consistently across setup, config, and runtime.

Fix:

- Normalize Inline group policy keys through the same target parser used elsewhere.
- Replace the generic group route resolver in the monitor with an Inline-specific resolver that understands Inline target prefixes.
- Cover `chat:88` and `inline:88` keys in runtime tests.

### 43. Inline lacked native-style security audit findings

Status: fixed in the working tree. Inline now exposes a shared security adapter from both the runtime channel plugin and setup-only plugin, including `collectAuditFindings`.

Refs:

- `packages/openclaw/src/inline/security.ts`
- `packages/openclaw/src/inline/channel.ts`
- `packages/openclaw/src/inline/setup-plugin.ts`
- `packages/openclaw/src/inline/channel.test.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/src/security-audit.ts`

Why it matters:

- Telegram reports audit findings for invalid sender allowlist entries, wildcard group command allowlists, and reachable groups without sender command allowlists.
- Inline only exposed status/doctor warnings, so `openclaw security audit` could miss confusing or unsafe Inline group-command setups.
- Setup-only plugin loading should still reveal the same security hooks without importing monitor/runtime code.

Fix:

- Add Inline audit findings for non-numeric sender allowlist entries, wildcard `groupAllowFrom`, disabled access groups on reachable Inline groups, and reachable groups with no group sender command allowlist.
- Share the same `inlineSecurityAdapter` between runtime and setup-only plugin surfaces.
- Add tests for setup-only audit exposure and each new Inline audit finding class.

### 44. Setup entry did not expose split secret metadata

Status: fixed in the working tree. Inline's setup entry now exposes a native-style `secrets` sidecar that points to `secret-contract-api.js`.

Refs:

- `packages/openclaw/src/setup-entry.ts`
- `packages/openclaw/src/secret-contract-api.ts`
- `packages/openclaw/src/inline/secret-contract.ts`
- `packages/openclaw/src/index.test.ts`
- `packages/openclaw/src/inline/package-artifact.test.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/setup-entry.ts`
- `/Users/mo/dev/openclaw/extensions/slack/setup-entry.ts`

Why it matters:

- Telegram and Slack setup entries expose `loadSetupSecrets` through the bundled channel setup contract.
- Inline had secret metadata on the setup plugin itself, but setup/read-only host paths that prefer the split sidecar could not load the token targets without importing the setup plugin bundle.
- This is subtle, but it is exactly the kind of native-channel polish gap that makes setup, secret planning, and audit behavior feel inconsistent.

Fix:

- Export `channelSecrets` from Inline's secret contract and sidecar API.
- Add `secrets: { specifier: "./secret-contract-api.js", exportName: "channelSecrets" }` to the setup entry.
- Cover the source setup entry and packed `dist/setup-entry.js` so the shipped artifact proves the sidecar wiring.

### 45. Config inspection treated unreadable token files as usable

Status: fixed in the working tree. Inline now exposes a native-style `config.inspectAccount` path and uses it for configured state, status descriptions, and unavailable-token reasons.

Refs:

- `packages/openclaw/src/inline/accounts.ts`
- `packages/openclaw/src/inline/shared.ts`
- `packages/openclaw/src/inline/accounts.test.ts`
- `packages/openclaw/src/inline/channel.test.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/src/account-inspect.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/src/shared.ts`

Why it matters:

- Runtime token resolution rejects unreadable or symlinked `tokenFile` paths, but read-only config/status paths still treated any non-empty `tokenFile` string as configured.
- Native Telegram inspects token files with OpenClaw's secret-file helper and reports configured-but-unavailable credentials before claiming the account can run.
- Without this, Inline status/setup could look healthy while gateway startup later failed on the same token file.

Fix:

- Add `inspectInlineAccount` with token status: `available`, `configured_unavailable`, or `missing`.
- Inspect `tokenFile` through `tryReadSecretFileSync(..., { rejectSymlink: true })`.
- Wire `inlineConfigAdapter.inspectAccount`, `isConfigured`, `unconfiguredReason`, and `describeAccount` through the inspector.
- Add tests for readable token files, symlinked token files, and unresolved SecretRef tokens.

### 46. Runtime entry still loaded too much compared with native channels

Status: fixed in the working tree. Inline now exposes a native-style bundled channel entry with split sidecars for the channel plugin, runtime setter, account inspector, secrets, and full runtime registration.

Refs:

- `packages/openclaw/src/index.ts`
- `packages/openclaw/src/channel-plugin-api.ts`
- `packages/openclaw/src/runtime-setter-api.ts`
- `packages/openclaw/src/account-inspect-api.ts`
- `packages/openclaw/src/runtime-register-api.ts`
- `packages/openclaw/src/index.test.ts`
- `packages/openclaw/src/inline/package-artifact.test.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/index.ts`
- `/Users/mo/dev/openclaw/extensions/slack/index.ts`

Why it matters:

- Telegram and Slack use `defineBundledChannelEntry`, so host discovery, secret planning, account inspection, runtime wiring, and full registration can load only the surface they need.
- Inline still exported a broad plain plugin entry that imported channel runtime, tools, native command sync, sanitizer hooks, and monitor-adjacent code from the main entry path.
- That made Inline less native-feeling in host metadata paths and raised the chance that setup/discovery/import flows pulled heavy runtime surfaces unnecessarily.

Fix:

- Replace the plain entry with `defineBundledChannelEntry`.
- Move full runtime registration for tools and hooks into `runtime-register-api.ts`.
- Add split sidecars for `inlineChannelPlugin`, `setInlineRuntime`, `inspectInlineReadOnlyAccount`, and `channelSecrets`.
- Extend package artifact tests to prove the shipped `dist/index.js` stays narrow and does not include monitor startup symbols.

Follow-up regression found and fixed during local install:

- The first split-entry artifact bundled `runtime.ts` separately into the runtime setter and channel plugin sidecars, so the gateway could load Inline but `openclaw channels status` reported `Inline runtime not initialized`.
- `runtime.ts` now stores the active runtime on a process-global key so separately bundled sidecars share the same holder.
- The package artifact test imports the built `dist/index.js`, registers the bundled entry, and calls the built channel outbound chunker to prove the runtime setter sidecar reaches the channel sidecar.

### 47. Setup status accepted unavailable token files

Status: fixed in the working tree. Inline's setup wizard now uses the read-only account inspector when deciding whether the channel is configured.

Refs:

- `packages/openclaw/src/inline/setup-surface.ts`
- `packages/openclaw/src/inline/channel.test.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/src/setup-surface.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/src/account-inspect.ts`

Why it matters:

- The config adapter already learned to reject unreadable or symlinked token files, but setup wizard status still used `resolveInlineAccount`, which treats any non-empty `tokenFile` as configured.
- Native Telegram uses `inspectTelegramAccount` in setup status, so setup does not mark an account ready unless the token is actually available.
- Without this, Inline onboarding could still show a green configured status for a credential path that runtime startup rejects.

Fix:

- Use `inspectInlineAccount` in `inlineSetupWizard.status.resolveConfigured`.
- Preserve account-specific checks by honoring the `accountId` passed to setup status.
- Add a symlinked `tokenFile` setup wizard regression test.

### 48. Group setup help referenced a non-existent `/chatinfo` command

Status: fixed in the working tree. Inline group setup help now points users to `/whoami`, which is the OpenClaw command registered for Inline and includes the group `Chat:` line.

Refs:

- `packages/openclaw/src/inline/setup-surface.ts`
- `packages/openclaw/src/inline/channel.test.ts`
- `packages/openclaw/src/inline/bot-commands-sync.ts`
- `/Users/mo/dev/openclaw/src/auto-reply/reply/commands-whoami.ts`

Why it matters:

- The setup wizard told users to run `/chatinfo` to find an Inline chat id, but Inline does not register or handle `/chatinfo`.
- `/whoami` is the native OpenClaw command for identity and group context, and its reply includes `Chat:` for group chats.
- This is exactly the kind of confusing copy that makes Inline feel less polished than native channel setup.

Fix:

- Replace the stale `/chatinfo` help line with `/whoami` guidance.
- Add a regression that the group setup help includes `/whoami` and no longer mentions `/chatinfo`.

### 49. Native command sync had a stale local base registry

Status: fixed in the working tree and installed local artifact. Inline now builds native commands directly from `listNativeCommandSpecsForConfig(..., { provider: "inline" })` and no longer carries its own base command table.

Refs:

- `packages/openclaw/src/inline/bot-commands-sync.ts`
- `/Users/mo/dev/openclaw/src/auto-reply/reply/native-command-registry.ts`

Why it matters:

- The stale list had already drifted from OpenClaw 2026.5.18 descriptions and ordering.
- Newer user-facing commands such as `/tools`, `/diagnostics`, `/tasks`, `/session`, `/trace`, and `/fast` should not require Inline-specific source changes to appear in the bot command menu.
- Native Telegram delegates to the shared registry rather than duplicating the command catalog.

Fix:

- Remove the local `INLINE_BASE_NATIVE_COMMANDS`.
- Let the shared native registry decide command names, order, descriptions, and config-gated command visibility.
- Keep tests on representative registry behavior instead of a duplicated full list.

### 50. Native skill commands were not account-scoped

Status: fixed in the working tree. Inline now resolves the agent route for each configured account before listing native skill commands.

Refs:

- `packages/openclaw/src/inline/bot-commands-sync.ts`
- `/Users/mo/dev/openclaw/src/routing/agent-route.ts`

Why it matters:

- Multi-account Inline setups can bind different accounts to different OpenClaw agents.
- A single global skill command list can expose the wrong skills in the wrong Inline bot menu.
- Native channel behavior is route-aware; Inline should not leak one account's skills into another account's command surface.

Fix:

- Call `resolveAgentRoute({ channel: "inline", accountId })` during per-account command sync.
- Pass the resolved `agentId` to `listSkillCommandsForAgents`.
- Add a regression where two Inline accounts expose different skill commands.

### 51. Plugin command specs were resolved without active config

Status: fixed in the working tree. Inline now calls `getPluginCommandSpecs("inline", { config: cfg })`.

Refs:

- `packages/openclaw/src/inline/bot-commands-sync.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/src/commands.ts`

Why it matters:

- Plugin command visibility can be config-sensitive.
- Telegram passes config into plugin command resolution; Inline should match that contract.
- Without config, Inline can sync commands that the active host config would otherwise hide or shape differently.

Fix:

- Pass the current OpenClaw config into plugin command spec resolution.
- Keep a regression that verifies config is passed.

### 52. Shared command copy leaked Discord/Telegram terms into Inline

Status: fixed in the working tree and installed local artifact. Inline now adapts shared Discord/Telegram command descriptions, plus generic thread/topic variants, before native command sync and before visible outbound text delivery.

Refs:

- `packages/openclaw/src/inline/message-formatting.ts`
- `packages/openclaw/src/inline/bot-commands-sync.ts`
- `/Users/mo/dev/openclaw/src/auto-reply/reply/commands-bind.ts`

Why it matters:

- `/bind` and `/unbind` descriptions talked about Discord threads and Telegram topics/conversations in an Inline bot menu.
- That is a visible product-quality mismatch and makes Inline feel copied rather than native to the channel.
- The same shared copy can appear in command-list replies, not only the Bot API native command menu.

Fix:

- Add `adaptInlineVisibleCopy`.
- Apply it in native command sync and the final outgoing text sanitizer.
- Keep regression tests for both current provider-specific copy and generic shared thread/topic copy.

### 53. Direct package dependencies were range-pinned

Status: fixed in the working tree. `@inline-chat/realtime-sdk`, `zod`, `@types/node`, `typescript`, and `vitest` are pinned exactly for this package.

Refs:

- `packages/openclaw/package.json`
- `bun.lock`

Why it matters:

- The repo security rule says dependencies should be pinned.
- This plugin is going into a production user update and should not accidentally build against a newer transitive/API surface than the reviewed one.
- Native compatibility already moved to an intentional OpenClaw 2026.5.18 floor; the package dependency story should be equally explicit.

Fix:

- Pin runtime deps and dev deps exactly.
- Refresh the lockfile with `bun install`.

### 54. Setup docs used an ambiguous gateway command

Status: fixed in the working tree. The setup docs now distinguish foreground `openclaw gateway run` from service `openclaw gateway start`, and restart instructions use `stop` then `start`.

Refs:

- `packages/openclaw/docs/openclaw-setup.md`

Why it matters:

- OpenClaw 2026.5.18 has explicit gateway subcommands.
- Ambiguous startup docs make it harder for users to know whether they are running a foreground process or managing the LaunchAgent/service.
- This kind of setup friction is one reason native providers feel more polished.

Fix:

- Document foreground and service modes separately.
- Use explicit restart commands.

### 55. Access-policy copy made `dmPolicy` and `groupAllowFrom` harder to reason about

Status: fixed in the working tree. README and plugin UI hints now call out `dmPolicy: "allowlist"` and clarify that `groupAllowFrom` filters senders inside allowed groups and may be left empty.

Refs:

- `packages/openclaw/README.md`
- `packages/openclaw/openclaw.plugin.json`

Why it matters:

- The previous README example omitted `allowlist` from the `dmPolicy` comment even though the docs table described it.
- The previous `groupAllowFrom` hint implied it only mattered when `groupPolicy=allowlist`, but group sender filtering is separate from group route access.
- Users need to understand DM policy, group route policy, and group sender filters as different controls.

Fix:

- Update README comments and access table text.
- Update config UI hint copy for `groupAllowFrom`.

### 56. Inline dropped shared reply-pipeline payload transforms

Status: fixed in the working tree and installed local artifact. Inline now forwards `transformReplyPayload` from OpenClaw's channel reply pipeline into the buffered reply dispatcher, and the stale Slack-specific compatibility field was removed from Inline's local pipeline type.

Refs:

- `packages/openclaw/src/sdk-runtime-compat.ts`
- `packages/openclaw/src/inline/monitor.ts`
- `packages/openclaw/src/inline/monitor.test.ts`
- `/Users/mo/dev/openclaw/src/channels/message/reply-pipeline.ts`
- `/Users/mo/dev/openclaw/extensions/slack/src/monitor/message-handler/dispatch.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/src/bot-message-dispatch.ts`

Why it matters:

- OpenClaw 2026.5.18 uses `transformReplyPayload` to let channel/plugin messaging adapters normalize reply payloads before delivery.
- Native channels spread the shared reply pipeline into dispatcher options; Inline previously cherry-picked prefix/typing fields and silently lost transforms.
- This could break future Inline channel payload transforms or host-level messaging behavior even when the plugin registered the right channel metadata.

Fix:

- Add `transformReplyPayload` to Inline's compatibility pipeline type.
- Pass it through to `dispatchReplyWithBufferedBlockDispatcher`.
- Update the monitor test harness to emulate dispatcher transforms and assert transformed text is delivered.

### 57. Reply-thread action hints were silent in compatibility mode

Status: fixed in the working tree. Inline now includes a disabled-mode message-tool hint explaining that `thread-reply` uses the legacy reply path and `thread-create` creates a normal chat unless `channels.inline.capabilities.replyThreads` is enabled.

Refs:

- `packages/openclaw/src/inline/channel.ts`
- `packages/openclaw/src/inline/channel.test.ts`
- `packages/openclaw/src/inline/actions.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/src/shared.ts`
- `/Users/mo/dev/openclaw/extensions/slack/src/shared.ts`

Why it matters:

- Inline exposes `thread-reply` and `thread-create` even when native reply threads are disabled for backward compatibility.
- The previous prompt only mentioned native reply threads when enabled, so the agent could infer native thread semantics from the action names without seeing the compatibility-mode behavior.
- Static `capabilities.threads: true` matches native providers, but the model-facing copy must explain the per-config behavior.

Fix:

- Keep the static thread capability and action names.
- Add disabled-mode guidance to `agentPrompt.messageToolHints`.
- Update the test to assert disabled and enabled hints both describe the correct behavior.

### 58. Static manifest treated named Inline accounts as opaque blobs

Status: fixed in the working tree. Inline's external `openclaw.plugin.json` now gives `channels.inline.accounts.*` the same typed token, access, group, reply-thread, command, and streaming fields as `channels.inline`, while still allowing future host-owned account fields.

Refs:

- `packages/openclaw/openclaw.plugin.json`
- `packages/openclaw/src/manifest.test.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/src/config-schema.ts`
- `/Users/mo/dev/openclaw/extensions/slack/src/config-schema.ts`
- `packages/openclaw/node_modules/openclaw/dist/extensions/telegram/openclaw.plugin.json`

Why it matters:

- Native generated channel manifests expose typed account schemas under `accounts.*`; Inline's hand-maintained external manifest only had `additionalProperties: true`.
- That made named Inline account config less discoverable and could hide account-scoped validation problems from setup/config tooling.
- SecretRef and streaming validation now work at account scope in the static manifest without requiring the full plugin runtime to load.

Fix:

- Replace opaque `accounts.additionalProperties: true` with a typed account object that references the root Inline config field schemas.
- Keep account-level `additionalProperties: true` so future host fields remain compatible.
- Align channel-specific manifest description with package/runtime metadata.
- Add a manifest regression test that validates account-scoped SecretRef, reply-thread, streaming, and future-field behavior through OpenClaw's JSON schema runtime.

### 59. Special Inline tools missed current live session-key shapes

Status: fixed in the working tree. `inline_nudge` and `inline_forward` now recognize current OpenClaw Inline session keys such as `agent:main:inline:direct:<userId>` and `agent:main:inline:group:<chatId>` when defaulting to the current conversation.

Refs:

- `packages/openclaw/src/inline/message-tools.ts`
- `packages/openclaw/src/inline/message-tools.test.ts`
- `openclaw status --json`

Why it matters:

- The tools advertise that omitting the target/source defaults to the current Inline conversation.
- The parser only understood older `inline:chat:<id>` / `inline:user:<id>` and legacy numeric session keys.
- Live local gateway state shows current sessions using `direct` and `group`, so the advertised no-target flow could fail for real users even though old tests passed.

Fix:

- Accept both current (`direct`, `group`) and compatibility (`user`, `chat`, legacy numeric) session-key forms.
- Map `direct` to `user:<id>` and `group` to chat id when building Inline peer targets.
- Add regression coverage for no-target nudge in a live-shaped group session and source-default forwarding in a live-shaped DM session.

### 60. Inline reply buttons were not constrained to Inline server limits

Status: fixed in the working tree. Inline now truncates rendered action labels to the server's 64-character limit and drops callback buttons whose UTF-8 payload exceeds the server's 1024-byte callback limit.

Refs:

- `packages/openclaw/src/inline/outbound-sanitize.ts`
- `packages/openclaw/src/inline/actions.ts`
- `packages/openclaw/src/inline/monitor.ts`
- `server/src/modules/message/messageActions.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/src/approval-callback-data.ts`
- `/Users/mo/dev/openclaw/extensions/slack/src/blocks-render.ts`

Why it matters:

- Telegram and Slack render only platform-valid interactive controls before sending, but Inline forwarded agent-authored button labels and callback data directly into `MessageActions`.
- Inline server validation rejects button labels over 64 characters and callback payloads over 1024 bytes.
- One overlong button could make an otherwise valid Inline reply fail instead of rendering the remaining usable controls.

Fix:

- Add Inline action-label and callback-data sanitizers next to the existing visible-text sanitizer.
- Use them in both message-tool sends/edits and the reply-dispatch path.
- Keep visible labels by truncating display text, but drop oversized callback controls because truncating callback commands would corrupt semantics.
- Add regression coverage for direct message actions and reply-pipeline interactive buttons.

### 61. Inline prompt capability said buttons were disabled despite supported controls

Status: fixed in the working tree. Inline now exposes `messageToolCapabilities: ["inlineButtons"]` when enabled Inline message actions can send/edit/reply with `presentation` or `buttons`, and adds an Inline-specific prompt hint to prefer buttons/selects for small discrete choices.

Refs:

- `packages/openclaw/src/inline/channel.ts`
- `packages/openclaw/src/inline/actions.ts`
- `packages/openclaw/src/inline/channel.test.ts`
- `/Users/mo/dev/openclaw/src/agents/system-prompt.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/src/channel.ts`
- `/Users/mo/dev/openclaw/extensions/slack/src/shared.ts`

Why it matters:

- OpenClaw's generic system prompt keys off the `inlineButtons` channel capability before telling agents whether inline buttons are available.
- Telegram advertises this capability when button replies are enabled, and Slack has explicit interactive-reply prompt hints.
- Inline could render `presentation` blocks and button rows, but did not advertise `inlineButtons`, so the generic prompt could incorrectly tell agents that Inline buttons were not enabled and suggest setting a Telegram-style `inline.capabilities.inlineButtons` config knob that Inline does not use.

Fix:

- Export a small action-capability helper from Inline actions.
- Return `["inlineButtons"]` from Inline channel metadata when send/reply/thread-reply/edit actions can carry buttons.
- Keep the capability absent when all button-capable outbound actions are disabled.
- Add a regression asserting both the capability and the Inline-specific prompt hint.

### 62. Status snapshots trusted configured token paths without inspecting them

Status: fixed in the working tree. Inline's `buildAccountSnapshot` now uses `inspectInlineAccount` before reporting `configured` and `tokenSource`, matching the setup wizard and config adapter.

Refs:

- `packages/openclaw/src/inline/channel.ts`
- `packages/openclaw/src/inline/channel.test.ts`
- `packages/openclaw/src/inline/accounts.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/src/shared.ts`
- `/Users/mo/dev/openclaw/extensions/slack/src/shared.ts`

Why it matters:

- `resolveInlineAccount` intentionally treats a configured `tokenFile` path as configured input, but only `inspectInlineAccount` proves the token is actually readable and not a symlink.
- Status snapshots still used `account.configured`, so an unreadable or symlinked `tokenFile` could appear configured and suppress the unavailable-token status issue.
- Native channel config/status surfaces gate user-facing configured state on inspected credential availability, not just the presence of a credential field.

Fix:

- Inspect the account inside `status.buildAccountSnapshot`.
- Report `configured: false` and `tokenSource: "file"` when a token file is configured but unavailable.
- Add a regression proving the resulting snapshot emits the unavailable-token status issue.

### 63. Multi-account Inline allowed duplicate bot-token owners

Status: fixed in the working tree. Inline now detects when a later account resolves to the same concrete bot token as an earlier account, marks the duplicate account unconfigured, reports a duplicate-token status issue, skips duplicate command-menu sync, and refuses gateway startup for the duplicate account.

Refs:

- `packages/openclaw/src/inline/accounts.ts`
- `packages/openclaw/src/inline/shared.ts`
- `packages/openclaw/src/inline/bot-commands-sync.ts`
- `packages/openclaw/src/inline/channel.ts`
- `packages/openclaw/src/inline/status-issues.ts`
- `packages/openclaw/src/inline/accounts.test.ts`
- `packages/openclaw/src/inline/bot-commands-sync.test.ts`
- `packages/openclaw/src/inline/channel.test.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/src/shared.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/src/channel.ts`

Why it matters:

- Native Telegram enforces one configured account owner per bot token and reports a clear duplicate-token reason.
- Inline multi-account config could let the default account and a named account share the same available token, including inherited base tokens.
- Starting duplicate realtime monitors or command-menu sync for one Inline bot credential can create confusing duplicated delivery, conflicting command menus, and account status that looks healthier than the runtime can safely be.

Fix:

- Add an Inline duplicate-token owner detector that inspects available tokens and gives the default account first ownership of the base token.
- Reuse that detector in config `isConfigured`, `unconfiguredReason`, account descriptions, status snapshots, and gateway startup.
- Reuse the detector in native command sync so only the owner account writes the bot command menu for a shared token.
- Teach status issue collection to report the duplicate-token reason instead of a generic unavailable-token warning.
- Add regressions for inherited duplicate tokens, explicit duplicate tokens, command-sync skip behavior, status issue copy, and startup refusal.

### 64. Message-tool action discovery ignored active account scope

Status: fixed in the working tree. Inline now scopes message-tool action discovery, button support, and `inlineButtons` prompt capability to the active account id when OpenClaw supplies one.

Refs:

- `packages/openclaw/src/inline/actions.ts`
- `packages/openclaw/src/inline/actions.test.ts`
- `packages/openclaw/src/inline/channel.ts`
- `packages/openclaw/src/inline/channel.test.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/src/channel-actions.ts`
- `/Users/mo/dev/openclaw/extensions/slack/src/message-tool-api.ts`

Why it matters:

- Native Slack and Telegram describe available message actions for the active account/config scope.
- Inline was unioning enabled actions across all configured accounts. If the default account allowed sends/buttons but a named account disabled send/reply/edit, the named account could still be advertised as supporting `presentation` and `inlineButtons`.
- Runtime `handleAction` correctly rejects disabled actions, so the old discovery could prompt the agent into trying actions that would later fail for the selected account.

Fix:

- Let `listEnabledInlineActions` accept an optional account id and inspect only that account when present.
- Thread `accountId` through `describeMessageTool`, `listActions`, `supportsButtons`, `messageToolCapabilities`, and button prompt hints.
- Add regressions proving a quiet named account no longer inherits `send`, `presentation`, or the Inline buttons/selects prompt from the default account.

### 65. Outbound sanitizer did not match OpenClaw's runtime-context stripping rules

Status: fixed in the working tree and installed local artifact. Inline now treats OpenClaw runtime-context delimiters as real delimiters only when they appear on standalone marker lines, strips nested internal blocks, and removes legacy internal task-completion event blocks.

Refs:

- `packages/openclaw/src/inline/outbound-sanitize.ts`
- `packages/openclaw/src/inline/outbound-sanitize.test.ts`
- `/Users/mo/dev/openclaw/src/agents/internal-runtime-context.ts`
- `/Users/mo/dev/openclaw/src/infra/outbound/sanitize-text.ts`

Why it matters:

- OpenClaw 2026.5.18 has canonical sanitizer behavior that ignores inline marker mentions but strips marked internal blocks and legacy internal task events before user-facing display.
- Inline's local sanitizer used broad `indexOf` matching for `<<<BEGIN_OPENCLAW_INTERNAL_CONTEXT>>>`, so a normal reply documenting that marker could be truncated as if it were hidden runtime context.
- Inline also did not remove one legacy internal task-completion event shape that OpenClaw strips from visible display paths.

Fix:

- Port the standalone-line marker detection and nested block stripping behavior into Inline's local sanitizer.
- Add legacy internal task-event removal before generic runtime-context preface stripping.
- Add regressions for nested canonical blocks, inline delimiter mentions, and legacy task-completion event blocks.

### 66. Named account token files could inherit the top-level token

Status: fixed in the working tree and installed local artifact. Inline now gives account-scoped credentials precedence before falling back to top-level credentials, matching native Telegram account inspection behavior.

Refs:

- `packages/openclaw/src/inline/accounts.ts`
- `packages/openclaw/src/inline/accounts.test.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/src/account-inspect.ts`

Why it matters:

- Native Telegram checks an account's `tokenFile` and `botToken` before falling back to channel-level credentials.
- Inline merged account config with base config first, then resolved the top-level token unless the account had its own `token` field. A named account with only `tokenFile` could silently run with the default account's token instead of its own file-backed credential.
- A named account with an unavailable token SecretRef could also appear to inherit the base token, hiding the actual account-level credential problem.
- This could start the wrong Inline bot for a named account, confuse duplicate-token ownership checks, and sync commands for the wrong credential.

Fix:

- Add explicit credential selection order: account token SecretRef/value, account tokenFile, then base token/tokenFile fallback only when the account has no account-scoped credential.
- Keep unresolved account SecretRefs as configured-but-unavailable instead of falling through to the base token.
- Add regressions for account tokenFile precedence and unavailable account SecretRef behavior.

### 67. Inline status reported running without native connected/liveness fields

Status: fixed in the working tree. Inline now publishes connected lifecycle fields on successful realtime setup and transport activity on inbound events. Status issue collection also warns after startup grace if an Inline monitor is still running but not connected.

Refs:

- `packages/openclaw/src/inline/channel.ts`
- `packages/openclaw/src/inline/monitor.ts`
- `packages/openclaw/src/inline/status-issues.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/src/polling-status.ts`
- `/Users/mo/dev/openclaw/extensions/slack/src/monitor/provider-support.ts`

Why it matters:

- Telegram and Slack expose connection state directly, so `channels status`, health, and readiness can distinguish "started" from "actually connected."
- Inline only exposed `running`, plus diagnostics when errors happened. That made a startup stall look healthier than native channels and reduced operator trust in status output.
- OpenClaw has a shared connected-channel status contract; Inline should participate instead of relying on channel-specific diagnostics alone.

Fix:

- Add connected lifecycle fields to Inline default runtime and status snapshots.
- Publish connected status after websocket connect plus `getMe` succeeds.
- Publish inbound transport activity on received updates.
- Add a startup-grace runtime issue when the monitor stays running but disconnected.
- Add regression coverage for connected status, inbound transport activity, and startup grace.

### 68. Manifest and tool copy exposed native/slash command jargon

Status: fixed in the working tree and installed local artifact. Inline setup/config copy now describes bot command sync in Inline terms, while the implementation can still use OpenClaw's `commands.native` config key internally.

Refs:

- `packages/openclaw/openclaw.plugin.json`
- `packages/openclaw/README.md`
- `packages/openclaw/src/inline/bot-commands-tool.ts`

Why it matters:

- The setup UI said "OpenClaw native slash commands" and "native skill slash commands", which sounds like Slack/Telegram implementation vocabulary rather than Inline product behavior.
- The agent tool description said "bot slash commands" even though the Inline Bot API exposes command lists through `getMyCommands` / `setMyCommands` / `deleteMyCommands`.
- This kind of copy mismatch is small but visible; native providers feel better partly because their setup labels match the channel users are configuring.

Fix:

- Rename visible config labels to `Inline Bot Command Sync` and `Inline Skill Command Sync`.
- Describe the command tool as managing Inline bot commands via the Inline Bot API.
- Describe the `inline_bot_commands` command-name parameter as an Inline bot command instead of a slash command.
- Describe reply-thread support through OpenClaw's thread API instead of "native threads".

### 69. Inline group command gate bypassed standard command authorization

Status: fixed in the working tree. Inline now runs OpenClaw's standard command authorization helper before applying its early group control-command block. The security audit also recognizes `commands.allowFrom.inline` as a valid group command authorization source.

Refs:

- `packages/openclaw/src/inline/monitor.ts`
- `packages/openclaw/src/inline/security.ts`
- `/Users/mo/dev/openclaw/src/auto-reply/command-auth.ts`
- `/Users/mo/dev/openclaw/extensions/slack/src/monitor/events/interactions.block-actions.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/src/bot-native-commands.ts`

Why it matters:

- Inline used a local `groupAllowFrom`-only command gate before dispatch. If a user configured standard OpenClaw command authorization with `commands.allowFrom.inline`, Inline could still block `/...` group commands before the generic command layer saw them.
- Conversely, if a sender was in `channels.inline.groupAllowFrom` but excluded by `commands.ownerAllowFrom`, Inline could mark the command as authorized in the inbound context.
- Native providers route command callbacks and control commands through OpenClaw's shared command authorization path, so Inline should not have a looser or stricter early gate.

Fix:

- Call `resolveCommandAuthorization` with Inline provider/account/sender context after the local route sender gate.
- Use the resolved command authorization for mention bypass, inbound `CommandAuthorized`, and the early group control-command block.
- Suppress the "group commands have no sender allowlist" audit warning when `commands.allowFrom.inline` or global `commands.allowFrom["*"]` is configured.
- Add monitor regressions for `commands.allowFrom.inline` allowing a group command and `commands.ownerAllowFrom` blocking an otherwise group-allowlisted sender.
- Add a security-audit regression for `commands.allowFrom.inline`.

### 70. Inline allowlists did not expand access groups

Status: fixed in the working tree and installed local artifact. Inline now expands `accessGroup:<name>` entries in DM `allowFrom` and group `groupAllowFrom` before applying sender authorization, matching Telegram's native allowlist behavior.

Refs:

- `packages/openclaw/src/inline/monitor.ts`
- `packages/openclaw/src/inline/security.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/src/access-groups.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/src/bot.create-telegram-bot.test.ts`

Why it matters:

- Native Telegram supports sender access groups in channel allowlists, so operators can centralize trusted people in `accessGroups`.
- Inline normalized `accessGroup:operators` as a literal sender id, so the sender never matched and DMs/groups configured through access groups were silently blocked.
- The Inline security audit also described those entries as invalid non-numeric senders, which contradicted native provider behavior.

Fix:

- Expand Inline allowlists with `expandAllowFromWithAccessGroups` before DM/group sender checks.
- Keep the existing Inline route/group policy model intact; only the sender allowlist expansion changed.
- Treat `accessGroup:<name>` as valid security-audit input.
- Add regressions for DM `allowFrom`, group `groupAllowFrom`, and audit handling.

### 71. Interactive-only replies could disappear or send empty text

Status: fixed in the working tree and installed local extension. Inline now derives visible fallback text from shared interactive/presentation controls before sending through channel outbound, monitor reply delivery, or message-tool actions.

Refs:

- `packages/openclaw/src/inline/interactive-fallback.ts`
- `packages/openclaw/src/inline/channel.ts`
- `packages/openclaw/src/inline/monitor.ts`
- `packages/openclaw/src/inline/actions.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/src/interactive-fallback.ts`
- `/Users/mo/dev/openclaw/extensions/slack/src/blocks-fallback.ts`

Why it matters:

- Telegram uses interactive button/select labels as fallback text for button-only payloads. Slack sends fallback text for block-only messages.
- Inline's live monitor path returned early when a reply had actions but no text/media, so rich button-only replies could be dropped.
- The channel outbound and message-tool paths could attempt empty text with actions, which is fragile and worse than native-channel behavior.

Fix:

- Add an Inline fallback helper mirroring Telegram's shared interactive/presentation fallback logic.
- Use it in `sendPayload`, live reply delivery, and message-tool `send`/`reply`/`thread-reply`/`edit` text resolution.
- Add regressions for interactive-only channel payloads, monitor replies, and message-tool sends.

### 72. Live replies and message actions bypassed Inline visible-text cleanup

Status: fixed in the working tree. Inline now applies `sanitizeInlineOutgoingText` across direct live replies, partial/edit streaming, command pagination edits, model picker edits, message-tool actions, and the plugin `messaging.transformReplyPayload` hook.

Refs:

- `packages/openclaw/src/inline/message-formatting.ts`
- `packages/openclaw/src/inline/channel.ts`
- `packages/openclaw/src/inline/monitor.ts`
- `packages/openclaw/src/inline/actions.ts`
- `/Users/mo/dev/openclaw/src/channels/message/reply-pipeline.ts`
- `/Users/mo/dev/openclaw/extensions/slack/src/channel.ts`

Why it matters:

- Direct outbound `sendPayload` already used the Inline-specific sanitizer, but monitor replies and message actions sent text straight to the SDK after only internal-context stripping.
- A model reply like ``See `https://example.com/docs` `` would render the URL as code in Inline instead of a usable plain URL/link.
- Shared command copy such as "thread (Discord) or topic/conversation (Telegram)" could still leak through live command/menu/action paths even after bot-command sync was cleaned up.
- Native Slack uses the plugin messaging transform hook for channel-specific payload shaping; Inline did not expose an equivalent transform.

Fix:

- Add plugin-level `messaging.transformReplyPayload` for Inline text cleanup.
- Sanitize live monitor outbound text immediately before `sendMessage` / `editMessage`, including command pagination, model picker, streaming edits, and media fallback captions.
- Sanitize message-action text/captions before `send`, `reply`, `thread-reply`, and `edit`.
- Add regressions for monitor replies, message actions, and the messaging transform.

### 73. Outbound session routing fell back to generic target parsing

Status: fixed in the working tree. Inline now implements `messaging.resolveOutboundSessionRoute`, matching the native Telegram/Slack pattern and canonicalizing Inline targets before OpenClaw writes outbound session metadata.

Refs:

- `packages/openclaw/src/inline/channel.ts`
- `packages/openclaw/src/inline/channel.test.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/src/channel.ts`
- `/Users/mo/dev/openclaw/extensions/slack/src/channel.ts`
- `/Users/mo/dev/openclaw/src/infra/outbound/outbound-session.ts`

Why it matters:

- Native Telegram and Slack define explicit outbound route resolvers so session keys, `From`, `To`, peer kind, and thread suffixes match their inbound runtime behavior.
- Inline did not, so OpenClaw's generic fallback treated `chat:7` as peer id `chat:7` and emitted generic group metadata like `inline:group:chat:7` / `channel:chat:7`.
- That can split outbound history/session metadata from the actual Inline chat and make `chat:<id>` behave worse than `inline:<id>`.

Fix:

- Resolve Inline outbound sessions through the same target parser used by sends.
- Canonicalize direct routes as `peer={kind:"direct", id}`, `from=inline:<userId>`, `to=user:<userId>`.
- Canonicalize group routes as `peer={kind:"group", id}`, `from=inline:chat:<chatId>`, `to=chat:<chatId>`.
- Respect resolved bare user targets and keep enabled reply-thread `threadId` values in the route suffix.

### 74. Inline ignored message edit/delete lifecycle events

Status: fixed in the working tree. Inline now queues message edit/delete notifications as OpenClaw system events, matching Slack's native treatment of `message_changed` / `message_deleted` and Telegram's edited-message tracking behavior more closely than silently dropping the events.

Refs:

- `packages/openclaw/src/inline/monitor.ts`
- `packages/openclaw/src/inline/monitor.test.ts`
- `packages/openclaw/node_modules/@inline-chat/realtime-sdk/src/sdk/types.ts`
- `/Users/mo/dev/openclaw/extensions/slack/src/monitor/events/messages.ts`
- `/Users/mo/dev/openclaw/extensions/slack/src/monitor/events/message-subtype-handlers.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/src/bot-handlers.runtime.ts`

Why it matters:

- The Inline SDK emits `message.edit` and `message.delete`, but the monitor only handled new messages, reactions, and message-action callbacks.
- Native Slack queues edit/delete lifecycle events into the target session so the next agent turn has channel context without causing an unsolicited reply.
- Dropping Inline edits/deletes can make the agent act on stale context and makes Inline feel less native than Slack/Telegram in active conversations.

Fix:

- Resolve a lifecycle-event route through Inline account/group/DM policy without creating pairing requests.
- Queue `Inline message edited...` / `Inline messages deleted...` system events with stable context keys.
- Ignore self-authored edits and avoid immediate agent dispatch for edit/delete-only events.
- Add monitor regressions for group edit queueing, self-edit suppression, and direct delete routing through the chat peer.

### 75. Reply-thread-disabled hint leaked native-channel wording

Status: fixed in the working tree. The Inline agent prompt no longer says disabled reply-thread mode creates "not a native reply-thread chat"; it now says "not a dedicated Inline reply-thread chat."

Refs:

- `packages/openclaw/src/inline/channel.ts`
- `packages/openclaw/src/inline/channel.test.ts`

Why it matters:

- Inline is an external plugin, and the rest of the copy now uses Inline-specific product language.
- "Native reply-thread chat" is ambiguous: it can read as a generic OpenClaw native-provider feature rather than an Inline behavior.
- This hint is injected into the agent message-tool prompt, so unclear copy can become weird or user-visible tool behavior.

Fix:

- Replace the native-channel phrase with Inline-specific wording.
- Update the channel prompt regression.

### 76. Reactions triggered immediate replies instead of native-style system events

Status: fixed in the working tree. Inline now queues reaction add/remove notifications as system events and no longer turns a reaction on a bot message into a synthetic inbound prompt that immediately dispatches an agent reply.

Refs:

- `packages/openclaw/src/inline/monitor.ts`
- `packages/openclaw/src/inline/monitor.test.ts`
- `/Users/mo/dev/openclaw/extensions/slack/src/monitor/events/reactions.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/src/bot-handlers.runtime.ts`

Why it matters:

- Slack queues `reaction_added` / `reaction_removed` as system events with a stable context key.
- Telegram queues `message_reaction` additions as system events and does not immediately ask the agent to answer.
- Inline previously synthesized a message like `@alice reacted with 🔥 to your message #...`, bypassed the mention gate, dispatched the agent, and sent a threaded reply. That makes a passive reaction noisy and less native than Telegram/Slack.

Fix:

- Reuse Inline lifecycle route authorization for reaction events so DM/group policy still applies without creating pairing side effects.
- Queue `Inline reaction added/removed...` system events with stable context keys and sender-owner downgrade flags.
- Keep the existing default "own" behavior by only emitting for reactions targeting known bot messages.
- Remove the reaction-as-inbound-message monitor path and add regressions for add, remove, and non-bot targets.

### 77. Reaction notifications had no user-facing mode switch

Status: fixed in the working tree. Inline now supports `reactionNotifications: "off" | "own" | "all"` at the top level and per account, matching Telegram's notification modes and Slack's configurable notification behavior.

Refs:

- `packages/openclaw/src/inline/config-schema.ts`
- `packages/openclaw/src/inline/monitor.ts`
- `packages/openclaw/openclaw.plugin.json`
- `packages/openclaw/README.md`
- `packages/openclaw/docs/openclaw-setup.md`
- `/Users/mo/dev/openclaw/extensions/telegram/src/bot-handlers.runtime.ts`
- `/Users/mo/dev/openclaw/extensions/slack/src/monitor/provider.ts`

Why it matters:

- Native Telegram defaults reaction notifications to `"own"` but lets users set `"off"` or `"all"`.
- Native Slack also exposes reaction notification configuration.
- After Inline reaction events became system events, users needed the same production control to silence passive reactions or broaden them beyond bot-authored messages.

Fix:

- Add `reactionNotifications` to Inline config schemas and manifest config metadata.
- Keep default behavior as `"own"` for bot-authored message reactions.
- Add `"off"` to drop before history lookup, and `"all"` to queue reactions on any authorized message.
- Document the mode in setup docs and README.

### 78. Static manifest missed account-level reaction notification config

Status: fixed in the working tree. The runtime schema accepted `channels.inline.accounts.<id>.reactionNotifications`, but `openclaw.plugin.json` only declared the top-level field.

Refs:

- `packages/openclaw/openclaw.plugin.json`
- `packages/openclaw/src/manifest.test.ts`
- `packages/openclaw/README.md`
- `packages/openclaw/docs/openclaw-setup.md`

Why it matters:

- Native channel configs expose per-account/per-provider overrides consistently through runtime and manifest metadata.
- Inline multi-account users could set the field manually, but config UI/schema consumers would not discover or strongly validate it at the account level.

Fix:

- Add `reactionNotifications` to the named-account property refs in the plugin manifest.
- Extend manifest tests to prove account-scoped `"all"` is accepted and invalid account-scoped modes are rejected.
- Clarify docs that named accounts can override the same reaction notification mode.

### 79. Reaction notifications missed Slack's selective allowlist mode

Status: fixed in the working tree. Inline now supports `reactionNotifications: "allowlist"` plus `reactionAllowlist` at the top level and per named account.

Refs:

- `packages/openclaw/src/inline/config-schema.ts`
- `packages/openclaw/src/inline/monitor.ts`
- `packages/openclaw/src/inline/config-schema.test.ts`
- `packages/openclaw/src/inline/monitor.test.ts`
- `packages/openclaw/src/manifest.test.ts`
- `packages/openclaw/openclaw.plugin.json`
- `packages/openclaw/README.md`
- `packages/openclaw/docs/openclaw-setup.md`
- `/Users/mo/dev/openclaw/extensions/slack/src/monitor/events/reactions.ts`
- `/Users/mo/dev/openclaw/extensions/slack/src/monitor/events/reactions.test.ts`

Why it matters:

- Slack offers a middle ground between `"own"` and `"all"` so teams can queue passive reaction events only from selected users.
- Inline had only Telegram's `off | own | all`, which forced operators to choose between broad reaction notifications and no selected-user reaction feed.

Fix:

- Add `"allowlist"` to Inline reaction notification modes and `reactionAllowlist` to runtime/static schemas and account manifest refs.
- Gate allowlist-mode reaction events before bot-target history lookup, using the same Inline allowlist/access-group expansion path as message authorization.
- Add regressions for blocked and accepted allowlist reaction senders, and document the mode.

### 80. Account/status surfaces hid reaction notification policy

Status: fixed in the working tree. Inline now exposes `reactionNotifications` and `reactionAllowlist` on resolved accounts, inspected accounts, account descriptions, and status snapshots.

Refs:

- `packages/openclaw/src/inline/accounts.ts`
- `packages/openclaw/src/inline/shared.ts`
- `packages/openclaw/src/inline/channel.ts`
- `packages/openclaw/src/inline/channel.test.ts`
- `/Users/mo/dev/openclaw/extensions/slack/src/account-inspect.ts`
- `/Users/mo/dev/openclaw/extensions/slack/src/account-surface-fields.ts`

Why it matters:

- Slack account inspection surfaces reaction notification settings directly, which helps operators understand configured channel behavior without digging through nested raw config.
- Inline had added reaction notification controls, but status/config consumers only saw them if they inspected the raw `config` object. That made the new controls less visible in multi-account diagnostics and config UIs.

Fix:

- Add effective reaction notification fields to `ResolvedInlineAccount` and `InspectedInlineAccount`.
- Include the fields in `describeAccount` and `buildAccountSnapshot`.
- Add a regression covering resolve, inspect, describe, and status snapshot output.

### 81. Reaction sender allowlist entries were not audited

Status: fixed in the working tree. Inline now emits a dedicated security audit finding for non-numeric `reactionAllowlist` entries.

Refs:

- `packages/openclaw/src/inline/security.ts`
- `packages/openclaw/src/inline/channel.test.ts`

Why it matters:

- `reactionNotifications: "allowlist"` compares sender IDs after Inline ID normalization and access-group expansion.
- A display name such as `@alice` would never match a reaction sender, but before this audit pass the config looked valid and failed silently.
- The allowlist docs say the field accepts the same numeric/access-group entries as `allowFrom`, so audit behavior should enforce that expectation.

Fix:

- Validate `reactionAllowlist` entries with the same Inline numeric-id/access-group rules used for `allowFrom`.
- Emit `channels.inline.reactionAllowlist.invalid_entries` with targeted remediation.
- Add regressions for invalid display-name entries and valid access-group entries.

### 82. Numeric Inline sender IDs were rejected by schema/manifest

Status: fixed in the working tree. Inline now accepts numeric allowlist entries in the same places native Telegram/Slack accept numeric sender IDs.

Refs:

- `packages/openclaw/src/inline/config-schema.ts`
- `packages/openclaw/openclaw.plugin.json`
- `packages/openclaw/src/inline/config-schema.test.ts`
- `packages/openclaw/src/manifest.test.ts`
- `packages/openclaw/src/inline/channel.test.ts`
- `/Users/mo/dev/openclaw/src/config/types.telegram.ts`
- `/Users/mo/dev/openclaw/src/config/types.slack.ts`

Why it matters:

- Native Telegram/Slack configs allow sender allowlists as `Array<string | number>`.
- Inline user IDs are numeric, and the runtime already normalizes allowlist values with `String(...)`, but the Inline Zod schema and plugin manifest only accepted strings.
- Users who write JSON/YAML numeric IDs without quotes could get rejected config even though the runtime behavior is otherwise valid.

Fix:

- Add a shared `InlineAllowEntrySchema = string | number`.
- Use it for `allowFrom`, `groupAllowFrom`, and `reactionAllowlist` at top-level and named-account config.
- Update the static plugin manifest schema for the same fields.
- Add regressions for top-level, account-level, manifest-runtime, and security-audit numeric entries.

### 83. Inline was missing native `defaultTo` outbound fallback support

Status: fixed in the working tree. Inline now accepts and resolves `defaultTo` targets like native Telegram and Slack.

Refs:

- `packages/openclaw/src/inline/config-schema.ts`
- `packages/openclaw/src/inline/shared.ts`
- `packages/openclaw/openclaw.plugin.json`
- `packages/openclaw/src/inline/config-schema.test.ts`
- `packages/openclaw/src/manifest.test.ts`
- `packages/openclaw/src/inline/channel.test.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/src/shared.ts`
- `/Users/mo/dev/openclaw/extensions/slack/src/shared.ts`
- `/Users/mo/dev/openclaw/src/infra/outbound/targets-resolve-shared.ts`

Why it matters:

- OpenClaw resolves outbound message targets from `plugin.config.resolveDefaultTo` when no explicit target is passed.
- Native Telegram exposes `channels.telegram.defaultTo` / account `defaultTo`; Slack exposes the same fallback surface.
- Inline accepted no `defaultTo` config and had no adapter hook, so users had a worse CLI/tooling path and had to pass explicit Inline targets even when other channel plugins did not.

Fix:

- Add `defaultTo: string | number` to Inline top-level and named-account config schemas.
- Add static manifest and UI-hint metadata for `defaultTo`.
- Add `inlineConfigAdapter.resolveDefaultTo`, normalizing numeric targets to strings and trimming empty values.
- Add regressions for schema acceptance, manifest runtime validation, and top-level/account adapter resolution.

### 84. Inline docs omitted the new outbound fallback target

Status: fixed in the working tree. README and setup docs now teach `channels.inline.defaultTo` and named-account `defaultTo` overrides.

Refs:

- `packages/openclaw/README.md`
- `packages/openclaw/docs/openclaw-setup.md`
- `/Users/mo/dev/openclaw/docs/channels/telegram.md`
- `/Users/mo/dev/openclaw/docs/channels/qa-channel.md`

Why it matters:

- Native channel docs describe `defaultTo` as the fallback target when no explicit target is supplied.
- Inline now implements the same behavior, but without docs it would look like an undocumented schema/UI-only option.
- Production users who rely on `openclaw message send --channel inline --message ...` need to know when a configured fallback is available and what target grammar to use.

Fix:

- Add a short default-target note near the core config defaults.
- Add top-level and per-account examples.
- Add outbound-target semantics copy explaining that explicit targets override configured defaults.

### 85. Inline group session announce targets resolved to invalid `group:<id>` targets

Status: fixed in the working tree. Inline now implements `messaging.resolveSessionTarget` and maps session-derived group/channel ids to `chat:<id>`.

Refs:

- `packages/openclaw/src/inline/channel.ts`
- `packages/openclaw/src/inline/channel.test.ts`
- `/Users/mo/dev/openclaw/src/agents/tools/sessions-send-helpers.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/src/channel.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/src/session-conversation.ts`
- `/Users/mo/dev/openclaw/extensions/slack/src/channel.ts`

Why it matters:

- OpenClaw's session announce helper parses `agent:<agent>:<channel>:group:<id>` keys and asks the channel for `messaging.resolveSessionTarget` when available.
- Telegram and Slack provide this hook, so their group/channel session keys become valid outbound targets.
- Inline did not provide the hook. The generic fallback for an Inline group session became `group:<id>`, but Inline's send path expects `chat:<id>` or a bare numeric legacy chat id.
- Agent-to-agent/session sends targeting an Inline group session could therefore fail or route through confusing target validation instead of reusing the current group chat.

Fix:

- Add `resolveInlineSessionTarget` and expose it through `messaging.resolveSessionTarget`.
- Normalize `inline:`/`chat:` shapes and return explicit `chat:<id>` targets.
- Add a regression covering both group and channel session target kinds.

### 86. Inline conversation delivery target formatting used generic `channel:<id>` grammar

Status: fixed in the working tree. Inline now implements `messaging.resolveDeliveryTarget` and returns Inline-native `chat:<id>` targets.

Refs:

- `packages/openclaw/src/inline/channel.ts`
- `packages/openclaw/src/inline/channel.test.ts`
- `/Users/mo/dev/openclaw/src/utils/delivery-context.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/src/channel.ts`
- `/Users/mo/dev/openclaw/extensions/slack/src/channel.ts`

Why it matters:

- OpenClaw's delivery-context helpers ask channel plugins to convert conversation ids into outbound targets.
- Telegram and Slack provide `resolveDeliveryTarget`; Inline did not, so the host fallback produced `channel:<id>`.
- Inline send paths accept `chat:<id>`, `user:<id>`, `inline:<id>`, or legacy bare numeric chat ids, but not generic `channel:<id>`.
- Any host flow that routes via conversation ids could therefore produce a target string that Inline rejects.

Fix:

- Add `resolveInlineDeliveryTarget`.
- Map single conversation ids to `chat:<id>`.
- Map child + parent conversation ids to `{ to: "chat:<parent>", threadId: "<child>" }` so reply-thread child conversations retain the parent chat target.
- Add regressions for both top-level and parent/child delivery target resolution.

### 87. Inline inbound conversation resolution fell back to generic stripped ids

Status: fixed in the working tree. Inline now implements `messaging.resolveInboundConversation` and canonicalizes inbound chat ids with the same `inline:chat:<id>` grammar its binding matcher already uses.

Refs:

- `packages/openclaw/src/inline/channel.ts`
- `packages/openclaw/src/inline/channel.test.ts`
- `/Users/mo/dev/openclaw/src/channels/conversation-resolution.ts`
- `/Users/mo/dev/openclaw/src/hooks/message-hook-mappers.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/src/channel.ts`

Why it matters:

- Telegram provides `resolveInboundConversation`, so inbound command/session binding code gets provider-owned conversation ids instead of host fallback strings.
- Inline had binding normalization for configured conversations, but no inbound resolver. Some OpenClaw paths therefore saw fallback ids like `7000` or `chat:7000`, while configured bindings normalized to `inline:chat:7000`.
- Reply-thread child chats were especially fragile because Inline's inbound context stores the parent chat in `To`/`OriginatingTo` and the child reply-thread chat in `MessageThreadId`.

Fix:

- Add `resolveInlineInboundConversation`.
- Canonicalize parent chats from `to`/`conversationId` into `inline:chat:<id>`.
- Use `threadId` as the child conversation when present and retain the parent chat as `parentConversationId`.
- Add regressions for top-level inbound chats and parent/child reply-thread inbound conversations.

### 88. Inline did not preserve reply-thread destinations for group heartbeat routes

Status: fixed in the working tree. Inline now opts into `messaging.preserveHeartbeatThreadIdForGroupRoute`, matching Telegram's behavior for plugin-owned threaded group destinations.

Refs:

- `packages/openclaw/src/inline/channel.ts`
- `packages/openclaw/src/inline/channel.test.ts`
- `/Users/mo/dev/openclaw/src/infra/outbound/targets.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/src/channel.ts`

Why it matters:

- OpenClaw heartbeat delivery intentionally drops inherited session thread ids by default to avoid stale thread replies.
- Telegram sets `preserveHeartbeatThreadIdForGroupRoute` because forum topic ids are part of the destination identity for group routes.
- Inline reply threads use a parent chat target plus the child reply-thread chat id. Without this hook, `heartbeat.target="last"` after an Inline reply-thread turn could send to the parent group chat instead of the active reply-thread child chat.

Fix:

- Set `messaging.preserveHeartbeatThreadIdForGroupRoute = true` for Inline.
- Add a channel regression asserting the hook stays enabled alongside Inline's session/delivery target hooks.

### 89. Inline did not advertise current-conversation binding support

Status: fixed in the working tree. Inline now exposes the generic current-conversation binding surface with provider-owned conversation ref normalization.

Refs:

- `packages/openclaw/src/inline/channel.ts`
- `packages/openclaw/src/inline/channel.test.ts`
- `/Users/mo/dev/openclaw/src/infra/outbound/current-conversation-bindings.ts`
- `/Users/mo/dev/openclaw/src/infra/outbound/session-binding-service.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/src/channel.ts`

Why it matters:

- Telegram advertises `conversationBindings.supportsCurrentConversationBinding`, so generic OpenClaw binding flows can pin an ACP/session target to the current chat or topic.
- Inline had configured binding normalization but no `conversationBindings` surface, so generic current-conversation binding capabilities were unavailable even though Inline has stable chat ids.
- This made Inline worse than native Telegram for "bind here" style ACP/session workflows and could leave production users with an unnecessary unsupported-channel error.

Fix:

- Add Inline `conversationBindings` with `supportsCurrentConversationBinding: true` and `defaultTopLevelPlacement: "current"`.
- Add `resolveInlineConversationRef` so current bindings use `inline:chat:<id>` for top-level chats and preserve child/parent reply-thread refs.
- Add regressions for top-level, parent/child, and thread-derived conversation refs.

### 90. Inline session conversation refs used generic bare ids instead of Inline binding ids

Status: fixed in the working tree. Inline now implements `messaging.resolveSessionConversation` so session-derived conversation refs keep stable session ids while exposing Inline-native `inline:chat:<id>` binding ids.

Refs:

- `packages/openclaw/src/inline/channel.ts`
- `packages/openclaw/src/inline/channel.test.ts`
- `/Users/mo/dev/openclaw/src/channels/plugins/session-conversation.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/src/session-conversation.ts`

Why it matters:

- OpenClaw's generic session parser handles `agent:main:inline:group:7:thread:8`, but it treats conversation ids and parent candidates as bare `7`.
- Inline's configured and current-conversation binding refs now normalize to `inline:chat:<id>`, so session-derived policy/binding/model override paths could compare different ids for the same Inline chat.
- Telegram owns its session conversation grammar for forum topics; Inline needed the same provider-owned normalization for reply-thread child chats.

Fix:

- Add `resolveInlineSessionConversation`.
- Keep session ids as numeric chat ids so base session keys stay stable.
- Expose `baseConversationId` and parent candidates as `inline:chat:<parent>` and preserve numeric `threadId` for actual Inline delivery.
- Add regressions for top-level and `:thread:` Inline session raw ids.

### 91. Inline has no native approval capability while Telegram and Slack do

Status: fixed in the working tree. See item 99 for the implementation and final install verification. The fix includes authorization, delivery routing, native runtime handling, and button resolution rather than only adding a fallback render hook.

Refs:

- `packages/openclaw/src/inline/channel.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/src/approval-native.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/src/exec-approvals.ts`
- `/Users/mo/dev/openclaw/extensions/slack/src/approval-native.ts`
- `/Users/mo/dev/openclaw/extensions/slack/src/exec-approvals.ts`
- `/Users/mo/dev/openclaw/src/plugin-sdk/approval-delivery-helpers.ts`

Why it matters:

- Telegram and Slack expose `approvalCapability`, including approver authorization, native delivery capabilities, origin/DM target resolution, fallback suppression, setup guidance, and lazy native runtime adapters for approval interactions.
- Inline currently has interactive buttons in normal replies, but no approval capability. Exec/plugin approval requests therefore fall back to the Web UI or terminal UI instead of Inline-native approval cards/buttons.
- Production users who rely on Telegram/Slack native approval flows will see Inline as a less capable channel for sensitive actions, especially when they expect approval prompts in the same chat/thread where a request originated.

Required fix:

- Add an Inline exec/plugin approval config surface compatible with OpenClaw's `execApprovals` profile helpers.
- Resolve approvers from Inline user ids, likely using explicit `channels.inline.execApprovals.approvers` with `commands.ownerAllowFrom` fallback.
- Resolve origin targets from Inline turn-source/session metadata using `inline:chat:<id>` and reply-thread parent/child grammar.
- Add an Inline approval native runtime that sends approval cards/buttons and handles approve/deny callbacks with proper sender authorization.
- Add setup/docs copy that names Inline-specific config paths and avoids Telegram/Slack/Web-only wording.

### 92. Inline parsed `inline:` targets but did not advertise the provider prefix

Status: fixed in the working tree. Inline now advertises `messaging.targetPrefixes = ["inline"]`, matching native plugins that expose provider-prefixed explicit targets.

Refs:

- `packages/openclaw/src/inline/channel.ts`
- `packages/openclaw/src/inline/channel.test.ts`
- `/Users/mo/dev/openclaw/src/infra/outbound/channel-target-prefix.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/src/channel.ts`
- `/Users/mo/dev/openclaw/extensions/slack/src/channel.ts`

Why it matters:

- Inline accepted `inline:<id>` and `inline:chat:<id>` in its own target parser.
- Core provider-prefix validation only recognizes prefixes advertised through `messaging.targetPrefixes`.
- Without the hook, a command targeting the wrong selected channel with an `inline:` target could bypass the standard native-channel "belongs to another channel" validation instead of failing early like Telegram/Slack.

Fix:

- Add `targetPrefixes: ["inline"]` to Inline's messaging adapter.
- Add a channel regression so the prefix remains part of the plugin contract.

### 93. Inline had typing indicators for live replies but not heartbeat replies

Status: fixed in the working tree. Inline now exposes `heartbeat.sendTyping` and `heartbeat.clearTyping` for chat and reply-thread destinations.

Refs:

- `packages/openclaw/src/inline/channel.ts`
- `packages/openclaw/src/inline/channel.test.ts`
- `/Users/mo/dev/openclaw/src/infra/heartbeat-typing.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/src/channel.ts`
- `/Users/mo/dev/openclaw/extensions/discord/src/channel.ts`

Why it matters:

- Inline already starts/stops typing indicators while processing normal inbound replies.
- Telegram and Discord expose the shared heartbeat typing hook, so cron/heartbeat-triggered replies can show activity before sending.
- Inline heartbeat replies could stay silent even when the route was a normal Inline chat or reply-thread child chat, making delayed heartbeat work feel less native than Telegram.

Fix:

- Add `sendTypingInline` and wire `heartbeat.sendTyping` / `heartbeat.clearTyping`.
- Resolve reply-thread child chat ids through the existing Inline reply-thread capability gate.
- Skip explicit `user:<id>` routes because the Inline SDK typing API only accepts chat ids; direct inbound sessions still record `inline:<chatId>` last routes and are covered.
- Add a regression for chat/reply-thread typing and the user-target skip.

### 94. Inline supported reactions but did not give native reaction guidance

Status: fixed in the working tree. Inline now exposes `agentPrompt.reactionGuidance` in minimal mode when its `react` action is enabled.

Refs:

- `packages/openclaw/src/inline/channel.ts`
- `packages/openclaw/src/inline/actions.ts`
- `packages/openclaw/src/inline/channel.test.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/src/channel.ts`
- `/Users/mo/dev/openclaw/src/agents/system-prompt.ts`

Why it matters:

- Telegram exposes `reactionGuidance`, which adds a dedicated Reactions prompt section when agent-controlled reactions are enabled.
- Inline already supports `react` / `reactions`, but the model only saw generic tool availability and one terse tool hint.
- Production Inline users therefore got less native-feeling reaction behavior than Telegram users even though the underlying action exists.

Fix:

- Add `supportsInlineReactionsForConfig`.
- Return minimal Inline reaction guidance when `react` is enabled.
- Suppress guidance when `channels.inline.actions.reactions=false`.
- Add prompt-surface regressions for both enabled and disabled reaction configs.

### 95. Inline only exposed legacy outbound sends, not the native `message` adapter

Status: fixed in the working tree. Inline now wraps its existing outbound adapter with OpenClaw's `createChannelMessageAdapterFromOutbound` helper.

Refs:

- `packages/openclaw/src/inline/channel.ts`
- `packages/openclaw/src/inline/channel.test.ts`
- `/Users/mo/dev/openclaw/src/channels/message/outbound-bridge.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/src/channel.ts`
- `/Users/mo/dev/openclaw/extensions/slack/src/channel.ts`
- `/Users/mo/dev/openclaw/extensions/discord/src/channel.ts`

Why it matters:

- Telegram, Slack, and Discord expose a `message` adapter so newer OpenClaw durable-send/live-preview flows can reason about text, media, payload, receipts, and live message capabilities.
- Inline had the same send primitives but only through `outbound`, so any core flow preferring the native message adapter treated Inline as less capable.
- This created a structural gap even when user-visible sends worked through the compatibility paths.

Fix:

- Hoist Inline's outbound adapter into `inlineOutbound`.
- Add `inlineMessageAdapter` via `createChannelMessageAdapterFromOutbound`.
- Declare live draft preview, preview finalization, and progress-update capabilities to match Inline's existing streaming behavior.
- Add a plugin contract regression for the adapter and send surfaces.

### 96. Inline target display formatting could throw on invalid targets

Status: fixed in the working tree. `formatTargetDisplay` now returns the raw target when parsing fails.

Refs:

- `packages/openclaw/src/inline/channel.ts`
- `packages/openclaw/src/inline/channel.test.ts`
- `/Users/mo/dev/openclaw/extensions/telegram/src/channel.ts`
- `/Users/mo/dev/openclaw/extensions/slack/src/channel.ts`

Why it matters:

- Inline's routing parser intentionally throws on invalid explicit targets.
- The display formatter is a presentation hook, not a routing validator, and core may call it for unresolved user input or diagnostic targets.
- Native plugins keep display formatting best-effort. Inline could turn a harmless label render into an exception.

Fix:

- Catch parser failures in `formatInlineTargetDisplay`.
- Return the trimmed raw target when parsing fails.
- Add a regression for `bad-target`.

### 97. Inline nudge/forward tools defaulted reply-thread sessions to the parent chat

Status: fixed in the working tree. Current-chat fallback parsing now prefers the `:thread:<childChatId>` segment for Inline group/chat session keys.

Refs:

- `packages/openclaw/src/inline/message-tools.ts`
- `packages/openclaw/src/inline/message-tools.test.ts`
- `packages/openclaw/src/inline/channel.ts`

Why it matters:

- Inline reply threads are separate chats. In a session key such as `agent:main:inline:group:77:thread:88`, `77` is the parent chat and `88` is the active reply-thread chat.
- `inline_nudge` and `inline_forward` use the current session as their default target/source when the agent omits explicit `to`/`from`.
- The fallback parser ignored the thread segment, so tools invoked inside a reply-thread conversation could nudge the parent chat or forward from the wrong source chat.

Fix:

- Parse numeric `:thread:<id>` segments for Inline chat/group session keys.
- Use the child chat id as the current chat for current-target defaults.
- Add regressions for reply-thread `inline_nudge` and `inline_forward`.

### 98. Inline media/profile uploads used a stale local file bypass path

Status: fixed in the working tree. Inline media sends now receive OpenClaw's media access context explicitly, and profile-photo uploads no longer retry blocked local paths with an unsafe `localRoots: "any"` fallback.

Refs:

- `packages/openclaw/src/inline/media.ts`
- `packages/openclaw/src/inline/channel.ts`
- `packages/openclaw/src/inline/actions.ts`
- `packages/openclaw/src/inline/profile-tool.ts`
- `packages/openclaw/src/inline/channel.test.ts`
- `packages/openclaw/src/inline/actions.test.ts`
- `/Users/mo/dev/openclaw/src/media/web-media.ts`

Why it matters:

- OpenClaw 2026.5.18 rejects `localRoots: "any"` unless the host passes a policy-gated `readFile` capability.
- Inline retried blocked local media paths with `localRoots: "any"` and no `readFile`, which is both stale against the current core contract and too broad for production media handling.
- Native channel media paths flow through the shared media access policy. Inline's custom upload helper needed to preserve that context for outbound sends and message actions.

Fix:

- Pass `mediaAccess`, `mediaLocalRoots`, and `mediaReadFile` through Inline outbound media sends and attachment actions.
- Build the media loader options from the host-provided policy context, only using `localRoots: "any"` when a host `readFile` capability is present.
- Remove the profile-photo blocked-path retry so profile uploads follow the same OpenClaw media loader policy.
- Add regressions that blocked local paths are not bypassed and that attachment actions forward media access.

## Proposed Refactor Plan

### Phase 1: Stop production footguns

1. Change `commands.native: false` to skip startup sync instead of clearing commands.
2. Remove delete-before-set for normal command sync.
3. Add shared command validation/trimming for startup sync.
4. Pass `threadId` through `sendPayload`.
5. Update tests around command disable, set failure, command limits, and rich reply-thread routing.

### Phase 2: Make Inline first-class in OpenClaw metadata/setup

1. Align `package.json`, `openclaw.plugin.json`, and runtime meta copy.
2. Add missing metadata: `detailLabel`, `systemImage`, `markdownCapable`, command auto metadata, configured state.
3. Add or expose setup entry support if external plugins can use it.
4. Replace the thin setup wizard with a native-quality setup flow.
5. Add DM policy and allowlist prompts.
6. Add group access guidance and warnings.

### Phase 3: Remove Telegram leakage

1. Add an Inline native command provider/surface or generic chat-button surface.
2. Replace `provider: "telegram"` and `effectiveSurface = "telegram"` in Inline.
3. Prefer `channelData.inline` everywhere.
4. Keep `channelData.telegram` fallback only as a backwards compatibility path.
5. Rename tests and docs that say "Telegram-style".

### Phase 4: Prompt/copy/docs polish

1. Collapse duplicated formatting instructions into one concise contract.
2. Move brittle sanitizer behavior toward an upstream non-visible/internal-message contract if OpenClaw supports it.
3. Tighten fallback copy.
4. Rework README and landing docs into user/admin/developer sections.
5. Add an update guide for production users.

### Phase 5: Release validation

1. Update devDependency to `openclaw@2026.5.18`.
2. Run package checks:
   - `cd packages/openclaw && bun run typecheck`
   - `cd packages/openclaw && bun run lint`
   - `cd packages/openclaw && bun run test`
   - `cd packages/openclaw && bun run build`
3. Build and install into local OpenClaw per repo instructions:
   - build package
   - replace local OpenClaw plugin dist
   - restart gateway
   - confirm gateway is healthy
   - ask for live try
4. Verify:
   - new install setup
   - existing install update
   - DM pairing
   - DM allowlist
   - group allowlist
   - group open with mention requirement
   - `/model`, `/models`, `/think`, `/exec`, `/status`
   - command buttons
   - `inline_bot_commands`
   - rich replies with buttons/selects
   - text/media/reply/thread-reply
   - native reply threads enabled and disabled

## Local Runtime Validation

Completed:

- Tried `openclaw plugins install --link /Users/mo/dev/inline-chat/inline/packages/openclaw`; OpenClaw blocked it because the workspace `node_modules/openclaw` symlink targets outside the plugin root. This was the right safety behavior.
- Packed the plugin with `npm pack --ignore-scripts --pack-destination /tmp`.
- Installed the packed artifact with `openclaw plugins install --force /tmp/inline-openclaw-inline-0.0.36.tgz`.
- The non-force reinstall path correctly refused to overwrite the existing managed plugin; `openclaw plugins update inline` also correctly failed because `@inline-openclaw/inline@0.0.36` is not published to npm yet.
- The final managed install root is `~/.openclaw/extensions/inline`.
- New install record:
  - source path: `/tmp/inline-openclaw-inline-0.0.36.tgz`
  - install path: `/Users/mo/.openclaw/extensions/inline`
  - integrity: `sha512-3H4sD7qbBzXGVYRuLtCrWeGHiYS1fMrsV2CmXma9WJh5jxtvDWehAa+e/Tibuq7Tth8tZSzWBi2mR6NGjS9ySw==`
  - shasum: `4a468d0e8517ee849ab8c59ab7135022454fb9d9`
- `openclaw plugins doctor` reports no plugin issues.
- Restarted the gateway with `openclaw gateway restart`.
- `openclaw channels status` reports Inline default enabled/configured/running/connected and Telegram default enabled/configured/running/disconnected in polling mode.
- `openclaw gateway health` -> `OK (916ms)`; Telegram configured; Inline configured.
- `openclaw status --json` reports gateway version `2026.5.18`, LaunchAgent runtime pid `35769`, and reachable loopback gateway.
- Gateway logs show:
  - `http server listening (... inline ...)`
  - `[inline] bot commands synced for account "default" (66 commands)`
  - `[default] inline connected (me=36100)`
  - `[default] starting Inline realtime monitor`
- Installed package verification:
  - `/Users/mo/.openclaw/extensions/inline/package.json` has no `moltbot` metadata.
  - Installed package metadata includes `openclaw.compat.pluginApi >=2026.5.18`, `openclaw.build.openclawVersion = 2026.5.18`, and release flags for npm/ClawHub.
  - Installed package metadata includes `openclaw.channel.quickstartAllowFrom: true`.
  - Installed package metadata includes Inline-specific `doctorCapabilities`.
  - Installed artifact includes `dist/inline/doctor.d.ts` / `dist/inline/doctor.d.ts.map` and the doctor adapter is bundled into `dist/channel-plugin-api.js`.
  - Installed artifact includes Inline `agentPrompt.inboundFormattingHints` output (`text_markup: "inline_markdown"`) in `dist/channel-plugin-api.js`.
  - Installed artifact includes Inline `agentPrompt.messageToolCapabilities` output (`inlineButtons`) and the Inline-specific buttons/selects prompt hint in `dist/channel-plugin-api.js`.
  - Installed `dist/channel-plugin-api.js` now builds account snapshots from `inspectInlineAccount`, so unavailable token files report unconfigured status.
  - Installed `dist/channel-plugin-api.js`, `dist/account-inspect-api.js`, and `dist/setup-plugin-api.js` include the duplicate Inline bot-token owner guard.
  - Installed `dist/channel-plugin-api.js` scopes message-tool action discovery and `inlineButtons` prompt capability by account id.
  - Installed `dist/channel-plugin-api.js` reports Inline connected lifecycle fields (`connected`, `lastConnectedAt`, `lastEventAt`, `lastTransportActivityAt`) in runtime/status snapshots.
  - Installed `dist/index.js` is the narrow bundled channel entry and points to `channel-plugin-api.js`, `runtime-setter-api.js`, `account-inspect-api.js`, `secret-contract-api.js`, and `runtime-register-api.js`.
  - Installed `openclaw.plugin.json` channel help mentions `INLINE_BOT_TOKEN` and no longer contains the stale "realtime bot token" wording.
  - Installed `openclaw.plugin.json` labels command setup as `Inline Bot Command Sync` / `Inline Skill Command Sync` and describes reply threads through OpenClaw's thread API.
  - Installed `openclaw.plugin.json` describes tool-progress compatibility as shared OpenClaw streaming config and no longer mentions "native channels" in the streaming setup hints.
  - Installed `README.md` includes the local `--force npm-pack` reinstall flow, update/restart/verify steps, the `openclaw message send --channel inline` smoke-test example, the OpenClaw 2026.5.18 static-help caveat, and Inline-specific reply-thread/media wording.
  - Installed artifact contains the native-style Inline button labels (`◀ Prev`, `Next ▶`, `✓`).
  - Installed `dist/secret-contract-api.js` exports Inline token secret targets: `channels.inline.token` and `channels.inline.accounts.*.token`.
  - Installed `dist/setup-plugin-api.js` exposes both setup-only secret targets and `security.collectAuditFindings`.
  - Installed `dist/setup-entry.js` exposes `loadSetupSecrets`, and the sidecar returns Inline token secret targets.
  - Installed setup-only config inspection exposes `inspectAccount` and marks symlinked token files as `configured_unavailable`.
  - Installed `dist/runtime-register-api.js` contains the final command sync behavior: registry-authoritative `provider: "inline"`, per-account route-scoped skill commands, plugin command specs with config, Inline-visible copy adaptation for provider-specific and generic thread/topic wording, and Inline-facing `bot command sync` log copy.
  - Installed `dist/channel-plugin-api.js` contains `resolveInlineInteractiveTextFallback`, `sanitizeInlineDeliveryText`, `transformReplyPayload`, and `resolveInlineOutboundSessionRoute`, covering the latest interactive fallback, visible-text sanitizer, reply payload transform, and outbound session routing fixes.
  - Installed dependency metadata pins `@inline-chat/realtime-sdk` to `0.0.11` and `zod` to `4.4.3`.
- Latest installed local artifact:
  - tarball: `/tmp/inline-openclaw-inline-0.0.36.tgz`
  - raw tarball `shasum`: `60ce28a649fbad9151d7c1df622d385b39e88444`
  - installed npm artifact shasum from `openclaw plugins inspect inline --json`: `4a468d0e8517ee849ab8c59ab7135022454fb9d9` (OpenClaw still reports the earlier npm artifact shasum here; direct tarball shasum plus installed-file checks are the artifact evidence for this pass.)
  - installed extension root: `/Users/mo/.openclaw/extensions/inline`
- CLI dry-run verification:
  - `openclaw message send --channel inline --target chat:0 --message "inline dry run" --dry-run --json` succeeds and reports `channel: "inline"`.
  - `openclaw message send --help` still omits `inline` from its static channel help; tracked as an upstream/discoverability gap.
- Final local gateway validation after artifact `60ce28a...`:
  - `openclaw gateway health` -> `OK (800ms)`; Telegram configured; Inline configured.
  - `openclaw plugins doctor` -> no plugin issues detected.
  - `openclaw channels status` reports Inline default enabled/configured/running/connected with token source `config`; Telegram default is enabled/configured/running/disconnected in polling mode.
  - `rg -n --glob '!*.map' "buildInlineMediaLoadOptions|mediaAccess|hostReadCapability|localRoots: \"any\"" /Users/mo/.openclaw/extensions/inline/dist/channel-plugin-api.js /Users/mo/.openclaw/extensions/inline/dist/runtime-register-api.js /Users/mo/.openclaw/extensions/inline/dist/inline/media.d.ts /Users/mo/.openclaw/extensions/inline/dist/inline/profile-tool.d.ts` confirms the installed extension contains the media access pass-through and policy-gated read-file option path.
  - `node -e "import('/Users/mo/.openclaw/extensions/inline/dist/channel-plugin-api.js').then(...)"` confirms installed `targetPrefixes`, heartbeat typing, minimal reaction guidance, native `message` adapter, bad-target display fallback, and outbound media support.
  - `openclaw plugins inspect inline --json` reports the active source as `/Users/mo/.openclaw/extensions/inline/dist/index.js`, status `loaded`, dependencies installed, source path `/tmp/inline-openclaw-inline-0.0.36.tgz`, and installed npm shasum `4a468d0e8517ee849ab8c59ab7135022454fb9d9`.
  - Installed `openclaw.plugin.json` now exposes typed `channels.inline.accounts.*` account fields by referencing the root `channels.inline` field schemas, while keeping account-level future fields allowed.
  - OpenClaw's JSON-schema runtime validates installed account-scoped SecretRef, reply-thread, streaming, and future-field config, and rejects invalid account-scoped streaming modes.
  - Installed `dist/channel-plugin-api.js` forwards `transformReplyPayload` from the shared reply pipeline and no longer contains the stale `enableSlackInteractiveReplies` field.
  - Installed `dist/channel-plugin-api.js` includes the disabled-mode reply-thread hint for `thread-reply` and `thread-create`.
  - Installed `dist/channel-plugin-api.js` includes `messageToolCapabilities` with `inlineButtons` and the Inline-specific buttons/selects prompt hint.
  - Installed `dist/channel-plugin-api.js` uses `inspectInlineAccount` inside `buildAccountSnapshot`, so status issue collection sees unavailable token files as unconfigured.
  - Installed `dist/channel-plugin-api.js` refuses duplicate Inline bot-token account ownership during config/status checks and gateway startup.
  - Installed `dist/channel-plugin-api.js`, `dist/account-inspect-api.js`, and `dist/setup-plugin-api.js` use account-scoped credential precedence, so named account token files and unavailable account SecretRefs do not inherit the top-level token.
  - Installed `dist/channel-plugin-api.js` scopes message-tool actions, button support, and `inlineButtons` prompt capability by active account id.
  - Installed `dist/channel-plugin-api.js` includes `resolveCommandAuthorization` for Inline group control-command gating, and installed audit code recognizes `commands.allowFrom.inline`.
  - Installed `dist/channel-plugin-api.js` includes `expandAllowFromWithAccessGroups`, so Inline DM/group sender allowlists honor `accessGroup:<name>` entries.
  - Installed `dist/runtime-register-api.js` describes the `inline_bot_commands` command field as an Inline bot command, no longer as a slash command, and uses `bot command sync` log copy instead of `native command sync`.
  - Installed `dist/channel-plugin-api.js` and `dist/runtime-register-api.js` include the OpenClaw-aligned runtime-context sanitizer with standalone marker matching and legacy internal task-event stripping.
  - Installed `dist/channel-plugin-api.js` and `dist/runtime-register-api.js` include Inline action limits (`INLINE_ACTION_LABEL_MAX_LENGTH = 64`, `INLINE_ACTION_CALLBACK_DATA_MAX_BYTES = 1024`) and the current `chat|group|user|direct` session-key parser.
  - `node -e "import('/Users/mo/.openclaw/extensions/inline/dist/setup-plugin-api.js').then(...)"` confirms installed group setup help points to `/whoami` and no longer `/chatinfo`.
  - The first split-entry install exposed `Inline runtime not initialized` in `openclaw channels status`; the global runtime holder fix removed that error and status now reports Inline running.
  - `openclaw security audit --json` reports no Inline-specific findings in the current local config; current host summary is 0 critical, 2 warn, 1 info.
  - `openclaw secrets audit --json` reports `channels.inline.token` as a plaintext secret finding, confirming host-level discovery of the Inline token target; current summary is 4 plaintext findings, 0 unresolved refs, 2 legacy OAuth residue findings.
  - `openclaw status --json` reports gateway runtime `2026.5.18`, reachable loopback gateway, and LaunchAgent runtime running with pid `31159`.

Notes:

- The latest status output no longer surfaced the earlier stale/non-standard PATH warning. The running gateway binary and status self-report are `2026.5.18`.
- Gateway logs warn that `plugins.allow` is empty, so non-bundled plugins may auto-load. For production hardening, set an explicit plugin allowlist that includes `inline` and the other trusted plugin ids.
- `openclaw status --json` is reachable and reports gateway runtime `2026.5.18`.

Still needs a human smoke test from Inline:

- DM message and command menu.
- Group allowlist/mention behavior.
- `/commands` pagination buttons.
- `/model` and `/models` inline buttons.
- Rich replies with buttons/selects.
- Reply-thread routing.

## Production Readiness

Closer, but not production-ready for a polished update until the live Inline DM/group smoke test passes. The package is built, installed into the local OpenClaw runtime, the gateway is healthy, and Inline connects from the new artifact.

Fixed in the working tree from the highest-risk findings:

- command clearing when users only disabled sync
- delete-before-set command sync
- stale hand-maintained native command list drift from the OpenClaw 2026.5.18 registry
- account-agnostic native skill command sync in multi-account setups
- plugin command specs being resolved without active config
- Discord/Telegram wording leaking into Inline-visible command copy
- rich payload thread routing gap
- Telegram provider leakage in command/UI behavior
- missing native-quality setup metadata for basic install/access guidance
- missing setup guidance for DM access
- missing setup/runtime support for native-style group access
- group allowlist route bug where configured groups were ignored unless `groupAllowFrom` also matched the sender
- group sender fallback bug where DM `allowFrom` implicitly acted as group sender allowlist
- group route key mismatch where documented `chat:<id>` / `inline:<id>` config keys did not match runtime policy
- env-token setup/runtime mismatch where `INLINE_TOKEN` was advertised but not accepted by runtime account resolution
- missing package setup entry and artifact coverage for setup-only onboarding paths
- missing SecretRef target registration/materialization support for Inline tokens compared with Telegram and Slack
- missing native-style security audit findings for Inline group command sender policy
- missing split setup-entry secret sidecar compared with Telegram and Slack
- missing native-style read-only account inspection for unavailable token files
- broad plain runtime entry instead of native-style bundled channel entry sidecars
- split bundled sidecar runtime singleton bug that made the installed channel report `Inline runtime not initialized`
- setup wizard status reporting unavailable token files as configured
- group setup help pointing users to a non-existent `/chatinfo` command
- package dependency ranges on reviewed runtime/dev dependencies
- ambiguous setup docs for foreground vs service gateway startup
- misleading `groupAllowFrom` config UI copy
- reply-thread action prompt silence in disabled compatibility mode
- static manifest treating named Inline accounts as opaque blobs
- special tools missing current `direct` / `group` Inline session-key shapes
- unconstrained Inline reply buttons that could fail server-side action validation
- prompt capability mismatch that told agents Inline buttons were disabled despite supported controls
- status snapshots reporting unavailable token files as configured
- duplicate Inline bot-token ownership across accounts, including command-menu sync conflicts
- message-tool action discovery leaking capabilities across Inline accounts
- group control-command gating that ignored OpenClaw's standard `commands.allowFrom.inline` authorization and `commands.ownerAllowFrom` restrictions
- missing `accessGroup:<name>` expansion in Inline DM/group sender allowlists
- interactive-only replies/buttons being dropped or sent with empty text instead of native-style fallback text
- live replies, command/model edits, message actions, and plugin messaging transforms bypassing Inline visible-text cleanup
- outbound Inline sends falling back to generic session target parsing instead of native-style canonical route metadata
- stale local media fallback that bypassed OpenClaw 2026.5.18 media access policy

Security risk:

- Access-policy confusion is reduced by setup warnings, group access prompts, group key normalization, security audit findings, and the removal of the stale local media bypass path. Token SecretRef and token-file handling now matches native-channel credential flows more closely. This still needs live setup validation against real Inline DMs/groups before release.

Performance risk:

- No obvious new performance regression was found in this review.
- Startup command sync now skips all Bot API calls when disabled, reducing startup work.
- Runtime entry loading is now lighter: `dist/index.js` is about 2.2 KB and defers full channel/tools/hooks into sidecars. The channel runtime bundle itself is still large and should be watched during release validation.

Compatibility risk:

- The plugin now targets OpenClaw `2026.5.18` in dev dependency, peer dependency, install min host, and lockfile.

## Verification

Passed:

- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/channel.test.ts src/inline/actions.test.ts src/inline/profile-tool.test.ts src/inline/message-tools.test.ts` (4 files, 102 tests)
- `cd packages/openclaw && bun run typecheck`
- `cd packages/openclaw && bun run lint`
- `git diff --check -- packages/openclaw/src/inline/channel.ts packages/openclaw/src/inline/channel.test.ts packages/openclaw/src/inline/actions.ts packages/openclaw/src/inline/actions.test.ts packages/openclaw/src/inline/media.ts packages/openclaw/src/inline/profile-tool.ts packages/openclaw/src/inline/message-tools.ts packages/openclaw/src/inline/message-tools.test.ts .context/2026-05-19-inline-openclaw-native-channel-review.md`
- `cd packages/openclaw && bun run build`
- `cd packages/openclaw && npm pack --ignore-scripts --pack-destination /tmp`
- `shasum /tmp/inline-openclaw-inline-0.0.36.tgz` -> `60ce28a649fbad9151d7c1df622d385b39e88444`
- `openclaw plugins install --force /tmp/inline-openclaw-inline-0.0.36.tgz`
- `openclaw gateway restart`
- `openclaw gateway health` -> `OK (800ms)`; Telegram configured; Inline configured.
- `openclaw channels status` reports Inline default enabled/configured/running/connected and Telegram default enabled/configured/running/disconnected in polling mode.
- `openclaw plugins doctor` -> no issues.
- `rg -n --glob '!*.map' "buildInlineMediaLoadOptions|mediaAccess|hostReadCapability|localRoots: \"any\"" /Users/mo/.openclaw/extensions/inline/dist/channel-plugin-api.js /Users/mo/.openclaw/extensions/inline/dist/runtime-register-api.js /Users/mo/.openclaw/extensions/inline/dist/inline/media.d.ts /Users/mo/.openclaw/extensions/inline/dist/inline/profile-tool.d.ts` confirms installed media access pass-through.
- `node -e "import('/Users/mo/.openclaw/extensions/inline/dist/channel-plugin-api.js').then(...)"` confirms installed native hooks and media sender are exposed.
- `openclaw message send --channel inline --target chat:0 --message "inline dry run" --dry-run --json`
- `openclaw status --json` reports gateway runtime `2026.5.18`, reachable loopback gateway, and LaunchAgent pid `31159`.
- `cd packages/openclaw && bun run test` (19 files, 278 tests)
- `git diff --check -- packages/openclaw .context/2026-05-19-inline-openclaw-native-channel-review.md bun.lock`
- `openclaw --version` -> `OpenClaw 2026.5.18 (50a2481)`
- `git -C /Users/mo/dev/openclaw describe --tags --always --dirty` -> `v2026.5.18`
- `rg -n "Telegram|telegram|Slack|slack|Discord|discord|native channel|native channels|slash command|Telegram-style|Slack-style|Discord-style|moltbot|realtime bot|chatinfo" packages/openclaw/src packages/openclaw/README.md packages/openclaw/docs packages/openclaw/openclaw.plugin.json` now finds only compatibility fallbacks/tests or negative assertions, not remaining user-facing setup/docs/manifest leakage.
- `cd packages/openclaw && bun run typecheck`
- `cd packages/openclaw && bun run lint`
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/config-schema.test.ts src/inline/channel.test.ts src/inline/monitor.test.ts` (3 files, 116 tests)
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/accounts.test.ts src/inline/channel.test.ts src/manifest.test.ts src/inline/package-artifact.test.ts` (4 files, 49 tests)
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/outbound-sanitize.test.ts src/inline/message-formatting.test.ts src/inline/monitor.test.ts` (3 files, 83 tests)
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/manifest.test.ts src/inline/channel.test.ts src/inline/outbound-sanitize.test.ts src/inline/message-formatting.test.ts src/inline/monitor.test.ts` (5 files, 120 tests)
- `cd packages/openclaw && ./node_modules/.bin/vitest run` (18 files, 203 tests)
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/manifest.test.ts src/inline/package-artifact.test.ts` (2 files, 3 tests)
- `cd packages/openclaw && bun run test` (18 files, 203 tests)
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/manifest.test.ts` (1 file, 2 tests)
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/manifest.test.ts src/inline/channel.test.ts` (2 files, 38 tests)
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/message-formatting.test.ts src/inline/channel.test.ts src/inline/monitor.test.ts` (3 files, 112 tests)
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/accounts.test.ts src/inline/config-schema.test.ts src/inline/secret-contract.test.ts src/inline/channel.test.ts src/inline/package-artifact.test.ts src/manifest.test.ts` (6 files, 67 tests)
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/accounts.test.ts src/inline/secret-contract.test.ts` (2 files, 17 tests)
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/accounts.test.ts src/inline/channel.test.ts src/inline/actions.test.ts src/inline/bot-commands-sync.test.ts` (4 files, 88 tests)
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/package-artifact.test.ts src/inline/channel.test.ts src/inline/accounts.test.ts` (3 files, 52 tests)
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/accounts.test.ts src/inline/channel.test.ts` (2 files, 52 tests)
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/monitor.test.ts src/inline/channel.test.ts` (2 files, 109 tests)
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/channel.test.ts src/inline/monitor.test.ts` (2 files, 112 tests)
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/channel.test.ts` (1 file, 40 tests)
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/accounts.test.ts src/inline/channel.test.ts` (2 files, 57 tests)
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/index.test.ts src/inline/secret-contract.test.ts src/inline/package-artifact.test.ts src/manifest.test.ts` (4 files, 9 tests)
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/package-artifact.test.ts src/index.test.ts src/inline/secret-contract.test.ts` (3 files, 7 tests)
- `cd packages/openclaw && ./node_modules/.bin/vitest run` (19 files, 221 tests)
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/index.test.ts src/inline/package-artifact.test.ts` (2 files, 4 tests)
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/runtime.test.ts src/index.test.ts src/inline/package-artifact.test.ts` (3 files, 6 tests)
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/channel.test.ts src/inline/accounts.test.ts src/index.test.ts` (3 files, 61 tests)
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/channel.test.ts src/inline/bot-commands-sync.test.ts` (2 files, 47 tests)
- `cd packages/openclaw && ./node_modules/.bin/vitest run` (19 files, 222 tests)
- `cd packages/openclaw && ./node_modules/.bin/vitest run` (19 files, 223 tests)
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/channel.test.ts src/inline/bot-commands-sync.test.ts` (2 files, 47 tests)
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/bot-commands-sync.test.ts` (1 file, 6 tests)
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/bot-commands-sync.test.ts src/inline/message-formatting.test.ts` (2 files, 11 tests)
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/bot-commands-sync.test.ts src/inline/message-formatting.test.ts src/inline/channel.test.ts src/inline/accounts.test.ts src/index.test.ts` (5 files, 72 tests)
- `cd packages/openclaw && ./node_modules/.bin/vitest run` (19 files, 225 tests)
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/monitor.test.ts` (1 file, 73 tests)
- `cd packages/openclaw && ./node_modules/.bin/vitest run` (19 files, 226 tests)
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/channel.test.ts` (1 file, 42 tests)
- `cd packages/openclaw && bun run typecheck`
- `cd packages/openclaw && bun run lint`
- `cd packages/openclaw && ./node_modules/.bin/vitest run` (19 files, 226 tests)
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/manifest.test.ts` (1 file, 3 tests)
- `cd packages/openclaw && bun run typecheck`
- `cd packages/openclaw && bun run lint`
- `cd packages/openclaw && ./node_modules/.bin/vitest run` (19 files, 227 tests)
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/outbound-sanitize.test.ts src/inline/actions.test.ts src/inline/monitor.test.ts src/inline/message-tools.test.ts` (4 files, 123 tests)
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/channel.test.ts src/inline/actions.test.ts` (2 files, 75 tests)
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/channel.test.ts` (1 file, 42 tests)
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/accounts.test.ts src/inline/channel.test.ts` (2 files, 60 tests)
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/bot-commands-sync.test.ts src/inline/accounts.test.ts src/inline/channel.test.ts` (3 files, 67 tests)
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/actions.test.ts src/inline/channel.test.ts` (2 files, 77 tests)
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/outbound-sanitize.test.ts` (1 file, 13 tests)
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/outbound-sanitize.test.ts src/inline/actions.test.ts src/inline/monitor.test.ts src/inline/message-tools.test.ts` (4 files, 127 tests)
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/accounts.test.ts` (1 file, 19 tests)
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/accounts.test.ts src/inline/channel.test.ts src/inline/bot-commands-sync.test.ts` (3 files, 69 tests)
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/channel.test.ts src/inline/monitor.test.ts` (2 files, 119 tests)
- `cd packages/openclaw && bun run typecheck`
- `cd packages/openclaw && bun run lint`
- `cd packages/openclaw && ./node_modules/.bin/vitest run` (19 files, 242 tests)
- `cd packages/openclaw && bun run lint`
- `git diff --check -- bun.lock .context/2026-05-19-inline-openclaw-native-channel-review.md packages/openclaw`
- `cd packages/openclaw && ./node_modules/.bin/vitest run` (19 files, 244 tests)
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/message-formatting.test.ts src/inline/bot-commands-tool.test.ts src/inline/bot-commands-sync.test.ts src/manifest.test.ts` (4 files, 21 tests)
- `cd packages/openclaw && bun run typecheck`
- `cd packages/openclaw && bun run lint`
- `git diff --check -- bun.lock .context/2026-05-19-inline-openclaw-native-channel-review.md packages/openclaw`
- `cd packages/openclaw && ./node_modules/.bin/vitest run` (19 files, 245 tests)
- `cd packages/openclaw && bun run build`
- `cd packages/openclaw && npm pack --ignore-scripts --pack-destination /tmp`
- `openclaw plugins install --force npm-pack:/tmp/inline-openclaw-inline-0.0.36.tgz`
- `openclaw gateway restart`
- `openclaw plugins doctor`
- `openclaw channels status`
- `openclaw gateway health`
- `openclaw plugins inspect inline --json`
- `openclaw security audit --json`
- `openclaw secrets audit --json`
- `node -e "import('/Users/mo/.openclaw/npm/node_modules/@inline-openclaw/inline/dist/index.js').then(...)"` confirms installed runtime entry is `bundled-channel-entry` with split secrets/account-inspection/runtime loaders.
- `node -e "import('/Users/mo/.openclaw/npm/node_modules/@inline-openclaw/inline/dist/setup-plugin-api.js').then(...)"` confirms installed group setup help uses `/whoami` instead of `/chatinfo`.
- `node -e "import('/Users/mo/.openclaw/npm/node_modules/@inline-openclaw/inline/dist/secret-contract-api.js').then(...)"` confirms installed secret targets and collector export.
- `node -e "import('/Users/mo/.openclaw/npm/node_modules/@inline-openclaw/inline/dist/setup-plugin-api.js').then(...)"` confirms installed setup-only security audit and secret metadata exposure.
- `node -e "import('/Users/mo/.openclaw/npm/node_modules/@inline-openclaw/inline/dist/setup-entry.js').then(...)"` confirms installed setup entry exposes `loadSetupSecrets` and the Inline token secret target ids.
- `node -e "import('/Users/mo/.openclaw/npm/node_modules/@inline-openclaw/inline/dist/setup-plugin-api.js').then(...)"` confirms installed setup-only `inspectAccount` marks symlinked token files as `configured_unavailable`.
- `openclaw security audit --json` reports no Inline-specific findings in the current local config.
- `openclaw secrets audit --json` reports `channels.inline.token` as a plaintext secret finding, confirming host-level discovery of the Inline token target.
- `openclaw message send --channel inline --target chat:0 --message "inline dry run" --dry-run --json`
- `openclaw status --json`
- `openclaw plugins inspect inline --json` confirmed installed artifact metadata for the prior command-authorization build.
- `node -e "...openclaw.plugin.json..."` confirms installed setup labels are `Inline Bot Command Sync` / `Inline Skill Command Sync`.
- `bun -e "import { buildJsonChannelConfigSchema } from 'openclaw/plugin-sdk/core'; ..."` validates the installed static manifest accepts typed named-account config and rejects invalid account-scoped streaming modes.
- `git diff --check -- bun.lock .context/2026-05-19-inline-openclaw-native-channel-review.md packages/openclaw`
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/monitor.test.ts src/inline/channel.test.ts` (2 files, 122 tests)
- `cd packages/openclaw && bun run typecheck`
- `cd packages/openclaw && bun run lint`
- `cd packages/openclaw && ./node_modules/.bin/vitest run` (19 files, 248 tests)
- `cd packages/openclaw && bun run build`
- `cd packages/openclaw && npm pack --ignore-scripts --pack-destination /tmp`
- `openclaw plugins install --force npm-pack:/tmp/inline-openclaw-inline-0.0.36.tgz`
- `openclaw gateway restart`
- `openclaw plugins inspect inline --json` confirmed installed artifact metadata for the prior command-authorization build.
- `node -e "...channel-plugin-api.js..."` confirms the installed dist contains `resolveCommandAuthorization`, `commands.allowFrom.inline` audit handling, and `CommandAuthorized` context output.
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/monitor.test.ts src/inline/channel.test.ts` (2 files, 125 tests)
- `cd packages/openclaw && bun run typecheck`
- `cd packages/openclaw && bun run lint`
- `cd packages/openclaw && ./node_modules/.bin/vitest run` (19 files, 251 tests)
- `cd packages/openclaw && bun run build`
- `cd packages/openclaw && npm pack --ignore-scripts --pack-destination /tmp`
- `openclaw plugins install --force npm-pack:/tmp/inline-openclaw-inline-0.0.36.tgz`
- `openclaw gateway restart`
- Prior access-group build local gateway validation passed: gateway healthy, Inline default connected, plugin doctor clean, and installed artifact metadata present.
- `rg -n "...expandAllowFromWithAccessGroups..." /Users/mo/.openclaw/npm/node_modules/@inline-openclaw/inline/dist/channel-plugin-api.js` confirms the installed dist contains Inline access-group allowlist expansion and updated audit copy.
- `openclaw security audit --json` reports no Inline-specific findings in the current local config.
- `openclaw secrets audit --json` reports `channels.inline.token` as a plaintext secret finding; current summary is 4 plaintext findings, 0 unresolved refs, 2 legacy OAuth residue findings.
- `openclaw message send --channel inline --target chat:0 --message "inline dry run" --dry-run --json`
- `openclaw status --json` reports gateway runtime `2026.5.18` and reachable loopback gateway.
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/bot-commands-tool.test.ts` (1 file, 6 tests)
- `cd packages/openclaw && bun run typecheck`
- `cd packages/openclaw && bun run lint`
- `cd packages/openclaw && bun run build`
- `cd packages/openclaw && npm pack --ignore-scripts --pack-destination /tmp`
- `openclaw plugins install --force npm-pack:/tmp/inline-openclaw-inline-0.0.36.tgz`
- `openclaw gateway restart`
- `openclaw gateway health` -> `OK (1512ms)`; Telegram configured; Inline configured.
- `openclaw channels status` reports Inline default enabled/configured/running/connected.
- `openclaw plugins inspect inline --json` confirms installed artifact `1d56cedd4240dddeca7b64589791395ac9f907a3`.
- `rg -n "Inline bot command name|slash command" /Users/mo/.openclaw/npm/node_modules/@inline-openclaw/inline/dist/runtime-register-api.js /Users/mo/.openclaw/npm/node_modules/@inline-openclaw/inline/dist/channel-plugin-api.js` confirms the installed schema copy uses `Inline bot command name` and has no installed `slash command` hit.
- `openclaw plugins doctor` -> no plugin issues detected.
- `openclaw message send --channel inline --target chat:0 --message "inline dry run" --dry-run --json`
- `openclaw status --json` reports gateway runtime `2026.5.18`, reachable loopback gateway, and LaunchAgent pid `10537`.
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/bot-commands-sync.test.ts src/inline/bot-commands-tool.test.ts src/inline/monitor.test.ts` (3 files, 92 tests)
- `cd packages/openclaw && bun run typecheck`
- `cd packages/openclaw && bun run lint`
- `cd packages/openclaw && ./node_modules/.bin/vitest run` (19 files, 252 tests)
- `git diff --check -- bun.lock .context/2026-05-19-inline-openclaw-native-channel-review.md packages/openclaw`
- `cd packages/openclaw && bun run build`
- `cd packages/openclaw && npm pack --ignore-scripts --pack-destination /tmp`
- `openclaw plugins install --force npm-pack:/tmp/inline-openclaw-inline-0.0.36.tgz`
- `openclaw gateway restart`
- `openclaw gateway health` -> `OK (1512ms)`; Telegram configured; Inline configured.
- `openclaw channels status` reports Inline default enabled/configured/running/connected.
- `openclaw plugins inspect inline --json` confirms installed artifact `1d56cedd4240dddeca7b64589791395ac9f907a3`.
- `rg -n "Inline bot command name|slash command|native command sync|bot command sync" /Users/mo/.openclaw/npm/node_modules/@inline-openclaw/inline/dist/runtime-register-api.js /Users/mo/.openclaw/npm/node_modules/@inline-openclaw/inline/dist/channel-plugin-api.js` confirms installed schema copy uses `Inline bot command name`, installed logs use `bot command sync`, and there is no installed `native command sync` hit.
- `openclaw plugins doctor` -> no plugin issues detected.
- `openclaw message send --channel inline --target chat:0 --message "inline dry run" --dry-run --json`
- `openclaw security audit --json` reports no Inline-specific findings in the current local config.
- `openclaw secrets audit --json` reports `channels.inline.token` as a plaintext secret finding; current summary is 4 plaintext findings, 0 unresolved refs, 2 legacy OAuth residue findings.
- `openclaw status --json` reports gateway runtime `2026.5.18`, reachable loopback gateway, and LaunchAgent pid `10537`.
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/manifest.test.ts src/inline/bot-commands-sync.test.ts src/inline/monitor.test.ts` (3 files, 89 tests)
- `cd packages/openclaw && bun run typecheck`
- `cd packages/openclaw && bun run lint`
- `cd packages/openclaw && ./node_modules/.bin/vitest run` (19 files, 252 tests)
- `git diff --check -- bun.lock .context/2026-05-19-inline-openclaw-native-channel-review.md packages/openclaw`
- `cd packages/openclaw && bun run build`
- `cd packages/openclaw && npm pack --ignore-scripts --pack-destination /tmp`
- `openclaw plugins install --force npm-pack:/tmp/inline-openclaw-inline-0.0.36.tgz`
- `openclaw gateway restart`
- `openclaw gateway health` -> `OK (874ms)`; Telegram configured; Inline configured.
- `openclaw channels status` reports Inline default enabled/configured/running/connected.
- `openclaw plugins inspect inline --json` confirms installed artifact `1e4e833472231a036e6aa07b3b2b3d864a4037f6`.
- `rg -n "native channels|native slash|slash command|shared OpenClaw streaming config compatibility" /Users/mo/.openclaw/npm/node_modules/@inline-openclaw/inline/openclaw.plugin.json /Users/mo/.openclaw/npm/node_modules/@inline-openclaw/inline/dist/runtime-register-api.js /Users/mo/.openclaw/npm/node_modules/@inline-openclaw/inline/dist/channel-plugin-api.js` confirms installed streaming copy uses shared OpenClaw wording and no longer has installed `native channels` / `slash command` hits.
- `openclaw plugins doctor` -> no plugin issues detected.
- `openclaw message send --channel inline --target chat:0 --message "inline dry run" --dry-run --json`
- `openclaw security audit --json` reports no Inline-specific findings in the current local config.
- `openclaw secrets audit --json` reports `channels.inline.token` as a plaintext secret finding; current summary is 4 plaintext findings, 0 unresolved refs, 2 legacy OAuth residue findings.
- `openclaw status --json` reports gateway runtime `2026.5.18`, reachable loopback gateway, and LaunchAgent pid `14648`.
- `rg -n "native|Native|moltbot|stale|realtime bot|Telegram-style|slash command|native channels|chat:<id>" packages/openclaw/README.md packages/openclaw/docs/openclaw-setup.md packages/openclaw/docs/create-inline-bot.md` now only finds expected config keys/placeholders, not stale docs copy.
- `git diff --check -- packages/openclaw/README.md packages/openclaw/docs/openclaw-setup.md .context/2026-05-19-inline-openclaw-native-channel-review.md`
- `cd packages/openclaw && npm pack --ignore-scripts --pack-destination /tmp`
- `openclaw plugins install --force npm-pack:/tmp/inline-openclaw-inline-0.0.36.tgz`
- `openclaw gateway restart`
- `openclaw gateway health` -> `OK (970ms)`; Telegram configured; Inline configured.
- `openclaw channels status` reports Inline default enabled/configured/running/connected.
- `openclaw plugins inspect inline --json` confirms installed artifact `4a468d0e8517ee849ab8c59ab7135022454fb9d9`.
- `rg -n "Optional native|Native media|native reply|Native thread|native-thread|Telegram-style|bot slash|realtime bot|openclaw gateway restart" /Users/mo/.openclaw/npm/node_modules/@inline-openclaw/inline/README.md /Users/mo/.openclaw/npm/node_modules/@inline-openclaw/inline/openclaw.plugin.json` confirms the installed README no longer has stale native/media/thread or slash-command copy; it only finds the intended `openclaw gateway restart` update command.
- `openclaw plugins doctor` -> no plugin issues detected.
- `openclaw message send --channel inline --target chat:0 --message "inline dry run" --dry-run --json`
- `openclaw status --json` reports gateway runtime `2026.5.18`, reachable loopback gateway, and LaunchAgent pid `17785`.
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/channel.test.ts src/inline/monitor.test.ts src/inline/actions.test.ts` (3 files, 162 tests)
- `cd packages/openclaw && bun run typecheck`
- `cd packages/openclaw && bun run lint`
- `cd packages/openclaw && ./node_modules/.bin/vitest run` (19 files, 255 tests)
- `cd packages/openclaw && bun run build`
- `cd packages/openclaw && npm pack --ignore-scripts --pack-destination /tmp`
- `shasum /tmp/inline-openclaw-inline-0.0.36.tgz` -> `64db0d5d678ec2c2ff6f9ec2b94ff6c85be0d938`
- `openclaw plugins install /tmp/inline-openclaw-inline-0.0.36.tgz`
- `openclaw gateway restart`
- `openclaw gateway health` -> `OK (858ms)`; Telegram configured; Inline configured.
- `openclaw channels status` reports Inline default enabled/configured/running/connected.
- `openclaw plugins inspect inline --json` reports source `/Users/mo/.openclaw/extensions/inline/dist/index.js`, status `loaded`, dependencies installed; persisted install metadata still reports the prior tarball shasum, so direct tarball and installed-file checks are the artifact evidence for this pass.
- `rg -n "resolveInlineInteractiveTextFallback" /Users/mo/.openclaw/extensions/inline/dist /Users/mo/.openclaw/extensions/inline/package.json` confirms installed dist includes the interactive-only fallback helper and channel/monitor/action call sites.
- `openclaw plugins doctor` -> no plugin issues detected.
- `openclaw message send --channel inline --target chat:0 --message "inline dry run" --dry-run --json`
- `openclaw status --json` reports gateway runtime `2026.5.18`, reachable loopback gateway, and LaunchAgent pid `24353`.
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/channel.test.ts src/inline/monitor.test.ts src/inline/actions.test.ts src/inline/message-formatting.test.ts` (4 files, 170 tests)
- `cd packages/openclaw && bun run typecheck`
- `cd packages/openclaw && bun run lint`
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/channel.test.ts` (1 file, 49 tests)
- `cd packages/openclaw && bun run typecheck`
- `cd packages/openclaw && bun run lint`
- `cd packages/openclaw && ./node_modules/.bin/vitest run` (19 files, 259 tests)
- `git diff --check -- packages/openclaw .context/2026-05-19-inline-openclaw-native-channel-review.md bun.lock`
- `cd packages/openclaw && bun run build`
- `cd packages/openclaw && npm pack --ignore-scripts --pack-destination /tmp`
- `shasum /tmp/inline-openclaw-inline-0.0.36.tgz` -> `0b58f45565254ddc694f8656cc0f22d9cdf6a62d`
- `openclaw plugins install --force /tmp/inline-openclaw-inline-0.0.36.tgz`
- `openclaw gateway restart`
- `openclaw gateway health` -> `OK (916ms)`; Telegram configured; Inline configured.
- `openclaw channels status` reports Inline default enabled/configured/running/connected and Telegram enabled/configured/running/disconnected in polling mode.
- `openclaw plugins inspect inline --json` reports source `/Users/mo/.openclaw/extensions/inline/dist/index.js`, status `loaded`, source path `/tmp/inline-openclaw-inline-0.0.36.tgz`, installed npm shasum `4a468d0e8517ee849ab8c59ab7135022454fb9d9`, and required dependencies installed.
- `rg -n --glob '!*.map' "resolveInlineOutboundSessionRoute|sanitizeInlineDeliveryText|transformReplyPayload|resolveInlineInteractiveTextFallback" /Users/mo/.openclaw/extensions/inline/dist /Users/mo/.openclaw/extensions/inline/package.json` confirms the installed extension contains the latest routing, sanitizer, reply transform, and interactive fallback code.
- `openclaw plugins doctor` -> no plugin issues detected.
- `openclaw message send --channel inline --target chat:0 --message "inline dry run" --dry-run --json`
- `openclaw status --json` reports gateway runtime `2026.5.18`, reachable loopback gateway, and LaunchAgent pid `35769`.
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/monitor.test.ts` (1 file, 84 tests)
- `cd packages/openclaw && bun run typecheck`
- `cd packages/openclaw && bun run lint`
- `git diff --check -- packages/openclaw/src/inline/monitor.ts packages/openclaw/src/inline/monitor.test.ts .context/2026-05-19-inline-openclaw-native-channel-review.md`
- `cd packages/openclaw && bun run build`
- `cd packages/openclaw && npm pack --ignore-scripts --pack-destination /tmp`
- `shasum /tmp/inline-openclaw-inline-0.0.36.tgz` -> `d3bbdac6ba686fcbf07a9f366373ecaaafa3d7da`
- `openclaw plugins install --force /tmp/inline-openclaw-inline-0.0.36.tgz`
- `openclaw gateway restart`
- `openclaw gateway health` -> `OK (970ms)`; Telegram configured; Inline configured.
- `openclaw channels status` reports Inline default enabled/configured/running/connected and Telegram enabled/configured/running/disconnected in polling mode.
- `openclaw plugins inspect inline --json` reports source `/Users/mo/.openclaw/extensions/inline/dist/index.js`, status `loaded`, source path `/tmp/inline-openclaw-inline-0.0.36.tgz`, and required dependencies installed.
- `rg -n --glob '!*.map' "message\\.edit|message\\.delete|buildInlineMessageLifecycleContextKey|enqueueSystemEvent" /Users/mo/.openclaw/extensions/inline/dist` confirms the installed extension contains the latest edit/delete lifecycle system-event handling.
- `openclaw plugins doctor` -> no plugin issues detected.
- `openclaw message send --channel inline --target chat:0 --message "inline dry run" --dry-run --json`
- `openclaw status --json` reports gateway runtime `2026.5.18`, reachable loopback gateway, and LaunchAgent pid `47680`.
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/channel.test.ts` (1 file, 49 tests)
- `cd packages/openclaw && bun run typecheck`
- `cd packages/openclaw && bun run lint`
- `cd packages/openclaw && bun run build`
- `cd packages/openclaw && npm pack --ignore-scripts --pack-destination /tmp`
- `shasum /tmp/inline-openclaw-inline-0.0.36.tgz` -> `9695760bb2cf73f8fb082a3b0f0d3ba8bff112f7`
- `openclaw plugins install --force /tmp/inline-openclaw-inline-0.0.36.tgz`
- `openclaw gateway restart`
- `openclaw gateway health` -> `OK (4631ms)`; Telegram configured; Inline configured.
- `openclaw channels status` reports Inline default enabled/configured/running/connected and Telegram enabled/configured/running/disconnected in polling mode.
- `openclaw plugins inspect inline --json` reports source `/Users/mo/.openclaw/extensions/inline/dist/index.js`, status `loaded`, source path `/tmp/inline-openclaw-inline-0.0.36.tgz`, and required dependencies installed.
- `rg -n --glob '!*.map' "not a dedicated Inline reply-thread chat|native reply-thread chat|message\\.edit|message\\.delete|buildInlineMessageLifecycleContextKey" /Users/mo/.openclaw/extensions/inline/dist` confirms the installed extension contains edit/delete lifecycle handling and the updated reply-thread-disabled prompt copy with no installed `native reply-thread chat` hit.
- `openclaw plugins doctor` -> no plugin issues detected.
- `openclaw message send --channel inline --target chat:0 --message "inline dry run" --dry-run --json`
- `openclaw status --json` reports gateway runtime `2026.5.18`, reachable loopback gateway, and LaunchAgent pid `49676`.
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/monitor.test.ts` (1 file, 85 tests)
- `cd packages/openclaw && bun run typecheck`
- `cd packages/openclaw && bun run lint`
- `git diff --check -- packages/openclaw/src/inline/monitor.ts packages/openclaw/src/inline/monitor.test.ts .context/2026-05-19-inline-openclaw-native-channel-review.md`
- `cd packages/openclaw && bun run build`
- `cd packages/openclaw && npm pack --ignore-scripts --pack-destination /tmp`
- `shasum /tmp/inline-openclaw-inline-0.0.36.tgz` -> `92e97361d18f5a856d2113bcbd69b2c8bf420b73`
- `openclaw plugins install --force /tmp/inline-openclaw-inline-0.0.36.tgz`
- `openclaw gateway restart`
- `openclaw gateway health` -> `OK (964ms)`; Telegram configured; Inline configured.
- `openclaw channels status` reports Inline default enabled/configured/running/connected and Telegram enabled/configured/running/disconnected in polling mode.
- `rg -n --glob '!*.map' "buildInlineReactionContextKey|Inline reaction|reacted with .*to your message|reactionEvent" /Users/mo/.openclaw/extensions/inline/dist` confirms the installed extension contains reaction system-event handling and no old reaction-as-inbound-message strings.
- `openclaw plugins doctor` -> no plugin issues detected.
- `openclaw message send --channel inline --target chat:0 --message "inline dry run" --dry-run --json`
- `openclaw status --json` reports gateway runtime `2026.5.18`, reachable loopback gateway, and LaunchAgent pid `54350`.
- `git diff --check -- packages/openclaw/src/inline/config-schema.ts packages/openclaw/src/inline/config-schema.test.ts packages/openclaw/src/inline/monitor.ts packages/openclaw/src/inline/monitor.test.ts packages/openclaw/openclaw.plugin.json packages/openclaw/README.md packages/openclaw/docs/openclaw-setup.md .context/2026-05-19-inline-openclaw-native-channel-review.md`
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/config-schema.test.ts src/inline/monitor.test.ts` (2 files, 100 tests)
- `cd packages/openclaw && bun run typecheck`
- `cd packages/openclaw && bun run lint`
- `cd packages/openclaw && bun run build`
- `cd packages/openclaw && npm pack --ignore-scripts --pack-destination /tmp`
- `shasum /tmp/inline-openclaw-inline-0.0.36.tgz` -> `e2e8fb4026b1d00aae618733e3ca5306ebfded3d`
- `openclaw plugins install --force /tmp/inline-openclaw-inline-0.0.36.tgz`
- `openclaw gateway restart`
- `openclaw gateway health` -> `OK (915ms)`; Telegram configured; Inline configured.
- `openclaw channels status` reports Inline default enabled/configured/running/connected and Telegram enabled/configured/running/disconnected in polling mode.
- `openclaw plugins doctor` -> no plugin issues detected.
- `openclaw plugins inspect inline --json` reports source `/Users/mo/.openclaw/extensions/inline/dist/index.js`, status `loaded`, source path `/tmp/inline-openclaw-inline-0.0.36.tgz`, and required dependencies installed. Persisted install shasum still reports the prior npm shasum, so direct tarball and installed-file checks are the artifact evidence for this pass.
- `rg -n --glob '!*.map' "reactionNotifications|shouldQueueInlineReactionSystemEvent|Inline reaction" /Users/mo/.openclaw/extensions/inline/dist` confirms the installed extension contains reaction notification config, the mode switch helper, and reaction system-event copy.
- `rg -n "reactionNotifications|Inline Reaction Notifications" /Users/mo/.openclaw/extensions/inline/openclaw.plugin.json /Users/mo/.openclaw/extensions/inline/README.md` confirms installed manifest and README expose the new reaction notification mode.
- `openclaw message send --channel inline --target chat:0 --message "inline dry run" --dry-run --json`
- `openclaw status --json` reports gateway runtime `2026.5.18`, reachable loopback gateway, and LaunchAgent pid `59594`.
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/manifest.test.ts src/inline/config-schema.test.ts` (2 files, 16 tests)
- `cd packages/openclaw && bun run typecheck`
- `cd packages/openclaw && bun run lint`
- `git diff --check -- packages/openclaw/openclaw.plugin.json packages/openclaw/src/manifest.test.ts packages/openclaw/README.md packages/openclaw/docs/openclaw-setup.md`
- `cd packages/openclaw && npm pack --ignore-scripts --pack-destination /tmp`
- `shasum /tmp/inline-openclaw-inline-0.0.36.tgz` -> `6304f64a003d3af7b63f9665a92f060ba9623c4f`
- `openclaw plugins install --force /tmp/inline-openclaw-inline-0.0.36.tgz`
- `openclaw gateway restart`
- `openclaw gateway health` -> `OK (895ms)`; Telegram configured; Inline configured.
- `openclaw channels status` reports Inline default enabled/configured/running/connected and Telegram enabled/configured/running/disconnected in polling mode.
- `openclaw plugins doctor` -> no plugin issues detected.
- `openclaw plugins inspect inline --json` reports source `/Users/mo/.openclaw/extensions/inline/dist/index.js`, status `loaded`, source path `/tmp/inline-openclaw-inline-0.0.36.tgz`, and required dependencies installed. Persisted install shasum still reports the prior npm shasum, so direct tarball and installed-file checks are the artifact evidence for this pass.
- `rg -n "reactionNotifications|Named accounts can override" /Users/mo/.openclaw/extensions/inline/openclaw.plugin.json /Users/mo/.openclaw/extensions/inline/README.md` confirms installed manifest includes the account-level `reactionNotifications` ref and installed README includes the named-account override note.
- `openclaw message send --channel inline --target chat:0 --message "inline dry run" --dry-run --json`
- `openclaw status --json` reports gateway runtime `2026.5.18`, reachable loopback gateway, and LaunchAgent pid `62313`.
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/config-schema.test.ts src/manifest.test.ts src/inline/monitor.test.ts` (3 files, 105 tests)
- `cd packages/openclaw && bun run typecheck`
- `cd packages/openclaw && bun run lint`
- `git diff --check -- packages/openclaw/src/inline/config-schema.ts packages/openclaw/src/inline/config-schema.test.ts packages/openclaw/src/manifest.test.ts packages/openclaw/src/inline/monitor.ts packages/openclaw/src/inline/monitor.test.ts packages/openclaw/openclaw.plugin.json packages/openclaw/README.md packages/openclaw/docs/openclaw-setup.md`
- `cd packages/openclaw && bun run build`
- `cd packages/openclaw && npm pack --ignore-scripts --pack-destination /tmp`
- `shasum /tmp/inline-openclaw-inline-0.0.36.tgz` -> `77d4a7c3d9f1d64e8601941e590e09c9e983c4b2`
- `openclaw plugins install --force /tmp/inline-openclaw-inline-0.0.36.tgz`
- `openclaw gateway restart`
- `openclaw gateway health` -> `OK (823ms)`; Telegram configured; Inline configured.
- `openclaw channels status` reports Inline default enabled/configured/running/connected and Telegram enabled/configured/running/disconnected in polling mode.
- `openclaw plugins doctor` -> no plugin issues detected.
- `openclaw plugins inspect inline --json` reports source `/Users/mo/.openclaw/extensions/inline/dist/index.js`, status `loaded`, source path `/tmp/inline-openclaw-inline-0.0.36.tgz`, and required dependencies installed. Persisted install shasum still reports the prior npm shasum, so direct tarball and installed-file checks are the artifact evidence for this pass.
- `rg -n --glob '!*.map' "reactionAllowlist|reactionNotifications.*allowlist|mode === \"allowlist\"|Inline Reaction Sender Allowlist" /Users/mo/.openclaw/extensions/inline/dist /Users/mo/.openclaw/extensions/inline/openclaw.plugin.json /Users/mo/.openclaw/extensions/inline/README.md` confirms the installed extension contains allowlist-mode schema, runtime gate, manifest metadata, and README docs.
- `openclaw message send --channel inline --target chat:0 --message "inline dry run" --dry-run --json`
- `openclaw status --json` reports gateway runtime `2026.5.18`, reachable loopback gateway, and LaunchAgent pid `66654`.
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/channel.test.ts src/inline/accounts.test.ts` (2 files, 69 tests)
- `cd packages/openclaw && bun run typecheck`
- `cd packages/openclaw && bun run lint`
- `git diff --check -- packages/openclaw/src/inline/accounts.ts packages/openclaw/src/inline/shared.ts packages/openclaw/src/inline/channel.ts packages/openclaw/src/inline/channel.test.ts`
- `cd packages/openclaw && bun run build`
- `cd packages/openclaw && npm pack --ignore-scripts --pack-destination /tmp`
- `shasum /tmp/inline-openclaw-inline-0.0.36.tgz` -> `305186c70cd2240d1ebecca1cd729c45b35f4122`
- `openclaw plugins install --force /tmp/inline-openclaw-inline-0.0.36.tgz`
- `openclaw gateway restart`
- `openclaw gateway health` -> `OK (1390ms)`; Telegram configured; Inline configured.
- `openclaw channels status` reports Inline default enabled/configured/running/connected and Telegram enabled/configured/running/disconnected in polling mode.
- `openclaw plugins doctor` -> no plugin issues detected.
- `openclaw plugins inspect inline --json` reports source `/Users/mo/.openclaw/extensions/inline/dist/index.js`, status `loaded`, source path `/tmp/inline-openclaw-inline-0.0.36.tgz`, and required dependencies installed. Persisted install shasum still reports the prior npm shasum, so direct tarball and installed-file checks are the artifact evidence for this pass.
- `rg -n --glob '!*.map' "reactionNotifications: effective|reactionAllowlist: effective|reactionNotifications: account\\.reactionNotifications|reactionAllowlist: account\\.reactionAllowlist" /Users/mo/.openclaw/extensions/inline/dist` confirms installed account resolution, account description, and status snapshot paths expose reaction notification fields.
- `openclaw message send --channel inline --target chat:0 --message "inline dry run" --dry-run --json`
- `openclaw status --json` reports gateway runtime `2026.5.18`, reachable loopback gateway, and LaunchAgent pid `69889`.
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/channel.test.ts` (1 file, 51 tests)
- `cd packages/openclaw && bun run typecheck`
- `cd packages/openclaw && bun run lint`
- `git diff --check -- packages/openclaw/src/inline/security.ts packages/openclaw/src/inline/channel.test.ts`
- `cd packages/openclaw && bun run build`
- `cd packages/openclaw && npm pack --ignore-scripts --pack-destination /tmp`
- `shasum /tmp/inline-openclaw-inline-0.0.36.tgz` -> `0e10b97f8edb786235e5ccf0b11df8e8bea347fb`
- `openclaw plugins install --force /tmp/inline-openclaw-inline-0.0.36.tgz`
- `openclaw gateway restart`
- `openclaw gateway health` -> `OK (1368ms)`; Telegram configured; Inline configured.
- `openclaw channels status` reports Inline default enabled/configured/running/connected and Telegram enabled/configured/running/connected in polling mode.
- `openclaw plugins doctor` -> no plugin issues detected.
- `openclaw plugins inspect inline --json` reports source `/Users/mo/.openclaw/extensions/inline/dist/index.js`, status `loaded`, source path `/tmp/inline-openclaw-inline-0.0.36.tgz`, version `0.0.36`, and required dependencies installed. Persisted install shasum still reports the prior npm shasum, so direct tarball and installed-file checks are the artifact evidence for this pass.
- `rg -n --glob '!*.map' "reactionAllowlist.invalid_entries|appendInvalidReactionAllowlistFinding|reaction sender allowlist|Found non-numeric reactionAllowlist" /Users/mo/.openclaw/extensions/inline/dist` confirms the installed extension contains the new reaction allowlist audit finding in `channel-plugin-api.js` and `setup-plugin-api.js`.
- `openclaw message send --channel inline --target chat:0 --message "inline dry run" --dry-run --json`
- `openclaw status --json` reports gateway runtime `2026.5.18`, reachable loopback gateway, and LaunchAgent pid `72770`.
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/config-schema.test.ts src/manifest.test.ts` (2 files, 17 tests)
- `cd packages/openclaw && bun run typecheck`
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/config-schema.test.ts src/manifest.test.ts src/inline/channel.test.ts` (3 files, 68 tests)
- `cd packages/openclaw && bun run lint`
- `cd packages/openclaw && bun run typecheck`
- `git diff --check -- packages/openclaw/src/inline/config-schema.ts packages/openclaw/src/inline/config-schema.test.ts packages/openclaw/src/manifest.test.ts packages/openclaw/openclaw.plugin.json packages/openclaw/src/inline/channel.test.ts`
- `cd packages/openclaw && bun run build`
- `cd packages/openclaw && npm pack --ignore-scripts --pack-destination /tmp`
- `shasum /tmp/inline-openclaw-inline-0.0.36.tgz` -> `db023c9dddec60c0d26c8a215b99fe3d6824112f`
- `openclaw plugins install --force /tmp/inline-openclaw-inline-0.0.36.tgz`
- `openclaw gateway restart`
- `openclaw gateway health` -> `OK (828ms)`; Telegram configured; Inline configured.
- `openclaw channels status` reports Inline default enabled/configured/running/connected and Telegram enabled/configured/running/disconnected in polling mode.
- `openclaw plugins doctor` -> no plugin issues detected.
- `openclaw plugins inspect inline --json` reports source `/Users/mo/.openclaw/extensions/inline/dist/index.js`, status `loaded`, source path `/tmp/inline-openclaw-inline-0.0.36.tgz`, version `0.0.36`, and required dependencies installed. Persisted install shasum still reports the prior npm shasum, so direct tarball and installed-file checks are the artifact evidence for this pass.
- `rg -n --glob '!*.map' "InlineAllowEntrySchema|reactionAllowlist.*z\\.array|allowFrom.*anyOf|reactionAllowlist.*anyOf|type\\\": \\\"number\\\"" /Users/mo/.openclaw/extensions/inline/dist /Users/mo/.openclaw/extensions/inline/openclaw.plugin.json` confirms the installed extension and manifest accept numeric allowlist entries.
- `openclaw message send --channel inline --target chat:0 --message "inline dry run" --dry-run --json`
- `openclaw status --json` reports gateway runtime `2026.5.18`, reachable loopback gateway, and LaunchAgent pid `78019`.
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/config-schema.test.ts src/manifest.test.ts src/inline/channel.test.ts` (3 files, 70 tests)
- `cd packages/openclaw && bun run typecheck`
- `cd packages/openclaw && bun run lint`
- `git diff --check -- packages/openclaw/src/inline/config-schema.ts packages/openclaw/src/inline/shared.ts packages/openclaw/src/inline/config-schema.test.ts packages/openclaw/src/manifest.test.ts packages/openclaw/openclaw.plugin.json packages/openclaw/src/inline/channel.test.ts .context/2026-05-19-inline-openclaw-native-channel-review.md`
- `cd packages/openclaw && bun run build`
- `cd packages/openclaw && npm pack --ignore-scripts --pack-destination /tmp`
- `shasum /tmp/inline-openclaw-inline-0.0.36.tgz` -> `4f37ca83f3bd758483b5de2b6bb1c5a5553b930f`
- `openclaw plugins install --force /tmp/inline-openclaw-inline-0.0.36.tgz`
- `openclaw gateway restart`
- `openclaw gateway health` -> `OK (890ms)`; Telegram configured; Inline configured.
- `openclaw channels status` reports Inline default enabled/configured/running/connected and Telegram enabled/configured/running/disconnected in polling mode.
- `openclaw plugins doctor` -> no plugin issues detected.
- `openclaw plugins inspect inline --json` reports source `/Users/mo/.openclaw/extensions/inline/dist/index.js`, status `loaded`, source path `/tmp/inline-openclaw-inline-0.0.36.tgz`, version `0.0.36`, and required dependencies installed. Persisted install shasum still reports the prior npm shasum, so direct tarball and installed-file checks are the artifact evidence for this pass.
- `rg -n --glob '!*.map' "resolveDefaultTo|defaultTo.*InlineTargetSchema|defaultTo.*anyOf|Inline Default Target|defaultTo" /Users/mo/.openclaw/extensions/inline/dist /Users/mo/.openclaw/extensions/inline/openclaw.plugin.json` confirms the installed extension and manifest expose `defaultTo` schema, UI metadata, and adapter resolution.
- `node -e "import('/Users/mo/.openclaw/extensions/inline/dist/channel-plugin-api.js').then(...)"` confirms installed `resolveDefaultTo` returns `51,chat:52` for top-level and named-account config.
- `openclaw message send --channel inline --target chat:0 --message "inline dry run" --dry-run --json`
- `openclaw status --json` reports gateway runtime `2026.5.18`, reachable loopback gateway, and LaunchAgent pid `83654`.
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/channel.test.ts` (1 file, 52 tests)
- `cd packages/openclaw && bun run typecheck`
- `cd packages/openclaw && bun run lint`
- `git diff --check -- packages/openclaw/src/inline/channel.ts packages/openclaw/src/inline/channel.test.ts packages/openclaw/README.md packages/openclaw/docs/openclaw-setup.md .context/2026-05-19-inline-openclaw-native-channel-review.md`
- `cd packages/openclaw && bun run build`
- `cd packages/openclaw && npm pack --ignore-scripts --pack-destination /tmp`
- `shasum /tmp/inline-openclaw-inline-0.0.36.tgz` -> `750216bf879f134228a9f54e5efa47f218f35ab9`
- `openclaw plugins install --force /tmp/inline-openclaw-inline-0.0.36.tgz`
- `openclaw gateway restart`
- `openclaw gateway health` -> `OK (829ms)`; Telegram configured; Inline configured.
- `openclaw channels status` reports Inline default enabled/configured/running/connected and Telegram enabled/configured/running/disconnected in polling mode.
- `openclaw plugins doctor` -> no plugin issues detected.
- `openclaw plugins inspect inline --json` reports source `/Users/mo/.openclaw/extensions/inline/dist/index.js`, status `loaded`, source path `/tmp/inline-openclaw-inline-0.0.36.tgz`, version `0.0.36`, and required dependencies installed. Persisted install shasum still reports the prior npm shasum, so direct tarball and installed-file checks are the artifact evidence for this pass.
- `rg -n --glob '!*.map' "resolveInlineSessionTarget|resolveSessionTarget|defaultTo" /Users/mo/.openclaw/extensions/inline/dist /Users/mo/.openclaw/extensions/inline/README.md /Users/mo/.openclaw/extensions/inline/openclaw.plugin.json` confirms the installed extension exposes session target mapping and installed docs/manifest include `defaultTo`.
- `node -e "import('/Users/mo/.openclaw/extensions/inline/dist/channel-plugin-api.js').then(...)"` confirms installed `resolveSessionTarget` returns `chat:7,chat:8` for group/channel session ids.
- `openclaw message send --channel inline --target chat:0 --message "inline dry run" --dry-run --json`
- `openclaw status --json` reports gateway runtime `2026.5.18`, reachable loopback gateway, and LaunchAgent pid `88659`.
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/channel.test.ts` (1 file, 52 tests)
- `cd packages/openclaw && bun run typecheck`
- `cd packages/openclaw && bun run lint`
- `git diff --check -- packages/openclaw/src/inline/channel.ts packages/openclaw/src/inline/channel.test.ts .context/2026-05-19-inline-openclaw-native-channel-review.md`
- `cd packages/openclaw && bun run build`
- `cd packages/openclaw && npm pack --ignore-scripts --pack-destination /tmp`
- `shasum /tmp/inline-openclaw-inline-0.0.36.tgz` -> `9af978a74c8eae3ebf8fe3e9bd6d3a7a3360c8e9`
- `openclaw plugins install --force /tmp/inline-openclaw-inline-0.0.36.tgz`
- `openclaw gateway restart`
- `openclaw gateway health` -> `OK (831ms)`; Telegram configured; Inline configured.
- `openclaw channels status` reports Inline default enabled/configured/running/connected and Telegram enabled/configured/running/disconnected in polling mode.
- `openclaw plugins doctor` -> no plugin issues detected.
- `rg -n --glob '!*.map' "resolveInlineDeliveryTarget|resolveDeliveryTarget|resolveInlineSessionTarget|resolveSessionTarget" /Users/mo/.openclaw/extensions/inline/dist/channel-plugin-api.js /Users/mo/.openclaw/extensions/inline/dist/runtime-register-api.js` confirms the installed extension exposes both session and delivery target hooks.
- `node -e "import('/Users/mo/.openclaw/extensions/inline/dist/channel-plugin-api.js').then(...)"` confirms installed `resolveDeliveryTarget` returns `{"to":"chat:7"}` and `{"to":"chat:7","threadId":"8"}` for top-level and parent/child conversations.
- `openclaw message send --channel inline --target chat:0 --message "inline dry run" --dry-run --json`
- `openclaw status --json` reports gateway runtime `2026.5.18`, reachable loopback gateway, and LaunchAgent pid `91868`.
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/channel.test.ts` (1 file, 52 tests)
- `cd packages/openclaw && bun run typecheck`
- `cd packages/openclaw && bun run lint`
- `git diff --check -- packages/openclaw/src/inline/channel.ts packages/openclaw/src/inline/channel.test.ts`
- `cd packages/openclaw && bun run build`
- `cd packages/openclaw && npm pack --ignore-scripts --pack-destination /tmp`
- `shasum /tmp/inline-openclaw-inline-0.0.36.tgz` -> `a30b81ace0299ab13e1c476d54d33298d0b38b92`
- `openclaw plugins install --force /tmp/inline-openclaw-inline-0.0.36.tgz`
- `openclaw gateway restart`
- `openclaw gateway health` -> `OK (1148ms)`; Telegram configured; Inline configured.
- `openclaw channels status` reports Inline default enabled/configured/running/connected and Telegram enabled/configured/running/disconnected in polling mode.
- `openclaw plugins doctor` -> no issues.
- `rg -n --glob '!*.map' "resolveInlineInboundConversation|resolveInboundConversation|resolveInlineDeliveryTarget|resolveSessionTarget" /Users/mo/.openclaw/extensions/inline/dist/channel-plugin-api.js /Users/mo/.openclaw/extensions/inline/dist/runtime-register-api.js` confirms the installed extension exposes inbound, delivery, and session target hooks.
- `node -e "import('/Users/mo/.openclaw/extensions/inline/dist/channel-plugin-api.js').then(...)"` confirms installed `resolveInboundConversation` returns `{"conversationId":"inline:chat:7"}` and `{"conversationId":"inline:chat:8","parentConversationId":"inline:chat:7"}` for top-level and reply-thread contexts.
- `openclaw message send --channel inline --target chat:0 --message "inline dry run" --dry-run --json`
- `openclaw status --json` reports gateway runtime `2026.5.18`, reachable loopback gateway, and LaunchAgent pid `4290`.
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/channel.test.ts` (1 file, 52 tests)
- `cd packages/openclaw && bun run typecheck`
- `cd packages/openclaw && bun run lint`
- `git diff --check -- packages/openclaw/src/inline/channel.ts packages/openclaw/src/inline/channel.test.ts .context/2026-05-19-inline-openclaw-native-channel-review.md`
- `cd packages/openclaw && bun run build`
- `cd packages/openclaw && npm pack --ignore-scripts --pack-destination /tmp`
- `shasum /tmp/inline-openclaw-inline-0.0.36.tgz` -> `554f01aaed55a6b1a99fbff6804baa133d33b5eb`
- `openclaw plugins install --force /tmp/inline-openclaw-inline-0.0.36.tgz`
- `openclaw gateway restart`
- `openclaw gateway health` -> `OK (916ms)`; Telegram configured; Inline configured.
- `openclaw channels status` reports Inline default enabled/configured/running/connected and Telegram enabled/configured/running/disconnected in polling mode.
- `openclaw plugins doctor` -> no issues.
- `node -e "import('/Users/mo/.openclaw/extensions/inline/dist/channel-plugin-api.js').then(...)"` confirms installed `resolveInboundConversation` returns the reply-thread child/parent pair and `preserveHeartbeatThreadIdForGroupRoute` is `true`.
- `openclaw message send --channel inline --target chat:0 --message "inline dry run" --dry-run --json`
- `openclaw status --json` reports gateway runtime `2026.5.18`, reachable loopback gateway, and LaunchAgent pid `6525`.
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/channel.test.ts` (1 file, 52 tests)
- `cd packages/openclaw && bun run typecheck`
- `cd packages/openclaw && bun run lint`
- `git diff --check -- packages/openclaw/src/inline/channel.ts packages/openclaw/src/inline/channel.test.ts .context/2026-05-19-inline-openclaw-native-channel-review.md`
- `cd packages/openclaw && bun run build`
- `cd packages/openclaw && npm pack --ignore-scripts --pack-destination /tmp`
- `shasum /tmp/inline-openclaw-inline-0.0.36.tgz` -> `653b0bca96e019c781126f0e8eeea1e643d8f12f`
- `openclaw plugins install --force /tmp/inline-openclaw-inline-0.0.36.tgz`
- `openclaw gateway restart`
- `openclaw gateway health` -> `OK (1003ms)`; Telegram configured; Inline configured.
- `openclaw channels status` reports Inline default enabled/configured/running/connected and Telegram enabled/configured/running/disconnected in polling mode.
- `openclaw plugins doctor` -> no issues.
- `rg -n --glob '!*.map' "conversationBindings|resolveInlineConversationRef|supportsCurrentConversationBinding|defaultTopLevelPlacement" packages/openclaw/dist/channel-plugin-api.js packages/openclaw/dist/runtime-register-api.js` confirms the built artifact exposes current-conversation binding support.
- `node -e "import('/Users/mo/.openclaw/extensions/inline/dist/channel-plugin-api.js').then(...)"` confirms installed `conversationBindings` exposes `supportsCurrentConversationBinding`, `defaultTopLevelPlacement`, and child/parent `resolveConversationRef`.
- `openclaw message send --channel inline --target chat:0 --message "inline dry run" --dry-run --json`
- `openclaw status --json` reports gateway runtime `2026.5.18`, reachable loopback gateway, and LaunchAgent pid `10028`.
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/channel.test.ts` (1 file, 52 tests)
- `cd packages/openclaw && bun run typecheck`
- `cd packages/openclaw && bun run lint`
- `git diff --check -- packages/openclaw/src/inline/channel.ts packages/openclaw/src/inline/channel.test.ts .context/2026-05-19-inline-openclaw-native-channel-review.md`
- `cd packages/openclaw && bun run build`
- `cd packages/openclaw && npm pack --ignore-scripts --pack-destination /tmp`
- `shasum /tmp/inline-openclaw-inline-0.0.36.tgz` -> `176fa6abbdda4957328f4731335fe06fd766e316`
- `openclaw plugins install --force /tmp/inline-openclaw-inline-0.0.36.tgz`
- `openclaw gateway restart`
- `openclaw gateway health` -> `OK (947ms)`; Telegram configured; Inline configured.
- `openclaw channels status` reports Inline default enabled/configured/running/connected and Telegram enabled/configured/running/disconnected in polling mode.
- `openclaw plugins doctor` -> no issues.
- `rg -n --glob '!*.map' "resolveInlineSessionConversation|resolveSessionConversation|baseConversationId|parentConversationCandidates" packages/openclaw/dist/channel-plugin-api.js packages/openclaw/dist/runtime-register-api.js` confirms the built artifact exposes session-conversation normalization.
- `node -e "import('/Users/mo/.openclaw/extensions/inline/dist/channel-plugin-api.js').then(...)"` confirms installed `resolveSessionConversation` returns `{id:"7",threadId:"8",baseConversationId:"inline:chat:7",parentConversationCandidates:["inline:chat:7"]}` for `7:thread:8`.
- `openclaw message send --channel inline --target chat:0 --message "inline dry run" --dry-run --json`
- `openclaw status --json` reports gateway runtime `2026.5.18`, reachable loopback gateway, and LaunchAgent pid `13033`.

Build/package note:

- `src/inline/package-artifact.test.ts` invokes `npm pack`, which runs `prepack -> bun run build`. This verified the built npm artifact contains `dist/index.js`, `dist/configured-state.js`, `dist/setup-entry.js`, `dist/setup-plugin-api.js`, `dist/secret-contract-api.js`, `dist/channel-plugin-api.js`, `dist/approval-handler.runtime.js`, `dist/runtime-setter-api.js`, `dist/account-inspect-api.js`, and `dist/runtime-register-api.js` without unresolved runtime package imports beyond OpenClaw SDK peers.
- The artifact test also verifies the setup-only bundle does not include monitor startup symbols such as `monitorInlineProvider` or `starting Inline realtime monitor`.
- The artifact test verifies `dist/setup-entry.js` exposes the split `secret-contract-api.js` sidecar with `channelSecrets`, matching Telegram/Slack setup-entry behavior.
- The artifact test imports the built `dist/index.js`, registers the bundled entry, and calls the built channel outbound chunker to prove `runtime-setter-api.js` and `channel-plugin-api.js` share runtime state.
- Setup bundle size stayed narrow during the final pass: `setup-plugin-api.js` is about 538.9 KB in the packed artifact, down from about 1.6 MB before the narrow setup entry split.
- Local runtime install used `npm pack --ignore-scripts` after the full package test/build had already verified the generated `dist`.

### 99. Inline lacked native exec/plugin approval delivery

Status: fixed in working tree.

Telegram and Slack expose channel approval capabilities plus lazy native runtime adapters, register live transport context from the monitor, and route approval requests to origin chats and/or approver DMs. Inline only had callback commands that could run `/approve` after a button press; it did not advertise native approval capability, did not register an approval runtime context, and could not receive native approval deliveries from OpenClaw.

Fix:

- Added `channels.inline.execApprovals` schema/manifest/docs with native-compatible `enabled`, `approvers`, `agentFilter`, `sessionFilter`, and `target` fields.
- Added Inline exec approval profile logic with approver normalization for numeric Inline user IDs and owner fallback via `commands.ownerAllowFrom`; `chat:<id>` approver entries are ignored.
- Added `inlineApprovalCapability`, native origin/approver-DM target resolution, `/approve` command behavior, and a render hook for fallback exec approval payloads.
- Added `inlineApprovalNativeRuntime`, delivering approval messages with Inline callback buttons and clearing buttons on resolution/expiry through `editMessage`.
- Registered the approval runtime context from `monitorInlineProvider` when the configured account has enabled native approval handling.
- Added build packaging for `dist/approval-handler.runtime.js`.

Verification:

- `cd packages/openclaw && bun run typecheck`
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/approval-native.test.ts src/inline/config-schema.test.ts src/inline/channel.test.ts src/inline/monitor.test.ts` -> 4 files, 163 tests.
- `cd packages/openclaw && bun run lint`
- `cd packages/openclaw && bun run build`
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/package-artifact.test.ts` -> verified the packed artifact includes `approval-handler.runtime.js` and no unresolved non-OpenClaw runtime imports.
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/index.test.ts` -> 1 file, 3 tests; split loader test completes in 3.6s after keeping the approval handler as a sidecar bundle.
- `cd packages/openclaw && bun run test` -> 20 files, 283 tests.
- `cd packages/openclaw && bun run lint`
- `git diff --check -- packages/openclaw/src/inline packages/openclaw/src/index.test.ts packages/openclaw/src/manifest.test.ts packages/openclaw/src/runtime.ts packages/openclaw/package.json packages/openclaw/openclaw.plugin.json packages/openclaw/README.md packages/openclaw/docs/openclaw-setup.md .context/2026-05-19-inline-openclaw-native-channel-review.md`
- `cd packages/openclaw && npm pack --ignore-scripts --pack-destination /tmp`; shasum `747177c5f68b83566d1f9d08426b6ef7652edcda`.
- `openclaw plugins install --force /tmp/inline-openclaw-inline-0.0.36.tgz`
- `openclaw gateway restart`
- `openclaw gateway health` -> `OK`; Telegram configured; Inline configured.
- `openclaw channels status` -> Inline default enabled/configured/running/connected; Telegram enabled/configured/running/disconnected polling.
- `openclaw plugins doctor` -> no plugin issues detected.
- `node --input-type=module -e ...` against `/Users/mo/.openclaw/extensions/inline/dist/channel-plugin-api.js` -> installed plugin reports `hasApproval: true`, `hasNativeRuntime: true`, `hasExecRender: true`, `deliveryKinds: ["exec","plugin"]`.
- `openclaw channels capabilities --channel inline --json` -> installed gateway capability probe reports `approvalCapability.nativeRuntime.eventKinds` for `exec` and `plugin`, and Inline probe succeeds for the configured bot.

### 100. Inline allowlist summaries stayed numeric even when names were known

Status: fixed in the working tree.

Slack exposes `allowlist.resolveNames`, so `/allowlist` output can annotate configured IDs with known user names. Inline already had live `getChats` data for directory and target resolution, but did not expose allowlist name resolution. That made DM and group sender allowlists harder to inspect than native Slack, especially after setup where users often paste numeric IDs.

Fix:

- Added Inline `allowlist.resolveNames` on top of the shared DM/group allowlist adapter.
- Resolved numeric Inline user IDs, `user:<id>`, and `inline:user:<id>` through the existing `getChats` snapshot.
- Kept wildcards, access groups, chat IDs, and unknown users unresolved instead of inventing names.
- Added regression coverage for DM and group sender allowlist name resolution.

Verification:

- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/channel.test.ts` -> 1 file, 54 tests.
- `cd packages/openclaw && bun run typecheck`
- `git diff --check -- packages/openclaw/src/inline/channel.ts packages/openclaw/src/inline/channel.test.ts`
- Checkpoint install after rebuild: tarball shasum `f5a2cd1a290ff0535ce66d53c380c7ff2261fd7b`; `openclaw gateway health`, `openclaw channels status`, and `openclaw plugins doctor` passed; installed channel API reports `hasResolveNames: true`.

### 101. Inline groups had no per-group sender allowlist override

Status: fixed in the working tree.

Slack, Discord, and Telegram expose per-room/per-topic sender allowlists through `allowlist.readConfig` group overrides, and their runtime gates can use those room-local sender lists. Inline only had one account-wide `groupAllowFrom`, so a stricter or looser sender policy for one Inline group could not be represented. `/allowlist` also could not show per-group sender overrides for Inline.

Fix:

- Added `groups.<chat>.allowFrom` to Inline config and manifest schemas.
- Exposed Inline per-group sender allowlists through `allowlist.readConfig.groupOverrides`.
- Updated runtime group gating so `groups.<chat>.allowFrom` overrides account-level `groupAllowFrom` for that group, with `groups["*"].allowFrom` as the default override.
- Updated doctor/security audit copy and checks so per-group sender allowlists count as configured sender policy and wildcard/invalid-entry warnings include them.
- Documented the account-wide vs per-group sender allowlist behavior.

Verification:

- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/channel.test.ts` -> 1 file, 56 tests.
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/monitor.test.ts` -> 1 file, 92 tests.
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/config-schema.test.ts src/manifest.test.ts` -> 2 files, 19 tests.
- `cd packages/openclaw && bun run typecheck`
- `git diff --check -- packages/openclaw/src/inline/config-schema.ts packages/openclaw/src/inline/policy.ts packages/openclaw/src/inline/channel.ts packages/openclaw/src/inline/monitor.ts packages/openclaw/src/inline/doctor.ts packages/openclaw/src/inline/security.ts packages/openclaw/src/inline/channel.test.ts packages/openclaw/src/inline/monitor.test.ts packages/openclaw/src/inline/config-schema.test.ts packages/openclaw/src/manifest.test.ts packages/openclaw/openclaw.plugin.json packages/openclaw/README.md packages/openclaw/docs/openclaw-setup.md`

### 102. Inline retained SDK cursor state across credential changes and account removal

Status: fixed in the working tree.

Telegram's native plugin clears its persisted update offset when bot credentials change or an account is removed. Inline stores realtime SDK cursor state per account under the OpenClaw state directory, but did not expose a lifecycle hook to clear that state. Reusing the same Inline account id with a different bot token or base URL could carry over stale cursors and skip or mis-order inbound updates from the new identity.

Fix:

- Added an Inline `lifecycle` adapter with `onAccountConfigChanged` and `onAccountRemoved`.
- Cleared only the affected account's Inline SDK state file when the effective Inline identity changes.
- Compared the resolved base URL and credential identity instead of clearing state for unrelated Inline config edits.
- Left env-token value changes and token-file content changes to runtime/operator action, because detecting those would require observing secret values outside a config lifecycle event.
- Added regression coverage for changed credentials deleting state, unchanged credentials preserving state, and account removal deleting state.

Verification:

- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/channel.test.ts` -> 1 file, 57 tests.
- `cd packages/openclaw && bun run typecheck`
- `git diff --check -- packages/openclaw/src/inline/channel.ts packages/openclaw/src/inline/channel.test.ts .context/2026-05-19-inline-openclaw-native-channel-review.md .context/2026-05-20-inline-openclaw-work-log.md`

### 103. Inline prompt still suggested reactions when reactions were disabled

Status: fixed in the working tree.

Telegram only exposes reaction guidance when the account configuration allows reactions. Inline correctly hid `reactionGuidance` when `channels.inline.actions.reactions=false`, but `messageToolHints` still told the agent to use Inline reactions. That could cause the agent to attempt a disabled tool path and then apologize or retry awkwardly.

Fix:

- Gated the Inline reactions message-tool hint on `supportsInlineReactionsForConfig`.
- Added regression coverage so disabled reactions also remove the text hint, not just `reactionGuidance`.

Verification:

- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/channel.test.ts` -> 1 file, 57 tests.
- `cd packages/openclaw && bun run typecheck`
- `git diff --check -- packages/openclaw/src/inline/channel.ts packages/openclaw/src/inline/channel.test.ts .context/2026-05-19-inline-openclaw-native-channel-review.md .context/2026-05-20-inline-openclaw-work-log.md`

### 104. Inline allowlist copy under-documented the `inline:user:<id>` form

Status: fixed in the working tree.

Inline outbound targets and exec approvals accept `inline:user:<id>`, and prompts tell agents to reuse discovered target values. The existing allowlist normalizers already handled that form, but setup help and README copy only documented `user:<id>` and `inline:<id>`. That made a valid user target look unsupported, and there was no focused regression coverage to keep the user-target form aligned across setup, allowlist summaries, and runtime sender authorization.

Fix:

- Made shared and monitor allowlist normalization explicit about accepting user targets and rejecting chat targets for sender allowlists.
- Updated setup allowlist parsing/help copy and README accepted user-id forms.
- Added regression coverage for setup parsing, allowlist name resolution, and runtime DM authorization.

Verification:

- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/channel.test.ts src/inline/monitor.test.ts` -> 2 files, 149 tests.
- `cd packages/openclaw && bun run typecheck`
- `git diff --check -- packages/openclaw/src/inline/shared.ts packages/openclaw/src/inline/monitor.ts packages/openclaw/src/inline/setup-surface.ts packages/openclaw/src/inline/channel.test.ts packages/openclaw/src/inline/monitor.test.ts packages/openclaw/README.md .context/2026-05-19-inline-openclaw-native-channel-review.md .context/2026-05-20-inline-openclaw-work-log.md`

### 105. Inline preserved native bot mentions in agent prompt bodies

Status: fixed in the working tree.

Slack strips the active provider mention token before constructing the agent prompt. Inline used the native `msg.mentioned` flag to route group messages to OpenClaw, but the agent-facing `Body` and `BodyForAgent` still included text like `@inlinebot can you summarize?`. That made Inline prompts noisier than native channel prompts and could confuse the model into treating the bot address as user intent.

Fix:

- Added Inline bot-mention stripping for agent-facing group prompt bodies when mention routing has already identified the message as addressed to the bot.
- Preserved `RawBody`, `CommandBody`, and `BodyForCommands` so diagnostics and targeted command parsing still see the exact inbound text.
- Kept stripping scoped to the active bot username and standalone mention syntax, avoiding unrelated usernames or email-like text.
- Added regression coverage proving `RawBody` keeps `@inlinebot` while `Body` and `BodyForAgent` do not.

Verification:

- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/monitor.test.ts` -> 1 file, 93 tests.
- `cd packages/openclaw && bun run typecheck`
- `git diff --check -- packages/openclaw/src/inline/monitor.ts packages/openclaw/src/inline/monitor.test.ts .context/2026-05-19-inline-openclaw-native-channel-review.md .context/2026-05-20-inline-openclaw-work-log.md`

### 106. Inline group prompts lacked native-style mention facts

Status: fixed in the working tree.

Slack records structured mention facts in the finalized context, including whether the bot was explicitly mentioned, which provider-native users were mentioned, whether the wake was implicit, and the mention source. Inline only set `WasMentioned`, so the prompt metadata could not distinguish an explicit bot mention from a regex mention, command bypass, button action, or reply-to-bot wake. That made Inline less diagnosable and gave the model weaker group-chat context than native channel prompts.

Fix:

- Added Inline mention-source resolution for explicit bot mentions, mention-pattern matches, command bypasses, message-action wakes, and reply-to-bot implicit wakes.
- Added `ExplicitlyMentionedBot`, `MentionedUserIds`, `ImplicitMentionKinds`, and `MentionSource` to group finalized context.
- Added the same facts to the Inline current-message metadata block consumed by the agent.
- Kept active bot address text stripped from both the visible message body and the current entity helper text while preserving the structured mention facts.

Verification:

- `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/monitor.test.ts` -> 1 file, 93 tests.
- `cd packages/openclaw && ./node_modules/.bin/vitest run src/index.test.ts` -> 1 file, 3 tests.
- `cd packages/openclaw && bun run test` -> 20 files, 289 tests. First full coverage attempt exposed a timeout in `src/index.test.ts`; the split-loader test timeout was raised to 30s and the full suite then passed.
- `cd packages/openclaw && bun run typecheck`
- `cd packages/openclaw && bun run lint`
- `git diff --check -- packages/openclaw/src/inline/monitor.ts packages/openclaw/src/inline/monitor.test.ts .context/2026-05-19-inline-openclaw-native-channel-review.md .context/2026-05-20-inline-openclaw-work-log.md`

## Latest Audit Verification

- Latest focused code checkpoint: Inline group mention metadata/agent-body cleanup; `cd packages/openclaw && ./node_modules/.bin/vitest run src/inline/monitor.test.ts` -> 93 tests; `cd packages/openclaw && ./node_modules/.bin/vitest run src/index.test.ts` -> 3 tests; `cd packages/openclaw && bun run test` -> 20 files, 289 tests; `cd packages/openclaw && bun run typecheck`; `cd packages/openclaw && bun run lint`; targeted `git diff --check`. Packaging/install/shasum intentionally deferred per cadence.
- Final-pass source/copy scan found no production-facing `native channel`, `slash command`, `realtime bot`, `moltbot`, or Telegram/Slack/Discord leakage outside tests and intentional compatibility adapters/sanitizer fixtures. Debug/secrets scan found only placeholders/env-var documentation and a package-artifact test child-process `console.log` used to return JSON.
- Final package/runtime checkpoint:
  - `openclaw --version` -> `OpenClaw 2026.5.18 (50a2481)`.
  - `git -C /Users/mo/dev/openclaw rev-parse --short HEAD` -> `50a2481652`.
  - `cd packages/openclaw && bun run build` -> passed.
  - `cd packages/openclaw && npm pack --ignore-scripts --pack-destination /tmp` -> `/tmp/inline-openclaw-inline-0.0.36.tgz`.
  - `shasum /tmp/inline-openclaw-inline-0.0.36.tgz` -> `2ffc45058cfa5b75ff5ad322229872e3659c9fa0`.
  - `openclaw plugins install --force /tmp/inline-openclaw-inline-0.0.36.tgz` -> installed plugin `inline`.
  - `openclaw gateway restart` -> restarted LaunchAgent.
  - `openclaw gateway health` -> OK; Telegram configured; Inline configured.
  - `openclaw channels status` -> Inline default enabled/configured/running/connected; Telegram enabled/configured/running/disconnected polling.
  - `openclaw plugins doctor` -> no plugin issues detected.
  - Installed channel API probe reports `allowlist.resolveNames`, lifecycle, approval capability, message adapter, and `messaging.targetPrefixes=["inline"]` present.
  - Installed channel API file contains the final mention-context code (`ExplicitlyMentionedBot`, `ImplicitMentionKinds`, `MentionSource`, `stripInlineBotMentionEntityText`).
  - Installed manifest probe reports root description `Use OpenClaw from Inline DMs and chats with an Inline bot token.` and env aliases `INLINE_TOKEN`, `INLINE_BOT_TOKEN`.
  - `openclaw channels capabilities --channel inline --json` -> Inline probe OK for configured bot `@mo_openclaw_bot`, supports direct/group/media/reactions/edit/reply/groupManagement/threads/nativeCommands/blockStreaming and exposes native approval runtime event kinds `exec` and `plugin`.
  - `openclaw message send --channel inline --target chat:0 --message "inline dry run" --dry-run --json` -> dry-run resolved through core with Inline direct delivery.
  - `openclaw plugins inspect inline --json` still reports an older persisted npm shasum even after installing the latest tarball. Direct tarball shasum and installed-file probes are the artifact evidence for this checkpoint.
  - Live Inline CLI smoke as Mo (user id `1600`) passed:
    - DM to Kevin bot user `36100`: sent `OpenClaw live smoke DM 2026-05-21: please reply OK.`; Kevin replied `OK` (messages 714 -> 715).
    - Group `1022` (`Random / AI bots`): sent `@Kevin OpenClaw live smoke group 2026-05-21: please reply OK.` with mention entity for user `36100`; Kevin replied `OK` (messages 410 -> 412).
    - Group native command: sent `/whoami@mo_openclaw_bot`; Kevin replied with Inline identity metadata including user id `1600` and chat reference (messages 414 -> 415).
    - The same shared group also produced unrelated `Severus` agent OAuth failures, matching earlier history in that room; Kevin/Inline plugin smoke path still passed.
- Re-checked Telegram setup behavior in `/Users/mo/dev/openclaw/extensions/telegram/src/setup-surface.ts` and `setup-surface.test.ts`: fresh setup also prepares `groups["*"].requireMention = true`, so Inline's matching setup prepare hook is intentional native parity, not a new group-access regression.

## Remaining Release Work

No OpenClaw clone blocker remains. Final package/install/runtime checkpoint passed. Live Inline DM/group smoke passed.

- Optional release hardening: decide whether to set a stricter `plugins.allow` list before release. `openclaw plugins doctor` reports no plugin issues, so this is an operator policy decision rather than a failing check.
