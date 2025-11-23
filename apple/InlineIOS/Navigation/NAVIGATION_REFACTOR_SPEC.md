# iOS Navigation Refactoring Specification

## Overview

Refactor from tab-based navigation (TabView with 3 tabs) to a single NavigationStack with HomeView as root.

---

## Current Architecture

### Navigation Components

| Component | File | Purpose |
|-----------|------|---------|
| `NavigationModel<Tab, Destination, Sheet>` | `Navigation/Router.swift` | Generic tab-based navigation with persistence |
| `Router` typealias | `Navigation/AppContent.swift` | `NavigationModel<AppTab, Destination, Sheet>` |
| `AppTab` | `Navigation/AppContent.swift` | Tab enum: `.archived`, `.chats`, `.spaces` |
| `Destination` | `Navigation/AppContent.swift` | Navigation destinations |
| `Sheet` | `Navigation/AppContent.swift` | Sheet presentations |
| `MainViewRouter` | `Utils/MainViewRouter.swift` | Switches between `.main` and `.onboarding` |
| `OnboardingNavigation` | `Utils/OnboardingNavigation.swift` | Manages onboarding flow path |
| `Navigation` (legacy) | `Utils/Navigation.swift` | Old navigation class (partially used) |

### Current Flow

```
MainViewRouter.route
├── .onboarding
│   └── OnboardingView (NavigationStack)
│       └── Welcome → Email → Code → Profile
└── .main
    └── ContentView2
        └── TabView (3 tabs)
            ├── .chats → HomeView
            ├── .archived → ArchivedChatsView
            └── .spaces → SpacesView
```

### Current Router API

```swift
// NavigationModel<Tab, Destination, Sheet>
router.selectedTab: Tab                    // Current selected tab
router[tab]: [Destination]                 // Path for specific tab
router.selectedTabPath: [Destination]      // Path for current tab
router.push(_:for:)                        // Push to specific tab
router.pop(for:)                           // Pop from specific tab
router.popToRoot(for:)                     // Pop to root for tab
router.presentSheet(_:)                    // Present sheet
router.dismissSheet()                      // Dismiss sheet
router.reset()                             // Reset all state
```

---

## Target Architecture

### New Flow

```
MainViewRouter.route
├── .onboarding
│   └── OnboardingView (NavigationStack) [UNCHANGED]
│       └── Welcome → Email → Code → Profile
└── .main
    └── ContentView2
        └── NavigationStack (single)
            └── HomeView (root)
                ├── → ArchivedChatsView
                ├── → SpacesView
                │   └── → SpaceView
                ├── → ChatView
                ├── → SettingsView
                └── Sheets (unchanged)
```

### New Router API

```swift
// NavigationModel<Destination, Sheet>
router.path: [Destination]                 // Single navigation path
router.push(_:)                            // Push destination
router.pop()                               // Pop last
router.popToRoot()                         // Clear path
router.presentSheet(_:)                    // Present sheet
router.dismissSheet()                      // Dismiss sheet
router.reset()                             // Reset all state
```

---

## Files Analysis

### Core Navigation Files (Need Significant Changes)

#### 1. Navigation/Router.swift
**Current State:**
- Generic over `Tab`, `Destination`, `Sheet`
- Maintains `paths: [Tab: [Destination]]` dictionary
- Has `selectedTab: Tab` property
- Persists per-tab paths

**Changes Required:**
- Remove `Tab` generic parameter
- Replace `paths` dictionary with single `path: [Destination]` array
- Remove `selectedTab`, `initialTab` properties
- Remove `selectedTabPath` computed property
- Simplify all navigation methods to work on single path
- Update persistence keys (remove tab-specific keys)

#### 2. Navigation/Protocols.swift
**Current State:**
```swift
public protocol DestinationType: Hashable, Codable {}
public protocol TabType: Hashable, CaseIterable, Identifiable, Sendable, Codable {
  var icon: String { get }
}
public protocol SheetType: Hashable, Identifiable, Codable {}
```

**Changes Required:**
- Remove `TabType` protocol entirely

#### 3. Navigation/AppContent.swift
**Current State:**
```swift
typealias Router = NavigationModel<AppTab, Destination, Sheet>

enum AppTab: String, TabType, CaseIterable, Codable {
  case archived, chats, spaces
  // ...
}

enum Destination: DestinationType, Codable {
  case chats
  case archived
  case spaces
  case space(id: Int64)
  case chat(peer: Peer)
  // ... more cases
}
```

**Changes Required:**
- Remove `AppTab` enum entirely
- Update Router typealias: `typealias Router = NavigationModel<Destination, Sheet>`
- Remove `.chats`, `.archived`, `.spaces` from Destination (they were tab roots, not pushable)
- Update `navigateFromNotification()` extension to remove tab logic

#### 4. ContentView.swift
**Current State:**
- Uses `TabView(selection: $bindableRouter.selectedTab)`
- Has `tabContentView(for:)` returning view per tab
- Has `destinationView(for:)` for navigation destinations

**Changes Required:**
- Remove TabView structure
- Use single `NavigationStack(path: $bindableRouter.path)`
- Set HomeView as root view
- Remove `tabContentView(for:)` function
- Keep `destinationView(for:)` and `sheetView(for:)`
- Keep all environment objects

#### 5. AppDelegate.swift (line 12)
**Current State:**
```swift
let router = NavigationModel<AppTab, Destination, Sheet>(initialTab: .chats)
```

**Changes Required:**
```swift
let router = NavigationModel<Destination, Sheet>()
```

---

### Files Using Router (Need Minor Updates)

#### Sheets/CreateSpace.swift (lines 69-70)
**Current:**
```swift
router.selectedTab = .spaces
router.push(.space(id: id))
```
**After:**
```swift
router.push(.space(id: id))
```

#### Lists/ChatListView.swift (line 48)
**Current:**
```swift
let currentPath = router.selectedTabPath
```
**After:**
```swift
let currentPath = router.path
```

---

### Files Using Router (No Changes Needed)

These files use standard router methods that remain unchanged:

| File | Router Usage |
|------|-------------|
| `MainViews/HomeView.swift` | `router.push(.chat(...))` |
| `MainViews/HomeToolbarContent.swift` | `router.push()`, `router.presentSheet()` |
| `MainViews/ArchivedChatsView.swift` | `router.push(.chat(...))` |
| `MainViews/SpacesView.swift` | `router.push()`, `router.presentSheet()` |
| `Features/Chat/ChatView.swift` | `router.push()`, `router.pop()` |
| `Features/Chat/ChatView+extensions.swift` | `router.push(.chatInfo(...))` |
| `Features/Space/SpaceView.swift` | `router.push()`, `router.presentSheet()` |
| `Features/Space/ChatItemRow.swift` | `router.push(.chat(...))` |
| `Features/Space/MemberItemRow.swift` | `router.push(.chat(...))` |
| `Features/CreateChat/CreateChatView.swift` | `router.popToRoot()`, `router.push()` |
| `Features/Settings/SpaceIntegrationsView.swift` | `router.push()` |
| `Features/Settings/LogoutSection.swift` | Uses router (check for reset) |

---

### Onboarding Files (No Changes)

Onboarding has its own separate NavigationStack and navigation model:

| File | Purpose |
|------|---------|
| `Utils/OnboardingNavigation.swift` | Onboarding path: `[OnboardingStep]` |
| `Utils/MainViewRouter.swift` | Switches `.main` / `.onboarding` |
| `Auth/OnboardingView.swift` | OnboardingView with NavigationStack |
| `Auth/Welcome.swift` | Welcome screen |
| `Auth/Email.swift` | Email input |
| `Auth/Code.swift` | Email verification code |
| `Auth/PhoneNumber.swift` | Phone input |
| `Auth/PhoneNumberCode.swift` | Phone verification code |
| `Auth/Profile.swift` | Profile setup |

---

## Detailed Implementation

### New Router.swift Structure

```swift
@Observable
@MainActor
public final class NavigationModel<Destination: DestinationType, Sheet: SheetType> {
  public var path: [Destination] = [] {
    didSet { savePersistentState() }
  }

  public var presentedSheet: Sheet? {
    didSet { savePersistentState() }
  }

  private let pathKey = "AppRouter_path"
  private let presentedSheetKey = "AppRouter_presentedSheet"

  public init() {
    loadPersistentState()
  }

  public func push(_ destination: Destination) {
    path.append(destination)
  }

  public func pop() {
    guard !path.isEmpty else { return }
    path.removeLast()
  }

  public func popToRoot() {
    path = []
  }

  public func presentSheet(_ sheet: Sheet) {
    presentedSheet = sheet
  }

  public func dismissSheet() {
    presentedSheet = nil
  }

  public func reset() {
    path = []
    presentedSheet = nil
    UserDefaults.standard.removeObject(forKey: pathKey)
    UserDefaults.standard.removeObject(forKey: presentedSheetKey)
  }

  // Persistence methods...
}
```

### New ContentView.swift Structure

```swift
var content: some View {
  switch mainViewRouter.route {
    case .main:
      NavigationStack(path: $bindableRouter.path) {
        HomeView()
          .navigationDestination(for: Destination.self) { destination in
            destinationView(for: destination)
          }
      }
      .sheet(item: $bindableRouter.presentedSheet) { sheet in
        sheetView(for: sheet)
      }
    case .onboarding:
      OnboardingView()
  }
}
```

### New AppContent.swift Destination

```swift
enum Destination: DestinationType, Codable {
  // Remove: case chats, archived, spaces (were tab roots)
  case space(id: Int64)
  case chat(peer: Peer)
  case chatInfo(chatItem: SpaceChatItem)
  case settings
  case spaceSettings(spaceId: Int64)
  case spaceIntegrations(spaceId: Int64)
  case integrationOptions(spaceId: Int64, provider: String)
  case createSpaceChat
  case createThread(spaceId: Int64)
  case archivedChats  // New: pushable destination
  case spacesRoot     // New: pushable destination
}
```

### Navigation Extension Update

```swift
@MainActor
extension Router {
  func navigateFromNotification(peer: Peer) {
    // Check if already in the correct chat
    if let currentDestination = path.last,
       case let .chat(currentPeer) = currentDestination,
       currentPeer == peer
    {
      return
    }

    DispatchQueue.main.asyncAfter(deadline: .now() + 0.15) {
      self.popToRoot()
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        self.push(.chat(peer: peer))
      }
    }
  }
}
```

---

## Migration Notes

### UserDefaults Keys
- Remove: `AppRouter_paths`, `AppRouter_selectedTab`
- Keep: `AppRouter_presentedSheet`
- Add: `AppRouter_path`

Users will lose their navigation state on first launch after update (acceptable).

### Breaking Changes
- `router.selectedTab` - removed
- `router[tab]` subscript - removed
- `router.selectedTabPath` - removed
- `router.push(_:for:)` - simplified to `router.push(_:)`
- `router.pop(for:)` - simplified to `router.pop()`
- `router.popToRoot(for:)` - simplified to `router.popToRoot()`

### Toolbar Updates
HomeToolbarContent already has menu items for Settings. Need to add navigation options for:
- Spaces (push `.spacesRoot`)
- Archived (push `.archivedChats`)

---

## Testing Considerations

1. **Navigation persistence** - Verify path saves/restores correctly
2. **Deep linking** - Test `navigateFromNotification` works
3. **Sheet presentation** - Verify sheets still work
4. **Onboarding flow** - Ensure onboarding → main transition works
5. **Logout flow** - Verify main → onboarding transition works
6. **Back navigation** - Test pop behavior throughout app

---

## File Change Summary

| Category | Count | Files |
|----------|-------|-------|
| Core navigation (major changes) | 5 | Router.swift, Protocols.swift, AppContent.swift, ContentView.swift, AppDelegate.swift |
| Router usage (minor updates) | 2 | CreateSpace.swift, ChatListView.swift |
| Router usage (no changes) | 12 | Various feature files |
| Onboarding (no changes) | 9 | Auth files, MainViewRouter, OnboardingNavigation |
| **Total files to modify** | **7** | |
