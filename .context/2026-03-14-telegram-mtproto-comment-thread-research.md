# Telegram MTProto comment thread research

Date: 2026-03-14

## Question

How Telegram ships information about a subthread or comment thread to clients in the MTProto API.

## Short answer

Telegram does not expose a distinct standalone "comment thread" entity in MTProto. For channel comments, the thread is represented as a normal message thread keyed by:

- the discussion peer
- the root or top message id

The wire-level flow is:

1. A channel post contains lightweight thread summary data in `Message.replies`.
2. The client resolves the discussion-side root with `messages.getDiscussionMessage`.
3. The client paginates actual comments with `messages.getReplies`.
4. Individual reply messages indicate thread membership through `reply_to_top_id`.
5. Read state is synchronized with `messages.readDiscussion` and discussion read updates.

## Relevant TL types

### `Message.replies`

`message#... replies:flags.23?MessageReplies = Message`

`MessageReplies` is the main summary object attached to the post:

```tl
messageReplies#83d60fc2 flags:# comments:flags.0?true replies:int replies_pts:int recent_repliers:flags.1?Vector<Peer> channel_id:flags.0?long max_id:flags.2?int read_max_id:flags.3?int = MessageReplies;
```

Important fields:

- `comments`: marks that this reply thread is a comments/discussion thread
- `channel_id`: linked discussion chat id
- `replies`: count
- `recent_repliers`
- `max_id`: highest known message id in the thread
- `read_max_id`: highest read message id in the thread

Source:

- `/Users/mo/dev/telegram/telegram_api.tl`

### `MessageReplyHeader`

```tl
messageReplyHeader#6917560b flags:# reply_to_scheduled:flags.2?true forum_topic:flags.3?true quote:flags.9?true reply_to_msg_id:flags.4?int reply_to_peer_id:flags.0?Peer reply_from:flags.5?MessageFwdHeader reply_media:flags.8?MessageMedia reply_to_top_id:flags.1?int quote_text:flags.6?string quote_entities:flags.7?Vector<MessageEntity> quote_offset:flags.10?int todo_item_id:flags.11?int = MessageReplyHeader;
```

Important fields:

- `reply_to_msg_id`: direct parent reply target
- `reply_to_top_id`: thread root

This is the core field clients use to determine that a message belongs to a thread.

### `messages.DiscussionMessage`

```tl
messages.discussionMessage#a6341782 flags:# messages:Vector<Message> max_id:flags.0?int read_inbox_max_id:flags.1?int read_outbox_max_id:flags.2?int unread_count:int chats:Vector<Chat> users:Vector<User> = messages.DiscussionMessage;
```

This is the resolution payload for a channel post's comment thread.

## Relevant RPCs

### `messages.getDiscussionMessage`

```tl
messages.getDiscussionMessage#446972fd peer:InputPeer msg_id:int = messages.DiscussionMessage;
```

Purpose:

- given a channel post, resolve the discussion-side thread root
- return thread-level read state and unread count
- return the messages needed to anchor the thread locally

### `messages.getReplies`

```tl
messages.getReplies#22ddd30c peer:InputPeer msg_id:int offset_id:int offset_date:int add_offset:int limit:int max_id:int min_id:int hash:long = messages.Messages;
```

Purpose:

- paginate actual messages inside the thread

The important input is:

- `peer`: the discussion peer, not the original broadcast channel
- `msg_id`: the thread root message id in that discussion peer

### `messages.readDiscussion`

```tl
messages.readDiscussion#f731a9f4 peer:InputPeer msg_id:int read_max_id:int = Bool;
```

Purpose:

- advance read state for a discussion thread

## How Telegram maps a channel post to a comments thread

For channel comments, Telegram creates or uses a corresponding root message in the linked discussion group. Client code shows that this discussion root is tied back to the original broadcast post using forwarded-source metadata.

The relevant TL forward header fields are:

```tl
messageFwdHeader#4e4df4bb flags:# imported:flags.7?true saved_out:flags.11?true from_id:flags.0?Peer from_name:flags.5?string date:int channel_post:flags.2?int post_author:flags.3?string saved_from_peer:flags.4?Peer saved_from_msg_id:flags.4?int saved_from_id:flags.8?Peer saved_from_name:flags.9?string saved_date:flags.10?int psa_type:flags.6?string = MessageFwdHeader;
```

The practical mapping is:

- original channel post has `Message.replies.channel_id`
- `messages.getDiscussionMessage(channel, post_id)` returns the discussion-side root message
- that returned message is typically a forwarded copy referencing the original broadcast post through `saved_from_peer` and `saved_from_msg_id`

## What clients do with this data

### Telegram iOS

Observed behavior in `ReplyThreadHistory.swift` and `StoreMessage_Telegram.swift`:

- parse `Message.replies` into a local `ReplyThreadMessageAttribute`
- store `commentsPeerId` from `messageReplies.channel_id`
- call `messages.getDiscussionMessage` to resolve the real thread root
- inspect `SourceReferenceMessageAttribute` on the returned root to recover the original channel post id
- page the thread by calling `messages.getReplies(peer: commentsPeerId, msgId: discussionRootId, ...)`
- derive `threadId` for each message from `reply_to_top_id`

### Telegram Desktop

Observed behavior in `window_session_controller.cpp` and `data_replies_list.cpp`:

- opening comments triggers `MTPmessages_GetDiscussionMessage(history->peer->input(), rootId)`
- the returned `messages.discussionMessage` is used to:
  - process peers and messages
  - set the discussion-side item id on the original post
  - set `commentsMaxId`
  - set inbox read state and unread count
- reading comments triggers `MTPmessages_ReadDiscussion`

## Effective wire model

Telegram comment threads in MTProto are effectively represented by this tuple:

- original post: channel peer + post id
- discussion thread location: discussion peer + discussion root id
- membership of descendant messages: `reply_to_top_id`

The post carries a summary. The full thread is fetched separately.

## End-to-end request flow

When a user opens comments on a channel post:

1. Client already has or fetches the channel post `Message`.
2. Client reads `Message.replies`.
3. Client calls `messages.getDiscussionMessage(channelPeer, postId)`.
4. Server returns:
   - discussion-side root `messages`
   - read state
   - unread count
   - user and chat vectors
5. Client identifies the discussion peer and root message id.
6. Client loads comments with `messages.getReplies(discussionPeer, discussionRootId, ...)`.
7. Client groups replies using `reply_to_top_id`.

## Update flow

Read state stays synchronized through:

- `updateReadChannelDiscussionInbox`
- `updateReadChannelDiscussionOutbox`

These updates carry:

- discussion `channel_id`
- `top_msg_id`
- `read_max_id`
- sometimes the original broadcast channel and post

## Main conclusion

Telegram ships comment-thread information in MTProto as a combination of:

- inline summary metadata on the post via `MessageReplies`
- explicit thread resolution via `messages.getDiscussionMessage`
- thread pagination via `messages.getReplies`
- per-message thread linkage via `reply_to_top_id`

So "subthread/comment thread" is not a first-class standalone object on the wire. It is a thread convention built from standard message, reply, forward-reference, and update types.

## Files checked

- `/Users/mo/dev/telegram/telegram_api.tl`
- `/Users/mo/dev/telegram/tdesktop/Telegram/SourceFiles/mtproto/scheme/api.tl`
- `/Users/mo/dev/telegram/Telegram-iOS/submodules/TelegramCore/Sources/TelegramEngine/Messages/ReplyThreadHistory.swift`
- `/Users/mo/dev/telegram/Telegram-iOS/submodules/TelegramCore/Sources/ApiUtils/StoreMessage_Telegram.swift`
- `/Users/mo/dev/telegram/Telegram-iOS/submodules/TelegramCore/Sources/State/AccountViewTracker.swift`
- `/Users/mo/dev/telegram/Telegram-iOS/submodules/TelegramCore/Sources/State/AccountStateManagementUtils.swift`
- `/Users/mo/dev/telegram/Telegram-iOS/submodules/TelegramCore/Sources/SyncCore/SyncCore_ReplyThreadMessageAttribute.swift`
- `/Users/mo/dev/telegram/Telegram-iOS/submodules/TelegramCore/Sources/SyncCore/SyncCore_SourceReferenceMessageAttribute.swift`
- `/Users/mo/dev/telegram/tdesktop/Telegram/SourceFiles/window/window_session_controller.cpp`
- `/Users/mo/dev/telegram/tdesktop/Telegram/SourceFiles/data/data_replies_list.cpp`
- `/Users/mo/dev/telegram/tdesktop/Telegram/SourceFiles/data/data_histories.cpp`
- `/Users/mo/dev/telegram/tdesktop/Telegram/SourceFiles/history/history_item.cpp`
