# Hermes private seams

`hermes plugins validate` (catalog rule 9) lists every import of an undocumented Hermes
internal. This file tracks the ones the Inline adapter still needs, why, what happens when
one disappears, and the public API we would ask upstream for.

Every entry below is guarded: when the seam is missing or changes shape, the adapter logs
`[inline] Hermes internal <seam> is unavailable (...)` once per process and degrades that
one feature. Message delivery never depends on these seams.

Audited against Hermes main `93ce7e34` (2026-11-05) and the minimum host `v2026.9.14`.
The cron metadata gap below was rechecked against main `9ffa7dff` on 2026-11-07.

## Already moved to public surfaces

| Was | Now |
|---|---|
| `gateway.display_config._PLATFORM_DEFAULTS` | `display_tier` + `display_overrides` on `ctx.register_platform` (feature-detected; legacy seed kept for older hosts) |
| `tools.skills_tool._find_all_skills` / `_sort_skills` | public `find_all_skills` / `sort_skills` (legacy names kept for hosts < 0.22.5) |
| `gateway.run._gateway_runner_ref()` | `BasePlatformAdapter.gateway_runner` |
| `gateway.run._load_gateway_config()` | `hermes_cli.config.load_config_readonly()` |
| `hermes_cli.__version__` | `importlib.metadata.version("hermes-agent")` |
| `hermes_cli.gateway` env/config helpers | `hermes_cli.config` (`get_env_value`, `save_env_value`, `read_raw_config`, `write_platform_config_field`) |
| `hermes_cli.setup.print_*` | `hermes_cli.cli_output` |
| own `send_exec_approval` (bypassed the button probe and newer hosts' Deny-only gate) | `_send_exec_approval_prompt` hook; taps resolve through `resolve_gateway_approval_card` and, where present, `gateway.approval_actor.approval_refusal` |

## Legacy-host fallbacks (no upstream ask)

Hermes main already has the public API; the private path runs only on older hosts. Remove
these when the plugin's minimum host includes the public API.

- `adapter.py` `_install_inline_display_defaults`: `gateway.display_config._PLATFORM_DEFAULTS`
  (needs `PlatformEntry.display_overrides`). Missing: Inline uses Hermes' generic display defaults.
- `adapter.py` `_inline_skill_catalog`: `tools.skills_tool._find_all_skills` / `_sort_skills`
  (needs Hermes 0.22.5). Missing: skill catalog sync fails with a warning.

## Upstream seams to request

Each draft is ready to file on NousResearch/hermes-agent.

### 1. Gateway command menu for plugin platforms

- Uses: `hermes_cli.commands_platforms.telegram_menu_commands(max_commands=)`
- Why: Inline publishes Hermes' slash-command menu to its native command picker, the same
  list Telegram gets.
- Without it: the Inline menu shows only Inline's own commands.

> **Plugin platforms need the gateway command menu.** Platform plugins with a native
> command picker (Inline) mirror what Telegram gets from `telegram_menu_commands()`, which is
> private and Telegram-named. Could Hermes expose a platform-neutral, documented
> `gateway_menu_commands(max_commands) -> (list[(name, description)], hidden_count)` (or a
> `ctx` accessor) covering core, plugin and skill commands?

### 2. Plugin slash-command lookup

- Uses: `hermes_cli.plugins.get_plugin_commands()`
- Why: Inline command names allow only underscores, Hermes registers plugin commands with
  hyphens. The adapter rewrites `/inline_sync` to `/inline-sync` only for real plugin commands.
- Without it: plugin commands with hyphens must be typed with hyphens.

> **Read-only registry of plugin slash commands.** Adapters whose platform forbids `-` in
> command names need to know which `/a_b` maps to a registered plugin command `a-b`. A
> documented `ctx.plugin_commands()` (names only) or a gateway-side normalization hook would
> remove the private import.

### 3. Slash-command access policy

- Uses: `gateway.slash_access.policy_from_extra(extra, scope).can_run(user_id, command)`
- Why: changing a chat's reply-thread mode from Inline's settings sheet follows the same
  admin lists as running `/threads`.
- Without it: fails closed. Group reply-thread settings are locked; a DM's owner can still
  change their own. Every supported host has it, so this only guards a future breakage.

> **Expose slash-command access checks to adapters.** Platform plugins that offer native
> settings UIs equivalent to a slash command need `can_run(user_id, command)` for the
> platform's configured admin lists. A public `BasePlatformAdapter.can_run_command(user_id,
> chat_type, command)` would cover it.

### 4. Session model and reasoning settings

- Uses: `GatewayRunner._session_key_for_source`, `_session_model_overrides`,
  `_resolve_session_reasoning_config`, `_handle_model_command`, `_apply_reasoning_selection`;
  `hermes_cli.model_switch_providers.list_picker_providers`.
- Why: Inline's agent settings sheet shows and changes the session/default model and
  reasoning effort, like `/model` and `/reasoning`.
- Without it: the sheet hides the model and reasoning rows; switching reports unavailable.

> **Session settings API for platform adapters.** Native settings UIs need to read and set
> the current model and reasoning effort for a `SessionSource`: e.g.
> `runner.session_settings(source) -> {session_key, model, provider, reasoning}`,
> `runner.set_session_model(source, provider, model, scope="session"|"global")`,
> `runner.set_session_reasoning(source, effort)`, plus a documented model-picker catalog
> (`list_picker_providers`). Today plugins call private runner methods and synthesize
> `/model` command text.

### 5. Model picker presentation helpers

- Uses: `hermes_cli.models_catalog_static.PROVIDER_GROUPS` / `group_providers`,
  `hermes_cli.providers.get_label`, `hermes_cli.model_cost_guard.expensive_model_warning`.
- Why: Inline renders `/model` as native buttons with the same provider grouping, labels and
  expensive-model confirmation as Telegram/Discord.
- Without them: providers list ungrouped with slugs, and the expensive-model confirmation
  is skipped.

> **Document the model-picker helpers.** Plugin platforms that render the `/model` picker
> natively need provider grouping, display labels and the expensive-model guard. Promoting
> these four names to the public list (or one `model_picker` helper module) would let
> plugins match core platforms without private imports.

### 6. Parent-aware authorization for child chats

- Uses: `GatewayRunner._is_user_authorized_for_source(source)`
- Why: the adapter's authorization callback `(user_id, chat_type, chat_id, *, is_bot,
  thread_id)` drops `parent_chat_id`, which Inline reply threads need for parent-routed
  profiles.
- Without it: credentialed side effects in reply threads fail closed (treated as unauthorized).

> **Pass `parent_chat_id` through the adapter authorization check.** `set_authorization_check`
> callbacks receive `thread_id` but not `parent_chat_id`, so plugins with child chats call
> `runner._is_user_authorized_for_source` directly. Forwarding `parent_chat_id` (or accepting
> a full `SessionSource`) in `_is_sender_authorized` would remove it.

### 7. Slash-confirm resolution from native buttons

- Uses: `tools.slash_confirm.resolve(session_key, confirm_id, choice)`
- Why: Inline renders slash-command confirmations as buttons, like approvals and clarify.
- Without it: the button answers "This Hermes version cannot record that choice."
- Note: the validator does not flag this import because the plugin ships its own `tools.py`,
  which shadows `tools.*` in `_local_modules`. Worth fixing alongside.

> **Add `tools.slash_confirm.resolve` to the public platform helpers.** It is the slash-confirm
> analogue of `resolve_gateway_approval_card` and `resolve_gateway_clarify`, which are already
> public. Separately, `plugin_validate_private_imports` treats `from tools import x` as local
> when a plugin has a `tools.py`.

### 8. Plugin load diagnostics for `hermes inline status`

- Uses: `hermes_cli.plugins.get_plugin_manager()` (and its `_plugins`), `hermes_cli.plugin_compat.plugin_hits`
- Why: `hermes inline status --json` attests that this exact install loaded and registered
  its tools.
- Without it: status reports `loader_unavailable` (inconclusive), never success.

> **Read-only plugin load status.** A documented `hermes_cli.plugins.plugin_status(name) ->
> {path, enabled, error, tools_registered, deprecated_imports}` would let plugin CLIs report
> health without walking the manager's private state.

### 9. Cron delivery metadata across transports

- Uses: the public adapter `send(..., metadata=...)` contract. No scheduler
  import or patch is needed for scheduled gateway text.
- Current gap: `cron.scheduler_delivery` supplies `job_id` and `notify` on live
  text, but only `notify` on media. The public `standalone_sender_fn` contract
  does not accept delivery metadata, including during live-to-standalone fallback.
- Without it: `cron_mention_prefix` can identify only scheduled gateway text.
  Applying it to other sends would also mention people in ordinary replies or
  manual CLI sends. `notify` alone cannot distinguish them: Hermes marks ordinary
  final replies with it too.

> **Preserve cron identity on every delivery transport.** Pass optional delivery
> metadata (`job_id`, `notify`, and a first-payload marker) through live media and
> standalone plugin callbacks. Keep existing callbacks compatible by forwarding
> the new keyword only when supported. The first-payload marker lets adapters
> mention once for a media-only post or a chunked standalone send, while retaining
> the job identity on subsequent payloads. This would let Inline reopen the right
> thread consistently without guessing from message text, process environment,
> or scheduler internals. Include normal-send, muted-cron, media-only, chunking,
> and standalone-fallback cases in the host contract tests.
