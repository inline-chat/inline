---
title: "AppleScript"
description: "Inline for Mac AppleScript syntax and examples."
---

Inline supports scripting on macOS via AppleScript. Here's a guide with some examples that are useful for asking your LLM to create any scripts you may want for making shortcuts, local integrations, etc.

## Account and Spaces

Return the current account and cached spaces:

```applescript
tell application "Inline"
  return {current account, list spaces}
end tell
```

## Current Conversation

Return the open reply thread or primary conversation:

```applescript
tell application "Inline"
  set selectedChat to current selection
  if selectedChat is missing value then error "Open a conversation first." number -1728
  return {id of selectedChat, name of selectedChat, URL of selectedChat}
end tell
```

- `current selection`: open reply thread, otherwise the primary conversation.
- `current thread`: alias for `current selection`.
- `current chat`: primary conversation only.

## Find a Person

Search cached users in a space:

```applescript
tell application "Inline"
  return find users "@maya" in space "7" maximum count 20
end tell
```

Search public usernames when the person is not cached:

```applescript
tell application "Inline"
  return search public users "@maya" maximum count 20
end tell
```

## IDs

Keep IDs as quoted decimal text, such as `"42"`.

## Create a Thread and Send

Replace the space ID and username before running:

```applescript
tell application "Inline"
  set people to find users "@maya" in space "7"
  if (count of people) is not 1 then error "Choose exactly one participant."
  set recipient to user id of item 1 of people

  set newThread to create thread "Release review" in space "7" participant ids {recipient}
  set destination to chat id of newThread
  set body to "**Ready for review** — [@Maya](inline://user/" & recipient & ")"
  return send message body to chat destination
end tell
```

Create a public space thread with `publicly visible true` and no participant list. Home threads cannot be public.

## Send and Retry

Send Markdown to a known chat:

```applescript
tell application "Inline"
  return send message "**Build passed**" to chat "123"
end tell
```

Reuse the same positive Int64 request ID only when retrying the same logical send:

```applescript
tell application "Inline"
  return send message "Build passed" to chat "123" request id "456"
end tell
```

- Markdown mentions: `[@Maya](inline://user/42)`
- Success returns `chat id`, `message id`, and `send request id`.

## Open a Chat and Copy Its Link

Find one cached chat, open it, and copy its link:

```applescript
tell application "Inline"
  set matches to find chats "Design" maximum count 20
  if (count of matches) is not 1 then error "Choose a more specific name."
  set destination to chat id of item 1 of matches
  open chat destination
  set the clipboard to chat link destination
end tell
```

## Shell Script

Save this as `notify-inline.applescript`:

```applescript
on run argv
  if (count of argv) is not 2 then error "Usage: notify-inline.applescript CHAT_ID MARKDOWN"
  set destination to item 1 of argv
  set body to item 2 of argv
  tell application "Inline"
    set receipt to send message body to chat destination
    return message id of receipt
  end tell
end run
```

Run it with a chat ID and Markdown body:

```bash
osascript ./notify-inline.applescript "123" "**Build passed**"
```

## Command Syntax

- `show inline`
- `current account`
- `list spaces`
- `list users [in space "7"] [maximum count 20]`
- `find users "Maya" [in space "7"] [maximum count 20]`
- `user info "42"`
- `search public users "@maya" [maximum count 20]`
- `list chats [in space "7"] [maximum count 20]`
- `find chats "Design" [in space "7"] [maximum count 20]`
- `current chat` / `current thread` / `current selection`
- `open chat "123"`
- `create thread "Review" [in space "7"] [participant ids {"42"}] [publicly visible true]`
- `recent messages "123" [before message "789"] [maximum count 20]`
- `send message "Hello" to chat "123" [request id "456"]`
- `chat link "123"`

Lists use cached data. Counts accept 1–100; public search returns at most 20 results. Titles are limited to 150 UTF-16 units. Commands have a 30-second deadline and at most 16 may be in flight.

macOS Automation permission is required. Errors: `-1743` permission, `-10004` account unavailable, `-1728` item unavailable, `-1712` timeout, `-10000` operation failed.

---

[Deep-link formats](/docs/technical/deep-links) · [Bot API](/docs/bot-api) · [CLI](/docs/cli)
