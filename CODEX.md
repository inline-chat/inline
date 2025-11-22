## Orientation

- Inline is a multi-client work chat app; repo at https://github.com/inline-chat/inline with backend (Bun/TS), Apple clients (SwiftUI/UIKit/AppKit), web (React/TanStack), and shared protobufs in `proto/`.
- Primary shared Swift packages live in `apple/InlineKit`, `InlineUI`, `InlineProtocol`, plus app targets under `apple/InlineIOS` and `apple/InlineMac`.
- Backend lives in `server/` (Bun runtime, Drizzle + Postgres, Elysia REST + WebSocket RPC) with protocol encoders/handlers split across `src/functions`, `src/realtime`, `src/db`.
- Web client in `web/` uses React Router v7, Tailwind + StyleX, Vite.
- Use `bun` for JS/TS tooling (not npm/yarn); keep IDs as `Int64` (Swift `Id`, proto `ID`), timestamps in seconds unless host API needs ms.

## Working Rules

- Do requested work only; mirror existing patterns; add comments only when clarifying non-obvious logic; never touch `.env` or delete others’ work.
- Avoid destructive git commands; keep commits atomic and scoped; do not amend existing commits; quote paths with special chars; check status before committing.
- Commit style: platform-prefixed, lowercase, scoped messages (e.g., `apple: fix sync`); add a brief description or bullets when extra context is needed.
- Prefer `rg` for search; keep edits ASCII; strip debug prints; use logging utilities (`Log` in Swift, `server/src/utils/log.ts`).
- Regenerate protobufs after proto changes with `bun run generate:proto` (or per-language commands in `scripts/`); rebuild Swift `InlineProtocol` target if needed.
- Default test timeout 25s; run focused tests from relevant package roots; avoid heavy/unapproved tooling (e.g., do not run `xcodebuild` full apps).

## Common Commands

- Root scripts: `bun run dev`/`dev:server` (backend), `bun run dev:web`, `bun run typecheck`, `bun run test` (backend), `bun run lint`.
- Protos: from root `bun run generate:proto`; from `scripts/` use `bun run generate` for per-language.
- Database: `cd server && bun run db:migrate`; generate migrations via `bun run db:generate <name>`; inspect with `bun run db:studio`.
- Targeted backend tests: `cd server && bun test src/__tests__/modules/...`; enable debug via `DEBUG=1`.
- Keep commands inside package dirs when running Swift or Bun tooling to avoid path issues.

## Apple (iOS/macOS)

- Swift 6 targets in `apple/InlineKit` (shared logic/DB/networking), `InlineUI` (shared UI), app targets `InlineIOS` (SwiftUI+UIKit) and `InlineMac` (AppKit+SwiftUI); share protocol via generated `InlineProtocol`.
- Do not build full apps with `xcodebuild`; ask user to run. Allowed: package tests and builds via e.g. `cd apple/InlineKit && swift test` and `cd apple/InlineUI && swift build`.
- Database migrations live in `InlineKit/Sources/InlineKit/Database.swift`; models in `Sources/InlineKit/Models/`; transactions in `Sources/InlineKit/Transactions/Methods/`.
- Logging via `Log.scoped`; avoid main-thread heavy work; use Swift concurrency; prefer small composable views/modifiers.
- Regenerate Swift protos with `bun run proto:generate-swift` (scripts) then rebuild `InlineProtocol` target in Xcode if necessary.

## Backend

- Runs on Bun (not Node); entry at `server/src/index.ts`; business logic in `src/functions`, RPC handlers in `src/realtime/handlers`, encoders in `src/realtime/encoders`, schema in `src/db/schema`, models in `src/db/models`.
- Use Drizzle for DB; follow add-table flow: create schema, export in `schema/index.ts`, `bun run db:generate <migration>`, migrate, then add model/tests.
- REST endpoints (legacy) in `src/methods`; realtime is primary; keep auth via `src/utils/authorize.ts`; secure data via `src/modules/encryption/encryption2.ts`.
- Testing/linting/typecheck from `server/`: `bun test`, `bun run lint`, `bun run typecheck`; set `DEBUG=1` for verbose output.
- External services: APN (`src/libs/apn.ts`), R2 storage (`src/libs/r2.ts`), AI (Anthropic/OpenAI), Linear/Notion/Loom integrations; ensure env vars handled via `src/env.ts`.

## Web

- TanStack router app under `web/app`; styling uses Tailwind 4 + StyleX; animations via Framer Motion/Motion; built with Vite.
- Scripts from `web/`: `bun run dev`, `bun run build`, `bun run typecheck`; ensure Bun runtime available.
- Keep routing with TanStack conventions; prefer StyleX/Tailwind utilities over ad-hoc CSS; maintain SSR compatibility (Nitro).
- When touching protocol-bound code, regenerate protos first (`bun run generate:proto`) to keep TS definitions synced.
