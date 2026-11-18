# `@inline/auth/flows`

Sign-in and sign-out for the web app, without a view framework. A typed HTTP client for the sign-in routes, a stable device ID, the sign-in state machine (signals from `@inline/reactive`), the provider (Google, Apple) redirect as far as it works without a browser, and the sign-out ordering. Views are not here.

Imports: `@inline/config`, `@inline/ids`, `@inline/reactive`, and `AuthStore` from this package through its public API. No DOM access: `fetch`, storage, crypto, the clock and the user agent are injected.

## Public API

| Export | What |
| --- | --- |
| `createSignInApi({ fetch, apiBaseUrl?, device, clock?, timeoutMs? })` | `sendEmailCode`, `verifyEmailCode`, `sendSmsCode`, `verifySmsCode`, `checkInviteCode`, `redeemProviderTicket`, `logout`. Each returns `ApiResult<T>`: `{ ok: true, value }` or `{ ok: false, error: SignInError }`. |
| `SignInError` | `network`, `rateLimited { retryAfterSeconds }`, `invalidCode`, `expiredCode`, `inviteRequired`, `invalidInvite { reason: format, notFound, taken }`, `invalidEmail`, `invalidPhone`, `signupsDisabled`, `accountDeactivated`, `invalidTicket`, `providerCancelled`, `providerFailed`, `providerStateMismatch`, `server { status, code }`. |
| `loadDeviceId`, `describeDevice`, `createDeviceFacts` | Device ID kept in injected storage (`inline:device-id`); a name like "Chrome on macOS". |
| `createSignInModel(options)` | The state machine below. |
| `ProviderAttemptStore`, `buildProviderStartUrl`, `parseProviderReturn`, `validateProviderReturn`, `stripProviderReturnParams`, `createProviderAttempt`, `codeChallengeFor` | Provider pieces, also used by the model. |
| `signOut({ authStore, api?, eraseAccountData?, clock?, revokeTimeoutMs? })` | Revoke, clear, erase; resolves to `SignOutResult`. |
| `watchAccountEnd(authStore, onAccountEnded)` | Calls back when this tab's account ends, wherever the sign-out happened. |
| `systemClock`, `Clock` | Time source; tests use a virtual clock. |

App wiring, in short:

```ts
const device = createDeviceFacts({ storage: localStorage, randomId: () => crypto.randomUUID(),
  environment: navigator, clientVersion: BUILD_VERSION, timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone })
const api = createSignInApi({ fetch: (u, i) => fetch(u, i), device, clock: systemClock })
const model = createSignInModel({ api, authStore, clock: systemClock,
  signOut: () => signOut({ authStore, api, clock: systemClock, eraseAccountData }),
  provider: { crypto, attempts: new ProviderAttemptStore(sessionStorage), apiBaseUrl, returnUrl, device: () => device } })
await model.completeProvider(location.href)            // at boot; then history.replaceState(null, "", stripProviderReturnParams(location.href))
const url = await model.startProvider("google"); if (url) location.assign(url)
```

## The sign-in model

Steps: `welcome` (method choice), `email`, `phone`, `invite` (access invite code), `code`, `provider` (waiting for or returning from Google or Apple), `setup` (signed in, account has `pendingSetup`), `done`.

```
welcome ─ chooseEmail ─▶ email ─ submitEmail ─▶ code ─ submitCode ─▶ setup ─ finishSetup ─▶ done
        ─ choosePhone ─▶ phone ─ submitPhone ─▶   │                    └──────────────────▶ done
                                   │   needsInviteCode   └ verify says INVITE_CODE_REQUIRED ┐
                                   └────────▶ invite ◀───────────────────────────────────────┘
                                              └ submitInvite (checkInviteCode) ─▶ code (and resubmits the held code)
        ─ startProvider ─▶ provider ─ completeProvider (after the redirect) ─▶ setup | done
```

Signals: `step`, `method`, `pending` (the running action or null), `error` (for the current step), `contact`, `existingUser`, `inviteCode`, `resendSeconds`, `canResend`, `canGoBack`, `signedInUserId`, `user`.

Rules, each covered by a test in `sign-in-model.test.ts`:

- An error never changes the step. The one routing answer is `INVITE_CODE_REQUIRED` from verify, which is the server saying an invite is needed: the model moves to `invite`, keeps the code, and resubmits it once the invite is accepted. Email codes are not spent by that answer (`server/src/modules/auth/emailLoginChallenges.ts:90`).
- The invite step appears only when the send answer says `needsInviteCode` or verify answers `INVITE_CODE_REQUIRED`. It sits between the contact and the code, so back from `code` goes to `invite` (prefilled) and back from `invite` goes to the contact step.
- Back pops to the previous step. Back from `provider` drops the pending attempt. Back after authentication (`setup`, `done`) signs out through the injected `signOut` and restarts at `welcome`, as `OnboardingViewModel.goBack` does on the Mac.
- Every step change bumps a generation. A response for an older generation is dropped; a session that arrives late is revoked with `POST /v1/logout` and never saved.
- One request at a time: every action is ignored while `pending` is set. Double submission cannot send twice.
- On success the session goes to `AuthStore.login`, then `signedInUserId` and `user` are set and the step moves to `setup` or `done`.
- Resend: 60 seconds after each send (the server allows one send per contact per minute, `otpDeliveryBudget.ts:26`), counted on the injected clock. A rate-limited resend waits for `retry-after`.
- `expiredCode` is inferred: the server answers `EMAIL_CODE_INVALID` for a wrong, expired or exhausted code alike. After 10 minutes (`emailLoginChallenges.ts:13`) the model reports it as expired. SMS codes are not inferred, since the SMS provider's lifetime is not in our code.
- Provider errors (`cancelled`, `failed`, state mismatch, rejected ticket) show on the `provider` step with no automatic redirect; `startProvider` from that step tries again.

## Sign-out

`signOut` order: revoke on the server (best effort, 5 s bound with a clock) → `AuthStore.logout()` (clears the record; the browser persistence writes a tombstone and broadcasts so other tabs' stores emit `logout`) → `eraseAccountData(userId)`. Credentials go first so the user is signed out even if erasing fails. A 401 on revoke counts as revoked. A second call while one runs joins it. `watchAccountEnd` fires in every tab, including the one that signed out, so the app has one place to close the account's views.

## Server routes, as found

All identity routes accept GET with query or POST with JSON, form or multipart (`server/src/controllers/identity.effect.ts:102-236`). This client always POSTs JSON so codes and tokens stay out of URLs. Success is `{ ok: true, result }` (`identity.effect.ts:366`); failure is `{ ok: false, error, errorCode, description }` with the status of the error (`identity.effect.ts:263`, codes in `server/src/types/errors.ts`). Validation failure is 400 `INVALID_ARGS`; unexpected failure is 500 `SERVER_ERROR` (`identity.effect.ts:255,273`).

| Route | Request | Result | Source |
| --- | --- | --- | --- |
| `POST /v1/sendEmailCode` | `email`, `deviceId?`, `clientType?`, `clientVersion?`, `osVersion?`, `deviceName?` | `existingUser`, `needsInviteCode`, `challengeToken?` | `methods/sendEmailCode.ts:17,26`; `modules/auth/identitySchemas.effect.ts:53,62` |
| `POST /v1/verifyEmailCode` | `email`, `code`, `challengeToken?`, `inviteCode?`, device fields, `timezone?` | `userId`, `token`, `user` (`UserInfo`, includes `pendingSetup`) | `methods/verifyEmailCode.ts:17,32`; `identitySchemas.effect.ts:72,130,148` |
| `POST /v1/sendSmsCode` | `phoneNumber`, device fields | `existingUser`, `needsInviteCode`, `phoneNumber` (E.164), `formattedPhoneNumber` | `methods/sendSmsCode.ts:16,25`; `identitySchemas.effect.ts:21,30` |
| `POST /v1/verifySmsCode` | `phoneNumber`, `code`, `inviteCode?`, device fields, `timezone?` | as verify email | `methods/verifySmsCode.ts:19,33`; `identitySchemas.effect.ts:41` |
| `POST /v1/checkInviteCode` | `inviteCode` (max 64) | `valid` | `methods/checkInviteCode.ts:9,13`; `identitySchemas.effect.ts:85` |
| `POST /v1/logout` | header `Authorization: Bearer <token>`, body `{}` | `{ ok: true }` | `identity.effect.ts:225,524` |
| `GET /v1/auth/provider/start` | query `provider`, `purpose=app`, `callback_scheme`, `code_challenge`, `client_type`, `device_id`, `client_version`, `os_version`, `device_name`, `timezone` | 302 to the provider | `modules/oauth/httpHandlers.ts:1469`; `controllers/oauth.effect.ts:449` |
| callback hand-off | `<scheme>://auth/provider?ticket&code_challenge` or `?error=cancelled\|failed&code_challenge` | | `httpHandlers.ts:2092` (`finishProviderBrowserLogin`), `:239` (`providerBrowserError`) |
| `POST /v1/auth/provider/redeem` | `ticket`, `code_verifier` | `{ ok: true, result: { userId, token, user } }`; 401 `{ error: "invalid_ticket" }`; 429 `{ error: "rate_limited" }` + `retry-after` | `httpHandlers.ts:2060,330`; `modules/auth/provider/service.ts:288` |

Facts that shaped the client:

- `clientType`: unknown values become `api` (`modules/auth/clientType.ts`); `web` is in the enum (`db/schema/sessions.ts:21`), so the client sends `web`. A missing `clientType` is also recorded as `web` (`verifyEmailCode.ts:107`, `verifySmsCode.ts:113`), but we send it explicitly.
- `clientVersion` and `osVersion` are kept only if they are up to four dot-separated numbers; `timezone` only if it is a valid IANA name.
- Rate limits: `FLOOD` with status 420 from the OTP budget and the HTTP limiter (`core/http/middleware.ts:286`), with `retry-after` when the limiter set it; the OAuth module answers 429 `rate_limited`. Both map to `rateLimited`. `retry-after` is in the CORS exposed headers.
- CORS allows `https://inline.chat`, `https://app.inline.chat`, `https://admin.inline.chat`, `https://mcp.inline.chat`, `http://localhost:8001`, `http://localhost:5174`, `http://127.0.0.1:5174` (`core/http/middleware.ts:37`). The dev server port 8001 is included.
- Hosted login (`/v1/auth/login`, `hostedLogin/service.ts`) belongs to the CLI and native protocol keys; the web app does not use it.

## Provider sign-in: what the server must change first

The app flow binds a ticket to a verifier the client keeps (PKCE style), which suits the web. Two server checks keep the web out today:

1. `handleProviderStart` accepts only `client_type` `ios` or `macos` (`httpHandlers.ts:1531`).
2. It returns only to a custom scheme from a fixed list (`service.ts:60`, `httpHandlers.ts:1527`); the hand-off page then opens that scheme.

The web needs `client_type=web` and a return to an https URL on an allow-listed origin (the CORS list is the natural one), ideally as a 303 rather than the script page. This package builds the start URL with a proposed `return_to` parameter (`WEB_RETURN_PARAM`) and expects the return with the same `ticket`, `code_challenge` and `error` query parameters the app callback uses. Both the parameter name and the return need the owner's sign-off; nothing here works around their absence.

The ticket arrives in the return URL's query. It is single use and cannot be redeemed without the verifier, which stays in this tab's `sessionStorage`; the app should strip it from the address bar at once (`stripProviderReturnParams`) and the return page should send `Referrer-Policy: no-referrer`.

## Not verified against a live server

- Everything in "Provider sign-in" above: the start redirect, the return, Apple's `form_post` callback, and redeeming from a browser.
- That a browser POST with `content-type: application/json` passes the CORS preflight on `/v1/*` (the allow-list and allowed headers say it should).
- The `retry-after` header on `FLOOD` answers from the OTP budget (only the HTTP limiter sets it in the code).
- Whether an SMS code survives an `INVITE_CODE_REQUIRED` answer; if the SMS provider spends it, the automatic resubmit fails with `invalidCode` and the user resends.
- Real `navigator.userAgentData` values in each supported browser.

## Tests

`bunx vitest run src/flows` from `web/packages/auth`. A scripted `fetch` answers by route and records each request; a virtual clock drives countdowns and timeouts; sessions go through the real `AuthStore` on in-memory persistence. The model tests assert that no `console` method is called; the API tests assert that codes, tokens and response text never reach an error value.

Note: `bun run typecheck` inside this package fails with TS6059/TS6307 (`rootDir`) on every cross-package import, including the existing `core.test.ts` import of `@inline/ids`. The package tsconfig is not owned here. The web-wide `bun run typecheck` is clean for these files, also with `noUncheckedIndexedAccess`.
