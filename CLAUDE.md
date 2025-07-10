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

# Inline iOS App - Enhanced Catppuccin Mocha Theme Implementation

## Overview
I've successfully enhanced the Catppuccin Mocha theme to comprehensively apply across all views in the iOS app, using the official Catppuccin color palette for both dark and light modes.

## Changes Made

### 1. Enhanced ThemeConfig Protocol
Added 16 new color properties to support comprehensive theming:
- `listRowBackground` - Background for list rows
- `listSeparatorColor` - List separator lines  
- `navigationBarBackground` - Navigation bar background
- `toolbarBackground` - Toolbar background
- `surfaceBackground` - Primary surface background
- `surfaceSecondary` - Secondary surface background
- `textPrimary` - Primary text color
- `textSecondary` - Secondary text color
- `textTertiary` - Tertiary text color
- `borderColor` - Border and stroke colors
- `overlayBackground` - Overlay backgrounds
- `cardBackground` - Card backgrounds
- `searchBarBackground` - Search bar background
- `buttonBackground` - Primary button background
- `buttonSecondaryBackground` - Secondary button background

### 2. Enhanced CatppuccinMocha Theme
Updated with official Catppuccin Mocha colors:

**Dark Mode (Mocha):**
- Base: `#1E1E2E`
- Mantle: `#181825` 
- Crust: `#11111B`
- Surface0: `#313244`
- Surface1: `#45475A`
- Surface2: `#585B70`
- Text: `#CDD6F4`
- Subtext1: `#BAC2DE`
- Subtext0: `#A6ADC8`
- Blue: `#89B4FA`
- Mauve: `#CBA6F7`
- Overlay0: `#6C7086`
- Overlay1: `#7F849C`

**Light Mode (Latte):**
- Base: `#EFF1F5`
- Mantle: `#E6E9EF`
- Crust: `#DCE0E8`
- Surface0: `#CCD0DA`
- Surface1: `#BCC0CC`
- Surface2: `#ACB0BE`
- Text: `#4C4F69`
- Subtext1: `#5C5F77`
- Subtext0: `#6C6F85`
- Blue: `#1E66F5`
- Mauve: `#8839EF`
- Overlay0: `#9CA0B0`
- Overlay1: `#8C8FA1`

### 3. SwiftUI Color Extensions
Added convenient SwiftUI Color accessors in ThemeManager:
- `listRowBackgroundColor`
- `navigationBarBackgroundColor`
- `textPrimaryColor`
- `accentColor`
- And 11 more color accessors with system fallbacks

### 4. View Modifiers for Easy Theming
Created reusable view modifiers:
- `.themedListRow()` - Applies theme to list rows
- `.themedListStyle()` - Applies theme to entire lists
- `.themedPrimaryText()` - Primary text color
- `.themedSecondaryText()` - Secondary text color
- `.themedCard()` - Card background and text
- `.themedAccent()` - Accent color
- And more for buttons, surfaces, navigation

### 5. Applied Theming Across All Views
Updated these key views to use the new theme system:
- `HomeView` - Chat list and search results
- `SpacesView` - Space list
- `SpaceView` - Member and chat lists
- `ChatListView` - Main chat list
- `DirectChatItem` - Direct chat items
- `ChatItemView` - Group chat items
- `MemberItemRow` - Space member rows
- `ChatItemRow` - Space chat rows
- `LocalSearchItem` - Search results
- `ChatInfoView` - Chat information
- `InfoRow` - Information rows
- `AddMember` - Add member sheet
- `SettingsView` - Settings screen
- `MultiPhotoPreviewView` - Photo preview
- `ChatView` - Chat interface
- And many more components

### 6. Maintained Backward Compatibility
- All existing themes (Default, PeonyPink, Orchid) still work
- New theme properties return `nil` for old themes, falling back to system colors
- No breaking changes to existing code

## How to Test

1. **Switch to Catppuccin Mocha Theme:**
   - Go to Settings → Appearance
   - Select "Catppuccin Mocha" theme

2. **Test Dark/Light Mode:**
   - Toggle between dark and light mode in iOS Settings
   - Theme automatically adapts with proper Catppuccin colors

3. **Verify Theme Application:**
   - Navigate through all main tabs (Chats, Archived, Spaces)
   - Check list backgrounds, text colors, and navigation elements
   - Open chat conversations and settings
   - Verify search functionality and member lists

## Key Features

✅ **Complete Color Consistency** - All UI elements use cohesive Catppuccin colors
✅ **Official Color Palette** - Uses exact Catppuccin Mocha/Latte hex values
✅ **Dynamic Light/Dark Support** - Automatically switches between Mocha and Latte
✅ **Comprehensive Coverage** - Themes lists, navigation, text, buttons, surfaces
✅ **Easy Maintenance** - Centralized theme system with reusable modifiers
✅ **Backward Compatible** - Existing themes continue to work

The enhanced Catppuccin Mocha theme now provides a beautiful, cohesive, and comprehensive theming experience across the entire iOS app, making it feel like a native Catppuccin application.