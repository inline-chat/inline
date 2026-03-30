# Telegram Postbox Logical Schema

Date: 2026-03-08

Purpose: save a reusable reference for Telegram macOS/iOS local storage schema at the Swift type level.

Important context:
- Telegram macOS (`TelegramSwift`) reuses the shared `Postbox` / `TelegramCore` code from the `Telegram-iOS` repo.
- The main account DB is not modeled as normal relational tables like `messages`, `dialogs`, `attachments`.
- Most logical tables are `t<ID>` key-value stores, and the real schema is encoded in Swift types and binary key/value layouts.

## Main Table Map

- `t2`: `PeerTable`
- `t8`: `ChatListIndexTable`
- `t9`: `ChatListTable`
- `t4`: `MessageHistoryIndexTable`
- `t7`: `MessageHistoryTable`
- `t6`: `MessageMediaTable`
- `t14`: `MessageHistoryReadStateTable`
- `t56`: `MessageHistoryHoleIndexTable`

Source:
- `/Users/mo/dev/telegram/Telegram-iOS/submodules/Postbox/Sources/Postbox.swift`

## Core Identity Types

```swift
struct PeerId {
    let namespace: PeerId.Namespace
    let id: PeerId.Id
}

struct MessageId {
    let peerId: PeerId
    let namespace: Int32
    let id: Int32
}

struct MessageIndex {
    let id: MessageId
    let timestamp: Int32
}

struct ChatListIndex {
    let pinningIndex: UInt16?
    let messageIndex: MessageIndex
}

struct MediaId {
    let namespace: Int32
    let id: Int64
}
```

Sources:
- `/Users/mo/dev/telegram/Telegram-iOS/submodules/Postbox/Sources/Peer.swift`
- `/Users/mo/dev/telegram/Telegram-iOS/submodules/Postbox/Sources/Message.swift`
- `/Users/mo/dev/telegram/Telegram-iOS/submodules/Postbox/Sources/Media.swift`

## Peer Table (`t2`)

Logical shape:

```swift
protocol Peer: AnyObject, PostboxCoding {
    var id: PeerId { get }
    var indexName: PeerIndexNameRepresentation { get }
    var associatedPeerId: PeerId? { get }
    var additionalAssociatedPeerId: PeerId? { get }
    var associatedPeerOverridesIdentity: Bool { get }
    var notificationSettingsPeerId: PeerId? { get }
    var associatedMediaIds: [MediaId]? { get }
    var timeoutAttribute: UInt32? { get }
}
```

Physical layout:
- key: `PeerId` as `Int64`
- value: serialized concrete `Peer` object

Important point:
- There is no single normalized user/chat/channel row.
- The peer table stores polymorphic peer objects directly.

Concrete peer types:

```swift
final class TelegramUser: Peer {
    let id: PeerId
    let accessHash: TelegramPeerAccessHash?
    let firstName: String?
    let lastName: String?
    let username: String?
    let phone: String?
    let photo: [TelegramMediaImageRepresentation]
    let botInfo: BotUserInfo?
    let flags: UserInfoFlags
    ...
}

final class TelegramGroup: Peer {
    let id: PeerId
    let title: String
    let photo: [TelegramMediaImageRepresentation]
    let participantCount: Int
    let role: TelegramGroupRole
    let membership: TelegramGroupMembership
    let flags: TelegramGroupFlags
    ...
}

final class TelegramChannel: Peer {
    let id: PeerId
    let accessHash: TelegramPeerAccessHash?
    let title: String
    let username: String?
    let photo: [TelegramMediaImageRepresentation]
    let creationDate: Int32
    let participationStatus: TelegramChannelParticipationStatus
    let info: TelegramChannelInfo
    let flags: TelegramChannelFlags
    ...
}

final class TelegramSecretChat: Peer {
    ...
}
```

Sources:
- `/Users/mo/dev/telegram/Telegram-iOS/submodules/Postbox/Sources/PeerTable.swift`
- `/Users/mo/dev/telegram/Telegram-iOS/submodules/Postbox/Sources/Peer.swift`
- `/Users/mo/dev/telegram/Telegram-iOS/submodules/TelegramCore/Sources/SyncCore/SyncCore_TelegramUser.swift`
- `/Users/mo/dev/telegram/Telegram-iOS/submodules/TelegramCore/Sources/SyncCore/SyncCore_TelegramGroup.swift`
- `/Users/mo/dev/telegram/Telegram-iOS/submodules/TelegramCore/Sources/SyncCore/SyncCore_TelegramChannel.swift`
- `/Users/mo/dev/telegram/Telegram-iOS/submodules/TelegramCore/Sources/SyncCore/SyncCore_TelegramSecretChat.swift`

## Dialog / Chat List Tables (`t8`, `t9`)

Telegram does not persist a single `Dialog` struct like a typical chat app.

Instead, dialog state is split into:
- per-peer inclusion and top-message state in `t8`
- ordered chat-list rows in `t9`
- read state and interface state from related tables when building views

### `t8` ChatListIndexTable

Logical shape:

```swift
struct ChatListPeerInclusionIndex {
    let topMessageIndex: MessageIndex?
    let inclusion: PeerChatListInclusion
}

enum PeerChatListInclusion {
    case notIncluded
    case ifHasMessagesOrOneOf(
        groupId: PeerGroupId,
        pinningIndex: UInt16?,
        minTimestamp: Int32?
    )
}

enum PeerGroupId {
    case root
    case group(Int32)
}
```

Physical layout:
- key: `PeerId`
- value: compact binary payload containing:
  - optional `topMessageIndex`
  - inclusion state
  - optional pinning index
  - optional minimum timestamp
  - peer group id

### `t9` ChatListTable

Physical row forms:

```swift
enum ChatListIntermediateEntry {
    case message(ChatListIndex, MessageIndex?)
    case hole(ChatListHole)
}

struct ChatListHole {
    let index: MessageIndex
}
```

Higher-level rendered view form:

```swift
enum ChatListNamespaceEntry {
    case peer(
        index: ChatListIndex,
        readState: PeerReadState?,
        topMessageAttributes: [MessageAttribute],
        tagSummary: MessageHistoryTagNamespaceSummary?,
        interfaceState: StoredPeerChatInterfaceState?
    )
    case hole(MessageIndex)
}
```

Important point:
- Telegram persists hole rows directly in the ordered chat list.
- Dialog ordering is part of the key space, not a `dialogs.sort_key` column.

Sources:
- `/Users/mo/dev/telegram/Telegram-iOS/submodules/Postbox/Sources/ChatListIndexTable.swift`
- `/Users/mo/dev/telegram/Telegram-iOS/submodules/Postbox/Sources/PeerChatListInclusion.swift`
- `/Users/mo/dev/telegram/Telegram-iOS/submodules/Postbox/Sources/PeerGroup.swift`
- `/Users/mo/dev/telegram/Telegram-iOS/submodules/Postbox/Sources/ChatListTable.swift`
- `/Users/mo/dev/telegram/Telegram-iOS/submodules/Postbox/Sources/ChatListHole.swift`

## Message Tables (`t4`, `t7`)

Telegram splits messages into:
- `t4`: lightweight id-based index
- `t7`: heavier message payload keyed by chronological index

### `t4` MessageHistoryIndexTable

Logical shape:

```swift
struct MessageHistoryIndexEntry {
    let timestamp: Int32
    let isIncoming: Bool
}
```

Physical layout:
- key: `MessageId`
- value:
  - flags byte
  - timestamp

Notes:
- This is used for existence checks, message-id lookups, incoming counts, and gap logic.
- It avoids decoding the full message payload when only id/timestamp information is needed.

### `t7` MessageHistoryTable

Stored intermediate shape:

```swift
struct IntermediateMessageForwardInfo {
    let authorId: PeerId?
    let sourceId: PeerId?
    let sourceMessageId: MessageId?
    let date: Int32
    let authorSignature: String?
    let psaType: String?
    let flags: MessageForwardInfo.Flags
}

class IntermediateMessage {
    let stableId: UInt32
    let stableVersion: UInt32
    let id: MessageId
    let globallyUniqueId: Int64?
    let groupingKey: Int64?
    let groupInfo: MessageGroupInfo?
    let threadId: Int64?
    let timestamp: Int32
    let flags: MessageFlags
    let tags: MessageTags
    let globalTags: GlobalMessageTags
    let localTags: LocalMessageTags
    let customTags: [MemoryBuffer]
    let forwardInfo: IntermediateMessageForwardInfo?
    let authorId: PeerId?
    let text: String
    let attributesData: ReadBuffer
    let embeddedMediaData: ReadBuffer
    let referencedMedia: [MediaId]
}
```

Public rendered message shape used by views:

```swift
struct MessageGroupInfo {
    let stableId: UInt32
}

struct MessageForwardInfo {
    let author: Peer?
    let source: Peer?
    let sourceMessageId: MessageId?
    let date: Int32
    let authorSignature: String?
    let psaType: String?
    let flags: Flags
}

final class Message {
    let stableId: UInt32
    let stableVersion: UInt32
    let id: MessageId
    let globallyUniqueId: Int64?
    let groupingKey: Int64?
    let groupInfo: MessageGroupInfo?
    let threadId: Int64?
    let timestamp: Int32
    let flags: MessageFlags
    let tags: MessageTags
    let globalTags: GlobalMessageTags
    let localTags: LocalMessageTags
    let customTags: [MemoryBuffer]
    let forwardInfo: MessageForwardInfo?
    let author: Peer?
    let text: String
    let attributes: [MessageAttribute]
    let media: [Media]
    let peers: SimpleDictionary<PeerId, Peer>
    let associatedMessages: SimpleDictionary<MessageId, Message>
    let associatedMessageIds: [MessageId]
    let associatedMedia: [MediaId: Media]
    let associatedThreadInfo: Message.AssociatedThreadInfo?
    let associatedStories: [StoryId: CodableEntry]
}
```

The `t7` value blob stores, in order:
- `stableId`
- `stableVersion`
- data flags
- optional `globallyUniqueId`
- optional `globalTags`
- optional `groupingKey`
- optional `groupInfo`
- optional `localTags`
- optional `threadId`
- `flags`
- `tags`
- optional `forwardInfo`
- optional `authorId`
- `text`
- encoded array of `MessageAttribute`
- encoded array of embedded `Media`
- array of referenced `MediaId`
- array of custom tags

Important point:
- The stored message is not yet the full UI message.
- Telegram renders it by decoding the attributes/media blobs, resolving peers from the peer table, resolving referenced media from `t6`, and pulling in associated messages/media/stories.

Sources:
- `/Users/mo/dev/telegram/Telegram-iOS/submodules/Postbox/Sources/MessageHistoryIndexTable.swift`
- `/Users/mo/dev/telegram/Telegram-iOS/submodules/Postbox/Sources/IntermediateMessage.swift`
- `/Users/mo/dev/telegram/Telegram-iOS/submodules/Postbox/Sources/Message.swift`
- `/Users/mo/dev/telegram/Telegram-iOS/submodules/Postbox/Sources/MessageHistoryTable.swift`

## Media Table (`t6`)

Media is polymorphic too.

```swift
protocol Media: AnyObject, PostboxCoding {
    var id: MediaId? { get }
    var peerIds: [PeerId] { get }
    var storyIds: [StoryId] { get }
    var indexableText: String? { get }

    func isLikelyToBeUpdated() -> Bool
    func preventsAutomaticMessageSendingFailure() -> Bool
    func isEqual(to other: Media) -> Bool
    func isSemanticallyEqual(to other: Media) -> Bool
}
```

Logical table entry:

```swift
enum MediaTableEntry {
    case direct(media: Media, referenceCount: Int32)
    case messageReference(index: MessageIndex)
}
```

Meaning:
- `direct`: the media object is stored in `t6` itself, plus a reference count
- `messageReference`: `t6` points to a message whose `embeddedMediaData` contains the media object

Concrete media examples:

```swift
final class TelegramMediaImage: Media {
    let imageId: MediaId
    let representations: [TelegramMediaImageRepresentation]
    let videoRepresentations: [VideoRepresentation]
    let immediateThumbnailData: Data?
    let emojiMarkup: EmojiMarkup?
    let reference: TelegramMediaImageReference?
    let partialReference: PartialMediaReference?
    let flags: TelegramMediaImageFlags
}

final class TelegramMediaFile: Media {
    let fileId: MediaId
    let partialReference: PartialMediaReference?
    let resource: TelegramMediaResource
    let previewRepresentations: [TelegramMediaImageRepresentation]
    let videoThumbnails: [VideoThumbnail]
    let videoCover: TelegramMediaImage?
    let immediateThumbnailData: Data?
    let mimeType: String
    let size: Int64?
    let attributes: [TelegramMediaFileAttribute]
    let alternativeRepresentations: [TelegramMediaFile]
}

final class TelegramMediaAction: Media {
    ...
}
```

Important point:
- The main DB stores media metadata and object graphs, not raw downloaded file bytes.
- Actual media bytes live in `MediaBox` storage outside the main message DB.

Sources:
- `/Users/mo/dev/telegram/Telegram-iOS/submodules/Postbox/Sources/Media.swift`
- `/Users/mo/dev/telegram/Telegram-iOS/submodules/Postbox/Sources/MessageMediaTable.swift`
- `/Users/mo/dev/telegram/Telegram-iOS/submodules/TelegramCore/Sources/SyncCore/SyncCore_TelegramMediaImage.swift`
- `/Users/mo/dev/telegram/Telegram-iOS/submodules/TelegramCore/Sources/SyncCore/SyncCore_TelegramMediaFile.swift`
- `/Users/mo/dev/telegram/Telegram-iOS/submodules/TelegramCore/Sources/SyncCore/SyncCore_TelegramMediaAction.swift`

## What Matters Architecturally

- There is no classic relational `dialogs/messages/attachments` schema.
- Peers and media are polymorphic object graphs.
- Dialog state is split between per-peer inclusion state and ordered chat-list rows.
- Message storage is split between:
  - id index
  - chronological payload row
  - holes
  - tags
  - threads
  - read state
  - media dedup/reference table
- The UI consumes rendered `Message` objects, not the raw stored message blobs.

## Good Follow-up Files

- `/Users/mo/dev/telegram/Telegram-iOS/submodules/Postbox/Sources/MessageHistoryHoleIndexTable.swift`
- `/Users/mo/dev/telegram/Telegram-iOS/submodules/Postbox/Sources/MessageHistoryViewState.swift`
- `/Users/mo/dev/telegram/Telegram-iOS/submodules/Postbox/Sources/MessageHistoryView.swift`
- `/Users/mo/dev/telegram/TelegramSwift/Telegram-Mac/ChatHistoryEntry.swift`

