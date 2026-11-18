/**
 * Fixtures for the message lab: users, a gallery of messages that covers
 * every case the row views handle, a long generated list, and the text a
 * streaming row grows into. Plain data, deterministic.
 */

import type { Entity, EntityType, MessageRow, ReactionSummary, UserRow } from "@inline/core-protocol"
import type { ChatID, InlineID, MessageID, PhotoID, UserID } from "@inline/ids"

export const CHAT_ID = "77" as ChatID
export const VIEWER_ID = "1" as UserID

const user = (id: string, fields: Omit<UserRow, "kind" | "id">): UserRow => ({ kind: "user", id: id as UserID, ...fields })

export const USERS: readonly UserRow[] = [
  user("1", { firstName: "Mo", lastName: "Rajabi", username: "mo" }),
  user("2", { firstName: "Ada", lastName: "Lovelace", username: "ada" }),
  user("3", { firstName: "Grace", lastName: "Hopper", username: "grace" }),
  user("4", { firstName: "Linus", username: "linus" }),
  user("5", { firstName: "مریم", lastName: "میرزاخانی", username: "maryam" }),
  user("6", { username: "deploy-bot", bot: true }),
  user("7", { firstName: "ليلى", lastName: "حداد", username: "layla" }),
]

export const userById = new Map(USERS.map((row) => [row.id, row]))

/** The entity covering `needle` in `text`. */
const at = (text: string, needle: string, type: EntityType, extra: Partial<Entity> = {}): Entity => {
  const offset = text.indexOf(needle)
  if (offset < 0) throw new Error(`fixture: "${needle}" not in "${text}"`)
  return { type, offset, length: needle.length, ...extra }
}

const reactions = (...list: [string, number, boolean?][]): ReactionSummary[] =>
  list.map(([emoji, count, mine]) => ({ emoji, count, mine: mine ?? false }))

type Draft = {
  from: string
  text: string
  /** Seconds after the previous message. */
  after?: number
  entities?: (text: string) => Entity[]
  extra?: Partial<MessageRow>
}

const build = (drafts: readonly Draft[], start: number, firstId: number): MessageRow[] => {
  let date = start
  return drafts.map((draft, index) => {
    date += draft.after ?? 45
    const messageId = String(firstId + index) as MessageID
    const out = draft.from === VIEWER_ID
    return {
      kind: "message",
      id: `${CHAT_ID}:${messageId}`,
      chatId: CHAT_ID,
      messageId,
      fromId: draft.from as UserID,
      out,
      date,
      text: draft.text,
      ...(draft.entities ? { entities: draft.entities(draft.text) } : {}),
      state: "sent",
      ...draft.extra,
    }
  })
}

const DAY = 86_400
const nowSeconds = (): number => Math.floor(Date.now() / 1000)

const longUrl =
  "https://example.com/a/really/long/path/that/keeps/going/and/going/without/any/spaces/at/all?with=query&and=more"
const entityText =
  "Bold, italic, underline, strike, highlight, inline code, a link to inline.chat, a hidden link, mail ada@example.com, @Ada, @grace, #design, and /deploy now."
const codeText =
  "Here is the fix:\nfunction pick(rows) {\n  return rows.filter((row) => row.state === \"sent\" && row.reactions?.length > 0 && row.text.length < 4096 && !row.hasUnsupportedContent)\n}\nIt keeps scrolling inside the block only."
const quoteText = "The guide says:\nRows are pure and receive prepared data.\nNothing they render is measured.\nAgreed, keeping it that way."
const mathText = "Inline math $e^{i\\pi} + 1 = 0$ stays inert text."

/** The read boundary: the unread line goes above the first message after it that is not your own. */
export const GALLERY_UNREAD_BOUNDARY = "1011" as MessageID


/** The gallery: every case, in chat order (oldest first). */
export const galleryRows = (): MessageRow[] => {
  const today = nowSeconds()
  const yesterday = build(
    [
      { from: "2", text: "Morning! Did the deploy go out?" },
      { from: "2", text: "The staging one, I mean.", after: 30 },
      { from: "1", text: "Yes, staging runs build 2026.11.16. Production goes out tonight.", after: 60 },
      { from: "1", text: "I'll post the notes here.", after: 20 },
      {
        from: "3",
        text: `Long words wrap: Pneumonoultramicroscopicsilicovolcanoconiosis-and-then-some. And a long link: ${longUrl}`,
        after: 400,
        entities: (text) => [at(text, longUrl, "url")],
      },
    ],
    today - DAY - 3600,
    1001,
  )
  const todayRows = build(
    [
      { from: "4", text: "Short one before the unread line.", after: 60 },
      {
        from: "3",
        text: entityText,
        entities: (text) => [
          at(text, "Bold", "bold"),
          at(text, "italic", "italic"),
          at(text, "underline", "underline"),
          at(text, "strike", "strikethrough"),
          at(text, "highlight", "highlight"),
          at(text, "inline code", "code"),
          at(text, "inline.chat", "url"),
          at(text, "a hidden link", "textUrl", { url: "https://inline.chat/docs" }),
          at(text, "ada@example.com", "email"),
          at(text, "@Ada", "mention", { userId: "2" as UserID }),
          at(text, "@grace", "usernameMention"),
          at(text, "#design", "textUrl", { url: "inline://chat/88" }),
          at(text, "/deploy", "botCommand"),
        ],
      },
      {
        from: "3",
        text: codeText,
        after: 20,
        entities: (text) => {
          const start = text.indexOf("function")
          const end = text.indexOf("\n}") + 2
          return [{ type: "pre", offset: start, length: end - start, language: "ts" }]
        },
      },
      {
        from: "3",
        text: quoteText,
        after: 20,
        entities: (text) => {
          const start = text.indexOf("Rows")
          const end = text.indexOf("measured.") + "measured.".length
          return [{ type: "blockquote", offset: start, length: end - start }]
        },
      },
      { from: "3", text: mathText, after: 15, entities: (text) => [at(text, "e^{i\\pi} + 1 = 0", "math")] },
      { from: "5", text: "سلام! این یک پیام فارسی است که باید از راست به چپ نمایش داده شود.", after: 200 },
      {
        from: "5",
        text: "Build شماره ۴۲ آماده است، لطفا قبل از انتشار بررسی کنید: https://inline.chat",
        after: 30,
        entities: (text) => [at(text, "https://inline.chat", "url")],
      },
      { from: "5", text: "Mixed: the ticket is INL-42, اما هنوز باز است.", after: 30 },
      { from: "1", text: "👍", after: 120 },
      { from: "1", text: "🎉🚀✨", after: 10 },
      { from: "2", text: "😂😂😂😂😂😂", after: 40 },
      { from: "2", text: "👨‍👩‍👧‍👦", after: 10 },
      { from: "1", text: "I edited this message after sending it.", after: 60, extra: { editDate: today - 600 } },
      { from: "1", text: "This one is still sending.", after: 30, extra: { state: "sending" } },
      { from: "1", text: "This one was sent.", after: 1, extra: { state: "sent" } },
      { from: "1", text: "This one failed to send.", after: 1, extra: { state: "failed" } },
      {
        from: "1",
        text: "This one was in flight when the connection dropped: not confirmed yet.",
        after: 1,
        extra: { state: "uncertain" },
      },
      { from: "2", text: "Replying to your build note.", after: 90, extra: { replyToMessageId: "1003" as MessageID } },
      { from: "1", text: "And this replies to something not loaded.", after: 30, extra: { replyToMessageId: "999" as MessageID } },
      {
        from: "2",
        text: "Reactions, ordered by count then emoji. Click one to toggle yours.",
        after: 60,
        extra: { reactions: reactions(["🎉", 3], ["👍", 3, true], ["❤️", 1], ["😂", 5]) },
      },
      {
        from: "1",
        text: "Reactions on my own message.",
        after: 30,
        extra: { reactions: reactions(["👍", 2, true], ["🔥", 1]) },
      },
      { from: "3", text: "", after: 60, extra: { hasUnsupportedContent: true } },
      { from: "3", text: "A caption under content this version can't show.", after: 5, extra: { hasUnsupportedContent: true } },
      { from: "6", text: "Deploy finished: web 2026.11.17 is live.", after: 120 },
      { from: "2", text: "The real content views are in the Content section below.", after: 60 },
      {
        from: "4",
        text:
          "A longer paragraph to see how text wraps inside the bubble at its maximum width. It goes on for a while, " +
          "so the time moves to its own line below the text, at the bubble's end, the way the Mac app lays out " +
          "multi-line messages.\n\nAnd a second paragraph after a blank line.",
        after: 40,
      },
    ],
    today - 2 * 3600,
    1011,
  )
  return [...yesterday, ...todayRows]
}

// ---------------------------------------------------------------------------
// Direction

/**
 * Rows for the direction panels, shown in a left-to-right and a right-to-left
 * interface side by side: Arabic from another sender (with an Arabic name,
 * a reply and reactions), English from another sender, and your own messages
 * in both scripts. Incoming rows must sit at the interface's inline start and
 * outgoing at its end, whatever the text's direction.
 */
export const directionRows = (): MessageRow[] =>
  build(
    [
      { from: "7", text: "مرحبا! هل تم نشر الإصدار الجديد؟" },
      {
        from: "7",
        text: "أرسلت الملاحظات في القناة، راجعها من فضلك قبل الاجتماع.",
        after: 20,
        extra: { reactions: reactions(["👍", 2, true], ["❤️", 1]) },
      },
      { from: "1", text: "Yes, it went out an hour ago.", after: 60 },
      { from: "2", text: "English from another sender, in either interface.", after: 60 },
      { from: "7", text: "شكرا جزيلا!", after: 30, extra: { replyToMessageId: "3003" as MessageID } },
      { from: "1", text: "رد بالعربية من جهتي، في الجهة المعتادة لرسائلي.", after: 40 },
    ],
    nowSeconds() - 1800,
    3001,
  )

// ---------------------------------------------------------------------------
// Content (drawn by the real `contentRenderer` from features/content)

const photo = (id: string, width: number, height: number, format: "jpeg" | "png" = "jpeg") => ({
  id: id as PhotoID,
  format,
  // No `cdnUrl`: the box keeps its final size and shows the content view's
  // unavailable state, which is what placement needs.
  sizes: [{ type: "c", width, height }],
})

const blockText = "Release plan\nShip the web app to everyone on Thursday, after the production build passes.\nbun run build && bun run test"

/**
 * One message for each placement: media above the text (a photo with a
 * caption), a link preview and "Sent via" below it, bot buttons and a reply
 * summary under the bubble, a sticker and a PNG without a caption with no
 * bubble, and rich blocks that replace the row's text.
 */
export const contentRows = (): MessageRow[] =>
  build(
    [
      {
        from: "2",
        text: "The new sidebar, with a caption under the photo.",
        extra: { media: { kind: "photo", photo: photo("9001", 1280, 800) } },
      },
      {
        from: "3",
        text: "Write-up here: https://inline.chat/blog/web",
        after: 40,
        entities: (text) => [at(text, "https://inline.chat/blog/web", "url")],
        extra: {
          attachments: [
            {
              kind: "urlPreview",
              id: "9101" as InlineID,
              url: "https://inline.chat/blog/web",
              displayUrl: "inline.chat/blog/web",
              siteName: "Inline",
              title: "Inline for the web",
              description: "A desktop-grade chat client in the browser: instant from local data, complete from the keyboard.",
            },
          ],
        },
      },
      {
        from: "2",
        text: "Summary of the review is in the thread.",
        after: 30,
        extra: {
          via: { kind: "app", app: "claude-code" },
          replies: { kind: "reply", chatId: "79" as ChatID, count: 4, hasUnread: true, recentUserIds: ["3" as UserID, "4" as UserID] },
        },
      },
      {
        from: "6",
        text: "Deploy web 2026.11.17 to production?",
        after: 60,
        extra: {
          actions: [
            [
              { actionId: "approve", text: "Approve", style: "primary", action: { kind: "callback" } },
              { actionId: "cancel", text: "Cancel", style: "default", action: { kind: "callback" } },
            ],
            [{ actionId: "log", text: "Open build log", style: "default", action: { kind: "openUrl", url: "https://inline.chat/builds/42" } }],
          ],
        },
      },
      { from: "3", text: "", after: 30, extra: { media: { kind: "photo", photo: photo("9002", 512, 512, "png"), sticker: true } } },
      { from: "1", text: "", after: 20, extra: { media: { kind: "photo", photo: photo("9003", 600, 400, "png") } } },
      {
        from: "6",
        text: blockText,
        after: 40,
        extra: {
          blocks: [
            { kind: "heading", level: 2, text: { offset: 0, length: 12 } },
            { kind: "paragraph", text: { offset: 13, length: blockText.indexOf("\nbun") - 13 } },
            { kind: "code", language: "sh", text: { offset: blockText.indexOf("bun"), length: blockText.length - blockText.indexOf("bun") } },
          ],
        },
      },
    ],
    nowSeconds() - 1200,
    4001,
  )

// ---------------------------------------------------------------------------
// Streaming

export const STREAM_ROW_ID = `${CHAT_ID}:2001`

export const STREAM_TEXT =
  "Looking at the timeline first. The anchor model keeps the reader still while rows above change size, " +
  "so the streaming row below only grows downward.\n\n" +
  "Plan:\n1. Keep each block's identity stable.\n2. Update only the block that changed.\n3. Coalesce to one update per frame.\n\n" +
  "const next = updateTextDocument(previous, text, entities)\n\n" +
  "Done. Every paragraph above this one kept its DOM nodes while this one grew."

/** Entities of the full streaming text, clipped to what has arrived. */
export const streamEntities = (length: number): Entity[] => {
  const all: Entity[] = [
    at(STREAM_TEXT, "anchor model", "bold"),
    at(STREAM_TEXT, "Plan:", "bold"),
    at(STREAM_TEXT, "const next = updateTextDocument(previous, text, entities)", "code"),
    at(STREAM_TEXT, "Done.", "italic"),
  ]
  return all.filter((entity) => entity.offset + entity.length <= length)
}

export const streamRow = (length: number): MessageRow => ({
  kind: "message",
  id: STREAM_ROW_ID,
  chatId: CHAT_ID,
  messageId: "2001" as MessageID,
  fromId: "6" as UserID,
  out: false,
  date: nowSeconds(),
  text: STREAM_TEXT.slice(0, length),
  entities: streamEntities(length),
  state: "sent",
})

// ---------------------------------------------------------------------------
// The long list

const words =
  "the timeline keeps a bounded window of real rows in normal flow so selection find in page and variable heights work as the browser intends while one owner corrects scroll and nothing moves under the reader".split(
    " ",
  )

/** A deterministic pseudo-random sequence. */
const random = (seed: number) => {
  let state = seed >>> 0
  return () => {
    state = (Math.imul(state, 1664525) + 1013904223) >>> 0
    return state / 2 ** 32
  }
}

/** `count` messages in runs of senders, about a day of chat ending now. */
export const longListRows = (count: number): MessageRow[] => {
  const next = random(42)
  const senders = ["1", "2", "3", "4", "5"]
  let date = nowSeconds() - count * 170
  let sender = "2"
  const rows: MessageRow[] = []
  for (let index = 0; index < count; index++) {
    if (next() < 0.35) sender = senders[Math.floor(next() * senders.length)] ?? "2"
    date += 20 + Math.floor(next() * 320)
    const length = 3 + Math.floor(next() ** 2 * 60)
    const parts: string[] = []
    for (let word = 0; word < length; word++) parts.push(words[Math.floor(next() * words.length)] ?? "row")
    const text = parts.join(" ")
    const messageId = String(5000 + index) as MessageID
    const roll = next()
    rows.push({
      kind: "message",
      id: `${CHAT_ID}:${messageId}`,
      chatId: CHAT_ID,
      messageId,
      fromId: sender as UserID,
      out: sender === VIEWER_ID,
      date,
      text: text.charAt(0).toUpperCase() + text.slice(1) + ".",
      ...(roll < 0.08 ? { reactions: reactions(["👍", 1 + Math.floor(next() * 4), next() < 0.5]) } : {}),
      ...(roll > 0.95 && index > 0 ? { replyToMessageId: String(5000 + index - 1) as MessageID } : {}),
      ...(roll > 0.9 && roll <= 0.95 ? { entities: [{ type: "code", offset: 0, length: Math.min(8, text.length) } as Entity] } : {}),
      state: "sent",
    })
  }
  return rows
}
