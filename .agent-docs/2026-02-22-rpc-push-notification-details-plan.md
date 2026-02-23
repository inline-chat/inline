# RPC Push Notification Details Plan (2026-02-22)

## Goal
Move push token registration from REST `savePushNotification` to realtime RPC, while preparing typed fields for notification-content encryption rollout and keeping backward compatibility.

## Scope
- Add a new RPC method in `proto/core.proto` for updating push notification details.
- Add server handler/function wiring for the new RPC method.
- Extend `sessions` schema/model with optional push-content key metadata.
- Keep legacy REST endpoint working by routing to shared model update path.
- Switch Apple push-registration call sites to realtime API (off `ApiClient.savePushNotification`).
- Add a focused realtime protocol test for the new RPC flow.

## Design
- RPC semantics are register/update (Telegram `account.registerDevice` inspired): idempotent per session, last write wins.
- Input includes:
  - `apple_push_token` (required)
  - optional typed encryption key metadata object (for future encrypted notification payloads)
  - optional payload/content version marker
- Result is empty success payload.

## Rollout
1. Land RPC and client switch while keeping REST endpoint.
2. Existing clients continue using REST path unchanged.
3. New clients use RPC path.
4. Later PR introduces encrypted push content using the uploaded key metadata.

## Phase 2 (Encrypted Push Content)
- Encrypt `send_message` notification content on the server when a session has push-content key capability.
- Keep plaintext fallback for legacy sessions without key capability.
- For encryption-capable sessions, avoid plaintext leakage by using a generic alert when encryption fails.
- Generate/store an X25519 private key on iOS in shared keychain and upload public key metadata during push registration.
- Decrypt encrypted push payload in `InlineNotificationExtension` and hydrate title/body/sender/thread metadata before intent rendering.
- Add notification-extension entitlements for shared keychain/app-group access.

## Validation
- Regenerate protocol artifacts.
- Run focused realtime protocol test for new method.
- Run targeted server typecheck/tests for changed files where feasible.
