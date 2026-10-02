# Updating and publishing Inline for ChatGPT

This plugin has two release surfaces: the remote MCP service at `https://mcp.inline.chat/mcp/v2`, and the plugin package/listing. A Git commit, server deployment, developer-mode refresh, and public plugin publication are separate operations. This runbook does not perform any of them automatically.

## Validate the candidate

Run from the repository root, using the pinned Bun version:

```sh
bun install --frozen-lockfile
bun --no-env-file scripts/check-codex-plugin.mjs
bun run --cwd packages/protocol build
bun run --cwd packages/oauth-core build
bun run --cwd packages/sdk build
bun run --cwd plugins/chatgpt/ui build
bun run --cwd plugins/chatgpt/ui typecheck
bun run --cwd plugins/chatgpt/ui lint
bun run --cwd plugins/chatgpt/ui test
bun run --cwd packages/mcp typecheck
bun run --cwd packages/mcp lint
bun run --cwd packages/mcp test
bun run --cwd packages/mcp build
bun --no-env-file scripts/ci/check-chatgpt-plugin.mjs /tmp/inline-chatgpt-contract.json
```

The `CI` workflow checks the MCP test suite and plugin package. The separate `ChatGPT plugin` workflow runs on relevant pull requests/main pushes and manual dispatch. It validates the manifest/skill mirror, builds the MCP distribution, runs type/lint/behavior checks, checks real HTTP/resource registration with synthetic local OAuth, and compares tool annotations with `packages/mcp/chatgpt-app-submission.json`. It saves a SHA-tagged receipt as `chatgpt-plugin-contract`. This checks packaging and protocol behavior, not the ChatGPT desktop application.

For a pushed candidate, inspect both workflows at the exact candidate SHA:

```sh
gh run list --repo inline-chat/inline --workflow integrations.yml --commit "$CANDIDATE_SHA"
gh run list --repo inline-chat/inline --workflow chatgpt-plugin.yml --commit "$CANDIDATE_SHA"
```

Set `CANDIDATE_SHA` to the reviewed commit. Do not treat green runs on another commit as validation of the candidate. The focused workflow uses path filtering and should not be configured as an always-required check without an always-reporting gate.

## Update a development install

For a remote developer-mode MCP connection: deploy/restart the test server, open its ChatGPT Plugins connection, choose **Refresh**, confirm the discovered metadata, and start a new conversation. For a local marketplace package: update the directory referenced by its marketplace entry and restart ChatGPT desktop. Refreshing local package files does not deploy the hosted server. See [connection testing](https://developers.openai.com/plugins/deploy/connect-chatgpt) and [local packaging](https://developers.openai.com/plugins/build/plugins).

Exercise these cases with a test account and approved test conversations:

1. Search/select a desktop mention, distinguish duplicate titles, and ask about its recent text. Confirm the resource is read and the answer respects snapshot coverage.
2. Test empty chats, long Unicode messages, denied scope, and revoked conversation access. A denial must not return cached content.
3. Read recent messages and search within a conversation. Verify native bubbles, sender names, profile photos and expired/missing-photo fallbacks, local text expansion, visible filters, and an empty filtered page. Only message-list results offer continuation; capped searches suggest refinement.
4. Verify ordinary text/tool behavior in a client without UI. Neither mention selection nor card rendering should post messages or mark them read.
5. In a supported Work/Cloud host, subscribe to an approved thread's `message.created`, receive a verified callback, read the actual reply and continue the waiting task. Renew before `refreshBefore`; qualify replay, restart, expiry, unsubscribe and revoked access. Do not equate a green proxy test with host continuation.
6. With approved test recipients, call `conversations.ask`: check the private audience, one delivered question, pre-question replay cursor, subscription acknowledgement and resumed task. An uncertain create/send must retain its receipt and avoid an automatic duplicate.
7. Open the React thread view from the tool and host entrypoints. Check light/dark, narrow layout, older history, read-only scope, confirmed/unconfirmed replies and selected context. Its picker must show only explicitly opened threads. Qualify actual media asset origins under the widget CSP.

Record host name/build, candidate SHA, deployment identity, case outcomes, and actual screenshots. Do not publish screenshots or capability claims before these paths work. Use the submission JSON as review material; the picker case is host-driven, not a promise that the model chooses an app-only search tool.

## Deploy the hosted MCP candidate

This release also adds an API migration and owned delivery worker. First qualify and deploy the exact API candidate through `server-deploy.yml`; check the migration and worker before deploying MCP. The internal `/oauth/mcp-events` endpoint uses the existing shared-secret channel. Keep the original OAuth scopes, grant context and API/MCP secret pairing. Do not send real teammates test messages without their authorized test scope.

The deployable artifact is `packages/mcp/Dockerfile`, built from the repository root, with runtime port `8791`. Its build invokes the MCP package build and copies MCP and `plugins/chatgpt/ui` distributions into the runtime image. The React UI must be present in that compiled output, not merely a local source file. Configure `MCP_UI_RESOURCE_DOMAINS` with exact HTTPS signed-media origins if needed; default photos use the API origin.

In the deployment controller for `mcp.inline.chat`, verify the current service, repository, branch/commit selection, root build context, Dockerfile path, and OAuth/API configuration. Select the reviewed candidate through that service's existing deployment process; preserve the previous working image for rollback. The controller's current identity and permissions must be checked by the release operator: this repository does not contain an MCP-specific production deployment workflow, and the API server's deployment workflow is not a substitute.

Read-only provider verification on September 30, 2026 found the Coolify application named `inline mcp`, serving `mcp.inline.chat`, configured for `inline-chat/inline` `main` at `HEAD`, root build context, and the Dockerfile/port above. Recheck this configuration before use. With an authenticated Coolify CLI context, the existing operational commands are:

```sh
coolify app list
coolify app deployments list "$MCP_APP_UUID"
# Only after authorization for the reviewed production candidate:
coolify deploy uuid "$MCP_APP_UUID"
coolify deploy get "$DEPLOYMENT_UUID"
```

Resolve `MCP_APP_UUID` from the matching service and `DEPLOYMENT_UUID` from the deployment response. The installed CLI's deployment command has no commit override: it deploys the configured revision. Do not run it against moving `HEAD` when approval is limited to one SHA; first pin the candidate through the controller's supported settings, or obtain approval for the current branch revision. Verify the deployment's recorded commit against the approved candidate. These commands were checked through CLI help; no deployment was performed for this runbook.

After an authorized deployment, check `/health`, OAuth discovery, anonymous-request denial, and an authenticated test-account tool/resource flow at `/mcp/v2`. A healthy endpoint alone does not prove OAuth, resource reading, or UI rendering. Then refresh the development connection and repeat the host cases above.

## Publish or update the public plugin

For changes confined to hosted MCP tools/UI, deploy the reviewed revision, open the existing plugin in the [submission portal](https://platform.openai.com/plugins), select **MCPs → Inline → Rescan**, and inspect findings and live tool definitions. Repair scan-account authorization if requested. Eligible server updates pass automated checks without a new package release; held changes do not replace approved definitions. Keep approved schemas working. See [current submission and update instructions](https://developers.openai.com/plugins/deploy/submission).

For listing, assets, skills, or packaged configuration changes, download the existing published release ZIP first. Preserve its package identity, components and version history; the repository marketplace package may have a different identity/version. Edit that package, increment its version, upload the complete ZIP to the existing plugin, resolve findings, submit for review, then publish after approval. Changing an existing MCP URL requires support.

The public directory package uses [the focused MCP skill](directory-skill/SKILL.md) at `skills/inline/SKILL.md`, with the existing skill license. Keep the mirrored `skills/inline` bundle for local marketplace clients: it also covers CLI installation and local-agent bridges, which the hosted directory's skill review cannot verify. The directory skill is self-contained; omit the CLI/bridge references and agent setup files from that ZIP.

In the directory ZIP's `.mcp.json`, keep the existing server key and endpoint but omit `oauth_resource`. The submission importer rejects that setting; OAuth remains configured on the existing portal connection. The local marketplace configuration keeps its explicit OAuth resource. Include only the published manifest, MCP configuration, icon, focused skill and license, preserving existing publisher/legal/support fields. After upload, verify that the server still points to the same associated app and remains authorized and domain-verified.

Record the exact archive hash and actual scan outcomes. An uploaded draft remains unpublished until approval and publication. If a hosted scan cannot finish, retain approved definitions and investigate the failure; metadata validation does not establish that new tools are live. Required submission attestations must be completed by an authorized publisher.

An initial submission also starts with a ZIP declaring MCP configuration. Review requires a dedicated sample account, five positive and three negative tested cases, and a walkthrough video. Keep reviewer credentials outside Git, public ZIPs and CI artifacts. `chatgpt-app-submission.json` is supporting material, not proof of publication.
