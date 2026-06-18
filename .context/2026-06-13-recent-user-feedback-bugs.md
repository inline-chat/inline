# Recent user feedback bug triage

Date: 2026-06-13
Scope: Inline CLI feedback scan for recent chats from 2026-06-10 00:00 Asia/Tehran through 2026-06-13.

Commands used:
- `inline auth me --json`
- `inline chats list --json`
- `inline messages list --chat-id ... --json`
- `inline messages search --chat-id ... --query bug --query broken --query crash --query "not work" --query "doesn't work" --query "didn't work" --query cant --query "can't" --query stuck --query lag --query issue --query weird --query error --query fail --query preview --query "long press" --query react --limit 30 --json`

## Confirmed and fixed

### macOS long-press reactions do not open from message text

Feedback:
- Georges, chat `948`, message `175`, 2026-06-10 05:38:19 +0330: cannot long press a message to react anymore.
- Jerry, chat `2265`, message `173`, 2026-06-10 02:31:06 +0330: cannot react with emojis.
- Georges, DM chat `281`, message `2008`, 2026-06-13 01:44:46 +0330: long press does not bring up emoji react anymore.

Confirmation:
- `MessageViewAppKit` and `MinimalMessageViewAppKit` still install `NSPressGestureRecognizer`.
- Their gesture delegate rejected long press whenever the pointer was over rendered message text via `isTextPoint(...)`.
- Most text-only messages are naturally pressed on text, so the picker could only appear from non-text bubble padding, matching the reports.

Fix prepared:
- `apple/InlineMac/Views/Message/MessageView.swift`
- `apple/InlineMac/Views/Message/MinimalMessageView.swift`
- Long press now works on ordinary message text again.
- Double-click ACK still ignores selectable text.
- Long press still avoids text entities such as links, mentions, commands, email/phone, and code so entity click behavior is not converted into a reaction gesture.

Risk:
- Low. The change is limited to gesture filtering in macOS message views.
- Text selection may still compete with long press if the user drags after pressing, but a stationary long press now reaches the reaction picker again.

## Confirmed feedback, not fixed in this pass

### Empty/random DM entries after space browsing

Feedback:
- Zsolt, chat `2256`, messages `189`-`195`, 2026-06-12 17:22-17:24 +0330: sees random people/results and does not know the person; Mo identified this as empty DM chats created after visiting a space.

Evidence:
- There is existing local visibility filtering around `Dialog.chatListHidden` and `HomeViewModel.filterEmptyChats`.
- `filterEmptyChats` only requires `item.chat != nil`, so a private chat row with no last message can still appear if a local/private `Chat` was persisted.

Decision:
- Not patched yet. The report is plausible, but the fix needs product boundary confirmation: space contacts are intentionally shown in some sidebar modes, while empty persisted DMs should probably be hidden unless open, pinned, drafted, unread, or message-backed.

Suggested follow-up:
- Add a regression test that private chat dialogs with `lastMessage == nil`, no draft, not pinned, not open, and unread count zero are excluded from global chat/search surfaces.
- Keep explicit space contacts visible only in the dedicated contacts section.

## Unconfirmed / needs repro

### First preview click did not work

Feedback:
- Dena, chat `2941`, message `1`, 2026-06-10 14:24:12 +0330: "Clicking on first preview didn't work #bug".

Evidence:
- The thread only contains the bug sentence, with no attachment, screenshot, target URL, platform, or parent message payload available from the CLI result.
- The macOS `URLPreviewAttachmentView` has click handling for the whole preview and separate image click handling, but there is not enough evidence to tie this report to a specific failing branch.

Decision:
- Not patched from this report alone.

Suggested follow-up:
- Ask for the original message/preview or reproduce with multiple URL previews in one message.
- Check whether the first preview's image area opens Quick Look while the text/background opens the URL; if that is the complaint, decide whether URL-preview image clicks should open the link by default and move image Quick Look to the context menu.

### Mac Quick Look shows api.inline.chat preview error

Feedback:
- Georges, DM chat `281`, messages `2006`-`2007`, 2026-06-12 01:54:53 +0330: screenshot showed Quick Look error for `api.inline.chat`; it went away after returning to the chat.

Evidence:
- Screenshot shows macOS Quick Look saying an error occurred previewing a document from `api.inline.chat`.
- The issue self-resolved after returning to the chat, suggesting a transient downloaded-file/Quick Look cache state.

Decision:
- Not patched from this report alone.

Suggested follow-up:
- Reproduce with document attachments from `api.inline.chat`, especially after switching chats while a download/preview is in progress.
- If reproducible, verify local file existence before opening Quick Look and prefer local cached file URLs over expiring remote URLs for document previews.

### File attachments broken in Hermes/OpenClaw adapter context

Feedback:
- Zsolt, chat `2256`, message `86`, 2026-06-12 14:59:03 +0330: file attachments are broken "in it".

Evidence:
- Surrounding messages refer to a customized Hermes adapter and custom tools, not clearly to the Inline macOS/iOS client.

Decision:
- Not treated as an Inline client bug in this pass.

## Noise excluded

- Wanver/Shopline product issues, automated alert failures, and daily pulse Sentry summaries were excluded from the client bug fix pass.
- The iOS/macOS beta thread `2878` had a recent note from Mo saying the iOS issue was solved on 2026-06-11.
