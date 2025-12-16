Inline is a work chat application. Repository: https://github.com/inline-chat/inline

## 1. Project Overview

```
inline/
├── apple/              # iOS/macOS clients
│   ├── InlineIOS/      # iOS app (SwiftUI/UIKit)
│   ├── InlineMac/      # macOS app (AppKit/SwiftUI)
│   ├── InlineKit/      # Shared: database, auth, networking
│   └── InlineUI/       # Shared SwiftUI components
├── server/             # TypeScript backend (Bun + Elysia + Drizzle)
├── web/                # React Router v7 web client
├── proto/              # Protocol buffer definitions
└── scripts/            # Build scripts
```

| Platform | Stack                                                                   |
| -------- | ----------------------------------------------------------------------- |
| Backend  | Bun, PostgreSQL/Drizzle, Elysia (REST), WebSocket RPC, Protocol Buffers |
| Apple    | Swift 6, SwiftUI/UIKit/AppKit hybrid, GRDB/SQLite, async/await          |
| Web      | React Router v7, Tailwind CSS, Vite                                     |

Key paths: `server/src/functions/` (business logic), `server/src/realtime/handlers/` (RPC handlers), `server/src/db/schema/` (Drizzle schemas), `apple/InlineKit/Sources/InlineKit/Models/` (GRDB models), `proto/core.proto` (protocol definitions)

## 2. Development

```bash
# Backend (from server/)
bun run dev                      # Start dev server
bun run typecheck                # Type checking
bun test                         # Run tests
bun test src/__tests__/file.ts   # Single test file
bun run lint                     # Linting
bun run db:generate <name>       # Generate migration
bun run db:migrate               # Run migrations

# Apple (from apple/InlineKit or apple/InlineUI)
swift test                       # Run package tests

# Protocol Buffers (from root)
bun run generate:proto           # Generate all protocol files
```

### Adding Realtime API Endpoints

1. Add RPC types in `proto/core.proto`
2. Run `bun run generate:proto`
3. Create function in `server/src/functions/`
4. Create handler in `server/src/realtime/handlers/`
5. Register in `server/src/realtime/handlers/_rpc.ts`
6. Add encoders in `server/src/realtime/encoders/`
7. Rebuild Xcode `InlineProtocol` target
8. Add tests in `server/src/__tests__/functions/`

### Adding Database Tables

**Server:** Create schema in `server/src/db/schema/`, export in `index.ts`, run `bun run db:generate <name>` then `bun run db:migrate`, create model in `server/src/db/models/`

**Apple:** Create model in `apple/InlineKit/Sources/InlineKit/Models/`, add migration in `Database.swift`

### Testing

Run tests with 15s timeout. Write tests only for isolated, simple-to-test non-UI code. Backend uses Bun test (`src/__tests__/setup.ts`), Apple uses Swift Testing (`@Test`, `@Suite`).

## 3. Code Conventions

### Code Style

Use Bun instead of Node.js/npm. Use Drizzle ORM patterns (`db.select()`, `db.query`). Target Swift 6 with async/await and actors.

IDs use Int64. Use `ID` in protocol buffers, `Id` in Swift code. Date/time values use SECONDS by default since that's our transport format—only convert to milliseconds when the host language requires it.

Write comments only to explain complex "why" that isn't obvious from code. Keep them concise. Avoid print statements—use the Log package for errors and warnings instead since it integrates with our logging infrastructure.

### Security

Encryption: `server/src/modules/encryption/encryption2.ts`
Authorization: `server/src/utils/authorize.ts`
Logging: `server/src/utils/log.ts` (backend with Sentry), `Log.scoped("Module")` (Apple)
Environment: Type-checked in `server/src/env.ts`

### Swift Principles

Build small, focused views using composition over inheritance. Use view modifiers for common styling. Follow Apple HIG and use SF Symbols. Keep heavy computations off the main thread to maintain UI responsiveness.

## 4. Agent Instructions

### Task Approach

Do exactly what is asked—nothing more, nothing less. Read and understand relevant code before proposing changes. Follow existing patterns in the codebase rather than introducing new abstractions.

Keep solutions simple and focused. A bug fix doesn't need surrounding code cleaned up. A simple feature doesn't need extra configurability. Only add error handling for scenarios that can actually happen.

Preserve `Note:`, `TODO:`, `FIXME:` comments since they track important context. Avoid creating documentation files unless explicitly requested.

For full iOS/macOS builds, ask the user to build and report back—xcodebuild output is too verbose for context. You can run `swift test` for InlineKit and InlineUI packages directly.

### Git Rules

Multiple agents often work on adjacent files simultaneously. Before deleting any file to resolve type/lint errors, ask first—another agent may be editing it. Coordinate before modifying work you didn't author.

Only the user should edit `.env` files since they contain sensitive credentials. Avoid destructive operations (`git reset --hard`, `git restore` to older commits) without explicit approval since they can lose uncommitted work.

Check `git status` before every commit to avoid committing unintended changes.

### Commits

Make atomic commits: one feature, bug fix, or refactor per commit. This makes history easy to understand and revert if needed.

Format: `platform: description` (e.g., `macos: fix navbar`, `api: add endpoint`). Use lowercase.

Commit only files you touched with explicit paths:

- Tracked files: `git commit -m "msg" -- path/to/file1 path/to/file2`
- New files: `git restore --staged :/ && git add "file1" "file2" && git commit -m "msg" -- file1 file2`

Quote paths containing brackets or parentheses so the shell doesn't interpret them as globs. Only amend commits with explicit approval since it rewrites history.

Do not add yourself (Claude/Opus) as the coauthor.
