import type { ChatID, DialogID, InlineID, MessageID, PhotoID, UserID } from "@inline/ids"
import { describe, expect, it } from "vitest"
import {
  applyPatch,
  applySnapshot,
  classifyPatch,
  createProtocolState,
  dropSubscription,
  isClientKey,
  newClientKey,
  optimisticMessageRow,
  localMedia,
  mediaSendIntents,
  ATTACHMENT_PREVIEW_MAX_BYTES,
  type ResourceValue,
  rowKey,
  sentMessageRowId,
  ACTION_ANSWER_TIMEOUT_MS,
  NEW_MESSAGES_RULE,
  type Command,
  type CoreResource,
  type DialogRow,
  type IntentResult,
  type MessageRow,
  type Patch,
  type Row,
  type WindowResource,
} from "./index"

const chat = "5" as ChatID
const user = "7" as UserID

const userRow = (id: string, firstName: string): Row => ({ kind: "user", id: id as UserID, firstName })

const patch = (base: number, extra: Partial<Patch> = {}): Patch => ({
  base,
  revision: base + 1,
  rows: [],
  lists: [],
  resources: [],
  settled: [],
  ...extra,
})

describe("client keys", () => {
  it("accepts only canonical positive 64-bit decimals", () => {
    expect(isClientKey("1")).toBe(true)
    expect(isClientKey("9223372036854775807")).toBe(true)
    expect(isClientKey("9223372036854775808")).toBe(false)
    expect(isClientKey("0")).toBe(false)
    expect(isClientKey("012")).toBe(false)
    expect(isClientKey("-3")).toBe(false)
    expect(isClientKey(12)).toBe(false)
  })

  it("generates valid keys, never zero, from 63 bits", () => {
    const draws: Array<[number, number]> = [
      [0, 0],
      [0xffff_ffff, 5],
    ]
    const key = newClientKey(() => draws.shift() ?? [0, 1])
    expect(key).toBe(((0x7fff_ffffn << 32n) | 5n).toString())
    expect(isClientKey(key)).toBe(true)
    expect(isClientKey(newClientKey())).toBe(true)
  })
})

describe("optimistic rows", () => {
  it("builds the row both sides commit, keyed by the client key", () => {
    const row = optimisticMessageRow(
      { kind: "sendText", chatId: chat, clientKey: "42", text: "hi", entities: [] },
      user,
      100,
    )
    expect(row).toEqual({
      kind: "message",
      id: sentMessageRowId(chat, "42"),
      chatId: chat,
      clientKey: "42",
      fromId: user,
      out: true,
      date: 100,
      text: "hi",
      state: "sending",
    })
  })
})

describe("reference reducer", () => {
  it("applies patches in order, ignores stale ones and reports gaps", () => {
    const state = createProtocolState()
    const a = rowKey("user", "1")
    const b = rowKey("user", "2")
    expect(
      applyPatch(
        state,
        patch(0, {
          rows: [
            { op: "upsert", row: userRow("1", "A") },
            { op: "upsert", row: userRow("2", "B") },
          ],
          lists: [{ sub: 1, op: "replace", keys: [a] }],
        }),
      ),
    ).toBe("applied")
    expect(
      applyPatch(
        state,
        patch(1, {
          rows: [{ op: "remove", kind: "user", id: "1" }],
          lists: [{ sub: 1, op: "splice", index: 0, remove: 1, insert: [b] }],
        }),
      ),
    ).toBe("applied")
    expect(state.revision).toBe(2)
    expect(state.lists.get(1)).toEqual([b])
    expect(state.rows.has(a)).toBe(false)
    expect(classifyPatch(state, patch(1))).toBe("stale")
    expect(applyPatch(state, patch(3))).toBe("gap")
    expect(state.revision).toBe(2)

    applySnapshot(state, {
      revision: 9,
      rows: [userRow("3", "C")],
      lists: [{ sub: 1, keys: [rowKey("user", "3")] }],
      resources: [],
      settled: [],
    })
    expect(state.revision).toBe(9)
    expect(Array.from(state.rows.keys())).toEqual([rowKey("user", "3")])
    dropSubscription(state, 1)
    expect(state.lists.size).toBe(0)
  })
})

describe("message content fields", () => {
  const row: MessageRow = {
    kind: "message",
    id: "5:40",
    chatId: chat,
    messageId: "40" as MessageID,
    fromId: user,
    out: false,
    date: 1,
    text: "Plan\nStep",
    state: "sent",
    media: {
      kind: "photo",
      photo: { id: "9" as PhotoID, sizes: [{ type: "f", width: 10, height: 5, cdnUrl: "https://cdn/f" }], stripped: new Uint8Array([1, 2, 3]) },
    },
    groupedId: "77",
    attachments: [{ kind: "urlPreview", id: "1" as InlineID, url: "https://example.com", title: "Example" }],
    forward: { fromPeer: { kind: "chat", chatId: "8" as ChatID }, fromMessageId: "2" as MessageID },
    replyQuote: "quoted",
    replies: { kind: "reply", chatId: "70" as ChatID, count: 2, hasUnread: false, recentUserIds: [user] },
    via: { kind: "app", app: "claude-code", name: "Claude Code" },
    service: { kind: "pinnedMessage", messageId: "3" as MessageID },
    actions: [[{ actionId: "ok", text: "OK", style: "primary", action: { kind: "callback" }, requiredGrant: "approve" }]],
    blocks: [
      { kind: "planProposal", title: { offset: 0, length: 4 }, children: [], state: "pending", actionIds: ["ok"] },
      { kind: "steps", steps: [{ text: { offset: 5, length: 4 }, status: "running" }] },
      { kind: "unknown" },
    ],
  }

  it("is structured-cloneable plain data and travels in a patch", () => {
    const cloned = structuredClone(row)
    expect(cloned).toEqual(row)
    const state = createProtocolState()
    expect(applyPatch(state, patch(0, { rows: [{ op: "upsert", row: cloned }] }))).toBe("applied")
    expect(state.rows.get(rowKey("message", "5:40"))).toEqual(row)
  })

  it("carries the window certification and the trim command as plain data", () => {
    const resource: WindowResource = {
      kind: "window",
      hasOlder: true,
      hasNewer: false,
      atLatest: true,
      loading: "none",
      certifiedThrough: "40" as MessageID,
    }
    const command: Command = { kind: "trimWindow", sub: 1, keep: { from: "10" as MessageID, to: "40" as MessageID } }
    expect(structuredClone({ resource, command })).toEqual({ resource, command })
  })

  it("carries the 17 November host additions as plain, optional data", () => {
    // A v0 dialog row (no new fields) is still a valid row.
    const v0: DialogRow = {
      kind: "dialog",
      id: "-5" as DialogRow["id"],
      chatId: chat,
      pinned: false,
      archived: false,
      open: true,
      unreadCount: 0,
      unreadMark: false,
    }
    const dialog: DialogRow = {
      ...v0,
      followMode: "following",
      notificationMode: "mentions",
      unreadMentionsCount: 1,
      unreadReactionsCount: 0,
      folderId: "3",
    }
    const core: CoreResource = {
      kind: "core",
      phase: "ready",
      connection: "connected",
      storage: "persistent",
      buildId: "b",
      stalledSync: [{ scope: "chat", chatId: chat, reason: "retryLimit" }],
    }
    const settled: IntentResult = {
      tx: "t",
      status: "confirmed",
      answer: { kind: "alert", title: "Done", text: "Approved" },
    }
    const commands: Command[] = [
      { kind: "subscribe", sub: 9, query: { kind: "newMessages" } },
      { kind: "intent", tx: "r", intent: { kind: "retrySync" } },
      {
        kind: "intent",
        tx: "d",
        intent: { kind: "deleteMessages", chatId: chat, messageIds: [], clientKeys: [newClientKey()] },
      },
      {
        kind: "intent",
        tx: "f",
        intent: {
          kind: "submitForm",
          chatId: chat,
          messageId: "4" as MessageID,
          formId: "survey",
          values: [{ fieldId: "a", value: { kind: "selection", optionIds: ["x"], otherText: "y" } }],
        },
      },
    ]
    const value = { v0, dialog, core, settled, commands }
    expect(structuredClone(value)).toEqual(value)
    expect(NEW_MESSAGES_RULE.maxAgeSeconds).toBeLessThan(NEW_MESSAGES_RULE.retainSeconds)
    expect(ACTION_ANSWER_TIMEOUT_MS).toBeGreaterThan(0)
  })
})

describe("contract-2 additions (17 November)", () => {
  it("an older consumer applies rows carrying fields it does not know", () => {
    // An older UI's reducer: it never reads `dialogId` or `tx`, and keeps the rows whole.
    const state = createProtocolState()
    const chatRow: Row = { kind: "chat", id: chat, title: "Design", dialogId: "-5" as DialogID }
    const sending: MessageRow = {
      ...optimisticMessageRow({ kind: "sendText", chatId: chat, clientKey: "77", text: "hi" }, user, 10, "tx-1"),
    }
    expect(
      applyPatch(state, patch(0, { rows: [{ op: "upsert", row: chatRow }, { op: "upsert", row: sending }] })),
    ).toBe("applied")
    expect(state.rows.get(rowKey("chat", chat))).toEqual(chatRow)
    expect((state.rows.get(rowKey("message", sending.id)) as MessageRow).tx).toBe("tx-1")
    expect(structuredClone(sending)).toEqual(sending)
  })

  it("optimistic rows carry the transaction ID only when given", () => {
    const intent = { kind: "sendText" as const, chatId: chat, clientKey: "77", text: "hi" }
    expect(optimisticMessageRow(intent, user, 10)).not.toHaveProperty("tx")
    expect(optimisticMessageRow(intent, user, 10, "tx-1").tx).toBe("tx-1")
  })

  it("local media carries the attachment's preview: a photo's, and a video's poster frame", () => {
    const preview = new Uint8Array([0xff, 0xd8, 0xff, 0xd9])
    const photo = localMedia({ kind: "photo", fileName: "a.jpg", mimeType: "image/jpeg", size: 9, width: 4, height: 3, preview })
    expect(photo).toMatchObject({ kind: "photo", photo: { preview, sizes: [{ type: "f", width: 4, height: 3 }] } })
    const video = localMedia({
      kind: "video",
      fileName: "a.mp4",
      mimeType: "video/mp4",
      size: 9,
      width: 1280,
      height: 720,
      duration: 12,
      preview,
    })
    expect(video).toEqual({
      kind: "video",
      video: { id: "0", width: 1280, height: 720, duration: 12, size: 9, thumbnail: { id: "0", sizes: [], preview } },
    })
    const plain = localMedia({ kind: "video", fileName: "a.mp4", mimeType: "video/mp4", size: 9 })
    expect(plain).toEqual({ kind: "video", video: { id: "0", width: 0, height: 0, duration: 0, size: 9 } })
  })

  it("mediaSendIntents puts the draft revision on the first send only", () => {
    const sends = mediaSendIntents({
      chatId: chat,
      text: "caption",
      draftRevision: 4,
      attachments: [
        { attachmentId: "a".repeat(24), clientKey: "1" },
        { attachmentId: "b".repeat(24), clientKey: "2" },
      ],
    })
    expect(sends.map((send) => send.draftRevision)).toEqual([4, undefined])
  })

  it("new intents, queries and resources are structured-cloneable", () => {
    const commands: Command[] = [
      { kind: "intent", tx: "a", intent: { kind: "addChatParticipants", chatId: chat, userIds: [user] } },
      { kind: "intent", tx: "r", intent: { kind: "removeChatParticipant", chatId: chat, userId: user } },
      { kind: "subscribe", sub: 1, query: { kind: "chatMedia", chatId: chat, filter: "photosVideos" } },
      { kind: "subscribe", sub: 2, query: { kind: "searchServerMessages", request: { chatId: chat, query: "deploy" } } },
      { kind: "subscribe", sub: 3, query: { kind: "searchUsers", request: { query: "ada" } } },
      { kind: "ensure", sub: 1, range: "older" },
    ]
    const resources: ResourceValue[] = [
      { kind: "chatMedia", loading: false, hasMore: true, fetched: true },
      { kind: "remoteSearch", status: "done", result: { kind: "users", users: [{ kind: "user", id: user }] } },
      { kind: "remoteSearch", status: "failed", reason: "offline" },
    ]
    expect(structuredClone({ commands, resources })).toEqual({ commands, resources })
    expect(ATTACHMENT_PREVIEW_MAX_BYTES).toBeGreaterThan(1024)
  })
})
