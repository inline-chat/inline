---
title: "Authentication"
description: "Realtime V3 credential creation, binding, persistence, rotation, and revocation."
---

Realtime V3 uses Inline Protocol authorization keys. A **permanent key** is associated with an account session after login. A **temporary key** carries ordinary application traffic only after the server binds it to an authorized permanent key. These keys are secret credentials; the production RSA ring contains public verification keys, not account credentials. This page covers V3 credential ownership. [Realtime V2](/docs/technical/realtime-v2), Bot API tokens, and MCP OAuth use separate authentication paths.

## About this page

For V3 client authors implementing login and a protected credential store. You need a trusted server key ring, an account able to complete login, and storage that coordinates rotation with logout. Follow creation → binding → persistence → revocation; the outcome is authorized application access with recoverable credentials.

**Applies to:** Realtime V3; TypeScript SDK. See the [version and example baseline](/docs/technical#versions-and-examples) before choosing a package.

**Figure: Application access begins after login and temporary-key binding.**

```text
permanent handshake → login authorized ──────────────┐
                                                    ├→ bind → application RPCs
temporary handshake ────────────────────────────────┘
```

The two handshakes establish separate keys. Binding joins temporary traffic authority to the account session established through the permanent key.

## Create and authorize a permanent key

1. Start a V3 handshake using a trusted, pinned server RSA public-key ring. The handshake creates a permanent authorization key and a server salt. It does not sign the user in.
2. On that encrypted permanent-key connection, start a login. Native login uses `authBegin` with an email address or phone number and returns a challenge ID, delivery channel, expiry, and retry delay. Complete it with `authComplete(challenge_id, code, ...)`. The response is either `authorized` or `invite_required`; handle both states. Hosted browser login is a separate `authBeginBrowser` and `authBrowserStatus` flow bound to the same permanent key.
3. Treat `authorized` as the point at which the server associates the permanent key with a user and account session. Login errors, an expired challenge, or `invite_required` do not grant ordinary RPC access.

The [login request and result messages](https://github.com/inline-chat/inline/blob/main/proto/core.proto) define the fields. The TypeScript [V3 client](https://github.com/inline-chat/inline/blob/main/packages/sdk/src/realtime/v3-client.ts) exposes `beginLogin` and `completeLogin`; the [server auth operations](https://github.com/inline-chat/inline/blob/main/server/src/modules/inlineProtocol/auth.ts) enforce the permanent-key requirement.

## Bind a temporary key

Create a fresh temporary key with a V3 handshake, then prove possession of the permanent key when binding it. The proof includes the temporary authorization key, session, nonce, and expiry. The server accepts application RPCs only after it has bound the temporary key to the authorized user's account session. A cryptographically valid but unbound temporary key cannot call ordinary RPCs.

Temporary keys have a 24-hour lifetime. The TypeScript and Rust clients treat 80% of that lifetime, measured against authenticated server time, as the rotation boundary. At that boundary, stop admitting new application work, make a fresh temporary key, bind it, and reconnect. A stored temporary key is probed on reconnect before reuse; an invalidated key is replaced through the permanent authority. If the permanent key or account session is revoked, replace credentials through login rather than retrying the old key.

## Persist credentials

Persist the permanent key and any bound temporary key in a protected credential store.

The exported `InlineProtocolV3Credentials` type requires `permanent: InlineProtocolAuthorization` and accepts optional `temporary: InlineProtocolAuthorization`. Import it from `@inline-chat/realtime-sdk`; the [canonical declaration](https://github.com/inline-chat/inline/blob/main/packages/sdk/src/realtime/v3-client.ts) defines the complete shape.

`InlineProtocolAuthorization` contains the secret key bytes, key ID, server salt, temporary flag, and optional expiry. The high-level `InlineSdkClient` selects V3 through `inlineProtocol: { credentials, onCredentials }`. Its `onCredentials` callback must persist a replacement credential set before the SDK makes the replacement authenticated session visible. The storage owner must reject a late write after logout begins; otherwise an in-flight rotation can restore credentials that logout removed. See the [SDK credential options](https://github.com/inline-chat/inline/blob/main/packages/sdk/src/sdk/types.ts) and [V3 transport rotation path](https://github.com/inline-chat/inline/blob/main/packages/sdk/src/realtime/v3-transport.ts).

Do not log authorization-key bytes or serialize them into diagnostics. Closing a client connection disposes that connection; it does not revoke or clear durable credentials.

## Revoke and recover

The high-level TypeScript SDK's `logout()` requires a durable `credentialOwner`. It attempts remote `LOG_OUT`, closes the client, and clears host-owned local credentials even when the remote outcome cannot be confirmed. Its result distinguishes `confirmed`, `notSent`, and `commitUnknown`; `commitUnknown` means the remote revocation must not be assumed. The [SDK logout contract](https://github.com/inline-chat/inline/blob/main/packages/sdk/src/sdk/inline-sdk-client.ts) and [result type](https://github.com/inline-chat/inline/blob/main/packages/sdk/src/sdk/types.ts) define these outcomes.

On the server, revoking a permanent authorization invalidates its bound temporary keys; an expired temporary key is removed from the temporary-key store. Application dispatch also checks the current key binding and account session. See the [authorization-key store](https://github.com/inline-chat/inline/blob/main/server/src/modules/inlineProtocol/authorizationKeys.ts) and [application admission](https://github.com/inline-chat/inline/blob/main/server/src/modules/inlineProtocol/application.ts). Keep local credential erasure and confirmed remote revocation distinct when reporting logout to a user.

For carrier and record details, see [Protocol](/docs/technical/protocol). For reconnect outcomes and mutation retries, see [Realtime](/docs/technical/realtime) and [RPC semantics](/docs/technical/rpc).

## Summary

A handshake creates a key; login grants permanent authority; binding admits temporary-key traffic. Persist replacements before use. Report local erasure separately from remote revocation, and use [RPC outcome rules](/docs/technical/rpc) when logout completion is uncertain.
