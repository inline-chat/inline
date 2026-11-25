---
title: "What's New"
description: "Release notes and exact app build links."
---

Release notes for Inline apps, developer tools, and integrations.

> [Download the latest Inline apps](/download).

## November 25, 2026

[macOS 0.2 beta, build 7475](https://public-assets.inline.chat/mac/beta/7475/Inline.dmg) · [CLI 0.7.26](https://github.com/inline-chat/inline/releases/tag/cli-v0.7.26) · [Hermes adapter 1.2.6](https://www.npmjs.com/package/@inline-chat/hermes-agent-adapter/v/1.2.6) · [OpenClaw plugin 1.0.0-alpha.3](https://www.npmjs.com/package/@inline-openclaw/inline/v/1.0.0-alpha.3)

The iOS TestFlight build follows soon. It is the first since October 30, so on iOS it also brings everything in the [November 13](#november-13-2026) notes, including quote replies, unread mention and reaction badges, focus status, hold-to-record, the swipeable media gallery, and the new iPad layout.

### New

- 🔎 **Search all your messages.** Search now finds messages from every chat you're in, even ones this device never loaded, with the sender, a highlighted excerpt and the date. On macOS it's in Quick Search, next to Command-F for the chat you're in.
- 📱 **A new message list on iOS.** Chats scroll more smoothly and open faster. Sent messages grow out of the composer, new messages rise in, and reactions animate without bouncing. The list and composer turn with the device and keep your place. Tap the day badge to jump to that day, or tap the status bar to go to the newest message.
- 🖼️ **Albums.** Photos, videos and files you send together arrive as one album, with files listed under the grid. You can forward or delete the album as a whole.
- 🔒 **Photos and videos without hidden details.** Media is resized for its content and sent without location, camera or time details. To send the untouched file instead, turn on **Original** in the composer, or choose **Send as Original** from an attachment's menu.
- 🤖 **Agents you can act on.** Agents bridged through the [CLI](/docs/cli) show plans to approve, approval requests, review findings, task suggestions and next-step buttons as native cards. Their forms show recommended options and keep your sent answers. An agent's suggested next message appears as your composer's placeholder; press Tab to use it.
- ✍️ **Sent via.** Messages an agent sends for you through the CLI or Inline's MCP connector carry an agent badge on the avatar and a "Sent via Claude Code" (or ChatGPT, Codex, and so on) line.
- 📋 **Copy with formatting.** Copying a message keeps its headings, lists, tables and code when you paste it into other apps. On macOS you can drag to select text across several messages and blocks. On iOS you can select part of a formatted message right in the message menu.
- 🔠 **Text size and fonts on macOS.** Use **View › Make Text Bigger**, **Make Text Smaller** and **Make Text Normal Size**. **Settings › Appearance** has text size with a preview, and **Customize** sets fonts and line spacing. The spacing in messages, compose and code blocks is retuned.
- ℹ️ **New Chat Info.** It has an action row (Message, Search, Mute, Follow, Output, Share, Add), cards for people, bots and threads, tabs for Members and the **Threads** you share with someone, and a faster media grid.
- 💾 **Data and Storage.** See what uses space by chat and file type and clear downloads per chat. You can also keep media for a week, a month or forever, set a size limit, and skip auto-download on cellular or in Low Data Mode.
- 🔐 **Choose who can message a bot.** Share a bot with people, spaces or groups, open it to everyone, and add admins who can manage bots they don't own. If you can't message a bot, its chat tells you who to ask. Change output and sharing for several bots at once from **Settings › Bots**.

### Quality of life improvements

- Reading is instant: a chat, the chat list, the app icon and the Dock update together, and unread counts no longer bounce back after you reach the bottom. Leaving a chat marks what was on screen as read.
- The iOS app icon shows how many chats have unread messages, including chats with only an unread mention. The macOS Dock badge and Dock menu count mention-only chats too, and muted chats no longer count.
- **Privacy › Time Zone** has **Set Automatically** and a time zone picker, so a time zone you choose stays put when you travel.
- On iOS, tap a photo in the composer to mark it up before sending.
- Deleting a message asks first. The message stays until the server confirms the delete.
- Opening a thread goes to its parent message in the parent chat. On iPad, reply threads open as the main chat.
- A new **Transcribe Voice Messages** switch in Privacy settings lets you keep your voice messages from being transcribed.
- Mention one of your bots in a space thread and Inline offers to add it to the space.
- On iOS, New Thread compose supports @ mentions of people, groups and agents, "Start with" suggestions, and agent folder, model and reasoning options. It also keeps your draft.
- Chats show "sending photo", "sending video" or "sending file" while someone uploads, including in the sidebar and title bar on macOS.
- The message time sits in the bubble's bottom corner next to reactions. Reaction chips keep their order when someone reacts. iOS reaction pills have tinted backgrounds, and the unread line is a subtle band.
- The iOS media gallery opens, closes and pages more smoothly, shows "N of M", deletes where the chat allows it, and adds video controls: mute, speed, hold for 2x, double-tap to skip 15 seconds, and pinch to zoom. It also supports hardware keyboard shortcuts.
- Media sends survive a relaunch and keep their order. On iOS they also keep going in the background. A failed send retries without sending twice.
- On macOS, the sidebar's hover controls no longer push badges aside, and long names fade out instead of showing an ellipsis. Message selection checkboxes moved to the trailing side, so avatars and text stay in place.
- Agent replies in Persian and other right-to-left languages read right to left even when they start with a Latin word.
- The macOS getting started screen is simpler. Agent setup on macOS starts on this Mac and lists other machines as a row. It also finds a ChatGPT Dot.
- When the CLI sits in an admin-owned folder, the macOS app updates it through the system password prompt.
- iOS: the send button has the same larger touch target as the mic button, the message menu scales with text size, and VoiceOver reads sender avatars as buttons with their names.

### Better tools and APIs for agents and hackers

- [CLI](/docs/cli) **0.7.26**:
  - **ChatGPT Dots**: `inline setup dots` bridges your ChatGPT Dot into Inline as a personal bot. You can share it with `/share` and bring it into threads. See [ChatGPT Dots](/docs/chatgpt-dots).
  - `inline listen` streams new messages and reactions as JSON lines, so an agent can wake up when something happens instead of polling.
  - Messages that coding agents send through the CLI are signed "Sent via …". Use `--as-me` to send without the signature, or `--via` / `--via-bot` to name the agent.
  - `inline bots settings` lists every bot's output mode and sharing. You can change many bots at once with `--all`, `--filter` or a comma-separated list, and preview with `--dry-run`.
  - Share at creation with `bots create --share-user`, `--share-space`, `--admin` and `--open`. `/share` and `/unshare` in bridge chats manage who can talk to your agent.
  - Bridged agents send plans, approvals, review findings, next steps and prompt suggestions as native blocks. Claude sub-agents show as agents, and prose keeps its Markdown styles.
  - Claude asks you to sign in again when its session expires, a recoverable connection error no longer logs the CLI out, and exports fetch long histories in pages.
- [Hermes](/docs/hermes) **1.2.1 → 1.2.6**:
  - Progress and heartbeats post quietly, so they skip unread counts and notifications, and Friendly answers always notify.
  - Output mode changes apply within seconds.
  - Stalled inbound messages recover.
  - The system prompt stays stable across turns, so Hermes reuses its cached agent.
  - Reactions are now opt-in through `reaction_triggers`.
- [OpenClaw](/docs/openclaw) **1.0.0-alpha.3** delivers chat updates in isolation per chat. `0.0.72` stays the default.
- The [Bot API](/docs/bot-api) `getFile` accepts the documented `chat_id` and `message_id`, and a malformed query id gets the documented JSON error. Silent bot sends are now quiet: they skip unread counts and notifications.
- Apps, the CLI and the SDK keep connecting when the device clock is wrong, by learning the server's clock instead of retrying forever.

### Fixes

- The first message from someone new now shows their DM on iOS, and DMs that went missing this way come back.
- Fixed the iOS media gallery losing its place on rotation, starting videos while you scrub, and flashing the thumbnail.
- Expired photo and file links refresh on their own, and failed photos no longer retry endlessly.
- Fixed Return, Tab and Escape while typing with an input method on macOS, and on iOS a pending autocorrection is applied before sending. Unfinished input is never sent.
- Fixed hold actions firing while you select text on macOS. Force click shows Look Up.
- Fixed the composer staying behind the keyboard after rotating an iPhone or iPad.
- Notifications for an account that isn't signed in on a device stay silent. Each install keeps its own notification identity, and signing out reaches the server reliably.
- Opening and switching chats on macOS is faster.
- Space admins can no longer remove owners, only a current owner can delete a space, the last owner deletes the space instead of leaving it, and removing a member also removes their bots.
- Translation keeps the parts that succeed, and voice transcription is more reliable under load.
- Improved connection reliability, upload speed and server performance.

---

## November 13, 2026

[macOS 0.2 beta, build 6741](https://public-assets.inline.chat/mac/beta/6741/Inline.dmg) · [CLI 0.7.24](https://github.com/inline-chat/inline/releases/tag/cli-v0.7.24) · [Hermes adapter 1.2.0](https://www.npmjs.com/package/@inline-chat/hermes-agent-adapter/v/1.2.0) · [OpenClaw plugin 1.0.0-alpha.2](https://www.npmjs.com/package/@inline-openclaw/inline/v/1.0.0-alpha.2)

### New

- 🔍 **Search inside a chat** on macOS. Press Command-F to see matching messages with an exact count, Return to jump to one, and Command-G to step through the rest, even far back in history.
- 💬 **Quote replies.** Select part of a message and choose **Quote** to reply to just those words. Tap the quote to go back to where it came from.
- 🔴 **Unread mentions and reactions** get their own badges and jump buttons. Chats open at your first unread message, or where you left off if you've caught up.
- ☑️ **Select several messages** on macOS. Choose **Select** from the message menu or drag across messages, then forward, delete, or press Command-C to copy them.
- 🌙 **Focus status.** When a Focus is on, people you choose see "Notifications silenced" in your DM. Pick who in Privacy settings, where you can now also choose who sees your time zone.
- 🤖 **Friendly or detailed agent output.** Choose per bot from Chat Info whether it shows each step of its work or just short updates. Works with Codex and Claude on [CLI](/docs/cli) 0.7.24, [Hermes](/docs/hermes) 1.2.0 and [OpenClaw](/docs/openclaw) 1.0 alpha. Working rows also show a live timer.
- 📱 **A new iPad layout** with a native sidebar, a floating New Thread button that opens a composer, and a compose bar that stays above the keyboard shortcut bar.

### Quality of life improvements

- Hold the mic button on iOS to start recording a voice message right away.
- Photos and videos on iOS open in a swipeable gallery.
- Sending photos shows upload progress, and you can cancel from the photo's menu.
- The scroll-to-bottom button shows how many unread messages are below.
- See who can use your bots and edit their profile from Chat Info. On macOS, you can also rename a bot from the chat header.
- A bot's DM header and the mention menu show whether the bot is online.
- Anyone in a private thread can add people to it, and chat creators on iOS can add and remove members.
- inline.chat links to chats, spaces, and invites open in the app. Chat menus have **Copy Deep Link**.
- On macOS, **Settings → Updates** shows your local agent bridge's status, with Restart, Stop, Logs, and Update Now. Agent setup shows its progress live.
- Reply threads on macOS open instantly and slide in next to their message.
- Messages that mix right-to-left and left-to-right text lay out each paragraph in its own direction.
- Message bubbles stay a readable width in wide windows.
- Emoji search ranks closer matches and the emoji you use most first. On iOS, `:` search shows results in a strip.
- Slash command suggestions rank better and list the nearest bot's commands first.
- The new message menu on iOS is now on for everyone.
- Grid keeps your mic the way you left it when you resume or move a call. **Mute When Alone** is now opt-in and lifts when someone joins.
- Grid shows a muted badge and a speaking halo on each person, and plays a sound when you mute or unmute.
- Stickers from the iOS keyboard send as stickers instead of photos.
- On macOS, click a message avatar to open that person's profile, use Control-N and Control-P in compose menus, and press Escape to remove a staged attachment without closing the chat. Unsent edits survive relaunching the app.

### Better tools and APIs for agents and hackers

- [CLI](/docs/cli) **0.7.24** keeps Linux bridges running after you log out or close the SSH session when installed as a service, and repairs that setting whenever the service starts. A bridge started in a terminal now reports the hangup instead of quietly stopping. CLIs with automatic updates pick this up on their own.
- Detailed agent output hides tokens and other credentials in commands, their output, and edit diffs.
- When someone without access mentions your agent, it now replies once to say who it takes requests from, instead of staying silent.
- Share a bot with a whole space or user group: `inline bots access grant --space-id <id>` or `--group-id <id>`.
- In your DM with a bridge agent, the agent can split work into task threads, each its own session, and report back when they finish. `/stop` in the DM stops them too.
- Agents can look up people and bots, ask them by mentioning them, and pick up their replies.
- New CLI commands: `inline messages wait` blocks until a reply arrives, `inline sidebar` opens, closes, orders, pins, and folders chats, `inline bots` manages profiles, photos, tokens, settings, and access, `messages list --include-threads` and `messages send --thread` read and post in reply threads, and `inline cli search "<task>"` finds the right command.
- OpenCode runs natively on bridge v2. Claude runs the newest installed version and finds your saved Claude project folders.
- An explicit `inline update` switches the background bridge at its next idle moment.
- The [Bot API](/docs/bot-api) adds `getContacts`, an `owner_id` on bot users, and access grants for spaces and user groups. `sendMessage` takes `add_mentioned_users: true` to add mentioned people to a private thread.
- Bots can send a sandboxed HTML **widget** in a message, such as a chart or mockup. See [Widgets](/docs/bot-api#widgets). Viewing them is experimental on macOS, under **Settings → Experimental**.
- [Hermes](/docs/hermes) **1.1.0** and **1.2.0** add friendly and detailed output and approval buttons that resolve only the request you tapped. It also shows the session's context window in agent settings, sends widgets, and no longer posts a partly sent reply twice. Upgrade with `npm install -g @inline-chat/hermes-agent-adapter@latest`, `inline-hermes install --force`, and restart the gateway.
- [OpenClaw](/docs/openclaw) **1.0.0-alpha.2** supports OpenClaw 2026.11.1 and later, with friendly and detailed output. It is an alpha; `0.0.72` stays the default for earlier OpenClaw versions.

### Fixes

- Fixed message lists on macOS jumping while new messages, edits, or reply panes change.
- File names, code, and agent progress summaries no longer turn into links.
- A pasted link no longer carries into text typed after it, and deleting a link on iOS clears its formatting.
- Mentions survive copy and paste in compose, and a partly deleted mention on iOS is cleared.
- Fixed swipe-to-reply getting clipped in centered chats on macOS.
- Fixed the code block copy button on macOS.
- Deleted bots now leave mentions and the sidebar.
- A photo send you cancel no longer comes back.
- Notifications on iOS are more reliable.
- Improved server reliability under heavy load.

---

## November 5, 2026

[CLI 0.7.21](https://github.com/inline-chat/inline/releases/tag/cli-v0.7.21) · [Hermes adapter 1.0.0](https://www.npmjs.com/package/@inline-chat/hermes-agent-adapter/v/1.0.0)

### Fixes

- 🛠️ **Hermes 0.22.6 and later work with Inline again.** Those versions refused every message from earlier adapters, replying "Hermes refused this message (invalid_params)". Upgrade to the [Hermes adapter](/docs/hermes) **1.0.0**: run `npm install -g @inline-chat/hermes-agent-adapter@latest`, `inline-hermes install --force`, and restart the gateway. 1.0.0 also changes when the bot answers; read [Upgrading to 1.0](/docs/hermes#upgrading-to-1-0) first.
- [CLI](/docs/cli) **0.7.21**: `inline agents setup` upgrades Hermes adapters older than 1.0.0. It also finds Codex in the current ChatGPT app, lets a signed-out bridge load so login and restart can repair it, and publishes installed skills from the agent bridge.

## October 30, 2026

[macOS 0.2 beta, build 6338](https://public-assets.inline.chat/mac/beta/6338/Inline.dmg) · [iOS TestFlight build 1393](https://testflight.apple.com/join/FkC3f7fz) · [CLI 0.7.20](https://github.com/inline-chat/inline/releases/tag/cli-v0.7.20)

### New

- 📌 Pin **several messages** in a chat. The header steps through them on iOS and macOS, and **Unpin All** clears them in one go.
- ⚡️ Switching and joining **Grid rooms** is faster, with refreshed glass rooms on iOS and macOS.
- 📝 **Transcribe Grid calls** in Pro spaces. Start it from the call dock on iOS, or from the call pill on macOS. Each transcript lands in a thread named after the room and start time, and it keeps up through network drops.
- 🤖 Chatting with an agent on iOS now uses a **compose card** where you pick the model, reasoning level and folder, see context usage, and stop or resume a turn.
- 💬 Messages on iOS use a new message view with rich formatting such as headings, lists and code, and smoother streaming agent replies.

### Quality of life improvements

- Your iPhone no longer buzzes for a chat you're actively in on your Mac.
- **Only mentions** notifications now really mean only mentions. Replies and reply-thread activity stay quiet.
- Mark all open chats as read from the cleanup menu on macOS.
- Restyled voice messages on iOS, plus a live progress ring for file downloads.
- Chat date separators on iOS only turn to glass while pinned to the top.
- Inline links now use `inline://`. Old `in://` links keep working.
- A new install window when you open the macOS download.
- Claude's five-hour and weekly limits now appear correctly in the usage meter. On macOS 26 and later, the meter is also available before you start a thread.

### Better tools and APIs for agents and hackers

- [CLI](/docs/cli) **0.7.20** adds OpenCode 2 and Amp to the dedicated agent bridge, with separate sessions per chat, tool activity, settings, Stop, and restart/resume. Existing Amp users can adopt the new adapter with `inline agents setup --target amp`. Older OpenCode installations keep their existing bridge; new setups require OpenCode 2.
- Claude Code setup no longer requires Node or npm when using its native bridge. Stop, Pause and Resume controls are consumed once, so catch-up cannot apply an old control to the next turn.
- [CLI](/docs/cli) **0.7.19**: `inline plugin install` now adds the Inline plugin to **Claude Code** as well as Codex.
- The CLI can now update its background agent bridge between turns, with signed releases and automatic recovery if an update fails. For an existing bridge from an older CLI, do the first upgrade and `inline bridge restart` while your agents are idle. Later managed updates wait for work to finish.
- The CLI has an **alpha channel**. Run `inline update --channel alpha` to try new agent features early. Agent plugins install from the same channel as the CLI.
- Bots that send too fast now get a Telegram-style **flood wait** instead of a server error. The [Bot API](/docs/bot-api) answers `429` with `retry_after`, so your bot knows exactly how long to wait.

### Fixes

- Codex and Claude ignore thread-link notices and other service messages instead of treating them as prompts.
- Fixed short delays catching up on messages after a brief disconnect.
- Fixed reactions picked from the message menu on iOS landing in the wrong place.
- Fixed a crash when drawing blurred headers on some iPhones.
- Improved server reliability under heavy load.

---

## October 27, 2026

### New

- 🪟 A floating **call pill** on macOS keeps the people in your Grid room, mic, screen share, and leave within reach while you work in other apps.
- 🔔 Notifications you read or delete on one device now **clear on your other devices** too, on iOS and macOS.
- 📦 Send files and videos up to **500 MB**, up from 200 MB.
- 🔍 Search **macOS Settings**. Press Command-F in Settings and jump straight to the option you need.

### Quality of life improvements

- Manage your bots on iOS: edit their profile, photo, and username, open their chat, or delete them. You can also change a bot's username on macOS.
- Send or discard a voice message on iOS while you're still recording. The recording bar now matches macOS.
- Archiving a chat on macOS now also closes and unpins it, with an undo toast to bring it back.
- Chats on iOS open with their messages ready, and the chat you tapped stays highlighted.
- Grid keeps you in your room after restarting the app or recovering a call, and your Mac stays awake while you're in a call.
- Added **Call Diagnostics** to the macOS Help menu, so you can send us a report when a call sounds off.
- macOS now offers Beta and Tip update channels. If you were on Stable, you're now on Beta.
- Refreshed the app icon and message bubble tails.

### Better tools and APIs for agents and hackers

- The local agent bridge in [CLI](/docs/cli) 0.7.18 now **heals itself** after network, sign-in, and rate-limit errors, without `inline bridge restart`. It only stops when it needs you to sign in or finish setup.
- CLI browser sign-in now asks you to confirm the code shown in your terminal, including with Google and Apple sign-in. A sign-in link on its own can no longer authorize someone else's terminal.
- The CLI, SDK, and [Bot API](/docs/bot-api) now handle 500 MB files, and large transfers survive slow or interrupted connections.
- In the [Bot API](/docs/bot-api), `forwardMessage` and `forwardMessages` take `copy: true` to send messages without a forward header. `sendMessage` now only accepts media your bot uploaded, so use `copy` to resend someone else's media. `getFile` also takes the `chat_id` and `message_id` of the message carrying the file.
- [OpenClaw](/docs/openclaw) and [Hermes](/docs/hermes) no longer wake on name patterns or wake words. Mentions, replies, followed threads, and commands still wake them. In OpenClaw group chats with several bots, the mentions at the start of a message decide who it's for.
- [OpenClaw](/docs/openclaw) now supports 2026.10.5 and adds an `inline_follow` tool, so the agent can follow or unfollow a chat itself. `toolsBySender` now matches numeric user ids only. Groups that still key senders by name have tools turned off until you update the config.
- Local agents now ignore other people's bots unless you add them to your allowlist.

### Fixes

- Fixed message links opening at the bottom of the chat on macOS, and the message highlight on iOS.
- Fixed a hang when pasting rich text from web pages.
- Fixed profile photos that failed to load or kept retrying.
- Fixed notifications that could still show messages after signing out or switching accounts on iOS.
- Pinning and unpinning messages now shows up right away in open chats.
- Fixed voice messages on iOS changing width after they appear.
- Fixed more ghost rows in the macOS sidebar.
- Fixed the Grid Resume button showing while leaving or switching rooms on macOS.
- Your email and phone number are now only visible to you.
- Improved server reliability and response times.

---

## October 10, 2026

[macOS 0.2, build 5957](https://public-assets.inline.chat/mac/beta/5957/Inline.dmg) · [macOS 0.2 tip, build 5959](https://public-assets.inline.chat/mac/tip/5959/Inline.dmg) · [iOS TestFlight build 1342](https://testflight.apple.com/join/FkC3f7fz)

### New

- 🎧 Voice messages on iOS now **keep playing** when you switch chats or lock your phone. A playback bar lets you pause, change speed, or jump back to the message.
- 🗄️ Rebuilt **Chat Info** on iOS and macOS. Files, media, links, and voice messages now load reliably, including older ones from far back in the chat.
- 📁 Send **folders** on macOS. Drop or attach one and Inline zips it for you.
- Messages on iOS now follow your system **text size**.

### Quality of life improvements

- Files you choose on iOS now wait in the composer until you send, so you can add a message or remove a file first.
- **Return** now sends on an iPad hardware keyboard, and **Shift-Return** adds a new line. You can turn this off in Settings.
- Turn off **Centered Chats** in macOS Appearance settings to use the full chat width.
- Choose a default chat icon in macOS Appearance settings.
- Copy a chat's link on macOS with Option-Command-C.

### Better tools and APIs for agents and hackers

- Inline is now in the **ChatGPT plugin store**. See [Add Inline to Your Agent](/docs/add-inline).
- [Hermes](/docs/hermes) now runs on **Umbrel**, and you can install Inline from the Hermes plugin catalog with `hermes plugins install inline-platform`.
- Added the [`add-inline-integration` skill](/docs/developers#add-inline-to-a-product-or-bot). Give it to your coding agent to add Inline as a channel in a product or bot that already supports Slack, Telegram, Discord, or Teams.
- Agent approvals now appear in the conversation where the agent is working, instead of your DM with it.
- Local agents are no longer limited to four sessions at a time. Claude also keeps its permission mode, including plan mode, between turns.
- Local agents on macOS now stay responsive in the background. After updating to CLI 0.7.16, run `inline bridge restart` once.
- You can now create up to **30 bots** per account.
- [MCP](/docs/mcp) can now read exact messages, forward messages, create reply threads, filter by sender, and ask teammates a question in a private thread.
- The [CLI](/docs/cli) can now filter messages by sender with `--sender-id`, return forwarding receipts, and list reply threads you haven't opened with `inline chats list --include-subthreads`. JSON output also includes pagination details.
- Improved Hermes access checks and recovery of missed messages. Pin and backlink notices no longer start agent turns.
- Improved [OpenClaw](/docs/openclaw) connection status and update details.

### Fixes

- Fixed messages disappearing from chats and new threads, including ones sent or received while you were scrolled up.
- Improved reconnecting and catching up on missed messages on iOS and macOS.
- Opening a chat from a notification now lands on the latest messages.
- Fixed unexpected logouts on macOS after a temporary connection or sign-in failure.
- Fixed iOS message menus leaving a blank gap when closing, and chats losing their scroll position while the reaction menu is open.
- Fixed the iOS Search tab getting stuck in a keyboard loop.
- Fixed canceling a message that is still sending on macOS.
- Fixed chats vanishing from your list when deleting them failed.
- Fixed chat links that could fail to open a DM, including DMs with bots.
- Fixed archiving group chats you were invited to but hadn't opened.
- Fixed profile photos that stayed blank after a failed download.
- Fixed macOS message times keeping the wrong color after switching between light and dark mode, or not updating after a failed send.
- Fixed the message highlight, reply-preview layout, and swipe-to-reply avatars on iOS.
- Fixed ghost rows lingering over chats in the macOS sidebar. Also improved sidebar performance and preview contrast.

---

## September 25, 2026

### New

- 🎙️ Added **dictation** on macOS. Speak to write a message or start a new thread.
- 🗂️ Select **multiple chats** in the macOS sidebar to move them together, create a folder, or mark them as read.
- 🖼️ Added **space photos** on iOS and macOS, plus space badges for members of Pro spaces.
- Added **iPad split navigation**, with chats and the sidebar side by side.
- Open unread chats or mark them all as read from Inline's **macOS Dock menu**.

### Quality of life improvements

- Choose your **swipe-to-reply direction** or turn off message double-tap and double-click actions. Your message gesture settings now sync across devices.
- Reaction pickers now suggest emoji from the message first. Also refreshed the iOS reaction picker.
- Chat translation preferences now sync across devices.
- Added a **pink theme** on iOS and macOS.
- Reply threads now inherit their parent chat's notification settings unless you choose otherwise.
- Mark an entire folder or a thread and its replies as read on macOS.
- Start a new thread from the macOS composer's plus menu, or drop attachments onto the empty page to begin composing.
- Added **Invite to Space** to the macOS command menu.
- Messages and the composer now stay centered on macOS.
- Improved macOS tooltips and Minimal message metadata.

### Better tools and APIs for agents and hackers

- Browse folders on your agent's machine and choose its project from macOS Agent Settings. Requires an updated bridge.
- See your agent provider's remaining usage and reset times in Agent Settings, where supported by the provider and bridge.
- Codex now shows collapsible work summaries, command previews, and file changes. Also improved model and reasoning settings, `/compact`, and `/stop`.
- Improved Claude and Codex setup, with clearer errors and retry options.
- [OpenClaw](/docs/openclaw) now supports 2026.9, with improved approvals, reply-thread support, and connection recovery.
- Improved reconnects and catching up on missed updates in [Hermes](/docs/hermes), the realtime SDK, and the [CLI](/docs/cli).

### Fixes

- Improved catching up on messages, unread counts, and membership changes after reconnecting.
- Fixed iOS message menus losing their preview, keyboard, or scroll position during live updates.
- Improved loading older messages on iOS. Your own messages no longer increase the scroll-to-bottom unread badge.
- Fixed scrolling while editing long messages and selecting text with double-click set to Ack on macOS.
- Fixed stale profile photos, full-size avatar previews, duplicate image drops, and missing files in macOS Chat Info.
- Improved notification delivery across desktop and mobile, with fewer stale or duplicate notifications.
- Fixed agent settings not remembering project and provider choices, stale agent lists, and skilled-agent mentions in new threads.
- Improved macOS dictation and restored the iOS microphone button after clearing the composer.
- Fixed macOS sidebar hover targets, closing pinned chats, and new-thread picker placement.
- Fixed copied thread links and backlinks, automatic thread titles, and mention matching.
- Improved rich-text rendering, forwarded-media spacing, and link-preview colors.
- Improved startup and resuming interrupted onboarding.

---

## September 2, 2026

### New

- 📝 Messages on macOS now support **rich formatting**, including headings, lists, checklists, tables, quotes, images, code blocks, and collapsible sections. This release also adds underline, strikethrough, highlight, and experimental native rendering for inline and display math.
- 🗂️ Added **chat folders** on macOS. Group conversations, choose a name and emoji, and organize folders in Open or Pinned. Pinned folders also appear in All Chats, and collapsed folders show a combined unread badge, with clearer unread indicators for nested threads.
- 🎨 iOS now has the same **themes** as macOS, with new color presets and gradient message bubbles.
- ✅ Added **Ack** on iOS and macOS. Double-click or double-tap someone else's message to acknowledge it with a small check-mark pill; repeat the action to remove it.
- Start a new thread directly from **All Chats** on macOS. Choose Home or a space, add participants and attachments, and write your first message in place. You can also filter All Chats by Home or a space without changing the selected sidebar chat.
- 🔗 Added **space join links** on iOS and macOS. Share a public space or invite people into a private one, with controls to turn links on or off.
- Added **Sign in with Apple** and **Sign in with Google** on iOS and macOS. iOS onboarding also has separate name and username steps and clearer sign-in progress.

### Quality of life improvements

- Copy links to DMs, threads, and individual messages on macOS. Message links open the referenced message. Home threads now have short numbered references, just like space threads, for linking and search.
- Added `/thread` on iOS and macOS to create a reply thread from the current conversation. Open the command picker from the composer's plus menu.
- Reply threads now show the message they branched from, so the original context is visible above the replies.
- Follow or pin chats from more places on iOS, including All Chats and search.
- Newly opened chats now appear at the top of Open Chats by default.
- Command-K on macOS includes more of your local conversations, including chats that were previously missing from its results.
- Undo closing chats or folders and archiving conversations on macOS.
- Added **Cleanup** on iOS to close inactive chats and remove empty folders, matching macOS.
- Turn on **Shorten Supported Links** on macOS to replace supported pasted URLs with readable titles. Escape, Undo, or Backspace restores the original URL.
- Choose Grid's input and output devices in **Audio and Video** settings. Opt into unmuting when you join or muting when you are alone, and hide Grid from the sidebar if you prefer.
- Improved sharing from other apps on iOS, including send progress and recovery from interrupted uploads.
- Improved participant and mention search when adding people, bots, groups, or Agents. Reply-thread suggestions now include people and groups from the parent conversation, with better exact-name ranking.
- Added dedicated bot-owner settings on iOS and macOS, including token rotation.
- Improved macOS agent setup, with clearer progress, errors, repair options, and retry instructions.
- Adjust chat text size on macOS across all message layouts.
- Audio documents now play inline instead of opening as generic files.
- Notifications preserve meaningful line breaks, describe photos and other media, show encrypted photo previews on iOS, and open the exact message when possible.
- iOS now animates the delivery status from sending to sent. Also polished swipe-to-reply avatars and dark message bubbles.
- Software updates on macOS now open in their own window.
- Hover over truncated macOS sidebar titles to see the full name.

### Better tools and APIs for agents and hackers

- [OpenClaw](/docs/openclaw) can now create reply threads from DMs and keep replies, typing, and activity in the child thread. Also improved rich replies, DM routing, agent-authored buttons, and compatibility with OpenClaw 2026.8.
- [Hermes](/docs/hermes) now has native pickers for questions, approvals, and model selection, plus richer replies and agent-authored buttons. Added optional processing reactions, quieter progress updates, and compatibility with Hermes 0.21.
- Browse and open existing local Codex sessions with `/sessions` or `/open`, resume the exact session before another prompt, and release Codex from Inline with `/stop` or `/close`. Project discovery now includes saved Codex roots and larger paged catalogs.
- Codex work now stays in one updating **Working** message and finishes as a normal reply, preserving complete long-form output instead of splitting progress across many messages. The message limit is now 100,000 characters.
- Added browser-based login to the [Inline CLI](/docs/cli). Agents and non-interactive tools can start the login flow for you to finish in your browser. CLI 0.7.7 also preserves rich Markdown input, resumes interrupted Realtime V3 uploads, installs the Codex plugin without extra flags, and improves shell completions and update checks.
- Added an **AppleScript API** for the Mac app. Find people and chats, create threads, inspect the current selection, read recent cached messages, send Markdown, and create Hookmark-compatible links from your own scripts.
- Expanded the [Bot API](/docs/bot-api) with polling, webhooks, thread and participant events, files, skill catalogs, and a typed TypeScript client. Bots can send rich Markdown, add callback or copy-text buttons, update buttons independently, and forward or delete messages in batches.
- Added [Realtime V3](/docs/realtime-api), with encrypted client-server transport, TypeScript and Rust support, durable resumable uploads, and authoritative recovery after reconnects or lost responses.
- Added Agent profile management to the Bot API, CLI, SDK, OpenClaw, and Hermes. The experimental **Skilled Agents** UI on iOS and macOS lets bot owners create named specializations, set a skill and instructions, and mention them in existing conversations.

### Fixes

- Improved catching up on missed messages, read state, unread counts, and chat updates after reconnecting. Damaged or incomplete local chat history can now recover from bounded authoritative snapshots without clearing the account.
- Fixed uploads that could stall, duplicate work, or unexpectedly sign you out. Large transfers now resume after reconnects and recover safely when finalization or a provider response is interrupted.
- Improved sign-in retries, logout, and account switching, including cleanup of stale account state.
- Fixed stale or duplicate macOS notifications, with better grouping and handling of replies and mentions.
- Fixed iOS chat previews and transitions when opening a conversation from a notification.
- Settings changes no longer interrupt OpenClaw's reply connection. Fixed agent settings that could stay loading or show stale results after switching bots or chats.
- Fixed code-block and rich-formatting errors in streamed bot replies, including incomplete fences, repeated progress updates, stale disclosure state, and broken image-gallery selection.
- Fixed pinned threads moving out of pinned folders, and restored chat placement when undoing a close on macOS.
- Fixed file paths being mistaken for slash commands and improved command and mention completion in the macOS composer. Autocomplete no longer resizes the chat while it is open.
- Improved macOS voice recording, including draft recovery, cancellation, and caption spacing.
- Improved Grid reconnects, screen sharing, and cleanup after leaving or losing access.
- Fixed cases where macOS could get stuck while quitting or loading the sidebar.
- Improved MCP browser sign-in and fixed connections left open after failed initialization.
- Improved macOS sidebar unread navigation and reporting when a chat cannot be opened.
- Fixed the forwarding picker showing an empty state before chats had finished loading.
- Fixed repeated press-and-hold urgent nudges and nudge toolbar press handling.
- Restored active reaction colors and corrected macOS reply-preview backgrounds and swipe-to-reply avatar movement.
- Fixed long link-heavy messages that could make the app unresponsive, and stopped URLs inside code from generating previews.

---

## August 15, 2026

[macOS 0.2 tip, build 4947](https://public-assets.inline.chat/mac/tip/4947/Inline.dmg) · [iOS TestFlight build 1193](https://testflight.apple.com/join/FkC3f7fz)

### New

- 🏠 iOS has an all-new Home with **Open**, **All Chats**, and **Search**, plus faster navigation and more control over how chats are shown.
- 🧵 The macOS sidebar now shows reply threads under their parent. You can pin or collapse them together, rename a reply thread, or open one beside the main conversation.
- 🎧 Added **Grid** on macOS: lightweight voice rooms for spaces, with presence, screen sharing, and controls for microphones, room names, and access.
- 🎨 Added themes on macOS, with new color presets across the sidebar, chats, composer, Grid, and settings.
- 🤖 Added one-click agent setup on macOS and in Inline CLI 0.7.3. Connect OpenClaw, Hermes, Codex, Claude, OpenCode, or Amp, create or reuse a bot, then start it and verify it is ready.
- Added a local agent bridge so coding agents can run as private Inline bots, keep workspace context, and continue work in reply threads.

### Quality of life improvements

- Improved bot setup and management, including profiles, chat controls, and commands such as `/command@bot`.
- Added **Copy as Markdown** for threads, with clean text and media links ready to paste as reference.
- Drop files or media onto a macOS sidebar chat to open it with the attachments ready as a draft.
- Press and hold a chat on iOS Home to preview it and see its actions.
- Command-K on macOS is faster, with immediate local results and better ranking over time.
- Added Privacy settings for **Appear in Global Search** and **Share Time Zone**. Both are on by default.
- Improved document, X, and Figma previews. Notifications now show document names and more reliable avatars.
- Choosing **All Notifications** now follows the chat, so it stays visible in your sidebar.
- Clear a conversation only for yourself, or privately share a thread with another Inline user.
- Improved profile setup, including Memoji profile photos on macOS and new Account settings on iOS.
- Improved macOS Settings, software updates, menus, emoji options, and email-code autofill.
- The iOS share menu now suggests the Inline chats you share with most often.
- Made reactions more compact and unread badges more consistent.
- Improved OpenClaw and Hermes setup and thread support. MCP now supports ChatGPT apps.
- Added **Connectors** on macOS and iOS. Connect Notion or Linear, reference pages with `[[`, and create tasks from Inline.

### Fixes

- Fixed sign-in, account switching, and fresh-account sync issues.
- Fixed incorrect unread counts.
- Fixed iOS chat opening, navigation, and share routing.
- Fixed iOS attachment sizing, message layout, and toolbar state.
- Improved macOS message performance and chat switching.
- Fixed macOS compose autocomplete, send-button state, and file drops.
- Fixed duplicate or misrouted bot and agent replies.
- Fixed notification settings, sender avatars, and invalid push tokens.
- Fixed media sends that could stall and URL previews that could disappear.
- Fixed message ordering and permission checks for chat actions.

---

## July 8, 2026

[macOS 0.2, build 4495](https://public-assets.inline.chat/mac/beta/4495/Inline.dmg) · [iOS on TestFlight](https://testflight.apple.com/join/FkC3f7fz)

### Better tools and APIs for agents and hackers

- Released new plugins for [OpenClaw](/docs/openclaw) and [Hermes Agent](/docs/hermes) with improved thread support.
- Released an [open-source Matrix bridge](https://github.com/inline-chat/matrix-inline), so you can use Inline in Beeper if that's your thing.
- Released a new version of the [Inline CLI](/docs/cli) with new commands for agentic usage. The new `transcript` command gives agents a complete thread as Markdown, including files and media.
- Released `inline-sdk` and `inline-client` for Rust.
- Published `llms.txt` and made the docs more agent-friendly.
- Improved our MCP server so it is more capable at finding and summarizing things.

---

## June 29, 2026

[macOS 0.2, build 4354](https://public-assets.inline.chat/mac/beta/4354/Inline.dmg) · [iOS on TestFlight](https://testflight.apple.com/join/FkC3f7fz)

### New

- 🎙️ Added voice messages on macOS and iOS.
- 💫 Added a smooth new iOS send-message animation.

  [Watch the iOS send-message animation](/changelog/2026-06-29/ios-send-message.mp4)

- `GIF` GIF support on macOS and iOS!
- 👀 Added a **Follow** button for threads. Followed threads appear in your sidebar when they receive a new message.

  ![The Follow button in the macOS chat toolbar](/changelog/2026-06-29/follow-button.png)

  > We automatically follow threads you create, reply threads addressed to you, and reply threads you write in. If a thread is noisy, you can manually unfollow it and we won't automatically follow it again.

- 🏷️ You can now create user groups such as `@eng`, `@design`, or `@support`. They make it easy to mention or add multiple people to a thread at once. Create one from Space Settings.
- 🔍 Search messages from Command-K on macOS.

### Quality of life improvements

- Added a new typing animation and a **recording voice** compose status.
- The macOS reaction picker now sorts suggestions by your recent usage instead of using static defaults.

  ![Recently used emoji suggestions in the macOS reaction picker](/changelog/2026-06-29/reaction-picker-recent.png)

- Choose whether macOS shows unread badges as dots or numbers.

  ![Dot and numbered unread badge options in macOS settings](/changelog/2026-06-29/unread-badge-style.png)

- Significantly improved large X/Twitter cards with larger media, author profiles, and long-text support.

  ![An expanded X post preview with large media and author information](/changelog/2026-06-29/x-preview.png)

- The dock badge now includes unread followed threads, not only unread direct messages.

  ![The Inline macOS dock icon showing two unread messages](/changelog/2026-06-29/dock-badge.png)

- Added **Copy Link** for sharing threads with other Inline users.

  ![Copy Link in the macOS thread menu](/changelog/2026-06-29/copy-link.png)

- Added an all-new Apple share-menu experience for sending content from other apps into Inline.
- Added haptic feedback when reordering threads in the sidebar.

### Fixes

- Thread icons now match across macOS, iOS, and notifications.
- Fixed a bug on iOS 27 where the composer could move outside the viewport.
- Improved voice waveform rendering and fixed composer state after sending voice messages.
- Fixed message hover states getting stuck in minimal mode.
- Fixed the emoji picker in the composer and switched it to our custom picker.
- Reduced scrolling lag on macOS and iOS. There is still more to improve!
- Fixed message-tap routing for documents, attachments, and URL previews on iOS.

---

## June 19, 2026

### New

- 💬 Bubbles now have tails! Thanks to [Jace](https://x.com/JaceThings) for her help polishing them.
- 🧲 Sticky avatars make scrolling chats nicer on macOS and iOS, in both minimal and bubble message modes.
- 🔗 Linking to a thread with `[[thread]]` now shows a backlink in the linked thread. This is the beginning of our multiplayer knowledge graph system.

### Fixes and improvements

- Pinning a message now shows a small service message in the chat.
- You can right-click a URL preview and exclude its domain from previews in your space threads.
- Improved large URL previews across more card and media types.
- Press and hold the macOS back or forward toolbar button to see your navigation history.

  ![Previous chats and dates in the macOS back-button history menu](/changelog/2026-06-19/navigation-history.png)

- Configure what holding or double-clicking a message does on macOS.
- Improved voice waveform rendering and reset composer state after sending voice messages.
- Fixed macOS 26 toolbar and background behavior, including the glass composer height.
- Fixed holding on reactions on macOS 15.
- Added composer auto-pairing for `[]` and `()`.
