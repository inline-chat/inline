---
title: "Local Agents"
description: "Understand local coding-agent ownership, message admission, workspace binding, and approval boundaries."
---

A local bridge connects an Inline bot to a coding-agent process on your computer. Inline carries messages and results; the provider executes work using its own runtime, authentication, and approval controls.

Read this page when operating or extending that bridge. For installation, use [Set Up an Agent](/docs/agents). Hermes and OpenClaw use their own gateway integrations; their lifecycle is described in the [Hermes](/docs/hermes) and [OpenClaw](/docs/openclaw) guides.

## About this page

For bridge operators and adapter authors with an installed provider and authenticated Inline account. Read ownership and admission before enabling shared-chat input, then use the diagnostic commands to verify the selected provider and workspace. Provider setup belongs in the linked installation guide.

**Applies to:** Inline CLI bridge; provider support is installation-specific. See the [version and example baseline](/docs/technical#versions-and-examples) before choosing a package.

## Ownership

| Component | Owns |
| --- | --- |
| Inline bot | The identity used to receive requests and publish results in Inline. |
| Bridge service | Provider processes, conversation routing, local session state, and workspace bindings. |
| Provider runtime | Model access, provider authentication, tool execution, and provider-specific approvals. |
| Owner | Human operator access, approval decisions, and project selection. |

One per-user bridge service can manage multiple configured providers. Each conversation uses its saved session and workspace binding; changing a default workspace does not silently move existing bound sessions.

Use `--folder` during setup to select the intended project. For an existing installation, use the documented project-selection controls in the [bridge reference](https://github.com/inline-chat/inline/blob/main/cli/docs/local-agent-bridge.md#project-folders). A chat title or a path written in a message is not authority to rebind a project.

## Message Admission

Admission has two distinct checks: whether a sender may provide input, and whether this message activates the selected bot.

| Sender | Admission and activation |
| --- | --- |
| Human | The provider's stable user-ID operator policy applies; the owner is allowed by default. Authorized input must also match routing rules such as the bot DM, mention, reply, or followed conversation. |
| Another bot | The bot must address the target through a structured mention. Bot input follows the bot-to-bot route rather than the human operator allowlist. A bot DM, generic mention flag, or reply alone does not activate it. |

Shared-chat membership does not add a human to the operator policy. The bridge ignores unauthorized human messages rather than sending them to the provider. Bot admission does not grant the sender authority to approve a tool request or change local operator policy.

## Approvals and Local Authority

The owner is the approver. Preserve the provider's exact requested approval scope; a conversation mention or a previous approval is not a broader grant to execute unrelated commands.

Approval details and local paths belong in the owner-only control context. Shared or public conversations can be visible to people outside the operator set, so a provider result must not expose local credentials or sensitive approval details there.

## Security

- Keep provider credentials in provider-owned stores. Inline bot credentials and local control capabilities belong to the bridge.
- Keep local control listeners restricted to their authenticated local transport. The Mac folder registrar uses a loopback endpoint and a service-epoch capability; do not expose it publicly.
- Do not log bot tokens, provider credentials, local control capabilities, or private approval payloads.
- Treat workspace selection and command approval as separate authority. A shared chat does not expand either one.

## Verify and Diagnose

For an installed CLI bridge, inspect its local status:

```bash
inline bridge status
inline bridge doctor
```

Check the named provider and its selected workspace, then send a test request from an authorized human account. A running service does not by itself prove provider authentication, correct project binding, or successful response delivery.

| Symptom | What to inspect |
| --- | --- |
| Service runs but the provider is unavailable | Provider installation and authentication; inspect the provider-specific doctor result. |
| A human message is ignored | Stable sender ID, live operator policy, and whether the message activates this bot. |
| Another bot's reply is ignored | An exact structured mention of the intended target; replies alone do not activate bot-to-bot routing. |
| Work opens in an unexpected project | The conversation's existing binding, then the selected default. Do not replace the binding based only on message text. |
| A linked session requires resuming | Follow its resume flow before resending input; opening history is not the same as acquiring a writable provider session. |

## Reference

- [Bridge setup and operations](https://github.com/inline-chat/inline/blob/main/cli/docs/local-agent-bridge.md): provider-specific lifecycle and recovery.
- [Inbound admission](https://github.com/inline-chat/inline/blob/main/cli/src/bridge/runtime.rs) and [activation routing](https://github.com/inline-chat/inline/blob/main/cli/src/bridge/routing.rs): human operator and bot mention handling.
- [Operator configuration](https://github.com/inline-chat/inline/blob/main/cli/src/bridge/user_config.rs): stable-ID policy and provider overrides.
- [Credential boundaries](/docs/technical/security): how bridge credentials differ from other Inline interfaces.

## Summary

Verify provider availability, operator admission, workspace binding, and response delivery separately. A running service proves only one part of that path. Resolve ignored input through [Verify and Diagnose](#verify-and-diagnose) before changing authority.
