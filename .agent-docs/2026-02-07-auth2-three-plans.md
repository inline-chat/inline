# Auth2: 3 Alternative Plans (Swift 6, Keychain, DB, Realtime)

Date: 2026-02-07

## Goals / Constraints

- No unexpected data loss (no “DB wipe because token read failed”).
- Keychain failures must be modeled explicitly (locked / interactionNotAllowed / access-group mismatch / transient nil).
- Swift 6 concurrency correctness: avoid leaking non-Sendable `ObservableObject` into actors and `@Sendable` tasks.
- Ergonomics: clear “ready vs locked vs logged out” states; easy to use in UI + realtime + REST; minimal footguns.
- Backward compatible storage:
  - read existing `token` keychain item + `userId` UserDefaults key
  - tolerate legacy macOS keychain items saved without access-group
- Rollout: start with macOS adoption, then iOS; keep old call sites working during transition.

---

## Plan A (Recommended): Incremental Core + Sendable Handle + DB-Key Decoupling

### Summary

- Keep `Auth.shared` API surface (and SwiftUI environment) but replace the internals with:
  - a single “AuthStore” actor (truth)
  - a thread-safe snapshot cache for synchronous reads (`token`, `userId`, `status`)
  - a `Sendable` `AuthHandle` that actors (RealtimeV2) depend on, not the `ObservableObject`
- Introduce a stable random **database key** in keychain (`db.key.v1`) and migrate DB encryption away from token/`"123"`.
- Make DB initialization **non-destructive** on “wrong key” errors: never delete the persistent DB because auth/keychain is unavailable.

### Pros

- Smallest blast radius: minimal call site changes (mostly RealtimeV2 init + DB init).
- Solves the most damaging problems immediately (DB wipes, “logged in but no token”, access-group migration).
- Allows macOS-first changes without forcing a full iOS UI refactor.
- Swift 6 correctness achievable: actors depend on `AuthHandle` (Sendable), not `Auth` (ObservableObject).

### Cons

- Still uses singletons; not “pure DI”.
- Some legacy code paths (legacy realtime wrapper, old routing) may still need staged cleanup.

### When to use

- You want real fixes quickly with controlled rollout and low risk.

---

## Plan B: App Session Orchestrator (Auth2 + DatabaseController + RealtimeCoordinator)

### Summary

- Introduce a new “AppSession” actor that owns:
  - `Auth2` actor (storage + state machine)
  - `DatabaseController` (lazy open, migrations, swap/reopen when locked -> unlocked)
  - `RealtimeCoordinator` (connect only when both auth + DB ready)
- Replace global singletons in UI with injected dependencies (`Environment`, init injection).

### Pros

- Clean architecture; correctness is easier to reason about.
- Natural place to represent “loading/locked” state: UI can be driven by one state machine.
- Makes it easier to fully remove legacy realtime + legacy auth assumptions.

### Cons

- Big refactor: touches lots of files on both macOS + iOS; more regression risk.
- Requires rewriting UI routing and many data managers to accept injected DB/auth.

### When to use

- You’re willing to invest in a larger foundational rewrite and can budget for iteration/testing time.

---

## Plan C: Multi-Account Session Store + Per-Account DB

### Summary

- Extend Plan B to support multiple accounts:
  - multiple credential records in keychain
  - per-account DB key + per-account DB file directory
  - explicit account switching + UI support

### Pros

- Future-proofs the platform for multi-account.
- Clarifies identity boundaries; reduces “global state” issues.

### Cons

- Overkill for current problem; largest scope and risk.
- Requires lots of UI + syncing changes; long tail of edge cases.

### When to use

- Only if multi-account is an explicit near-term product requirement.

---

## Recommendation

Pick **Plan A** now:

- It addresses the highest-severity issues immediately:
  - token vs userId inconsistency
  - keychain “locked” state
  - destructive DB deletion on key mismatch
  - Swift 6 concurrency unsafety from passing `ObservableObject` into actors
- It sets you up to evolve into Plan B later, without wasting work:
  - `AuthHandle` and stable DB-key are reusable.

