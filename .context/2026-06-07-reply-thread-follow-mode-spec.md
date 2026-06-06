# Reply Thread Follow Mode

## Model

- `dialog.open` remains current sidebar membership.
- `dialog.chatListHidden` remains current normal chat-list visibility.
- `dialog.followMode` is the automatic surfacing policy for reply threads.
- `dialog.notificationSettings` remains push/OS notification policy and does not imply following.

## Follow Modes

- `nil`: default relevance mode.
- `following`: all new reply-thread activity may surface the dialog.
- No `none` mode for v1; add it later only if users need "never auto-surface".

## Manual Follow

The toolbar Follow toggle is the one place where following also surfaces immediately:

- Follow sets `followMode = following`, then opens/shows/unarchives the dialog with normal sidebar order assignment.
- Unfollow clears `followMode`.
- Unfollow does not close, hide, archive, or reorder the dialog.

## Auto-Follow

Set `followMode = following` when the user actively owns/participates in the reply thread:

- User creates/starts the reply thread.
- User sends a message in the reply thread.
- A reply thread is created/used on a parent message authored by the user.

Auto-follow is policy-only. It does not immediately open, show, unarchive, or reorder the dialog.

## Auto-Surface

On a new message in a reply thread, existing open/chat-list mechanics are applied only when policy or relevance says so:

- If `followMode = following`, any incoming message can set `open = true`, `chatListHidden = nil`, `archived = false`, and assign order if needed.
- If `followMode = nil`, only relevance events can surface: explicit mention or direct reply to one of the user's messages inside the reply thread.
- Relevance surfacing does not set `followMode`.

## Notifications

Notifications are independent:

- Following controls in-app surfacing.
- Notification settings control push/OS interruption.
- `notificationSettings = all` should not silently follow or surface a thread.
- Muting notifications should not suppress in-app relevance surfacing.

## UI Scope

- Show the Follow toolbar button only for reply threads for now.
- Keep existing "Open in Sidebar" and "Keep in Chat List" mechanics unless they directly conflict with follow policy.
