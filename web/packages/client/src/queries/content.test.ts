import {
  AgentGrantRequirement,
  Block,
  BlockContent,
  BlockDecisionState,
  BlockFormText_Kind,
  BlockList_Kind,
  BlockStatus,
  BlockTable_Alignment,
  GridTranscriptMessageKind,
  Message as ProtoMessage,
  MessageAction_Style,
  MessageAttachmentExternalTask_Status,
  MessageSubthread_Kind,
  Photo,
  Photo_Format,
  UrlPreview_MediaType,
  type Message as ProtoMessageType,
} from "@inline-chat/protocol/core"
import type { ContentBlock, MessageRow } from "@inline/core-protocol"
import { describe, expect, it } from "vitest"
import { decodeInlineModel, encodeInlineModel } from "../database/model-codec"
import type { Message } from "../database/models"
import { messageModel } from "../realtime/transactions/mappers"
import { contentBlock, contentBlocks, mediaContent, textRange, type StoredMessageExtras } from "./content"
import { plainEqual } from "./diff"
import { messageRow } from "./rows"

// Fixtures are built from the proto types, mapped to the stored model the way
// the sync path does (`messageModel`), and round-tripped through the replica's
// msgpack codec, so the mapper sees exactly what the replica gives back.

const stripped = new Uint8Array([1, 30, 40, 9, 8, 7])

const photo = (id = 11n) =>
  Photo.create({
    id,
    date: 1_700_000_000n,
    format: Photo_Format.JPEG,
    fileUniqueId: `p${id}`,
    sizes: [
      { type: "s", w: 40, h: 30, size: 6, bytes: stripped },
      { type: "b", w: 140, h: 105, size: 2_000, fileUniqueId: "pb", cdnUrl: "https://cdn.example/b.jpg?sig=1" },
      { type: "f", w: 2_560, h: 1_920, size: 400_000, fileUniqueId: "pf", cdnUrl: "https://cdn.example/f.jpg?sig=1" },
    ],
  })

const proto = (extra: Partial<ProtoMessageType>): ProtoMessageType =>
  ProtoMessage.create({
    id: 40n,
    fromId: 7n,
    chatId: 5n,
    peerId: { type: { oneofKind: "chat", chat: { chatId: 5n } } },
    message: "hello",
    out: false,
    date: 1_700_000_100n,
    ...extra,
  })

/** The replica's stored shape: the sync mapper, then msgpack out and back. */
const stored = (message: ProtoMessageType, extras: StoredMessageExtras = {}): Message & StoredMessageExtras =>
  decodeInlineModel(encodeInlineModel({ ...messageModel(message), ...extras } as Message)) as Message &
    StoredMessageExtras

const row = (message: ProtoMessageType, extras?: StoredMessageExtras): MessageRow =>
  messageRow(stored(message, extras), undefined, undefined)

describe("media", () => {
  it("maps a photo with its sizes and stripped thumbnail, copying the bytes", () => {
    const result = row(proto({ media: { media: { oneofKind: "photo", photo: { photo: photo() } } } }))
    expect(result.media).toEqual({
      kind: "photo",
      photo: {
        id: "11",
        date: 1_700_000_000,
        format: "jpeg",
        fileUniqueId: "p11",
        sizes: [
          { type: "b", width: 140, height: 105, size: 2_000, fileUniqueId: "pb", cdnUrl: "https://cdn.example/b.jpg?sig=1" },
          { type: "f", width: 2_560, height: 1_920, size: 400_000, fileUniqueId: "pf", cdnUrl: "https://cdn.example/f.jpg?sig=1" },
        ],
        stripped,
      },
    })
    const bytes = result.media?.kind === "photo" ? result.media.photo.stripped : undefined
    expect(bytes?.buffer.byteLength).toBe(stripped.length)
    expect(result.hasUnsupportedContent).toBeUndefined()
  })

  it("marks a sticker photo", () => {
    const result = row(proto({ isSticker: true, media: { media: { oneofKind: "photo", photo: { photo: photo() } } } }))
    expect(result.media).toMatchObject({ kind: "photo", sticker: true })
  })

  it("maps video, GIF, document, voice and nudge", () => {
    const video = row(
      proto({
        media: {
          media: {
            oneofKind: "video",
            video: {
              video: {
                id: 21n,
                date: 3n,
                w: 1_280,
                h: 720,
                duration: 75,
                size: 9_000_000,
                photo: photo(12n),
                cdnUrl: "https://cdn.example/v.mp4",
                isAnimated: true,
                hasAudio: false,
              },
            },
          },
        },
      }),
    )
    expect(video.media).toMatchObject({
      kind: "video",
      video: { id: "21", width: 1_280, height: 720, duration: 75, size: 9_000_000, animated: true, hasAudio: false },
    })
    expect(video.media?.kind === "video" && video.media.video.thumbnail?.id).toBe("12")

    const document = row(
      proto({
        media: {
          media: {
            oneofKind: "document",
            document: { document: { id: 22n, fileName: "plan.pdf", mimeType: "application/pdf", size: 52_000, date: 4n } },
          },
        },
      }),
    )
    expect(document.media).toEqual({
      kind: "document",
      document: { id: "22", date: 4, fileName: "plan.pdf", mimeType: "application/pdf", size: 52_000 },
    })

    const waveform = new Uint8Array([0, 128, 255])
    const voice = row(
      proto({
        media: {
          media: {
            oneofKind: "voice",
            voice: { voice: { id: 23n, date: 5n, duration: 12, size: 30_000, mimeType: "audio/ogg", waveform } },
          },
        },
      }),
    )
    expect(voice.media).toEqual({
      kind: "voice",
      voice: { id: "23", date: 5, duration: 12, size: 30_000, mimeType: "audio/ogg", waveform },
    })

    const nudge = row(proto({ message: "👋", media: { media: { oneofKind: "nudge", nudge: {} } } }))
    expect(nudge.media).toEqual({ kind: "nudge" })
  })

  it("degrades unknown or malformed media to an absent field and flags it", () => {
    const unknown = row(proto({ media: { media: { oneofKind: undefined } } }))
    expect(unknown.media).toBeUndefined()
    expect(unknown.hasUnsupportedContent).toBe(true)
    expect(mediaContent({ media: { oneofKind: "photo", photo: { photo: { id: "x" } } } }, false)).toBeUndefined()
    expect(mediaContent({ media: { oneofKind: "video", video: null } }, false)).toBeUndefined()
    expect(mediaContent("nonsense", false)).toBeUndefined()
  })
})

describe("attachments, headers, service, buttons", () => {
  it("maps URL previews and external tasks", () => {
    const result = row(
      proto({
        attachments: {
          attachments: [
            {
              id: 70n,
              attachment: {
                oneofKind: "urlPreview",
                urlPreview: {
                  id: 71n,
                  url: "https://example.com/a",
                  displayUrl: "example.com/a",
                  siteName: "Example",
                  title: "A",
                  description: "About A",
                  photo: photo(13n),
                  duration: 90n,
                  mediaType: UrlPreview_MediaType.VIDEO,
                  provider: "youtube",
                  media: {
                    media: {
                      oneofKind: "externalVideo",
                      externalVideo: { url: "https://media.example/a.mp4", mimeType: "video/mp4", w: 640, h: 360 },
                    },
                  },
                  layout: { hasLargeMedia: true, showLargeMedia: false },
                },
              },
            },
            {
              id: 72n,
              attachment: {
                oneofKind: "externalTask",
                externalTask: {
                  id: 73n,
                  taskId: "LIN-1",
                  application: "linear",
                  title: "Fix it",
                  status: MessageAttachmentExternalTask_Status.IN_PROGRESS,
                  assignedUserId: 9n,
                  url: "https://linear.app/x/LIN-1",
                  number: "LIN-1",
                  date: 6n,
                },
              },
            },
            { id: 74n, attachment: { oneofKind: undefined } },
          ],
        },
      }),
    )
    expect(result.attachments).toEqual([
      {
        kind: "urlPreview",
        id: "70",
        previewId: "71",
        url: "https://example.com/a",
        displayUrl: "example.com/a",
        siteName: "Example",
        title: "A",
        description: "About A",
        provider: "youtube",
        duration: 90,
        mediaType: "video",
        photo: expect.objectContaining({ id: "13" }),
        media: { kind: "externalVideo", url: "https://media.example/a.mp4", mimeType: "video/mp4", width: 640, height: 360 },
        layout: { hasLargeMedia: true, showLargeMedia: false },
      },
      {
        kind: "externalTask",
        id: "72",
        taskRecordId: "73",
        taskId: "LIN-1",
        application: "linear",
        title: "Fix it",
        status: "inProgress",
        assigneeUserId: "9",
        url: "https://linear.app/x/LIN-1",
        number: "LIN-1",
        date: 6,
      },
      { kind: "unknown", id: "74" },
    ])
    expect(result.hasUnsupportedContent).toBe(true)
  })

  it("maps forward, replies, grouped ID and service events", () => {
    const result = row(
      proto({
        groupedId: 900n,
        fwdFrom: { fromPeerId: { type: { oneofKind: "user", user: { userId: 8n } } }, fromId: 8n, fromMessageId: 3n },
        replies: { chatId: 77n, replyCount: 4, hasUnread: true, recentReplierUserIds: [8n, 9n, 8n] },
      }),
    )
    expect(result.groupedId).toBe("900")
    expect(result.forward).toEqual({ fromPeer: { kind: "user", userId: "8" }, fromUserId: "8", fromMessageId: "3" })
    expect(result.replies).toEqual({ kind: "reply", chatId: "77", count: 4, hasUnread: true, recentUserIds: ["8", "9"] })

    const subthread = row(proto({}), {
      subthread: {
        chatId: 78n,
        kind: MessageSubthread_Kind.SUBTHREAD,
        title: " Design ",
        messageCount: 2,
        hasUnread: false,
        recentAuthorUserIds: [9n],
      },
    })
    expect(subthread.replies).toEqual({
      kind: "subthread",
      chatId: "78",
      count: 2,
      hasUnread: false,
      recentUserIds: ["9"],
      title: "Design",
    })

    const backlink = row(
      proto({ serviceMessage: { event: { oneofKind: "threadBacklink", threadBacklink: { sourceChatId: 12n, sourceTitle: "Launch" } } } }),
    )
    expect(backlink.service).toEqual({ kind: "threadBacklink", sourceChatId: "12", sourceTitle: "Launch" })
    const pinned = row(proto({ serviceMessage: { event: { oneofKind: "pinnedMessage", pinnedMessage: { messageId: 3n } } } }))
    expect(pinned.service).toEqual({ kind: "pinnedMessage", messageId: "3" })
    const transcript = row(
      proto({
        serviceMessage: {
          event: {
            oneofKind: "gridTranscript",
            gridTranscript: { runId: "r", segmentId: "s", speakerUserId: 8n, kind: GridTranscriptMessageKind.GRID_TRANSCRIPT_TURN },
          },
        },
      }),
    )
    expect(transcript.service).toEqual({ kind: "gridTranscript", runId: "r", segmentId: "s", speakerUserId: "8", event: "turn" })
    const unknown = row(proto({ serviceMessage: { event: { oneofKind: undefined } } }))
    expect(unknown.service).toEqual({ kind: "unknown" })
    expect(unknown.hasUnsupportedContent).toBe(true)
  })

  it("maps via (when stored) and the reply quote", () => {
    expect(row(proto({}), { via: { source: { oneofKind: "app", app: "claude-code" }, name: "Claude Code" } }).via).toEqual({
      kind: "app",
      app: "claude-code",
      name: "Claude Code",
    })
    expect(row(proto({}), { via: { source: { oneofKind: "botUserId", botUserId: 30n } } }).via).toEqual({
      kind: "bot",
      botUserId: "30",
    })
    expect(row(proto({}), { replyQuote: "quoted" }).replyQuote).toBe("quoted")
  })

  it("maps bot buttons by row, with styles, confirm and grants", () => {
    const result = row(
      proto({
        actions: {
          rows: [
            {
              actions: [
                {
                  actionId: "ok",
                  text: "Approve",
                  style: MessageAction_Style.PRIMARY,
                  action: { oneofKind: "callback", callback: { data: new Uint8Array([1]) } },
                  confirm: { title: "Sure?", confirmText: "Yes" },
                  requiredGrant: AgentGrantRequirement.APPROVE,
                },
                {
                  actionId: "copy",
                  text: "Copy",
                  style: MessageAction_Style.DEFAULT,
                  action: { oneofKind: "copyText", copyText: { text: "abc" } },
                  requiredGrant: AgentGrantRequirement.NONE,
                },
              ],
            },
            {
              actions: [
                {
                  actionId: "open",
                  text: "Open",
                  style: MessageAction_Style.DESTRUCTIVE,
                  action: { oneofKind: "openUrl", openUrl: { url: "javascript:alert(1)" } },
                  requiredGrant: 0,
                },
                {
                  actionId: "go",
                  text: "Go",
                  style: 0,
                  action: { oneofKind: "openLink", openLink: { peerId: { type: { oneofKind: "chat", chat: { chatId: 5n } } }, messageId: 2n } },
                  requiredGrant: 0,
                },
                { actionId: "ask", text: "Ask", style: 0, action: { oneofKind: "compose", compose: { text: "hi" } }, requiredGrant: 99 as AgentGrantRequirement },
              ],
            },
            { actions: [] },
          ],
        },
      }),
    )
    expect(result.actions).toEqual([
      [
        {
          actionId: "ok",
          text: "Approve",
          style: "primary",
          action: { kind: "callback" },
          confirm: { title: "Sure?", confirmText: "Yes" },
          requiredGrant: "approve",
        },
        { actionId: "copy", text: "Copy", style: "default", action: { kind: "copyText", text: "abc" } },
      ],
      [
        // The row carries the URL as sent; the UI passes it through `safeLink`.
        { actionId: "open", text: "Open", style: "destructive", action: { kind: "openUrl", url: "javascript:alert(1)" } },
        {
          actionId: "go",
          text: "Go",
          style: "default",
          action: { kind: "openLink", peer: { kind: "chat", chatId: "5" }, messageId: "2" },
        },
        { actionId: "ask", text: "Ask", style: "default", action: { kind: "compose", text: "hi" }, requiredGrant: "unknown" },
      ],
    ])
    expect(result.hasUnsupportedContent).toBeUndefined()
  })

  it("keeps the old row shape for a plain message", () => {
    const result = row(proto({}))
    expect(Object.keys(result).sort()).toEqual(["chatId", "date", "fromId", "id", "kind", "messageId", "out", "state", "text"])
  })
})

// ---------------------------------------------------------------------------
// Blocks

const t = (offset: number, length: number) => ({ offset: BigInt(offset), length: BigInt(length) })

const blocksRow = (blocks: Block[], text = "x".repeat(200)): MessageRow =>
  row(proto({ message: text }), { blockContent: BlockContent.create({ blocks }) })

describe("blocks", () => {
  it("projects every block kind with its fields and status", () => {
    const blocks: Block[] = [
      { kind: { oneofKind: "paragraph", paragraph: { ...t(0, 5), isRtl: false } } },
      { kind: { oneofKind: "heading", heading: { text: t(6, 3), level: 2 } } },
      { kind: { oneofKind: "code", code: { text: t(10, 4), language: "ts" } } },
      {
        kind: {
          oneofKind: "list",
          list: {
            kind: BlockList_Kind.ORDERED,
            start: 3n,
            items: [
              { children: [{ kind: { oneofKind: "paragraph", paragraph: t(15, 2) } }], checked: true },
              { children: [{ kind: { oneofKind: "paragraph", paragraph: t(18, 2) } }] },
            ],
          },
        },
      },
      { kind: { oneofKind: "separator", separator: {} } },
      {
        kind: {
          oneofKind: "image",
          image: { alt: t(21, 2), state: { oneofKind: "pending", pending: { dimensions: { width: 300, height: 200 }, strippedThumbnail: stripped } } },
        },
      },
      {
        kind: {
          oneofKind: "album",
          album: {
            images: [
              { state: { oneofKind: "ready", ready: photo(14n) } },
              { state: { oneofKind: "unavailable", unavailable: {} } },
            ],
          },
        },
      },
      {
        kind: {
          oneofKind: "disclosure",
          disclosure: {
            summary: t(24, 7),
            kind: 1,
            children: [{ kind: { oneofKind: "paragraph", paragraph: t(32, 3) } }],
            activityKind: 8,
            status: BlockStatus.RUNNING,
            meta: t(36, 2),
            startedAt: 1_700_000_000n,
          },
        },
      },
      { kind: { oneofKind: "footer", footer: t(40, 3) } },
      { kind: { oneofKind: "quote", quote: { children: [{ kind: { oneofKind: "paragraph", paragraph: t(44, 2) } }], isRtl: true } } },
      {
        kind: {
          oneofKind: "table",
          table: {
            rows: [{ cells: [t(47, 1), t(49, 1)] }, { cells: [t(51, 1), t(53, 1)] }],
            alignments: [BlockTable_Alignment.UNSPECIFIED, BlockTable_Alignment.RIGHT],
          },
        },
      },
      { kind: { oneofKind: "math", math: t(55, 4) } },
      {
        kind: {
          oneofKind: "diff",
          diff: { path: t(60, 5), text: t(66, 10), change: 2, additions: 3, deletions: 1, language: "swift", truncated: true },
        },
      },
      {
        kind: {
          oneofKind: "fields",
          fields: { fields: [{ label: t(77, 3), value: t(81, 4), monospace: true }] },
        },
      },
      {
        kind: {
          oneofKind: "steps",
          steps: { steps: [{ text: t(86, 3), status: BlockStatus.DONE }, { text: t(90, 3), status: BlockStatus.WAITING, detail: t(94, 2) }] },
        },
      },
      {
        kind: {
          oneofKind: "callout",
          callout: { kind: 3, title: t(97, 4), children: [{ kind: { oneofKind: "paragraph", paragraph: t(102, 3) } }] },
        },
      },
      { kind: { oneofKind: "meter", meter: { label: t(106, 3), value: 0.5, max: 1, tone: 2 } } },
      {
        kind: {
          oneofKind: "form",
          form: {
            formId: "f1",
            title: t(110, 3),
            fields: [
              {
                fieldId: "pick",
                label: t(114, 3),
                required: true,
                kind: {
                  oneofKind: "select",
                  select: {
                    options: [{ optionId: "a", label: t(118, 1), recommended: true }],
                    multiple: false,
                    defaultOptionIds: ["a"],
                    allowOther: true,
                  },
                },
              },
              {
                fieldId: "token",
                label: t(120, 3),
                required: false,
                kind: { oneofKind: "text", text: { kind: BlockFormText_Kind.SECRET, defaultValue: "leaked" } },
              },
              { fieldId: "on", label: t(124, 2), required: false, kind: { oneofKind: "toggle", toggle: { defaultValue: true } } },
              {
                fieldId: "n",
                label: t(127, 1),
                required: false,
                kind: { oneofKind: "number", number: { min: 0, max: 10, step: 1, integer: true } },
              },
            ],
            requiredGrant: AgentGrantRequirement.ACCESS,
            closed: false,
          },
        },
      },
      {
        kind: {
          oneofKind: "widget",
          widget: { widgetId: "w", title: t(129, 3), html: "<b>hi</b>", height: 300, images: [], requiredGrant: 0 },
        },
      },
      {
        kind: {
          oneofKind: "planProposal",
          planProposal: { title: t(133, 4), children: [], state: BlockDecisionState.PENDING, actionIds: ["approve", "keep"], decidedByUserId: 7n },
        },
      },
      {
        kind: {
          oneofKind: "approval",
          approval: { subject: 1, title: t(138, 3), command: t(142, 4), children: [], state: BlockDecisionState.ACCEPTED, actionIds: [] },
        },
      },
      {
        kind: {
          oneofKind: "review",
          review: {
            verdict: 3,
            findings: [{ title: t(147, 3), priority: 2, path: t(151, 4), startLine: 10, confidence: 1, outcome: 0, category: "correctness" }],
          },
        },
      },
      {
        kind: {
          oneofKind: "taskSuggestion",
          taskSuggestion: {
            title: t(156, 3),
            state: BlockDecisionState.ACCEPTED,
            startedPeer: { type: { oneofKind: "chat", chat: { chatId: 66n } } },
            expiresAt: 1_800_000_000n,
            actionIds: ["start"],
          },
        },
      },
      { kind: { oneofKind: "nextStep", nextStep: { recap: t(160, 3), question: t(164, 3), actionIds: ["yes"], blocking: true } } },
      { kind: { oneofKind: "promptSuggestions", promptSuggestions: { prompts: [{ label: t(168, 3), text: "Do it" }] } } },
      { kind: { oneofKind: undefined } },
    ]
    const result = blocksRow(blocks)
    const kinds = result.blocks?.map((block) => block.kind)
    expect(kinds).toEqual([
      "paragraph",
      "heading",
      "code",
      "list",
      "separator",
      "image",
      "album",
      "disclosure",
      "footer",
      "quote",
      "table",
      "math",
      "diff",
      "fields",
      "steps",
      "callout",
      "meter",
      "form",
      "widget",
      "planProposal",
      "approval",
      "review",
      "taskSuggestion",
      "nextStep",
      "promptSuggestions",
      "unknown",
    ])
    const at = <K extends ContentBlock["kind"]>(kind: K) =>
      result.blocks?.find((block) => block.kind === kind) as Extract<ContentBlock, { kind: K }>
    expect(at("paragraph")).toEqual({ kind: "paragraph", text: { offset: 0, length: 5, rtl: false } })
    expect(at("list")).toEqual({
      kind: "list",
      style: "ordered",
      start: 3,
      items: [
        { children: [{ kind: "paragraph", text: { offset: 15, length: 2 } }], checked: true },
        { children: [{ kind: "paragraph", text: { offset: 18, length: 2 } }] },
      ],
    })
    expect(at("image").image).toEqual({ alt: { offset: 21, length: 2 }, state: "pending", width: 300, height: 200, stripped })
    expect(at("album").images.map((image) => image.state)).toEqual(["ready", "unavailable"])
    expect(at("disclosure")).toMatchObject({ style: "progress", activity: "command", status: "running", startedAt: 1_700_000_000 })
    expect(at("table").alignments).toEqual([undefined, "right"])
    expect(at("diff")).toMatchObject({ change: "modified", additions: 3, deletions: 1, truncated: true })
    expect(at("steps").steps.map((step) => step.status)).toEqual(["done", "waiting"])
    expect(at("callout").tone).toBe("warning")
    expect(at("meter")).toMatchObject({ value: 0.5, max: 1, tone: "critical" })
    const form = at("form")
    expect(form.requiredGrant).toBe("access")
    expect(form.fields.map((field) => field.input.kind)).toEqual(["select", "text", "toggle", "number"])
    // A secret field never carries a default, even if the sender sent one.
    expect(form.fields[1]?.input).toEqual({ kind: "text", style: "secret" })
    expect(JSON.stringify(result)).not.toContain("leaked")
    // The widget's HTML is not on the row.
    expect(at("widget")).toEqual({ kind: "widget", widgetId: "w", title: { offset: 129, length: 3 }, htmlLength: 9, height: 300, images: [] })
    expect(JSON.stringify(result)).not.toContain("<b>")
    expect(at("planProposal")).toMatchObject({ state: "pending", actionIds: ["approve", "keep"], decidedByUserId: "7" })
    expect(at("approval")).toMatchObject({ subject: "command", state: "accepted" })
    expect(at("review")).toMatchObject({ verdict: "needsAttention", findings: [{ priority: "p1", confidence: "confirmed", startLine: 10 }] })
    expect(at("taskSuggestion")).toMatchObject({ startedPeer: { kind: "chat", chatId: "66" }, expiresAt: 1_800_000_000 })
    expect(at("nextStep")).toMatchObject({ blocking: true, actionIds: ["yes"] })
    expect(at("promptSuggestions").prompts).toEqual([{ label: { offset: 168, length: 3 }, text: "Do it" }])
    // Unknown block kinds do not flag the message: they fall back to text.
    expect(result.hasUnsupportedContent).toBeUndefined()
  })

  it("survives structured clone and compares structurally", () => {
    const result = blocksRow([{ kind: { oneofKind: "image", image: { state: { oneofKind: "ready", ready: photo() } } } }])
    const cloned = structuredClone(result)
    expect(cloned).toEqual(result)
    expect(plainEqual(cloned, result)).toBe(true)
  })

  it("degrades malformed parts without throwing", () => {
    expect(textRange({ offset: -1n, length: 2n })).toBeUndefined()
    expect(textRange({ offset: 1n << 60n, length: 2n })).toBeUndefined()
    expect(textRange("x")).toBeUndefined()
    expect(contentBlock(null)).toEqual({ kind: "unknown" })
    expect(contentBlock({ kind: { oneofKind: "heading", heading: { text: { offset: "a" }, level: 2 } } })).toEqual({
      kind: "heading",
      level: 2,
    })
    expect(contentBlock({ kind: { oneofKind: "list", list: { items: "nope" } } })).toEqual({ kind: "list", items: [] })
    const hostile = {
      get kind() {
        throw new Error("boom")
      },
    }
    expect(contentBlock(hostile)).toEqual({ kind: "unknown" })
    expect(contentBlocks({ blocks: [hostile, { kind: { oneofKind: "separator", separator: {} } }] })).toEqual([
      { kind: "unknown" },
      { kind: "separator" },
    ])
  })

  it("caps nesting depth as unknown", () => {
    let block: unknown = { kind: { oneofKind: "paragraph", paragraph: t(0, 1) } }
    for (let depth = 0; depth < 40; depth++) block = { kind: { oneofKind: "quote", quote: { children: [block] } } }
    let projected: ContentBlock | undefined = contentBlock(block)
    let levels = 0
    while (projected?.kind === "quote") {
      projected = projected.children[0]
      levels++
    }
    expect(levels).toBe(32)
    expect(projected).toEqual({ kind: "unknown" })
  })

  it("keeps an encoded proto round trip identical to the direct object", () => {
    const content = BlockContent.create({ blocks: [{ kind: { oneofKind: "paragraph", paragraph: t(0, 3) } }] })
    const decoded = BlockContent.fromBinary(BlockContent.toBinary(content))
    expect(blocksRow(decoded.blocks).blocks).toEqual([{ kind: "paragraph", text: { offset: 0, length: 3 } }])
    expect(Block.create().kind.oneofKind).toBeUndefined()
  })
})
