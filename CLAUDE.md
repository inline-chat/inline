Inline is a work chat application.

### Repository

This repository is on GitHub at https://github.com/inline-chat/inline

### Project Structure

- **Backend**: TypeScript server built with Bun, featuring REST and WebSocket APIs
- **Apple Platforms**: Swift clients for iOS (SwiftUI/UIKit) and macOS (AppKit/SwiftUI)
- **Web Client**: React + Tanstack Router web application
- **Protocol**: Protocol Buffers for cross-platform communication
- **Database**: PostgreSQL (server) and GRDB/SQLite (Apple platforms)

```
inline/
├── apple/              # Apple platform clients (iOS/macOS)
│   ├── InlineIOS/      # iOS SwiftUI/UIKit application
│   ├── InlineMac/      # macOS AppKit/SwiftUI application
│   ├── InlineKit/      # Shared Swift logic, database, auth, networking
│   ├── InlineShareExtension # iOS share extension
│   └── InlineUI/       # Shared SwiftUI components
├── server/             # TypeScript backend API server
├── web/                # React Router web client
├── proto/              # Protocol buffer definitions (.proto files)
└── scripts/            # Build scripts and protocol buffer generation
```

### Key Directories

- **`apple/InlineKit/`**: Core shared functionality between iOS and macOS
  - `Sources/InlineKit/Models/` - Database models and GRDB schemas
  - `Sources/InlineKit/Transactions/` - Optimistic update transactions
- **`server/src/`**: Backend source code with functions, handlers, and database models
  - `functions/` - Business logic functions
  - `realtime/handlers/` - WebSocket RPC handlers
  - `db/schema/` - Database schema definitions
- **`proto/`**: Protocol buffer definitions for cross-platform communication
- **`web/app/`**: React Router application structure

## Backend (server/)

#### Backend API Layers

- **Runtime**: Bun (not Node.js)
- **Database**: PostgreSQL with Drizzle ORM
- **API Framework**: Elysia (REST) + Custom WebSocket RPC
- **Protocol**: Protocol Buffers for real-time communication

### Architecture

#### API Layers

- **REST API** (Legacy): Elysia framework in `src/methods/`
- **Realtime API** (Primary): WebSocket RPC using Protocol Buffers

#### Backend Core Components

- **Functions** (`src/functions/`): Business logic abstracted from API
- **Handlers** (`src/realtime/handlers/`): RPC handlers connecting functions to protocols
- **Models** (`src/db/models/`): Database interaction layer with encryption support
- **Schema** (`src/db/schema/`): Drizzle schema definitions
- **Encoders** (`src/realtime/encoders/`): Convert database types to protocol buffers
- **Utils** (`src/utils/`): Authorization, logging, validation utilities

### Backend Development Commands

```bash
# Development
bun run dev                 # Start development server
bun run typecheck          # Type checking

# Database
bun run db:generate <slug> # Generate new migration
bun run db:migrate         # Run migrations

# Testing & Quality
bun test                   # Run tests
bun run lint               # Run linting
```

### Running tests for a single file

Run tests from the `server/` subdirectory, like this:

```
cd ./server
bun test src/__tests__/modules/accessGuards.test.ts
```

### Backend External Integrations

- **Notifications**: Push notifications via APN (`src/libs/apn.ts`)
- **File Storage**: Cloudflare R2 for uploads (`src/libs/r2.ts`)
- **AI Services**: Anthropic, OpenAI integrations in `src/libs/`
- **Third-party**: Linear (`src/libs/linear/`), Notion (`src/libs/notion.ts`), Loom integrations

### Adding New Realtime API Endpoints

1. **Define Protocol**: Add RPC types in `proto/core.proto`
2. **Generate Code**: Run `bun run generate:proto`
3. **Business Logic**: Create function in `server/src/functions/`
4. **Handler**: Create handler in `server/src/realtime/handlers/`
5. **Register**: Add to `server/src/realtime/handlers/_rpc.ts`
6. **Encoders**: Add encoders/decoders in `server/src/realtime/encoders/`
7. **Client Code**: Rebuild Xcode `InlineProtocol` target for Swift changes
8. **Testing**: Add tests in `server/src/__tests__/functions/`

### Adding Database Tables

#### Server

1. **Schema**: Create schema file in `server/src/db/schema/`
2. **Export**: Add export to `server/src/db/schema/index.ts`
3. **Generate**: Run `cd server && bun run db:generate <migration-name>`
4. **Migrate**: Run `cd server && bun run db:migrate`
5. **Model**: Create model file in `server/src/db/models/`
6. **Testing**: Add model tests in `server/src/__tests__/models/`

## Apple Platforms (apple/) (iOS, macOS)

### Technologies

- **iOS**: SwiftUI + UIKit hybrid architecture
- **macOS**: AppKit + SwiftUI hybrid architecture
- **Database**: GRDB (SQLite) with migrations
- **Networking**: Custom WebSocket RPC with Protocol Buffers
- **Concurrency**: Swift Concurrency (async/await, actors)

### Shared Packages for Apple

#### InlineKit

Core functionality shared between platforms:

- **Database**: GRDB schema and migrations in `Sources/InlineKit/Models/`
- **Networking**: `RealtimeAPI` WebSocket client in `Sources/RealtimeV2/`
- **Authentication**: Auth flow management in `Sources/Auth/`
- **File Management**: Upload/download, caching, image processing
- **Transactions**: (Legacy) optimistic updates with retry in `Sources/InlineKit/Transactions/`

#### InlineUI

Shared SwiftUI components:

- User and space avatars
- Text processing and link detection

#### InlineProtocol

Generated Protocol Buffer Swift code from `proto/core.proto`

#### Logger

Centralized logging accessible via `Log.scoped("ModuleName")` or `Log.shared`

### Platform-Specific Apps

#### iOS App (InlineIOS/)

- **Chat View**: UIKit-based with upside-down collection view
- **Navigation**: SwiftUI navigation with hybrid UIKit chat views
- **Image Loading**: Nuke/NukeUI for remote images

#### macOS App (InlineMac/)

- **Chat View**: AppKit-based for performance
- **Compose**: AppKit text handling with SwiftUI UI
- **MessageView**: AppKit message bubble
- **MessageTableRow**: NSTableView row handling cell-reuse
- **Architecture**: AppKit + SwiftUI hybrid

### Build Commands

Do not use `xcodebuild`.

```bash
# Run package tests (from package directory)
cd apple/InlineKit && swift test
cd apple/InlineUI && swift test
```

### Available Xcode Schemes

- **"Inline (iOS)"**
- **"Inline (macOS)"**
- **InlineKit**
- **InlineUI**
- **InlineProtocol**
- **Logger**
- **RealtimeV2**
- **TextProcessing**

## Web Client (web/)

### Technologies

- **Framework**: React Router v7
- **Styling**: Tailwind CSS + StyleX
- **Animation**: Framer Motion
- **Build Tool**: Vite

## Protocol Buffers

Protocol Buffers enable type-safe communication between all platforms.

### Core Files

- **Definition**: `proto/core.proto` - Core protocol specification
- **TypeScript**: `server/packages/protocol/src/core.ts` (generated)
- **Swift**: `apple/InlineKit/Sources/InlineProtocol/core.pb.swift` (generated)

### Generation Commands

```bash
# Generate all protocol files
bun run generate:proto

# Individual generation (from scripts/)
bun run proto:generate-ts     # TypeScript generation
bun run proto:generate-swift  # Swift generation
```

### Usage Examples

#### Swift

```swift
var message = Message.with {
    $0.id = 1234
    $0.text = "Hello, world!"
    $0.author = "User"
}
```

#### TypeScript

```typescript
const message: Message = {
  id: 1234,
  text: "Hello, world!",
  author: "User",
};
```

#### Naming Conventions

- **Proto**: snake_case → **TypeScript**: camelCase → **Swift**: camelCase (except Id → ID)

## Development Workflows

### Adding New Realtime API Endpoints

1. **Define Protocol**: Add RPC types in `proto/core.proto`
2. **Generate Code**: Run `bun run generate:proto`
3. **Business Logic**: Create function in `server/src/functions/`
4. **Handler**: Create handler in `server/src/realtime/handlers/`
5. **Register**: Add to `server/src/realtime/handlers/_rpc.ts`
6. **Encoders**: Add encoders/decoders in `server/src/realtime/encoders/`
7. **Client Code**: Rebuild Xcode `InlineProtocol` target for Swift changes
8. **Testing**: Add tests in `server/src/__tests__/functions/`

### Adding Database Tables in Backend

1. **Schema**: Create schema file in `server/src/db/schema/`
2. **Export**: Add export to `server/src/db/schema/index.ts`
3. **Generate**: Run `cd server && bun run db:generate <migration-name>`
4. **Migrate**: Run `cd server && bun run db:migrate`
5. **Model**: Create model file in `server/src/db/models/`
6. **Testing**: Add model tests in `server/src/__tests__/models/`

#### Adding Client Database Tables In Apple Platforms

1. **Model**: Create model file in `apple/InlineKit/Sources/InlineKit/Models/`
2. **Migration**: Add migration in `apple/InlineKit/Sources/InlineKit/Database.swift`
3. **Testing**: Add tests using Swift Testing framework

### Data Mutations and Transactions

Create transactions in `apple/InlineKit/Sources/InlineKit/Transactions/Methods/` for operations like `sendMessage`. Use the transactions singleton for automatic retry and optimistic updates.

## Testing & Quality

### Testing Frameworks

- **Backend**: Bun test with utilities in `src/__tests__/setup.ts`
- **Apple Platforms**: Swift Testing framework with `@Test` and `@Suite` macros
- **Debug Logging**: Set `process.env["DEBUG"] = "1"` for backend debug output

### Code Quality

- **Linting**: `bun run lint` (root level), `bun run lint` (server)
- **Type Checking**: `bun run typecheck` (verifies TypeScript across projects)
- **Testing**: `bun test` (backend), `swift test` (Swift packages)
- **Database**: `bun run db:studio` for visual database inspection

### Performance Guidelines

- **Apple Platforms**: Avoid heavy computations on main thread
- **Database**: Use appropriate query patterns for complexity
- **Real-time**: Encode updates separately for each user
- **UI**: Use minimal, subtle animations and interactions

## Development Guidelines

### Code Style & Conventions

- **Backend**: Use Bun instead of Node.js/npm
- **Database**: Drizzle ORM with `db.select()` and `db.query` patterns
- **Swift**: Target Swift 6, use modern APIs and concurrency patterns
- **UI Design**: Follow Apple Human Interface Guidelines, use SF Symbols
- Only add comments that explain exactly why a certain complex code is needed and only when the code is not self explanatory. Keep them concise and do not add comments that do not provide anything important. We use comments sparingly.
- Do not fill stubs with comments.
- Do not keep print statements, only use them while debugging and delete them afterwards.
- Prefer using the log package for error and warnings.
- Most IDs use `Int64`. Use all caps `ID` in protocol buffers types and `Id` in app Swift code

### Security & Best Practices

- **Encryption**: Use `server/src/modules/encryption/encryption2.ts` for sensitive data
- **Authorization**: Use `server/src/utils/authorize.ts` helpers
- **Logging**:
  - **Backend**: `server/src/utils/log.ts` for Sentry integration
  - **Apple**: `Log.scoped("ModuleName")` for structured logging
- **Environment**: Type-checked environment variables in `server/src/env.ts`
- **Error Handling**: Use `server/src/utils/log.ts` for error capture and Sentry integration

### Swift Development Principles

- Build UI with small, focused views
- Extract reusable components naturally
- Use view modifiers for common styling
- Prefer composition over inheritance
- Follow Swift naming conventions
- Use Swift Concurrency (async/await, actors)
- Leverage Swift 6 data race safety
- Use protocols for abstraction

### Environment Configuration

- **Server**: Environment variables in `server/src/env.ts`
- **Database**: PostgreSQL with Drizzle migrations
- **File Storage**: Cloudflare R2 configuration
- **Push Notifications**: APN setup for iOS/macOS

## Development Tips

- **Apple Development**: Use IDE diagnostics and `swift test` instead of verbose xcodebuild commands
- **IDE Issues**: Restart IDE when package changes aren't reflected in diagnostics
- **Build Output**: Use silent mode for xcodebuild to avoid context window overflow
- **Package Testing**: Run Swift package tests from package root: `cd apple/InlineKit && swift test`
- **Protocol Changes**: Always run `bun run generate:proto` after modifying `.proto` files

## General Instructions

- Do what has been asked; nothing more, nothing less
- NEVER proactively create documentation files unless explicitly requested
- Follow existing code patterns and conventions in the codebase
- Reference this guide for accurate commands and file structure
- Write tests for isolated, simple to test, non-UI code in Swift packages. Avoid attempting to write tests automatically when it requires significant investment, mocking, re-architecture or complex testing workflows
- run tests with a timeout of 15s
- When you want to build the full macOS/iOS using xcodebuild, ask me to do it, do not build the full apps. Only run tests for InlineUI or InlineKit.
- Do not remove comments that are prefixed with Note:, TODO:, or FIXME: or documentation.
- Our date/time values are in SECONDS in transport by default. We only transform to milliseconds for calculations if the host language's native date object expects something else. Use seconds by default unless specifically asked for.
- Instead of using xcodebuild to build the whole macOS/iOS application, ask the user to do it and report back. If your work was in InlineKit or InlineUI

## Git Instructions

- **Before attempting to delete a file to resolve a local type/lint failure, stop and ask the user.** Other agents are often editing adjacent files; deleting their work to silence an error is never acceptable without explicit approval.
- NEVER edit `.env` or any environment variable files—only the user may change them.
- Coordinate with other agents before removing their in-progress edits—don't revert or delete work you didn't author unless everyone agrees.
- Moving/renaming and restoring files is allowed.
- ABSOLUTELY NEVER run destructive git operations (e.g., `git reset --hard`, `rm`, `git checkout`/`git restore` to an older commit) unless the user gives an explicit, written instruction in this conversation. Treat these commands as catastrophic; if you are even slightly unsure, stop and ask before touching them. _(When working within Cursor or Codex Web, these git limitations do not apply; use the tooling's capabilities as needed.)_
- Never use `git restore` (or similar commands) to revert files you didn't author—coordinate with other agents instead so their in-progress work stays intact.
- Always double-check git status before any commit
- Keep commits atomic: commit only the files you touched and list each path explicitly. For tracked files run `git commit -m "<scoped message>" -- path/to/file1 path/to/file2`. For brand-new files, use the one-liner `git restore --staged :/ && git add "path/to/file1" "path/to/file2" && git commit -m "<scoped message>" -- path/to/file1 path/to/file2`.
- Quote any git paths containing brackets or parentheses (e.g., `src/app/[candidate]/**`) when staging or committing so the shell does not treat them as globs or subshells.
- When running `git rebase`, avoid opening editors—export `GIT_EDITOR=:` and `GIT_SEQUENCE_EDITOR=:` (or pass `--no-edit`) so the default messages are used automatically.
- Never amend commits unless you have explicit written approval in the task thread.

## Commit style guide

- We commit changes atomically so usually one unit of commit is one feature, bug, refactor or one unit of working piece of code toward a bigger task.
- Write the affected platform like this: "macos: fix the navbar", "ios:", "apple:", "api:", etc.
- Use lowercase
- If change is larger and requires more context on the cause or future consideration write a description with a concise explanation or a bullet list.
