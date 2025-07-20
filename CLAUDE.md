# Inline Chat App - Development Guide

Inline is a native chat application with Swift clients for iOS and macOS, and a TypeScript backend API server. This guide provides comprehensive information about the codebase architecture, development workflow, and key modules.

## Project Structure

```
inline/
├── apple/              # Apple platform clients (iOS/macOS)
│   ├── InlineIOS/      # iOS SwiftUI/UIKit app
│   ├── InlineMac/      # macOS AppKit/SwiftUI app
│   ├── InlineKit/      # Shared Swift logic, database, auth, protocol
│   └── InlineUI/       # Shared SwiftUI views between platforms
├── server/             # TypeScript backend API server
├── web/                # React Router web client
├── proto/              # Protocol buffer definitions
└── scripts/            # Build and utility scripts
```

## Backend Architecture (server/)

The backend is a TypeScript server built with **Bun**, featuring two API layers:

### Core Technologies
- **Runtime**: Bun (not Node.js)
- **Database**: PostgreSQL with Drizzle ORM
- **Framework**: Elysia for REST API
- **Protocol**: Protocol Buffers for real-time communication
- **WebSocket**: Custom RPC format for real-time API

### Key Modules

#### API Layers
1. **REST API** (Legacy): Using Elysia framework in `methods/` directory
2. **Realtime API** (Primary): WebSocket-based RPC using Protocol Buffers

#### Database Layer
- **Schema**: `/server/src/db/schema/` - Drizzle schema definitions
- **Models**: `/server/src/db/models/` - Database interaction layer with encryption support
- **Migrations**: `/server/drizzle/` - Database migration files

#### Protocol Buffer Integration
- **Proto Definition**: `/proto/core.proto` - Core protocol specification
- **Generated Code**: `/server/packages/protocol/src/core.ts`
- **Encoders**: `/server/src/realtime/encoders/` - Convert database types to protocol buffers

#### Real-time API Components
- **Functions**: `/server/src/functions/` - Business logic abstracted from API
- **Handlers**: `/server/src/realtime/handlers/` - RPC handlers connecting functions to type system
- **Transport**: WebSocket transport with custom RPC format

#### External Services
- **Integrations**: `src/libs/` - External service clients (Anthropic, OpenAI, Linear, Notion, etc.)
- **Notifications**: Push notifications via APN
- **File Storage**: R2 (Cloudflare) for file uploads

### Development Workflow

#### Available Commands (Backend)
```bash
# Development
bun run dev:server          # Start development server
bun run typecheck           # Type checking

# Database
bun run db:migrate         # Run migrations
bun run db:generate <slug> # Generate new migration

# Testing & Quality
bun test                   # Run tests
bun run lint               # Run linting
bun run lint:fix           # Auto-fix linting issues

# Build & Deploy
bun run build              # Production build
bun run start              # Start production server
```

#### Creating New Realtime API Endpoints
1. Define RPC types in `proto/core.proto`
2. Create business logic function in `/server/src/functions/`
3. Create handler in `/server/src/realtime/handlers/`
4. Register handler in `/server/src/realtime/handlers/_rpc.ts`
5. Add encoders/decoders as needed

## Apple Platform Architecture (apple/)

The Apple ecosystem consists of shared Swift packages and platform-specific apps using modern Swift patterns.

### Core Technologies
- **iOS App**: SwiftUI + UIKit hybrid
- **macOS App**: AppKit + SwiftUI hybrid
- **Database**: GRDB (SQLite)
- **Networking**: Custom WebSocket RPC with Protocol Buffers
- **Concurrency**: Swift Concurrency (async/await, actors)

### Shared Packages

#### InlineKit
Core shared functionality between iOS and macOS:
- **Database**: GRDB schema and migrations (`Sources/InlineKit/Models/`)
- **Networking**: `RealtimeAPI` WebSocket client
- **Authentication**: Auth flow management
- **File Management**: Upload/download, caching, image processing
- **Transactions**: Optimistic updates with retry logic (`Sources/InlineKit/Transactions/`)

#### InlineUI
Shared SwiftUI components:
- User avatars and space avatars
- Chat creation views
- Text processing and link detection

#### InlineProtocol
Generated Protocol Buffer Swift code from `/proto/core.proto` using swift-protobuf.

#### Logger
Centralized logging system accessible via `Log.scoped` or `Log.shared`.

### Platform-Specific Apps

#### iOS App (InlineIOS/)
- **Architecture**: SwiftUI + UIKit hybrid
- **Chat View**: UIKit-based with upside-down collection view for chat behavior
- **Message List**: Custom collection view with cell reuse
- **Image Loading**: Nuke/NukeUI for remote images
- **Navigation**: SwiftUI navigation with UIKit chat screens

#### macOS App (InlineMac/)
- **Architecture**: AppKit + SwiftUI hybrid
- **Chat View**: AppKit-based for performance
- **Compose**: AppKit text handling with SwiftUI UI
- **Window Management**: Custom window controllers

### Key Implementation Details

#### Database Management
- All database logic must be shared between platforms
- Schema changes require migrations in `InlineKit/Sources/InlineKit/Database.swift`
- Use GRDB for thread-safe database operations

#### Protocol Buffer Usage
```swift
// Creating protocol buffer objects
var message = Message.with {
    $0.id = 1234
    $0.text = "Hello, world!"
    $0.author = "User"
}
```

#### Mutations and Transactions
For data mutations like `sendMessage`, create transactions under `InlineKit/Sources/InlineKit/Transactions/Methods/` and call via the transactions singleton for automatic retry and optimistic updates.

#### Translation System
- **Language Support**: English (en), Spanish (es), French (fr), Japanese (ja), Chinese Simplified (zh-Hans), Chinese Traditional (zh-Hant), Tagalog (tl), Persian (fa)
- **Language Preference**: `UserLocale.setPreferredTranslationLanguage()` to set custom language, stored in UserDefaults
- **Translation State**: `TranslationState.shared` manages per-peer translation enable/disable state
- **Language Picker**: `LanguagePickerView` provides UI for selecting translation target language
- **Integration**: Translation button in `apple/InlineMac/Toolbar/TranslateButtion/TranslationButton.swift`

## Web Client (web/)

React Router application for web access to the chat platform.

### Technologies
- **Framework**: React Router v7
- **Styling**: Tailwind CSS + StyleX
- **Animation**: Framer Motion
- **Build Tool**: Vite

### Available Commands
```bash
bun run dev              # Development server
bun run build            # Production build
bun run typecheck        # Type checking
bun run start            # Start production server
```

## Apple Platform Build Commands

### Available Schemes
From `apple/Inline.xcodeproj`:
- **"Inline (macOS)"** - Main macOS application
- **"Inline (iOS)"** - Main iOS application  
- **"2nd Inline (macOS)"** - Alternative macOS build configuration
- **InlineKit** - Shared Swift package
- **InlineUI** - Shared SwiftUI components
- **InlineProtocol** - Protocol buffer Swift code
- **Logger** - Logging framework
- **RealtimeAPI** - WebSocket client
- **TextProcessing** - Text processing utilities

### Build Commands
```bash
# Build macOS app
xcodebuild -project apple/Inline.xcodeproj -scheme "Inline (macOS)" -configuration Debug build

# Build iOS app  
xcodebuild -project apple/Inline.xcodeproj -scheme "Inline (iOS)" -configuration Debug build

# Build specific package (e.g. InlineKit)
xcodebuild -project apple/Inline.xcodeproj -scheme "InlineKit" -configuration Debug build

# List all available schemes
xcodebuild -project apple/Inline.xcodeproj -list
```

## Development Guidelines

### Code Style & Conventions
- **Backend**: Use Bun instead of Node.js/npm
- **Testing**: `bun test` for backend, Swift Testing for Apple platforms
- **Database**: Drizzle ORM with both `db.select()` and `db.query` patterns
- **Protocol**: Snake case in `.proto` → camelCase in TypeScript, camelCase in Swift (except Id → ID)

### Security & Best Practices
- **Encryption**: Use `server/src/modules/encryption` for sensitive data
- **Authorization**: Use `server/src/utils/authorize.ts` helpers
- **Logging**: Use `server/src/utils/log.ts` for error capture to Sentry
- **Environment**: Type-checked environment variables in `server/src/env.ts`

### Performance Considerations
- **Apple Platforms**: Don't perform heavy computations on main thread
- **Database**: Use appropriate query patterns for complexity
- **Real-time**: Encode updates separately for each user
- **UI**: Use minimal, subtle animations and interaction styles

### Testing
- **Backend**: Bun test with utilities in `src/__tests__/setup.ts`
- **Apple**: Swift Testing framework with `@Test` and `@Suite` macros
- **Debug**: Set `process.env["DEBUG"] = "1"` for debug logging

## Getting Started

1. **Clone and Install**:
   ```bash
   bun install
   ```

2. **Start Development**:
   ```bash
   bun run dev:server    # Backend
   bun run dev           # Web client (separate terminal)
   ```

3. **Open Apple Projects**:
   Open `apple/Inline.xcodeproj` in Xcode

4. **Database Setup**:
   ```bash
   cd server
   bun run db:migrate
   ```


## Swift
* Design UI in a way that is idiomatic for the macOS platform and follows Apple Human Interface Guidelines.
* Use SF Symbols for iconography.
* Use the most modern macOS APIs. Since there is no backward compatibility constraint, this app can target the latest macOS version with the newest APIs.
* Use the most modern Swift language features and conventions. Target Swift 6 and use Swift concurrency (async/await, actors) and Swift macros where applicable.
- Build UI with small, focused views
- Extract reusable components naturally
- Use view modifiers to encapsulate common styling
- Prefer composition over inheritance
- Use extensions to organize large files
- Follow Swift naming conventions consistently
- Unit test business logic and data transformations
- Use SwiftUI Previews for visual testing
- Test @Observable classes independently
- Keep tests simple and focused
- Don't sacrifice code clarity for testability
- Use Swift Concurrency (async/await, actors)
- Leverage Swift 6 data race safety when available
- Utilize property wrappers effectively
- Embrace value types where appropriate
- Use protocols for abstraction, not just for testing

## Common Development Tasks

### Adding New Protocol Buffer Types
1. Edit `/proto/core.proto`
2. Regenerate: `bun run generate:proto`
3. Update encoders in `server/src/realtime/encoders/`
4. Rebuild Xcode project for Swift changes

### Adding Database Tables
1. Create schema in `server/src/db/schema/`
2. Export from `server/src/db/schema/index.ts`
3. Generate migration: `bun run db:generate`
4. Update Apple schema in `apple/InlineKit/Sources/InlineKit/Database.swift`

### Debugging
- **Backend**: Use `server/src/utils/log.ts` for structured logging
- **Apple**: Use `Logger` package with `Log.scoped("ModuleName")`
- **Database**: Use `bun run db:studio` for visual inspection

This guide provides the foundation for understanding and contributing to the Inline chat application codebase. For specific implementation details, refer to the existing code patterns and the `.cursor/rules/*.mdc` files for additional context.

