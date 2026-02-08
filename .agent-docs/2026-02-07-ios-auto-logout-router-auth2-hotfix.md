# iOS "Auto Logout" Hotfix (Router + Auth Hydration) (2026-02-07)

From notes (Feb 4, 2026): "TMRW: FIX AUTO LOGOUT on IOS" and "auth 2".

This spec is the smallest safe fix to stop the iOS app from *appearing* to log out when the keychain is temporarily locked/unavailable. It does not require the full Auth2 rewrite.

Related auth planning:
- `/.agent-docs/2026-02-07-auth2-three-plans.md`
- `/.agent-docs/2026-02-07-auth-rewrite-review-plan.md`

## Symptoms (What Users See)

- Cold launch (often from lock screen, notification tap, or after reboot) lands in onboarding as if logged out.
- After unlocking device, credentials are actually present and can hydrate, but UI never returns to main.

## Likely Root Cause (High Confidence)

- `MainViewRouter` decides `.main` vs `.onboarding` once at init time using `Auth.shared.isLoggedIn`.
- When the keychain is locked, `AuthStore` reports `.locked` (or similar) and `isLoggedIn == false` even if valid credentials exist.
- AppDelegate triggers `Auth.shared.refreshFromStorage()` when protected data becomes available, but the router does not observe auth changes, so it stays stuck in onboarding.

## Goals

- Never route to onboarding solely because the keychain is temporarily locked.
- Router should react to auth hydration events and update UI deterministically.
- Avoid destructive side effects (no DB wipes, no clearing local state) on transient keychain failures.

## Non-Goals (For Tomorrow)

- Full Auth2 architecture change across macOS+iOS.
- Multi-account.
- Realtime changes beyond what is needed to fix the symptom.

## Current Code Pointers

- Router snapshot behavior: `apple/InlineIOS/Utils/MainViewRouter.swift`.
- Auth refresh hooks: `apple/InlineIOS/AppDelegate.swift` (protected data available, app activation).
- Auth storage/status: `apple/InlineKit/Sources/Auth/AuthStore.swift`, `apple/InlineKit/Sources/Auth/Auth.swift`, `apple/InlineKit/Sources/Auth/Auth2Types.swift`.

## Proposed Minimal Fix (Tomorrow)

### 1. Make the router reactive to auth changes

Implementation sketch:
- In `MainViewRouter`, subscribe to a published auth status stream (or an `AuthEvent` stream).
- Update `route` when auth becomes authenticated or explicitly unauthenticated.

Important behavior choices:
- Treat `.locked` and `.hydrating` as "unknown". Do not force onboarding.
- Only route to onboarding on explicit `.unauthenticated` or `.reauthRequired` after hydration is complete.
- If we have a `userIdHint` (stored user id) but no token (locked), prefer showing a "Locked" splash rather than onboarding.

### 2. Add a lightweight "Locked/Loading" UI state (optional but improves UX)

Option A (minimal): keep current route until auth resolves.
Pros: almost no UI changes. Cons: might show stale main UI briefly if the user is actually logged out.

Option B (recommended): add a `Route.loading` or `Route.locked` and show a simple screen:
UI: show "Unlock iPhone to continue" if locked; show a spinner if hydrating; include a Retry button calling `Auth.shared.refreshFromStorage()`.

### 3. Validate server-side invalidation doesn't masquerade as keychain-lock

This is not the primary root cause, but confirm:
- Session revocation leads to `.reauthRequired` and then onboarding.
- Token refresh failure leads to reauth flow, not infinite connecting.

Server touchpoints for context:
- `server/src/methods/logout.ts`
- `server/src/db/models/sessions.ts`

## Acceptance Criteria

1. Launch on a locked device no longer permanently shows onboarding if credentials exist.
2. After unlocking, UI transitions to main within one auth refresh cycle.
3. Explicit logout still routes to onboarding reliably.
4. Revoked session routes to onboarding after hydration, with a clear reason (reauth required).

## Test Plan

Manual (most important):
1. On a logged-in device, lock phone.
2. Trigger launch via notification or icon while locked.
3. Confirm app does not show onboarding as a terminal state.
4. Unlock phone, return to app.
5. Confirm router transitions to main without relaunching.

Regression:
1. Logout from settings and confirm onboarding appears.
2. Simulate session revoke (server-side) and confirm reauth path.

Automated (nice to have):
Add a small Swift Testing test for `MainViewRouter` behavior when auth status stream changes.

## Follow-ups (After Hotfix)

If the hotfix works, proceed with Auth2 Plan A:
- Separate Sendable auth handle for actors.
- Stable DB key decoupled from token.
- No destructive DB actions on keychain failure.
