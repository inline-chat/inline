## Orientation

- Inline is a multi-client work chat app; repo at https://github.com/inline-chat/inline with backend (Bun/TS), Apple clients (SwiftUI/UIKit/AppKit), web (React/TanStack), and shared protobufs in `proto/`.
- Primary shared Swift packages live in `apple/InlineKit`, `InlineUI`, `InlineProtocol`, plus app targets under `apple/InlineIOS` and `apple/InlineMac`.
- Backend lives in `server/` (Bun runtime, Drizzle + Postgres, Elysia REST + WebSocket RPC) with protocol encoders/handlers split across `src/functions`, `src/realtime`, `src/db`.
- Web client in `web/` uses React Router v7, Tailwind + StyleX, Vite.
- Use `bun` for JS/TS tooling (not npm/yarn); keep IDs as `Int64` (Swift `Id`, proto `ID`), timestamps in seconds unless host API needs ms.
- Production URLs: API at `https://api.inline.chat`, web at `https://inline.chat`.

## Critical Rules

- Never revert a file; never discard a change yourself; never undo work on any file by destructive shell commands or clearing files unless explicitly given permission to do so. Otherwise keep a copy or comment out, do not do irreversible deletions especially to files you have not made those changes to.
- Never discard/restore/reset all files (or “start over”) without asking for explicit permission first (e.g., avoid `git restore .`, `git checkout .`, `git reset --hard`).

## Working Rules

- Do requested work only; mirror existing patterns; add comments only when clarifying non-obvious logic; never touch `.env` or delete others’ work.
- Avoid destructive git commands; keep commits atomic and scoped; do not amend existing commits; quote paths with special chars; check status before committing.
- If you need to undo your work in a file, first check whether that file has any other uncommitted changes in git; if it does, ask for explicit permission before undoing anything in that file.
- Commit style: platform-prefixed, lowercase, scoped messages (e.g., `apple: fix sync`); add a brief description or bullets when extra context is needed.
- Prefer `rg` for search; keep edits ASCII; strip debug prints; use logging utilities (`Log` in Swift, `server/src/utils/log.ts`).
- Avoid `Any`/`any`, force unwraps (`!`), `try!`, forced/unsafe casts (e.g. `as!`), and other unsafe patterns that can crash or trigger runtime fatal errors; use safe alternatives whenever possible unless there is no other way.
- Regenerate protobufs after proto changes with `bun run generate:proto` (or per-language commands in `scripts/`); rebuild Swift `InlineProtocol` target if needed.
- If changes touch a Swift package, run a focused `swift build` for that package before asking the user to build.
- When adding new `AppDatabase` migrations in `InlineKit/Sources/InlineKit/Database.swift`, append them at the bottom of the migration list (order matters; newest last).
- Default test timeout 25s; run focused tests from relevant package roots; avoid heavy/unapproved tooling (e.g., do not run `xcodebuild` full apps).
- Run tests when a feature is finished or when asked to write tests; follow up with typecheck for TS when relevant.
- NEVER revert, discard, reset unrelated changes to the work you are doing or files you are touching. User may be working on other files simultaneously. NEVER clean files you have not edited, created or moved. When asked to commit, just commit your changes.
- When working on New UI features, do not modify previous UI files (legacy sidebar/old UI). Keep changes scoped to new UI components.
- For larger tasks, write a comprehensive plan first; if there are multiple design choices or any room for ambiguity, ask clarifying questions; when implementing a large plan (more than a few tasks) save the plan in a markdown file in .agent-docs/ and update it after each task before starting next one.
- When adding markdown files in `.agent-docs/`, prefix the filename with the date in `YYYY-MM-DD-title-kebab-case.md` format (example: `2026-01-02-title-kebab-case.md`).
- After you're done, write a short note on whether it's ready for production or anything is of concern for further review/tests.

## Common Commands

- Root scripts: `bun run dev`/`dev:server` (backend), `bun run dev:web`, `bun run typecheck`, `bun run test` (backend), `bun run lint`.
- Protos: from root `bun run generate:proto`; from `scripts/` use `bun run generate` for per-language.
- Database: `cd server && bun run db:migrate`; generate migrations via `bun run db:generate <name>`; inspect with `bun run db:studio`.
- Targeted backend tests: `cd server && bun test src/__tests__/modules/...`; enable debug via `DEBUG=1`.
- Keep commands inside package dirs when running Swift or Bun tooling to avoid path issues.

## CLI

- Source lives in `cli/` (Rust); binary name is `inline`, release artifacts are `inline-cli-<version>-<target>.tar.gz`.
- Release flow: `cd scripts && bun run release:cli -- release` (builds, packages, uploads, tags `cli-v<version>`, creates GitHub release).
- Requires `gh` authenticated and release env vars for R2 uploads; release script checks for duplicate tags before starting.
- Homebrew cask lives in `inline-chat/homebrew-inline` (repo) and pulls from GitHub Releases.

## Apple (iOS/macOS)

- Swift 6 targets in `apple/InlineKit` (shared logic/DB/networking), `InlineUI` (shared UI), app targets `InlineIOS` (SwiftUI+UIKit) and `InlineMac` (AppKit+SwiftUI); share protocol via generated `InlineProtocol`.
- iOS minimum supported version is 18; macOS min version is 15.
- Prefer Swift Testing for Apple code (`import Testing`, `@Test`, `@Suite`) instead of XCTest.
- Do not build full apps with `xcodebuild`; ask user to run. Allowed: package tests and builds via e.g. `cd apple/InlineKit && swift test` and `cd apple/InlineUI && swift build`.
- Database migrations live in `InlineKit/Sources/InlineKit/Database.swift`; models in `Sources/InlineKit/Models/`; transactions in `Sources/InlineKit/Transactions/Methods/`.
- Logging via `Log.scoped`; avoid main-thread heavy work; use Swift concurrency; prefer small composable views/modifiers.
- Regenerate Swift protos with `bun run proto:generate-swift` (scripts) then rebuild `InlineProtocol` target in Xcode if necessary.
- Search for relevant Apple developer documentations for key APIs you want to use. To load the link, replace https://developer.apple.com/ with https://sosumi.ai/ to give you compact markdown versions of the same docs. Read the links via CURL, do not use web search for that. Read the URL.
- Helpers: Liquid Glass (SwiftUI) — gate with `#available` (iOS/macOS 26+); apply `glassEffect` after layout/appearance; wrap multiple glass views in `GlassEffectContainer`; use `.interactive()` only for tappable elements.
- Beta release for macOS happens with `bash scripts/macos/release-local.sh --channel beta` or a GitHub action.

## Backend

- Runs on Bun (not Node); entry at `server/src/index.ts`; business logic in `src/functions`, RPC handlers in `src/realtime/handlers`, encoders in `src/realtime/encoders`, schema in `src/db/schema`, models in `src/db/models`.
- Use Drizzle for DB; follow add-table flow: create schema, export in `schema/index.ts`, `bun run db:generate <migration>`, migrate, then add model/tests. Never hand-write migrations.
- REST endpoints (legacy) in `src/methods`; realtime is primary; keep auth via `src/utils/authorize.ts`; secure data via `src/modules/encryption/encryption2.ts`.
- Testing/linting/typecheck from `server/`: `bun test`, `bun run lint`, `bun run typecheck`; set `DEBUG=1` for verbose output.
- External services: APN (`src/libs/apn.ts`), R2 storage (`src/libs/r2.ts`), AI (Anthropic/OpenAI), Linear/Notion/Loom integrations; ensure env vars handled via `src/env.ts`.

## Web

- TanStack router app under `web/app`; styling uses Tailwind 4 + StyleX; animations via Framer Motion/Motion; built with Vite.
- Scripts from `web/`: `bun run dev`, `bun run build`, `bun run typecheck`; ensure Bun runtime available.
- Keep routing with TanStack conventions; prefer StyleX/Tailwind utilities over ad-hoc CSS; maintain SSR compatibility (Nitro).
- When touching protocol-bound code, regenerate protos first (`bun run generate:proto`) to keep TS definitions synced.
- Use StyleX variables for colors, fontSizes, fonts, radiuses, etc; Follow naming of Apple system variables for theming; Support dark and light theme; Check Theme for macOS/iOS if you are unsure about a variable;

## Admin

- Admin frontend lives in `admin/` (Vite + TanStack Router file-based routing). Routes are under `admin/src/routes`, pages under `admin/src/pages`, layout under `admin/src/components/layout/app-layout.tsx`.
- Admin backend lives in `server/src/controllers/admin.ts`; keep new endpoints behind `/admin` with origin allowlist + admin session cookie.
- Do not load remote assets/scripts/styles/fonts in admin UI. Use local assets from `admin/public` only.
- Always require a valid admin session (cookie) for admin endpoints. Use step-up checks for sensitive actions (user updates, role changes, exports).
- Keep admin cookies `httpOnly`, `secure` in prod, `sameSite: "strict"`, and scoped to the admin API domain.
- Rate-limit or lockout admin auth flows (password + email code) when adding new login/verification paths.
- Never send decrypted secrets to the client. For session/device data, limit to explicitly needed fields and redact when possible.
- Maintain separate admin metrics endpoints for UI. For new metrics, exclude deleted users and bots by default.

## Glossary

### Area nicknames we use to reference to different files/views on macOS

- New UI: Refers to an alternative all-new UI that starts with a new MainWindowController that is swapped based on a toggle in the settings.
- New sidebar: Refers to MainSidebar.swift that is used in new sidebar
- New chat icon: `apple/InlineMac/Views/ChatIcon/SidebarChatIconView.swift` a cleaner version of chat icon used in new UI
- CMD+K menu: `apple/InlineMac/Features/MainWindow/QuickSearchPopover.swift`
