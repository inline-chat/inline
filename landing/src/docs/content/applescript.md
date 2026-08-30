---
title: "AppleScript"
description: "Create threads, find people, send Markdown mentions, and automate Inline for Mac."
---

Automate Inline for Mac from Script Editor, a launcher, Shortcuts, or a shell script. Commands use the account signed in to the Mac app. No bot token or separate API login is needed.

## Get Started

Open **Script Editor → File → Open Dictionary** and choose Inline. These workflows require a build whose dictionary includes `create thread`, `find users`, and `current selection`. If a command is missing, your installed build does not support that workflow; check for an update that includes it.

Sign in to Inline and wait for your account to load. Paste this complete example into Script Editor and click **Run**:

```applescript
tell application "Inline"
  set accountInfo to current account
  set availableSpaces to list spaces
  return {accountInfo, availableSpaces}
end tell
```

The result contains your account and cached space records. Use their IDs in later scripts. **Keep all IDs as quoted decimal text**, such as `"42"`; AppleScript numbers can lose precision for large IDs. A user ID and a chat ID are different values.

macOS may ask the calling app for permission to control Inline. Grant access only to trusted software: it can read exposed chat text and identities, create threads, and send messages as you. Manage access in **System Settings → Privacy & Security → Automation**; Accessibility permission is not required.

The examples below are complete scripts unless marked as fragments. Replace example IDs and usernames with your own. Creation and send examples make real changes when you run them.

## Current Selection and Current Thread

Get a conversation's ID, name, and link without moving focus or changing the clipboard:

```applescript
tell application "Inline"
  set contextItem to current selection
  if contextItem is missing value then error "Open a conversation in Inline first." number -1728
  return {chat id of contextItem, title of contextItem, url of contextItem}
end tell
```

| Command | Which conversation? |
| --- | --- |
| `current selection` | The open reply thread, otherwise the primary conversation, in the frontmost visible, non-minimized Inline main window. |
| `current thread` | The primary conversation, including a DM; an alias for `current chat`. |
| `current chat` | The existing primary-conversation command. An open reply pane does not change its result. |

Each returns a chat record or `missing value`. Selection means the open conversation, not highlighted text, selected message rows, or keyboard focus. If a reply pane is open, `current selection` keeps targeting it even after a click in the parent pane. Use `current thread` for the parent. An open reply's metadata is available even when that reply is hidden from chat lists.

Chat records include `chat id`, `title`, `url`, and `markdown link`, alongside their other fields. The URL uses the stable ID, so renaming a thread does not change its link. The Markdown label escapes punctuation in titles and turns line breaks into spaces; `title` itself is unchanged. Keep one returned record when you need a consistent name and address.

## Connect Inline to Hookmark

[Hookmark](https://hookproductivity.com/help/integration/information-for-developers-api-requirements/) links an app's current resource to notes, documents, tasks, and other resources. Its integration needs a stable identity, a name, and a way to reopen the item.

In Hookmark's **Scripts** settings, select Inline and put this script in **Get Address**:

```applescript
tell application "Inline"
  set contextItem to current selection
  if contextItem is missing value then error "Open a conversation in Inline first." number -1728
  return markdown link of contextItem
end tell
```

Leave **Get Name** empty: [Hookmark accepts the name and URL together as a Markdown link](https://hookproductivity.com/help/integration/creating-integration-scripts/). Leave **Open Item** empty too; Inline already handles the returned URL. Use `current thread` instead if you always want to link the parent conversation rather than an open reply pane. Custom scripts require a Hookmark edition that supports editing integrations.

Open a conversation in Inline, invoke Hookmark, and copy its link. Confirm the name and destination, then hook it to a note or task. Opening the link later still requires an Inline account with access. These scripts do not use UI scripting or change the clipboard themselves; Hookmark's own commands and permissions are separate.

For **Hook to New**, this optional **New Item** script creates and opens a private Home thread containing only you:

```applescript
tell application "Inline"
  set createdThread to create thread "Hookmark note"
  set destination to chat id of createdThread
  try
    open chat destination
  on error errorText number errorNumber
    error ("Thread " & destination & " was created. Check Inline before creating another. " & errorText) number errorNumber
  end try
  return url of createdThread
end tell
```

This deliberately uses a fixed title; rename the thread in Inline afterward. Each invocation requests a new thread, so do not automatically retry creation after an uncertain result. You can add an initial message with the [review-thread workflow](#start-a-review-thread-with-a-mention).

For other launchers, or to paste into a Markdown note without Hookmark, copy the same link explicitly:

```applescript
tell application "Inline"
  set contextItem to current selection
  if contextItem is missing value then error "Open a conversation in Inline first." number -1728
  set linkText to markdown link of contextItem
end tell
set the clipboard to linkText
return linkText
```

These are custom integration recipes, not a claim that Inline is already included in Hookmark's built-in scripts. Test them with the Inline build you use before sharing an integration.

## Find People and User IDs

Find a cached person by name or username. Replace `"7"` with a space ID returned by `list spaces`, or omit `in space` to search all known cached identities:

```applescript
tell application "Inline"
  return find users "@maya" in space "7" maximum count 20
end tell
```

Each result contains `user id`, `display name`, `username`, and `is bot`. Matching is a literal substring, so inspect multiple matches before choosing someone. Use `list users in space "7"` for a cached roster, or `user info "42"` to look up one known ID.

Cached identities come from your account, visible conversations, and spaces where you have cached membership. They can be incomplete or stale. Lookup never creates a DM and does not expose email addresses or phone numbers.

For someone who is not cached, search public usernames explicitly:

```applescript
tell application "Inline"
  return search public users "@maya" maximum count 20
end tell
```

Public search uses the network, excludes you, and does not save results to the cache. Use the returned record directly; a later `user info` call may not find it. Public discovery is not proof of space membership. Queries need at least two characters; email and phone searches return no results. Owned bots also match names; other bots require an exact username.

## Start a Review Thread With a Mention

This script finds a participant, creates a private space thread, and sends its first message. Replace `"7"` and `"@maya"` before running. It stops if the cached search does not identify exactly one person.

```applescript
tell application "Inline"
  set people to find users "@maya" in space "7"
  if (count of people) is not 1 then error "Choose exactly one participant first."
  set recipient to user id of item 1 of people

  set reviewThread to create thread "Release review" in space "7" participant ids {recipient}
  set destination to chat id of reviewThread
  log ("Created thread: " & destination)

  set body to "**Ready for review** — [@Maya](inline://user/" & recipient & "), please take a look."
  try
    set receipt to send message body to chat destination
  on error errorText number errorNumber
    error ("Thread " & destination & " exists. Check it before retrying the message. " & errorText) number errorNumber
  end try
  return receipt
end tell
```

Success returns a receipt with `chat id`, `message id`, and `send request id`. Creation does not open the thread; use `open chat destination` if you want to navigate to it.

Threads are private by default and include you. `participant ids {"42", "73"}` adds multiple people and removes duplicates. Space participants must already be members; creation never invites them into the space. Omit `in space` for Home. Omit participant IDs for a private thread containing only you, useful for a new idea or personal checklist. Omit the title for an untitled thread.

**Creation and sending are separate operations.** Save the returned chat ID before sending when building a persistent integration. A failed send does not undo creation. Do not automatically repeat `create thread` after an error or timeout: the thread may already exist, and a repeat can create a duplicate. See [Sending and Retries](#sending-and-retries).

## Send Markdown and Mentions

Every scripted send enables Markdown parsing (`parseMarkdown = true`). The API uses the same server parser for formatting and mentions.

These are message-body fragments, not standalone AppleScript:

```markdown
**Build passed** — ready for review.
[@Maya](inline://user/42), could you check the release notes?
[@Maya](inline://user?id=42), could you check the release notes?
```

Use an actual user ID for a stable mention. A resolvable `@username` also works; an unknown ID stays an ordinary link. A mention does not add a participant or grant access: put the person in `participant ids` before sending. The mention URL uses `inline://`, not `in://`.

Escape Markdown punctuation when you intend literal text. There is no plain-text override, attachment input, or raw entity input in this API.

## Publish an Announcement in a Space

Public threads require a space and no explicit participant IDs. This script creates a new announcement thread. Replace `"7"` with the intended space ID and choose a title that is not already used there; reusing an existing title can fail.

**Treat public space threads as internet-accessible.** Check the audience before running and never use them for private material. See Inline's [security and privacy notes](/docs/security).

```applescript
tell application "Inline"
  set announcement to create thread "Release notes" in space "7" publicly visible true
  set destination to chat id of announcement
  log ("Created announcement: " & destination)
  try
    return send message "**New release** is ready. Add your feedback here." to chat destination
  on error errorText number errorNumber
    error ("Thread " & destination & " exists. Check it before retrying the message. " & errorText) number errorNumber
  end try
end tell
```

To post future updates to the same announcement, retain its chat ID and call `send message` directly. Public Home threads are not supported.

## Jump to a Project Chat and Copy Its Link

Save this script as a launcher action or keyboard shortcut. Replace `"Design"` with the chat's title or a person's name. It requires a unique cached match:

```applescript
tell application "Inline"
  set matches to find chats "Design" maximum count 20
  if (count of matches) is not 1 then error "Choose a more specific chat name."
  set destination to chat id of item 1 of matches
  open chat destination
  set the clipboard to (chat link destination)
end tell
```

Inline comes forward, requests navigation, and copies the link. Opening a chat can mark messages read. `chat link` by itself does not navigate; use its returned URL rather than hardcoding a release channel's URL scheme.

## Copy Recent Context From the Current Chat

Copy up to 20 cached text messages from the primary chat in the frontmost Inline window. Review the result before pasting it into a document or agent: the clipboard may contain private conversation data.

```applescript
set transcript to ""
tell application "Inline"
  set selectedChat to current chat
  if selectedChat is missing value then error "Open a chat in Inline first."
  set rows to recent messages (chat id of selectedChat) maximum count 20
  repeat with entry in rows
    set lineText to message text of entry
    if lineText is not "" then
      set transcript to transcript & (sender id of entry) & ": " & lineText & linefeed
    end if
  end repeat
end tell
set the clipboard to transcript
return transcript
```

Messages are newest first. This is cached context, not a complete transcript: it excludes media payloads, pending sends, and personally collapsed history. Reading does not fetch older messages or mark them read. Reply panes do not replace the primary `current chat` selection.

## Post a Build Result From a Shell Script

Save this complete script as `notify-inline.applescript`:

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

Run it on the Mac signed in to Inline, from the directory containing the file. Replace `"123"` with a known chat ID:

```bash
osascript ./notify-inline.applescript "123" "**Build passed** — ready for review."
```

It prints the acknowledged message ID. Pass the destination and body as arguments instead of inserting untrusted text into AppleScript source. This uses the Mac app's account; it is not a headless CI or bot integration. Use the [Bot API](/docs/bot-api) for an independent service, or the [CLI](/docs/cli) for its broader shell interface.

## Sending and Retries

A send requires an explicit cached chat ID, preserves your composer draft, and does not open the chat or queue offline. Success means server acknowledgement, not that a recipient read the message.

For repeatable automation, generate and persist a unique **positive Int64 decimal-text** request ID before the first send. Replace both IDs below; `"456"` is only a placeholder:

```applescript
tell application "Inline"
  set receipt to send message "Build passed" to chat "123" request id "456"
  return receipt
end tell
```

After a timeout, inspect the destination: the send may have completed. If retrying that same logical send, reuse the same request ID, chat ID, and text. Never reuse an ID for different content or another chat. An omitted ID is generated for you but is returned only on success. Request IDs use the server's existing deduplication, not a permanent exactly-once guarantee. They do not make thread creation idempotent.

## Command Reference

| Command | Returns or does |
| --- | --- |
| `show inline` | Brings Inline forward; works signed out. |
| `current account` | `user id`, `display name`, `username`. |
| `list spaces` | Cached `space id` and `title` records. |
| `list users` | Known cached user records. |
| `find users "Maya"` | Cached users matching a name or username. |
| `user info "42"` | One known cached user record. |
| `search public users "@maya"` | Public user records from network discovery. |
| `list chats` | Cached `chat id`, `title`, `chat kind`, `space id`, `unread count` records. |
| `find chats "Design"` | Cached chats matching title, name, or username. |
| `current chat` | The selected primary chat, or `missing value`. |
| `current thread` | Alias for `current chat`, including DMs. |
| `current selection` | Open reply thread or primary conversation, or `missing value`. |
| `open chat "123"` | Requests navigation and returns the chat ID. |
| `create thread "Review"` | Creates a top-level thread and returns chat info. |
| `recent messages "123"` | `message id`, `chat id`, `sender id`, `message text`, `sent at`, `outgoing`. |
| `send message "Hello" to chat "123"` | `chat id`, `message id`, `send request id`. |
| `chat link "123"` | This app build's deep link to the chat. |

All chat records also include `url` and `markdown link`. Cached lists take `maximum count` from 1–100; defaults are 20 messages and 100 chats, spaces, or users. Public search is capped at 20 results and 60 requests per minute. Chats, spaces, and users support `start offset`, ordered by ascending ID. Chats and users support `in space`; history supports `before message "789"` for older cached message IDs. Lists can change between calls.

Messages are limited to 4096 UTF-16 units, titles to 150, and search queries to 200. Participant lists accept up to 100 supplied user IDs. Group IDs and reply-subthread creation are not supported. Message IDs are unique within their chat; retain both IDs. `sent at` is Unix time in seconds. Optional names and space IDs use empty text.

## Troubleshooting

| Symptom | What to check |
| --- | --- |
| Script Editor does not recognize a command | Open the installed app's dictionary and confirm it contains the command. Use a build with AppleScript support. |
| Permission denied (`-1743`) | Allow the calling app under Privacy & Security → Automation. |
| Account unavailable (`-10004`) | Sign in and wait for loading to finish. Commands stop during logout or account changes. |
| Invalid or missing input (`-1700`, `-1701`) | Use quoted positive decimal-text IDs, an explicit destination, and the documented limits. |
| Item unavailable (`-1728`) or an empty cached list | Confirm the account and open the item in Inline to load it. Hidden dialogs are excluded; a cached roster can be incomplete. |
| Timeout (`-1712`) | Check the destination before retrying a send. Check whether a thread already exists before repeating creation. |
| Operation failed (`-10000`) | Read the error explanation. Access may have changed, the server may be unavailable, or the scripting bridge may be busy. |

Commands have a 30-second deadline and at most 16 may be in flight. Use the exact application path when multiple Inline builds are installed, for example `tell application "/Applications/Inline.app"`. For unresolved issues, [contact the team](mailto:founders@inline.chat).
