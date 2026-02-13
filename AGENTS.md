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
- While you are working, if you notice unexpected changes that you didn't make in files you were working on, stop immediately. Otherwise if the changes are in different files, IGNORE those changes and focus on files you DID touch. Don't revert, discard, or restore them: they may be part of another agent's work.

## Multi-agent safety

- Multi-agent safety: do not create/apply/drop git stash entries unless explicitly requested (this includes `git pull --rebase --autostash`). Assume other agents may be working; keep unrelated WIP untouched and avoid cross-cutting state changes.
- Multi-agent safety: when the user says "push", you may `git pull --rebase` to integrate latest changes (never discard other agents' work; if a rebase hits conflicts, stop and ask before resolving). When the user says "commit", scope to your changes only. When the user says "commit all", commit everything in grouped chunks.
- Multi-agent safety: do not create/remove/modify git worktree checkouts (or edit `.worktrees/*`) unless explicitly requested.
- Multi-agent safety: never clone this repo to commit/push changes from outside the main GitHub worktree unless the user explicitly confirms first.
- Multi-agent safety: do not switch branches / check out a different branch unless explicitly requested.
- Multi-agent safety: running multiple agents is OK as long as each agent has its own session.
- Multi-agent safety: when you see unrecognized files, keep going; focus on your changes and commit only those.
- Multi-agent safety: focus reports on your edits; avoid guard-rail disclaimers unless truly blocked; when multiple agents touch the same file, continue if safe; end with a brief “other files present” note only if relevant.

## Working Rules

- Do requested work only; mirror existing patterns; add comments only when clarifying non-obvious logic; never touch `.env` or delete others’ work.
- When answering questions, respond with high-confidence answers only: verify in code; do not guess.
- Bug investigations: read source code of relevant npm dependencies and all related local code before concluding; aim for high-confidence root cause.
- Code style: add brief comments for tricky logic; aim to keep files under ~700 LOC (guideline only, not a hard guardrail). Split/refactor when it improves clarity or testability.
- Avoid destructive git commands; keep commits atomic and scoped; do not amend existing commits; quote paths with special chars; check status before committing.
- Before committing, verify the staging area contains only the intended files (`git diff --cached --name-only`).
- When parking large WIP changes, a git worktree under `../inline-worktrees/` (sibling of this repo) can help keep changes isolated (only create/modify worktrees when explicitly requested).
- If you need to undo your work in a file, first check whether that file has any other uncommitted changes in git; if it does, ask for explicit permission before undoing anything in that file.
- Commit style: platform-prefixed, lowercase, scoped messages (e.g., `apple: fix sync`); add a brief description or bullets when extra context is needed.
- Prefer `rg` for search; keep edits ASCII; strip debug prints; use logging utilities (`Log` in Swift, `server/src/utils/log.ts`).
- Avoid `Any`/`any`, force unwraps (`!`), `try!`, forced/unsafe casts (e.g. `as!`), and other unsafe patterns that can crash or trigger runtime fatal errors; use safe alternatives whenever possible unless there is no other way.
- Regenerate protobufs after proto changes with `bun run generate:proto` (or per-language commands in `scripts/`); rebuild Swift `InlineProtocol` target if needed.
- If changes touch a Swift package, run a focused `swift build` for that package before asking the user to build.
- When adding new `AppDatabase` migrations in `InlineKit/Sources/InlineKit/Database.swift`, append them at the bottom of the migration list (order matters; newest last).
- Default test timeout 25s; run focused tests from relevant package roots; avoid heavy/unapproved tooling (e.g., do not run `xcodebuild` full apps).
- Run tests when a feature is finished or when asked to write tests; follow up with typecheck for TS when relevant.
- Follow the Multi-agent safety rules: never revert/discard/reset/clean unrelated changes or files you have not edited, created, or moved.
- When working on New UI features, do not modify previous UI files (legacy sidebar/old UI). Keep changes scoped to new UI components.
- For larger tasks, write a comprehensive plan first; if there are multiple design choices or any room for ambiguity, ask clarifying questions; when implementing a large plan (more than a few tasks) save the plan in a markdown file in .agent-docs/ and update it after each task before starting next one.
- When adding markdown files in `.agent-docs/`, prefix the filename with the date in `YYYY-MM-DD-title-kebab-case.md` format (example: `2026-01-02-title-kebab-case.md`).
- After you're done, write a short note on whether it's ready for production or anything is of concern for further review/tests.

## Common Commands

- Root scripts: `bun run dev`/`dev:server` (backend), `bun run dev:web`, `bun run typecheck`, `bun run test` (backend), `bun run lint`.
- Protos: from root `bun run generate:proto`; from `scripts/` use `bun run generate` for per-language.
- Database: `cd server && bun run db:migrate`; generate migrations via `bun run db:generate <name>`; inspect with `bun run db:studio`.
- Targeted backend tests: `cd server && bun test src/__tests__/modules/...`; enable debug via `DEBUG=1`.
- Create commits with `scripts/committer "<msg>" <file...>`; avoid manual `git add`/`git commit` so staging stays scoped.
- Keep commands inside package dirs when running Swift or Bun tooling to avoid path issues.

## NPM SDK Releases

- Public SDK packages for realtime + bot API are: `@inline-chat/protocol`, `@inline-chat/realtime-sdk`, `@inline-chat/bot-api-types`, `@inline-chat/bot-api`.
- Publish these when external SDK consumers need new runtime behavior or new/updated public types (server-only internal changes do not require publish).
- Publish in dependency order: `protocol` -> `realtime-sdk`, and `bot-api-types` -> `bot-api`; if both tracks changed, publish both base packages before dependents.
- Use prerelease channel for rollout testing: `npm publish --access public --tag alpha` from each package directory.
- If npm 2FA is enabled, include OTP on each publish command: `npm publish --access public --tag alpha --otp=<code>`.

## CLI

- Source lives in `cli/` (Rust); binary name is `inline`, release artifacts are `inline-cli-<version>-<target>.tar.gz`.
- Release flow: `cd scripts && bun run release:cli -- release` (builds, packages, uploads, tags `cli-v<version>`, creates GitHub release).
- Requires `gh` authenticated and release env vars for R2 uploads; release script checks for duplicate tags before starting.
- Homebrew cask lives in `inline-chat/homebrew-inline` (repo) and pulls from GitHub Releases.

## Apple (iOS/macOS)

- Swift 6 targets in `apple/InlineKit` (shared logic/DB/networking), `InlineUI` (shared UI), app targets `InlineIOS` (SwiftUI+UIKit) and `InlineMac` (AppKit+SwiftUI); share protocol via generated `InlineProtocol`.
- iOS minimum supported version is 18; macOS min version is 15.
- Prefer Swift Testing for Apple code (`import Testing`, `@Test`, `@Suite`) instead of XCTest.
- SwiftUI state management (iOS/macOS): prefer the Observation framework (`@Observable`, `@Bindable`) over `ObservableObject`/`@StateObject`; don’t introduce new `ObservableObject` unless required for compatibility, and migrate existing usages when touching related code.
- Do not build full apps with `xcodebuild`; ask user to run. Allowed: package tests and builds via e.g. `cd apple/InlineKit && swift test` and `cd apple/InlineUI && swift build`.
- Database migrations live in `InlineKit/Sources/InlineKit/Database.swift`; models in `Sources/InlineKit/Models/`; transactions in `Sources/InlineKit/Transactions/Methods/`.
- For embedded protobuf fields stored in local DB blobs, follow the `DraftMessage` pattern: keep typed model properties (not raw `Data`), add matching `ProtocolHelpers` extensions with `Codable` + `DatabaseValueConvertible` using `serializedData()`/`serializedBytes`, and reuse this pattern for future features for consistent type safety.
- Logging via `Log.scoped`; avoid main-thread heavy work; use Swift concurrency; prefer small composable views/modifiers.
- Regenerate Swift protos with `bun run proto:generate-swift` (scripts) then rebuild `InlineProtocol` target in Xcode if necessary.
- Search for relevant Apple developer documentations for key APIs you want to use. To load the link, replace https://developer.apple.com/ with https://sosumi.ai/ to give you compact markdown versions of the same docs. Read the links via CURL, do not use web search for that. Read the URL.
- Helpers: Liquid Glass (SwiftUI) — gate with `#available` (iOS/macOS 26+); apply `glassEffect` after layout/appearance; wrap multiple glass views in `GlassEffectContainer`; use `.interactive()` only for tappable elements.
- macOS local releases should use the JS orchestrator: `bun run release:macos -- --channel <stable|beta>` (or `cd scripts && bun run macos:release-app -- --channel <stable|beta>`).
- `bash scripts/macos/release-local.sh --channel <stable|beta>` is a lower-level fallback, not the default local release path.
- macOS TestFlight is a deprecated distribution method; keep it aligned with the stable direct Sparkle build, but the primary path is the direct Sparkle/DMG unsandboxed build.

## Backend

- Runs on Bun (not Node); entry at `server/src/index.ts`; business logic in `src/functions`, RPC handlers in `src/realtime/handlers`, encoders in `src/realtime/encoders`, schema in `src/db/schema`, models in `src/db/models`.
- Use Drizzle for DB; follow add-table flow: create schema, export in `schema/index.ts`, `bun run db:generate <migration>`, migrate, then add model/tests. Never hand-write migrations.
- REST endpoints (legacy) in `src/methods`; realtime is primary; keep auth via `src/utils/authorize.ts`; secure data via `src/modules/encryption/encryption2.ts`.
- Any user-sensitive information or user content stored in the server database must be encrypted at rest; follow existing server encryption patterns (`src/modules/encryption/encryption2.ts`) instead of writing plaintext.
- Testing/linting/typecheck from `server/`: `bun test`, `bun run lint`, `bun run typecheck`; set `DEBUG=1` for verbose output.
- External services: APN (`src/libs/apn.ts`), R2 storage (`src/libs/r2.ts`), AI (Anthropic/OpenAI), Linear/Notion/Loom integrations; ensure env vars handled via `src/env.ts`.

## Web & Docs

- Stack: TanStack Router + Vite + StyleX/Tailwind (+ Motion where needed); keep SSR-safe patterns.
- Commands: from `web/` use `bun run dev`, `bun run build`, `bun run typecheck`.
- Web styling: prefer existing StyleX tokens/utilities over ad-hoc CSS; preserve light/dark behavior.
- Protocol-bound web changes: run `bun run generate:proto` when types/contracts are affected.
- Docs architecture: routes in `web/src/routes/docs/`, markdown in `web/src/docs/content/`, nav in `web/src/docs/nav.ts`.
- New docs page flow: add `content/<page>.md` + matching `routes/docs/<page>.tsx` + nav entry.
- Docs structure/tone: minimal sections, short paragraphs, practical bullets, explicit links; avoid filler/meta language.
- Developer docs positioning: `Realtime API` = full two-way/live integrations, `Bot API` = simpler workflows/alerts.

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
