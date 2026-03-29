## Orientation

- Inline is a work chat app
- Key paths: 
  - `server/` Backend (Bun/TS)
  - `apple/` macOS/iOS clients (SwiftUI/UIKit/AppKit)
  - `web/` web app (React/TanStack, not started) 
  - `desktop/` Windows app (Electron, not started)
  - `proto/` protobufs
  - `cli/` client cli (Rust)
  - `packages/mcp/` MCP
  - `packages/openclaw/` OpenClaw plugin
  - `packages/bot-api/` bot API client (HTTP, TypeScript)
  - `packages/sdk/` realtime SDK (WS, TypeScript)
- Shared Swift packages: `apple/InlineKit`, `apple/InlineUI`, `apple/InlineProtocol`; app targets: `apple/InlineIOS`, `apple/InlineXIOS`, `apple/InlineMac`.
- Backend structure: `src/functions`, `src/realtime`, `src/db`.
- Use `bun` for JS/TS tooling (not npm/yarn); keep IDs as `Int64` (`Id`/`ID`) and timestamps in seconds unless API requires ms.
- Production: `https://api.inline.chat` and `https://inline.chat`.

## Critical Rules

- Never revert/discard/reset/clean work unless explicitly asked; ask before one-way deletion commands (`rm`, restore/reset/checkout) unless explicitly requested.
- When the worktree is dirty, continue without stopping for unrelated modified/untracked files. Only stop if unexpected changes appear in the specific file/hunk currently being edited.
- Never read, write or touch `.env` files.

## Multi-agent Safety

- Do not create/apply/drop stashes (including `--autostash`) unless explicitly requested.
- Do not switch branches, create/modify worktrees, or clone this repo for commit/push unless explicitly requested.
- On "push", `git pull --rebase` is allowed; if conflicts occur, stop and ask before resolving.
- Scope commits to your changes unless user asks for "commit all".
- When unrecognized files exist, continue and focus only on relevant files.
- When a file contains unrelated changes, only stage the hunks you changed manually. Do not blindly add files.

## Working Rules

- Use existing logging for production logs (`Log`, `server/src/utils/log.ts`).
- Avoid unsafe Swift/typescript patterns (`Any`/`any` where avoidable, force unwraps, `try!`, unsafe casts).
- Prefer minimizing dependencies and external tooling; do not add new dependencies unless the ongoing maintenance cost is clearly justified.
- Keep commits atomic and scoped; do not amend existing commits.
- Before committing, verify staged files (`git diff --cached --name-only`); prefer `scripts/committer "<msg>" <file...>`.
- Write commit message in lowercase, include scope like this: `macos: fix ...`; scopes include: macos|ios|server|mcp|sdk|cli|openclaw|apple|web|docs|website; for general changes either no prefix or generic ones: eg. chore
- If undoing your own changes in a file with other uncommitted edits, ask first.
- Regenerate protobufs when contracts change (`bun run generate:proto`); run focused `swift build` for touched Swift packages.
- Run focused tests/typechecks for affected areas; add/update tests for new features and regressions.
- Web is WIP. Do not extend requested changes or investigations to `web/` unless explicitly asked.
- New UI work must stay in new UI components; do not modify legacy sidebar/old UI.
- When asked to write a plan or save your investigation, make a file in `.agent-docs/` named `YYYY-MM-DD-title-kebab-case.md`.
- In final handoff/review/push, call out security risks, possible performance regressions, and state production readiness.
- Do just the right amount of engineering, not over engineer, and not under engineer. Simple and elegant solutions are often better than prematuraly complex solutions that go beyond the scope and spec.

## Reminders

- Security (due 2026-05-18): remove legacy email OTP verification fallback without `challengeToken` in `server/src/modules/auth/emailLoginChallenges.ts`.

## Common Commands

- Root: `bun run dev`, `bun run dev:server`, `bun run dev:web`, `bun run typecheck`, `bun run test`, `bun run lint`.
- Protos: `bun run generate:proto`; per-language from `scripts/`: `bun run generate`.
- DB: `cd server && bun run db:migrate`; create migration `bun run db:generate <name>`; inspect `bun run db:studio`.
- Backend tests: `cd server && bun test src/__tests__/modules/...` (`DEBUG=1` for verbose).

## NPM SDK Releases

- Public SDKs: `@inline-chat/protocol`, `@inline-chat/realtime-sdk`, `@inline-chat/bot-api-types`, `@inline-chat/bot-api`.
- Publish only when external runtime behavior/public types change.
- Publish order: `protocol -> realtime-sdk` and `bot-api-types -> bot-api`.
- For publish requests, provide copy-paste commands with package dir and `--otp=<YOUR_OTP_CODE>`.

## CLI

- CLI source: `cli/` (Rust), binary `inline`, release artifacts `inline-cli-<version>-<target>.tar.gz`.
- Release flow: `cd scripts && bun run release:cli -- release`.
- Requires authenticated `gh` and release env vars; script checks duplicate tags.

## Apple (iOS/macOS)

- Prefer new feature work in `apple/InlineIOSUI` and `apple/InlineMacUI`; use legacy targets only when tightly coupled.
- Minimum versions: iOS 18, macOS 15.
- Prefer Swift Testing (`import Testing`, `@Test`, `@Suite`) and Observation (`@Observable`, `@Bindable`).
- Prefer focused package builds/tests (for example `swift test`, `swift build`, swift syntax typecheck) over full `xcodebuild` if fits your scope.
- `AppDatabase` migrations are in `InlineKit/Sources/InlineKit/Database.swift`; append new migrations at the bottom.
- For protobuf blobs in DB, follow the `DraftMessage` typed-model + `ProtocolHelpers` + `DatabaseValueConvertible` pattern.
- Use `Log.scoped`; avoid main-thread heavy work; prefer Swift concurrency and composable views.
- Regenerate Swift protos with `bun run proto:generate-swift` (from `scripts/`) when needed.
- For Apple docs, use `https://sosumi.ai/...` mirror of Developer docs via `curl` instead of web search.
- Liquid Glass: gate with `#available` (iOS/macOS 26+), apply after layout/appearance, wrap related views in `GlassEffectContainer`, use `.interactive()` only for tappable elements.
- macOS releases: `bun run release:macos -- --channel <stable|beta>` or `cd scripts && bun run macos:release-app -- --channel <stable|beta>`.
- TestFlight is deprecated for macOS distribution; Sparkle/DMG direct build is primary.
- send-message and open-chat paths are latency-critical; progressive/message-list changes must avoid regressions and include focused perf validation.

## Backend

- Bun runtime entry: `server/src/index.ts`; logic in `src/functions`, realtime handlers/encoders in `src/realtime`, DB schema/models in `src/db`.
- Add shutdown cleanup in `server/src/lifecycle/gracefulShutdown.ts`.
- Use Drizzle flow for schema changes; do not hand-write migrations.
- User sensitive data must be encrypted.
- Realtime is primary; legacy REST in `src/methods`; auth in `src/utils/authorize.ts`.
- Encrypt user-sensitive data at rest using existing patterns (`src/modules/encryption/encryption2.ts`).
- Backend checks from `server/`: `bun test`, `bun run lint`, `bun run typecheck`.
- User data integrity and correctness must be considered during shutdown, DB downtime, burst requests, and such.

## Web & Docs

- Web stack: TanStack Router + Vite + StyleX/Tailwind; keep SSR-safe patterns.
- Web commands: `cd web && bun run dev|build|typecheck`.
- Prefer existing tokens/utilities over ad-hoc CSS; keep light/dark behavior consistent.
- Docs: routes in `web/src/routes/docs/`, content in `web/src/docs/content/`, nav in `web/src/docs/nav.ts`.
- Docs additions: add markdown page + route + nav entry; keep writing concise and practical.

## Admin

- Admin frontend lives in the separate repo at `~/dev/inline-chat/admin`; backend remains `server/src/controllers/admin.ts`.
- Keep admin endpoints under `/admin` with origin allowlist + admin session cookie.
- Never load remote assets/scripts/styles/fonts in admin UI.
- Require valid admin session for all admin endpoints; use step-up checks for sensitive actions.
- Cookies: `httpOnly`, `secure` in production, `sameSite: "strict"`, scoped to admin API domain.
- Rate-limit auth flows; never expose decrypted secrets to clients.
- Admin metrics should exclude deleted users and bots by default.

## Glossary

### Area nicknames we use to reference different macOS views

- New UI: alternate UI switched by settings toggle with a different `MainWindowController`.
- New sidebar: `apple/InlineMac/Features/Sidebar/MainSidebar.swift`.
- New chat icon: `apple/InlineMac/Views/ChatIcon/SidebarChatIconView.swift`.
- CMD+K menu: `apple/InlineMac/Features/MainWindow/QuickSearchPopover.swift`.
