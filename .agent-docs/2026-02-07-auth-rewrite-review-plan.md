# Auth Rewrite Review (macOS + iOS)

Date: 2026-02-07

## Scope

This review focuses on Apple-platform auth behavior and its interactions with:

- Persistent credential storage (Keychain + UserDefaults)
- Database encryption / DB lifecycle (GRDB + SQLCipher passphrase usage)
- Realtime connectivity (legacy RealtimeAPI + RealtimeV2)
- HTTP clients (Bearer token injection)
- App lifecycle timing (iOS protected data availability, background/foreground, etc.)

Goal: produce a backward-compatible plan for a new Auth module, starting with macOS adoption first.

---

## Current Auth Module (What Exists)

### Implementation

Auth lives in:

- `apple/InlineKit/Sources/Auth/Auth.swift`

Key details:

- `Auth` is an `ObservableObject` wrapper around an `AuthManager` actor.
- Credentials are split across:
  - Keychain: `"token"` via KeychainSwift (`KeychainSwift.get("token")`).
  - UserDefaults: `"<prefix>userId"` as an `NSNumber`.
- "Logged in" is effectively `userId != nil` (token optional).
  - `AuthManager.updateLoginStatus()` publishes `loggedIn = cachedUserId != nil`
  - `Auth.isLoggedIn` tracks that boolean.
- There are explicit mitigations for iOS early/locked launches:
  - In `AuthManager.init()` it schedules `refreshKeychainAfterLaunch()` with a 0.3s delay.
  - iOS app calls `Auth.shared.refreshFromStorage()` on:
    - launch
    - `UIApplication.protectedDataDidBecomeAvailableNotification`
    - `UIApplication.didBecomeActiveNotification`

### Public API used throughout the apps

- Read state:
  - `Auth.shared.isLoggedIn`
  - `Auth.shared.currentUserId`
  - `Auth.shared.getToken()`, `getCurrentUserId()`, `getIsLoggedIn()`
  - `Auth.getCurrentUserId()` (static helper reading from UserDefaults)
- Write state:
  - `Auth.shared.saveCredentials(token:userId:)`
  - `Auth.shared.logOut()`
  - `Auth.shared.refreshFromStorage()`
- Event stream:
  - `Auth.shared.events` (an `AsyncChannel<AuthEvent>`)

---

## Inventory (Where Auth Is Used)

This is a call-site inventory by *dependency* (`import Auth`) and then by key API usage.

### `import Auth` occurrences

```text
apple/InlineShareExtension/ShareState.swift:1
apple/InlineKit/Sources/InlineKit/ApiClient.swift:1
apple/InlineKit/Sources/InlineKit/RealtimeAPI/RealtimeAPI.swift:2
apple/InlineKit/Sources/InlineKit/RealtimeHelpers/RealtimeWrapper.swift:8
apple/InlineKit/Sources/InlineKit/ApplyUpdates.swift:1
apple/InlineKit/Sources/InlineKit/ViewModels/ComposeActions.swift:1
apple/InlineKit/Sources/InlineKit/RealtimeAPI/MsgQueue.swift:1
apple/InlineKit/Sources/RealtimeV2/Client/Client.swift:2
apple/InlineKit/Sources/InlineKit/ViewModels/ChatParticipantsWithMembersViewModel.swift:1
apple/InlineKit/Sources/InlineKit/ViewModels/SpaceMembershipStatusViewModel.swift:1
apple/InlineKit/Tests/InlineKitTests/RealtimeV2/AuthRealtimeIntegrationTests.swift:1
apple/InlineKit/Sources/InlineKit/ViewModels/HomeSearchViewModel.swift:1
apple/InlineKit/Sources/InlineKit/RealtimeAPI/Updates.swift:1
apple/InlineKit/Sources/RealtimeV2/Realtime/Realtime.swift:2
apple/InlineKit/Sources/InlineKit/ViewModels/SpaceInviteSearchViewModel.swift:1
apple/InlineKit/Sources/InlineKit/NotionTaskService.swift:4
apple/InlineKit/Sources/InlineKit/ViewModels/RootData.swift:5
apple/InlineKit/Sources/InlineKit/ViewModels/ParticipantSearchViewModel.swift:1
apple/InlineKit/Sources/InlineKit/ViewModels/HomeViewModel.swift:1
apple/InlineIOS/InlineApp.swift:1
apple/InlineIOS/AppDelegate.swift:1
apple/InlineIOS/Shared/SharedApiClient.swift:1
apple/InlineKit/Sources/InlineKit/Transactions2/DeleteMessageTransaction.swift:1
apple/InlineKit/Sources/InlineKit/Transactions2/SendMessageTransaction.swift:1
apple/InlineKit/Sources/InlineKit/ViewModels/CurrentUserQuery.swift:1
apple/InlineIOS/Utils/MainViewRouter.swift:1
apple/InlineKit/Sources/InlineKit/Transactions2/CreateChatTransaction.swift:1
apple/InlineKit/Sources/RealtimeV2/Connection/ConnectionAdapters.swift:1
apple/InlineKit/Sources/InlineKit/ProtocolHelpers/ProtocolPeer.swift:1
apple/InlineKit/Sources/InlineKit/Transactions2/DeleteReactionTransaction.swift:1
apple/InlineKit/Sources/InlineKit/Analytics.swift:1
apple/InlineKit/Sources/InlineKit/NotionTaskManager.swift:1
apple/InlineKit/Sources/InlineKit/Api.swift:1
apple/InlineKit/Sources/InlineKit/Database.swift:1
apple/InlineKit/Sources/InlineKit/Transactions2/EditMessageTransaction.swift:1
apple/InlineKit/Sources/InlineKit/ProtocolHelpers/ProtocolComposeAction.swift:1
apple/InlineKit/Sources/InlineKit/ProtocolHelpers/ProtocolEntities.swift:1
apple/InlineKit/Sources/InlineKit/ProtocolHelpers/ProtocolDraftMessage.swift:1
apple/InlineKit/Sources/InlineKit/Transactions/Methods/SendMessage.swift:1
apple/InlineKit/Sources/InlineKit/Transactions/Methods/EditMessage.swift:1
apple/InlineKit/Sources/InlineKit/Transactions/Methods/DeleteMessage.swift:1
apple/InlineKit/Sources/InlineKit/Transactions2/AddReactionTransaction.swift:1
apple/InlineKit/Sources/InlineKit/Transactions/Methods/DeleteReaction.swift:1
apple/InlineKit/Sources/InlineKit/Transactions/Methods/AddReaction.swift:1
apple/InlineKit/Sources/InlineKit/Models/User.swift:1
apple/InlineKit/Sources/InlineKit/Utils/PreviewsEnv.swift:3
apple/InlineKit/Sources/InlineKit/Utils/Env.swift:1
apple/InlineMac/Services/LinearIntegrationService.swift:2
apple/InlineIOS/Lists/DirectChatItem.swift:1
apple/InlineMac/Services/DockBadge/DockBadgeService.swift:1
apple/InlineIOS/Features/Compose/ComposeEmbedView.swift:1
apple/InlineMac/Views/Onboarding/EnterCode.swift:1
apple/InlineIOS/Features/Message/UIMessageView.swift:2
apple/InlineIOS/Features/Message/UIMessageView+extensions.swift:1
apple/InlineIOS/Features/Reactions/ReactionsFlowView.swift:1
apple/InlineIOS/Features/Space/SpaceView.swift:1
apple/InlineMac/Views/NotionTask/NotionTaskCoordinator.swift:3
apple/InlineMac/Views/Main/Commands.swift:3
apple/InlineIOS/Features/Chat/MessagesCollectionView.swift:1
apple/InlineIOS/Features/Chat/ChatView+extensions.swift:1
apple/InlineIOS/Features/ChatInfo/ChatInfoView.swift:1
apple/InlineMac/Views/ReactionPicker/MessageReactionOverlay.swift:2
apple/InlineMac/Views/ReactionPicker/ReactionOverlayView.swift:1
apple/InlineIOS/Features/Settings/Settings.swift:1
apple/InlineMac/Toolbar/ChatTitleToolbar.swift:2
apple/InlineMac/Views/SpaceSettings/IntegrationCard.swift:2
apple/InlineIOS/Features/Settings/IntegrationCard.swift:1
apple/InlineMac/Views/SpaceSettings/IntegrationOptionsView.swift:1
apple/InlineMac/Views/SpaceSettings/SpaceIntegrationsView.swift:1
apple/InlineIOS/Features/Settings/IntegrationsView.swift:1
apple/InlineIOS/Features/Settings/LogoutSection.swift:1
apple/InlineMac/Views/Message/MessageView.swift:3
apple/InlineMac/Views/Sidebar/HomeSidebar.swift:1
apple/InlineIOS/Features/Settings/SpaceIntegrationsView.swift:1
apple/InlineIOS/Features/Settings/SpaceSettings.swift:1
apple/InlineMac/Views/Settings/Views/IntegrationsSettingsDetailView.swift:1
apple/InlineIOS/MainViews/HomeView.swift:1
apple/InlineIOS/Auth/PhoneNumberCode.swift:1
apple/InlineIOS/Auth/Code.swift:1
apple/InlineMac/Views/Reactions/ReactionsView.swift:2
apple/InlineMac/Views/Reactions/MessageReactionsView.swift:2
apple/InlineMac/Features/Toolbar/MainToolbar.swift:3
apple/InlineMac/Views/Compose/MentionCompletionMenu.swift:2
apple/InlineMac/App/AppDependencies.swift:1
apple/InlineMac/Features/MainWindow/MainWindowController.swift:2
apple/InlineMac/App/AppDelegate.swift:2
```

### Token usage (`Auth.shared.getToken()`)

```text
apple/InlineKit/Sources/InlineKit/RealtimeAPI/RealtimeAPI.swift:78
apple/InlineKit/Sources/InlineKit/RealtimeAPI/RealtimeAPI.swift:198
apple/InlineKit/Sources/InlineKit/ApiClient.swift:136
apple/InlineKit/Sources/InlineKit/ApiClient.swift:186
apple/InlineKit/Sources/InlineKit/ApiClient.swift:721
apple/InlineKit/Sources/InlineKit/Database.swift:650
apple/InlineKit/Sources/InlineKit/Database.swift:664
apple/InlineIOS/Shared/SharedApiClient.swift:67
apple/InlineIOS/Shared/SharedApiClient.swift:115
apple/InlineIOS/Shared/SharedApiClient.swift:226
apple/InlineShareExtension/ShareState.swift:792
apple/InlineShareExtension/ShareState.swift:795
apple/InlineShareExtension/ShareState.swift:859
apple/InlineShareExtension/ShareState.swift:863
apple/InlineShareExtension/ShareState.swift:970
apple/InlineShareExtension/ShareState.swift:1147
apple/InlineIOS/Features/Settings/IntegrationCard.swift:48
apple/InlineMac/Views/SpaceSettings/IntegrationCard.swift:126
```

### Login state usage (`isLoggedIn` / `getIsLoggedIn` / `$isLoggedIn`)

```text
apple/InlineKit/Sources/InlineKit/RealtimeHelpers/RealtimeWrapper.swift:38
apple/InlineKit/Sources/InlineKit/RealtimeHelpers/RealtimeWrapper.swift:44
apple/InlineKit/Sources/InlineKit/RealtimeHelpers/RealtimeWrapper.swift:119
apple/InlineKit/Sources/InlineKit/RealtimeHelpers/RealtimeWrapper.swift:121
apple/InlineIOS/AppDelegate.swift:68
apple/InlineIOS/Utils/MainViewRouter.swift:16
apple/InlineIOS/Utils/MainViewRouter.swift:17
apple/InlineKit/Sources/InlineKit/Analytics.swift:36
apple/InlineMac/Features/MainWindow/MainWindowController.swift:847
apple/InlineMac/App/AppDelegate.swift:81
```

### Credential write (`saveCredentials`)

```text
apple/InlineIOS/Auth/Code.swift:96
apple/InlineIOS/Auth/PhoneNumberCode.swift:96
apple/InlineMac/Views/Onboarding/EnterCode.swift:112
```

### Storage refresh (`refreshFromStorage`)

```text
apple/InlineIOS/AppDelegate.swift:34
apple/InlineIOS/AppDelegate.swift:45
apple/InlineIOS/AppDelegate.swift:55
apple/InlineShareExtension/ShareState.swift:793
apple/InlineShareExtension/ShareState.swift:860
apple/InlineShareExtension/ShareState.swift:971
apple/InlineKit/Sources/RealtimeV2/Client/Client.swift:171
```

### Logout (`logOut`)

```text
apple/InlineIOS/Features/Settings/LogoutSection.swift:88
apple/InlineMac/App/AppDelegate.swift:431
```

### Current-user access patterns

Uses `Auth.shared.getCurrentUserId()` in many places (UI and services). Example list:

```text
apple/InlineKit/Sources/InlineKit/NotionTaskService.swift:16
apple/InlineKit/Sources/InlineKit/ViewModels/ComposeActions.swift:287
apple/InlineKit/Sources/InlineKit/RealtimeAPI/Updates.swift:610
apple/InlineKit/Sources/InlineKit/Analytics.swift:46
apple/InlineMac/Services/LinearIntegrationService.swift:34
apple/InlineIOS/Features/Chat/MessagesCollectionView.swift:2081
... (see `rg -n "Auth\\.shared\\.getCurrentUserId\\(" apple`)
```

Also direct property usage exists:

- `Auth.shared.currentUserId` (including force unwraps):
  - `apple/InlineKit/Sources/InlineKit/Transactions2/SendMessageTransaction.swift:170` (force unwrap)

---

## Current Workflows (How It’s Wired)

### App launch hydration

iOS:

- `apple/InlineIOS/AppDelegate.swift` calls `Auth.shared.refreshFromStorage()`:
  - once on launch
  - again on `protectedDataDidBecomeAvailable`
  - again on `didBecomeActive`
- Routing uses `MainViewRouter`:
  - `apple/InlineIOS/Utils/MainViewRouter.swift` routes to `.main` when `Auth.shared.getIsLoggedIn() == true`

macOS:

- No explicit refresh hook like iOS; relies on `AuthManager.init()` immediate read + delayed retry.

### Login (credential acquisition)

iOS:

- `apple/InlineIOS/Auth/Code.swift` and `apple/InlineIOS/Auth/PhoneNumberCode.swift`:
  1. `auth.saveCredentials(token:userId:)`
  2. `AppDatabase.authenticated()` (rotates DB passphrase to token)
  3. saves `user` into DB
  4. navigates to main

macOS:

- `apple/InlineMac/Views/Onboarding/EnterCode.swift` mirrors the same idea.

### Logout

iOS:

- `apple/InlineIOS/Features/Settings/LogoutSection.swift`:
  1. tries server `logout` (w/ a 2s timeout race)
  2. `Analytics.logout()`
  3. `Auth.shared.logOut()`
  4. `AppDatabase.loggedOut()` (clears DB + rotates passphrase back to `"123"`)
  5. clears transactions and local UI state

macOS:

- `apple/InlineMac/App/AppDelegate.swift`:
  - order differs slightly (DB cleared before creds).
  - also calls `dependencies.realtime.loggedOut()`.

### Realtime

There are two systems currently:

Legacy (InlineKit):

- `apple/InlineKit/Sources/InlineKit/RealtimeHelpers/RealtimeWrapper.swift`
- `apple/InlineKit/Sources/InlineKit/RealtimeAPI/RealtimeAPI.swift`
  - `start()` hard-requires `Auth.shared.getToken() != nil`
  - `authenticate()` sends connection init and **logs the token** (debug log leak)

RealtimeV2:

- Handshake token injection is in `apple/InlineKit/Sources/RealtimeV2/Client/Client.swift` (`ProtocolSession.sendConnectionInit()`):
  - if `auth.getToken()` is `nil`, it calls `await auth.refreshFromStorage()` once, then retries
  - if token still `nil` -> `authFailed` event
- Auth connection gating is via `AuthConnectionAdapter`:
  - `apple/InlineKit/Sources/RealtimeV2/Connection/ConnectionAdapters.swift`
  - listens to `Auth.shared.events` for `.login`/`.logout`

Important: `Auth.isLoggedIn` can be true even if token is nil (userId exists but keychain temporarily unavailable).

---

## DB Integration (How Auth Affects GRDB)

Core file:

- `apple/InlineKit/Sources/InlineKit/Database.swift`

Mechanism:

- DB passphrase is chosen on open:
  - if `Auth.shared.getToken()` exists -> `db.usePassphrase(token)`
  - else -> `db.usePassphrase("123")`
- On login: `AppDatabase.authenticated()` calls `AppDatabase.changePassphrase(token)` to rotate to token.
- On logout: `AppDatabase.loggedOut()` clears DB and rotates passphrase back to `"123"`.

Critical behavior:

- In `AppDatabase.makeShared()`, on any open failure it does aggressive recovery:
  - if error contains `"SQLite error 26"` (SQLCipher key mismatch) it **deletes the DB file and recreates**
  - also deletes DB for other cases (foreign key violation, malformed DB, and even as last resort)

This means: *a transient “token unavailable at launch” can look like a wrong passphrase and cause a destructive DB delete*.

---

## Findings (Why It’s Complicated / Unreliable)

### 1) Auth “logged in” is not equal to “has token”

Auth treats `userId != nil` as logged in:

- UI routes to main, analytics tries to identify user, realtime wrappers try to start, etc.
- Yet token can be `nil` on early/locked launches (especially iOS).

Auth already logs this condition:

- `AUTH_TOKEN_MISSING_FOR_LOGGED_IN_USER phase=init`
- `AUTH_TOKEN_MISSING_FOR_LOGGED_IN_USER phase=reload`
- `AUTH_LOGGED_IN_WITHOUT_CREDENTIALS ...`

### 2) DB encryption key is coupled to auth token (and rotates)

Using the auth token as a SQLCipher passphrase creates multiple failure modes:

- Token unreadable temporarily -> DB open uses `"123"` -> passphrase mismatch -> `"SQLite error 26"` -> DB deleted.
- Token can change (login on another device / server invalidation / future refresh strategy) -> DB becomes unreadable.

### 3) Destructive “recovery” deletes local DB on passphrase errors

`AppDatabase.makeShared()` treats key mismatch as “token lost” and recreates the DB file. That’s a direct path to:

- local data loss
- “unexpected logout” user perception
- state inconsistencies if auth rehydrates later

### 4) Sensitive token leaks in DEBUG logs

- `apple/InlineKit/Sources/InlineKit/Database.swift` logs `"Database passphrase: \(token)"` in `#if DEBUG`.
- `apple/InlineKit/Sources/InlineKit/RealtimeAPI/RealtimeAPI.swift` logs `"sending connection init with token \(token)"`.

### 5) Concurrency / correctness footguns

- `Auth.shared.events` is a public `AsyncChannel`, so any consumer can `send()` events (tests currently do).
- `Auth.logOut()` mutates published vars on `@MainActor` *without* taking the internal lock (other paths do).
- Force unwrap call sites:
  - `apple/InlineKit/Sources/InlineKit/Transactions2/SendMessageTransaction.swift:170`
  - `apple/InlineKit/Sources/InlineKit/Transactions/Methods/SendMessage.swift:155`
  - `apple/InlineKit/Sources/InlineKit/Transactions2/AddReactionTransaction.swift:43`

---

## Target Properties For The New Auth Module

Hard requirements:

- No unexpected data loss on launch.
- No “looks logged in” state unless credentials are actually usable.
- Separate concerns:
  - network auth token lifecycle (server concern)
  - local DB encryption key lifecycle (device concern)
- Clear state machine + single source of truth.
- Backward compatibility:
  - read legacy stored token/userId
  - keep existing call sites compiling initially
  - gradual adoption (macOS first)

---

## Proposed Plan (Backward-Compatible, macOS First)

### Phase 0: Stabilize semantics + add instrumentation (no behavioral break yet)

- Add an internal “credential readiness” concept:
  - `credentialsAvailable = (token != nil && userId != nil)`
- Emit structured logs/metrics when:
  - `isLoggedIn == true` but `credentialsAvailable == false`
  - DB open fails with key mismatch
  - realtime handshake fails due to missing token

(This guides rollout and prevents silent regressions.)

### Phase 1: New Auth storage model (keep `Auth` API surface)

Implement a new internal storage layer under `Auth`:

- Store credentials as a single record in Keychain, not split across Keychain+UserDefaults.
  - Example: key `"auth.credentials.v2"` value = JSON/Plist encoding of `{ userId, token, createdAt }`.
- Migration on read:
  - if v2 record exists -> use it
  - else read legacy:
    - token from `"token"`
    - userId from `UserDefaults.<prefix>userId`
  - after successful legacy read, write v2 record and optionally remove legacy pieces (controlled rollout).
- Replace KeychainSwift (optional but recommended) with a small Security.framework wrapper that returns status codes:
  - distinguishes “item not found” vs “interaction not allowed / protected data” vs other errors.

New public additions (keep old members working):

- `Auth.shared.status: AuthStatus` where:
  - `.hydrating`
  - `.unauthenticated`
  - `.authenticated(Credentials)`
  - `.locked` (iOS-only, if we can detect “protected data unavailable”)
- `Auth.shared.credentialsAvailable: Bool`
- Make `events` read-only for external consumers (expose `AsyncStream<AuthEvent>`), keep internal sender.

macOS-first adoption:

- Update macOS routing + realtime start to use `credentialsAvailable` (not `isLoggedIn`).
- Leave iOS routing untouched until Phase 2.

### Phase 2: Decouple DB encryption from token

Introduce a stable database key stored in keychain:

- Key: `"db.key.v1"` (random 32+ bytes, base64 string or Data)
- DB open uses dbKey, not auth token.
- Migration strategy for existing installs:
  - Attempt open in order:
    1) dbKey (new)
    2) token (legacy)
    3) `"123"` (legacy logged-out DB)
  - If opened with token or `"123"`:
    - generate dbKey if missing
    - rotate passphrase to dbKey (one-time migration)
- Absolutely remove “delete DB file on key mismatch” behavior:
  - If all keys fail: treat as locked/unavailable/corrupted; do not erase automatically.
  - Provide explicit “Reset Local Data” action for the user (or a controlled recovery path).

macOS-first adoption:

- Implement dbKey + migration on macOS first (fewer protected-data constraints).

### Phase 3: Align realtime + network with credential readiness

- RealtimeV2:
  - only set `authAvailable=true` when credentials are actually available (token present).
  - remove initial constraint `authAvailable: auth.getIsLoggedIn() == true || auth.getToken() != nil` and require token.
- Legacy realtime wrapper:
  - stop logging token
  - gate `start()` on credentialsAvailable (and don’t rely on delayed `DispatchQueue.main.asyncAfter` for correctness)

### Phase 4: iOS lifecycle correctness

iOS should treat “no token while logged in” as a transient state, not logout:

- When protected data is unavailable:
  - status becomes `.locked` (or remains `.hydrating`) and the UI can show a minimal “Unlock to continue” screen instead of onboarding.
- Ensure DB is not opened/rotated/deleted based on a transient nil token.

### Phase 5: Cleanup + deprecations

- Remove:
  - token logging in DEBUG paths
  - force unwrap auth usage in transactions
  - legacy storage keys after a safe window
- Consider deprecating `isLoggedIn` in favor of `status`/`credentialsAvailable`.

---

## Concrete “First PR” Suggestion (macOS-first)

1. Add `credentialsAvailable` and use it to gate macOS realtime connect + initial routing (instead of `isLoggedIn`).
2. Stop DB deletion on `"SQLite error 26"` immediately (replace with non-destructive fallback + explicit recovery).
3. Remove token logging in:
   - `apple/InlineKit/Sources/InlineKit/Database.swift`
   - `apple/InlineKit/Sources/InlineKit/RealtimeAPI/RealtimeAPI.swift`

This alone should reduce unexpected DB wipes and “logged in but broken” states on macOS.

---

## Checks To Run During Rewrite

- `cd apple/InlineKit && swift test`
- `cd apple/InlineKit && swift build`
- `cd apple/InlineUI && swift build` (if any auth env plumbing changes touch UI packages)

Not recommended (per repo rules) unless Mo requests:

- full `xcodebuild` for apps

