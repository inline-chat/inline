# What's New

Release notes for Inline apps, developer tools, and integrations.

> 🍬 Inline is available in private beta. [Join the waitlist](https://inline.chat) or [download the apps](/download) if you have an invite code.

## July 8, 2026

[macOS beta 0.2, build 4495](https://public-assets.inline.chat/mac/beta/4495/Inline.dmg) · [iOS beta on TestFlight](https://testflight.apple.com/join/FkC3f7fz)

### Better tools and APIs for agents and hackers

- Released new plugins for [OpenClaw](/docs/openclaw) and [Hermes Agent](/docs/hermes) with improved thread support.
- Released an [open-source Matrix bridge](https://github.com/inline-chat/matrix-inline), so you can use Inline in Beeper if that's your thing.
- Released a new version of the [Inline CLI](/docs/cli) with new commands for agentic usage. The new `transcript` command gives agents a complete thread as Markdown, including files and media.
- Released alpha versions of `inline-sdk` and `inline-client` in Rust.
- Published `llms.txt` and made the docs more agent-friendly.
- Improved our MCP server so it is more capable at finding and summarizing things.

---

## June 29, 2026

[macOS beta 0.2, build 4354](https://public-assets.inline.chat/mac/beta/4354/Inline.dmg) · [iOS beta on TestFlight](https://testflight.apple.com/join/FkC3f7fz)

### New

- 🎙️ Voice messages are out of experimental!
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

- Added **Copy Link** for threads. These are internal deep links for other Inline users; public links will come later.

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
