# What's New

Source: https://inline.chat/docs/changelog

Release notes for Inline apps, developer tools, and integrations.

> [Download the latest Inline apps](https://inline.chat/download).

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

- Released new plugins for [OpenClaw](https://inline.chat/docs/openclaw) and [Hermes Agent](https://inline.chat/docs/hermes) with improved thread support.
- Released an [open-source Matrix bridge](https://github.com/inline-chat/matrix-inline), so you can use Inline in Beeper if that's your thing.
- Released a new version of the [Inline CLI](https://inline.chat/docs/cli) with new commands for agentic usage. The new `transcript` command gives agents a complete thread as Markdown, including files and media.
- Released `inline-sdk` and `inline-client` for Rust.
- Published `llms.txt` and made the docs more agent-friendly.
- Improved our MCP server so it is more capable at finding and summarizing things.

---

## June 29, 2026

[macOS 0.2, build 4354](https://public-assets.inline.chat/mac/beta/4354/Inline.dmg) · [iOS on TestFlight](https://testflight.apple.com/join/FkC3f7fz)

### New

- 🎙️ Added voice messages on macOS and iOS.
- 💫 Added a smooth new iOS send-message animation.

  [Watch the iOS send-message animation](https://inline.chat/changelog/2026-06-29/ios-send-message.mp4)

- `GIF` GIF support on macOS and iOS!
- 👀 Added a **Follow** button for threads. Followed threads appear in your sidebar when they receive a new message.

  ![The Follow button in the macOS chat toolbar](https://inline.chat/changelog/2026-06-29/follow-button.png)

  > We automatically follow threads you create, reply threads addressed to you, and reply threads you write in. If a thread is noisy, you can manually unfollow it and we won't automatically follow it again.

- 🏷️ You can now create user groups such as `@eng`, `@design`, or `@support`. They make it easy to mention or add multiple people to a thread at once. Create one from Space Settings.
- 🔍 Search messages from Command-K on macOS.

### Quality of life improvements

- Added a new typing animation and a **recording voice** compose status.
- The macOS reaction picker now sorts suggestions by your recent usage instead of using static defaults.

  ![Recently used emoji suggestions in the macOS reaction picker](https://inline.chat/changelog/2026-06-29/reaction-picker-recent.png)

- Choose whether macOS shows unread badges as dots or numbers.

  ![Dot and numbered unread badge options in macOS settings](https://inline.chat/changelog/2026-06-29/unread-badge-style.png)

- Significantly improved large X/Twitter cards with larger media, author profiles, and long-text support.

  ![An expanded X post preview with large media and author information](https://inline.chat/changelog/2026-06-29/x-preview.png)

- The dock badge now includes unread followed threads, not only unread direct messages.

  ![The Inline macOS dock icon showing two unread messages](https://inline.chat/changelog/2026-06-29/dock-badge.png)

- Added **Copy Link** for sharing threads with other Inline users.

  ![Copy Link in the macOS thread menu](https://inline.chat/changelog/2026-06-29/copy-link.png)

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

  ![Previous chats and dates in the macOS back-button history menu](https://inline.chat/changelog/2026-06-19/navigation-history.png)

- Configure what holding or double-clicking a message does on macOS.
- Improved voice waveform rendering and reset composer state after sending voice messages.
- Fixed macOS 26 toolbar and background behavior, including the glass composer height.
- Fixed holding on reactions on macOS 15.
- Added composer auto-pairing for `[]` and `()`.
