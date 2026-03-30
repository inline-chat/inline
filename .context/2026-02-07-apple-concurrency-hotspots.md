# Apple Concurrency Hotspots (Swift)

Scope: quick scan for Task.detached, @unchecked Sendable, and nonisolated(unsafe) in apple sources.

## Task.detached hotspots

- apple/InlineKit/Sources/InlineKit/RealtimeAPI/Updates.swift
- apple/InlineKit/Sources/RealtimeV2/Realtime/Realtime.swift
- apple/InlineKit/Sources/InlineKit/Transactions/Actor.swift
- apple/InlineKit/Sources/InlineKit/RealtimeHelpers/RealtimeWrapper.swift
- apple/InlineKit/Sources/InlineKit/Drafts.swift
- apple/InlineKit/Sources/InlineKit/ViewModels/ComposeActions.swift
- apple/InlineKit/Sources/InlineKit/ViewModels/HomeViewModel.swift
- apple/InlineKit/Sources/InlineKit/Transactions2/GetChatHistoryTransaction.swift
- apple/InlineKit/Sources/InlineKit/Transactions2/SearchMessagesTransaction.swift
- apple/InlineKit/Sources/InlineKit/UserSettings/INUserSettings.swift
- apple/InlineKit/Sources/InlineKit/DataManager.swift
- apple/InlineKit/Sources/RealtimeV2/Transaction/Transactions.swift
- apple/InlineIOS/Utils/ImagePrefetcher.swift
- apple/InlineIOS/Features/Chat/MessagesCollectionView.swift
- apple/InlineIOS/Features/Compose/ComposeView.swift
- apple/InlineIOS/Shared/AppDataUpdater.swift
- apple/InlineIOS/Navigation/Router.swift
- apple/InlineMac/Views/Compose/ComposeAppKit.swift
- apple/InlineMac/Features/MainWindow/MainSplitView.swift
- apple/InlineMac/Views/Main/MainSplitViewAppKit.swift
- apple/InlineMac/Views/Sidebar/NewSidebar/NewSidebar.swift
- apple/InlineMac/Views/Sidebar/MainSidebar/SpaceSidebar.swift
- apple/InlineUI/Sources/InlineUI/CreateChatView.swift
- apple/InlineUI/Sources/InlineUI/PlatformPhotoView.swift
- apple/InlineUI/Sources/InlineUI/UserAvatar.swift
- apple/InlineUI/Sources/Translation/TranslationDetector.swift
- apple/InlineShareExtension/ShareState.swift

## @unchecked Sendable hotspots

- apple/InlineKit/Sources/InlineKit/ApiClient.swift
- apple/InlineKit/Sources/InlineKit/NotificationData.swift
- apple/InlineKit/Sources/InlineKit/Debouncer.swift
- apple/InlineKit/Sources/InlineKit/Transactions/Transactions.swift
- apple/InlineKit/Sources/InlineKit/Models/Space.swift
- apple/InlineKit/Sources/InlineKit/Models/Member.swift
- apple/InlineKit/Sources/InlineKit/ViewModels/FullChat.swift
- apple/InlineKit/Sources/InlineKit/ViewModels/FullMessage.swift
- apple/InlineKit/Sources/InlineKit/ViewModels/ChatDocuments.swift
- apple/InlineKit/Sources/InlineKit/ViewModels/ChatLinks.swift
- apple/InlineKit/Sources/InlineKit/ViewModels/ChatParticipantsViewModel.swift
- apple/InlineKit/Sources/InlineKit/ViewModels/ChatPhotos.swift
- apple/InlineKit/Sources/InlineKit/ViewModels/ChatMedia.swift
- apple/InlineKit/Sources/InlineKit/UserSettings/NotificationSettings.swift
- apple/InlineKit/Sources/InlineKit/NotionTaskManager.swift
- apple/InlineKit/Sources/InlineKit/TimeZoneFormatter.swift
- apple/InlineIOS/Utils/UserData.swift
- apple/InlineIOS/Utils/Navigation.swift
- apple/InlineIOS/Shared/SharedApiClient.swift
- apple/InlineIOS/UI/OnboardingUtils.swift
- apple/InlineKit/Sources/InlineProtocol/core.pb.swift (generated)

## nonisolated(unsafe) hotspots

- apple/InlineUI/Sources/TextProcessing/ProcessEntities.swift
- apple/InlineUI/Sources/Translation/UserLocale.swift
- apple/InlineMacUI/Sources/MacTheme/Theme.swift
- apple/InlineKit/Sources/InlineProtocol/core.pb.swift (generated)
