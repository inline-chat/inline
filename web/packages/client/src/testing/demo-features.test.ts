import { inflateSync } from "node:zlib"
import {
  CreateUploadInput,
  DialogNotificationSettings_Mode,
  GetChatHistoryMode,
  GetChatInput,
  GetChatsInput,
  GetUpdatesInput,
  Method,
  RpcError_Code,
  SearchMessagesFilter,
  UpdateComposeAction_ComposeAction,
  UploadKind,
  type Message,
  type RpcCall,
  type RpcResult,
  type Update,
} from "@inline-chat/protocol/core"
import { describe, expect, it } from "vitest"
import { sha256 } from "../media/bytes"
import { createDemoAccount, type DemoChatPlan } from "./demo-account"
import {
  demoPng,
  demoPngSize,
  demoStripped,
  demoText,
  demoWav,
  demoWavSize,
  imageDimensions,
} from "./demo-bytes"
import { extrasOf, mediaKindOf, photoSpec } from "./demo-content"
import { isDemoCommand } from "./demo-protocol"
import { DemoServerModel, isDemoPersistedState } from "./demo-server-model"
import { generateFile } from "./demo-transfers"
import { chatInputPeer, type ModelPush } from "./server-model"

/**
 * The demo server model's features, RPC by RPC: content, files, uploads,
 * people, typing, dialog actions, settings, search, bot actions and what a
 * restart keeps. End to end through the real core: `demo-features-core.test.ts`.
 */

const ANCHOR = 1_800_000_000

type Input = RpcCall["input"]

const setup = (scale: "small" | "medium" = "small") => {
  const account = createDemoAccount({ seed: 5, scale, anchor: ANCHOR })
  let now = ANCHOR
  const server = new DemoServerModel(account, { now: () => now })
  for (const plan of account.chats) server.installChat(plan)
  const scheduled: Array<() => void> = []
  server.schedule = (_delay, run) => {
    scheduled.push(run)
  }
  const pushes: ModelPush[] = []
  const session = server.connect((push) => pushes.push(push))
  const other = server.connect(() => undefined)
  const rpc = <K extends NonNullable<RpcResult["result"]["oneofKind"]>>(input: Input, kind: K, sessionId = other.id) => {
    const outcome = server.handleRpc(sessionId, Method.UNSPECIFIED, input)
    if (!("result" in outcome)) throw new Error(`${input.oneofKind}: ${outcome.error.message}`)
    if (outcome.result.oneofKind !== kind) throw new Error(`expected ${kind}`)
    return (outcome.result as Record<string, unknown>)[kind] as Extract<RpcResult["result"], { oneofKind: K }>[K & keyof Extract<RpcResult["result"], { oneofKind: K }>]
  }
  const error = (input: Input) => {
    const outcome = server.handleRpc(other.id, Method.UNSPECIFIED, input)
    if ("result" in outcome) throw new Error("expected an error")
    return outcome.error
  }
  const tick = (seconds: number) => {
    now += seconds
  }
  return { account, server, pushes, session, other, rpc, error, scheduled, tick }
}

const history = (rpc: ReturnType<typeof setup>["rpc"], chatId: bigint, limit = 200, beforeId?: bigint) =>
  rpc(
    {
      oneofKind: "getChatHistory",
      getChatHistory: {
        peerId: chatInputPeer(chatId),
        mode: beforeId != null ? GetChatHistoryMode.HISTORY_MODE_OLDER : GetChatHistoryMode.HISTORY_MODE_LATEST,
        limit,
        ...(beforeId != null ? { beforeId } : {}),
      },
    },
    "getChatHistory",
  ).messages

const allSeeded = (account: ReturnType<typeof createDemoAccount>) =>
  account.chats.flatMap((plan) =>
    Array.from({ length: plan.count }, (_, index) => BigInt(index + 1))
      .filter((id) => !account.holeAt(plan, id))
      .map((id) => ({ plan, message: account.messageAt(plan, id) })),
  )

const pushedUpdates = (pushes: ModelPush[]) => pushes.flatMap((push) => push.updates)

describe("demo bytes", () => {
  it("makes valid PNGs of a size known up front", () => {
    for (const [w, h] of [
      [320, 240],
      [90, 320],
      [800, 133],
      [1, 1],
    ] as const) {
      const png = demoPng(42, w, h)
      expect(png.length).toBe(demoPngSize(w, h))
      expect(Array.from(png.subarray(0, 8))).toEqual([0x89, 0x50, 0x4e, 0x47, 0x0d, 0x0a, 0x1a, 0x0a])
      expect(imageDimensions(png)).toEqual({ width: w, height: h })
      // Chunks: each CRC checks out, IDAT inflates to one filter byte plus one index per pixel and row.
      const view = new DataView(png.buffer)
      let at = 8
      let idat: Uint8Array | undefined
      while (at < png.length) {
        const length = view.getUint32(at)
        const type = String.fromCharCode(...png.subarray(at + 4, at + 8))
        if (type === "IDAT") idat = png.subarray(at + 8, at + 8 + length)
        at += 12 + length
      }
      expect(at).toBe(png.length)
      expect(inflateSync(idat!).length).toBe(h * (1 + w))
    }
    // Deterministic, and different seeds draw different pictures.
    expect(demoPng(7, 40, 30)).toEqual(demoPng(7, 40, 30))
    expect(demoPng(8, 40, 30)).not.toEqual(demoPng(7, 40, 30))
  })

  it("makes stripped previews, voice notes and documents", () => {
    const stripped = demoStripped(9, 4_032, 3_024)
    expect(Array.from(stripped.subarray(0, 3))).toEqual([1, 30, 40])
    expect(stripped.length).toBeGreaterThan(20)
    expect(stripped.length).toBeLessThan(2_000)
    const wav = demoWav(3, 5)
    expect(wav.length).toBe(demoWavSize(5))
    expect(String.fromCharCode(...wav.subarray(0, 4))).toBe("RIFF")
    expect(demoText(4, 1_234).length).toBe(1_234)
    expect(generateFile("dp_1_10x20")?.length).toBe(demoPngSize(10, 20))
    expect(generateFile("not-a-demo-file")).toBeUndefined()
  })
})

describe("demo content", () => {
  it("seeds media of every kind, entities, forwards, edits, emoji, bot content and holes", () => {
    const { account } = setup("medium")
    const seeded = allSeeded(account)
    const kinds = new Map<string, number>()
    for (const { message } of seeded) {
      const kind = mediaKindOf(extrasOf(message))
      if (kind) kinds.set(kind, (kinds.get(kind) ?? 0) + 1)
    }
    const share = (count: number) => count / seeded.length
    expect(share(Array.from(kinds.values()).reduce((sum, count) => sum + count, 0))).toBeGreaterThan(0.08)
    for (const kind of ["photo", "video", "document", "voice"]) expect(kinds.get(kind) ?? 0).toBeGreaterThan(20)
    const withEntities = seeded.filter(({ message }) => extrasOf(message)?.entities)
    expect(share(withEntities.length)).toBeGreaterThan(0.05)
    for (const { message } of withEntities) {
      for (const entity of extrasOf(message)!.entities!) {
        expect(Number(entity.offset + entity.length)).toBeLessThanOrEqual(message.text.length)
      }
    }
    expect(seeded.some(({ message }) => extrasOf(message)?.fwdFrom)).toBe(true)
    expect(seeded.some(({ message }) => message.editDate != null)).toBe(true)
    expect(seeded.some(({ message }) => /^\p{Extended_Pictographic}/u.test(message.text) && !/\w/.test(message.text))).toBe(true)
    // Bot messages: blocks with ranges inside the text, buttons and forms, from the agent.
    const bot = seeded.filter(({ message }) => extrasOf(message)?.blockContent)
    expect(bot.length).toBeGreaterThan(0)
    expect(bot.every(({ message }) => message.fromId === account.agentUserId)).toBe(true)
    expect(bot.some(({ message }) => extrasOf(message)?.actions)).toBe(true)
    expect(
      bot.some(({ message }) => extrasOf(message)?.blockContent?.blocks.some((block) => block.kind.oneofKind === "form")),
    ).toBe(true)
    // Holes, never the newest message.
    const holes = account.chats.reduce(
      (sum, plan) => sum + Array.from({ length: plan.count }, (_, index) => account.holeAt(plan, BigInt(index + 1))).filter(Boolean).length,
      0,
    )
    expect(holes).toBeGreaterThan(0)
    expect(account.chats.every((plan) => plan.count === 0 || !account.holeAt(plan, BigInt(plan.count)))).toBe(true)
  })

  it("has people: full names, usernames, avatars, direct messages, public and private threads", () => {
    const { account, rpc, server } = setup()
    const chats = rpc({ oneofKind: "getChats", getChats: GetChatsInput.create() }, "getChats")
    expect(chats.users.some((user) => user.lastName && user.username)).toBe(true)
    expect(chats.users.some((user) => user.profilePhoto?.cdnUrl?.startsWith("data:image/png;base64,"))).toBe(true)
    expect(chats.users.some((user) => !user.profilePhoto)).toBe(true)
    expect(chats.spaces.length).toBe(account.spaces.length)
    const direct = account.chats.find((plan) => plan.peerUserId != null)!
    expect(direct).toBeDefined()
    const dialog = chats.dialogs.find((entry) => entry.chatId === direct.id)!
    expect(dialog.peer?.type).toEqual({ oneofKind: "user", user: { userId: direct.peerUserId } })
    // A direct message is addressed by its user, and its messages name the user.
    const page = rpc(
      {
        oneofKind: "getChatHistory",
        getChatHistory: {
          peerId: { type: { oneofKind: "user", user: { userId: direct.peerUserId! } } },
          mode: GetChatHistoryMode.HISTORY_MODE_LATEST,
          limit: 5,
        },
      },
      "getChatHistory",
    )
    expect(page.messages.length).toBeGreaterThan(0)
    expect(page.messages[0]!.peerId?.type).toEqual({ oneofKind: "user", user: { userId: direct.peerUserId } })
    expect(account.chats.some((plan) => plan.isPublic === true)).toBe(true)
    const privateThread = account.chats.find((plan) => plan.isPublic === false)!
    const inside = new Set(server.participantsOf(privateThread.id).map((entry) => entry.userId))
    expect(server.spaceMembersOf(privateThread.spaceId).some((id) => !inside.has(id))).toBe(true)
  })
})

describe("demo files", () => {
  it("encodes photos with a stripped preview and sizes whose bytes GET_FILE_PART serves exactly", () => {
    const { account, rpc, server } = setup("medium")
    const found = allSeeded(account).find(({ message }) => extrasOf(message)?.media?.kind === "photo")!
    const page = history(rpc, found.plan.id, 1, found.message.id + 1n)
    const media = page[0]!.media!.media
    if (media.oneofKind !== "photo") throw new Error("expected a photo")
    const photo = media.photo.photo!
    const stripped = photo.sizes.find((size) => size.type === "s")!
    expect(stripped.bytes?.[0]).toBe(1)
    const largest = photo.sizes.find((size) => size.type === "d")!
    expect(largest.size).toBeGreaterThan(0)
    expect(server.transfers.partsServed).toBe(0)
    let offset = 0n
    const parts: Uint8Array[] = []
    for (;;) {
      const part = rpc(
        { oneofKind: "getFilePart", getFilePart: { fileUniqueId: largest.fileUniqueId!, offset, limit: 256 * 1024 } },
        "getFilePart",
      )
      expect(part.totalSize).toBe(BigInt(largest.size))
      expect(part.sha256).toEqual(sha256(part.data))
      parts.push(part.data)
      offset += BigInt(part.data.length)
      if (offset >= part.totalSize) break
    }
    const bytes = new Uint8Array(parts.reduce((sum, part) => sum + part.length, 0))
    let at = 0
    for (const part of parts) {
      bytes.set(part, at)
      at += part.length
    }
    expect(imageDimensions(bytes)).toEqual({ width: largest.w, height: largest.h })
    // Very tall and very wide shapes keep their aspect in every size.
    for (const shape of ["tall", "panorama"] as const) {
      const spec = photoSpec(1, shape)
      if (spec.kind !== "photo") throw new Error("photo")
      expect(shape === "tall" ? spec.h / spec.w : spec.w / spec.h).toBeGreaterThan(3)
    }
  })

  it("uploads in parts with processing and failures on a control, then sends the photo once", () => {
    const { account, rpc, error, server, pushes } = setup()
    const chat = account.chats.find((plan) => plan.peerUserId == null && plan.count > 0)!
    const body = demoPng(77, 600, 400)
    server.transfers.settings.processingRounds = 1
    const upload = (clientId: number) => {
      const created = rpc(
        {
          oneofKind: "createUpload",
          createUpload: CreateUploadInput.create({
            clientUploadId: new Uint8Array(16).fill(clientId),
            fileName: "photo.png",
            mimeType: "image/png",
            byteCount: BigInt(body.length),
            sha256: sha256(body),
            kind: UploadKind.PHOTO,
            inlineData: body,
          }),
        },
        "createUpload",
      )
      // Inline data is off by default, so the part goes on its own and progress shows.
      expect(created.complete).toBeUndefined()
      expect(created.acceptedParts).toEqual([])
      rpc({ oneofKind: "saveUploadPart", saveUploadPart: { uploadId: created.uploadId, partIndex: 0, data: body } }, "saveUploadPart")
      return created.uploadId
    }
    const uploadId = upload(1)
    expect(rpc({ oneofKind: "finishUpload", finishUpload: { uploadId } }, "finishUpload").state.oneofKind).toBe("processing")
    const finished = rpc({ oneofKind: "finishUpload", finishUpload: { uploadId } }, "finishUpload").state
    if (finished.oneofKind !== "complete" || finished.complete.media.oneofKind !== "photo") throw new Error("complete")
    const photo = finished.complete.media.photo
    expect(photo.sizes[0]).toMatchObject({ w: 600, h: 400, size: body.length })

    server.transfers.settings.failNext = 1
    const failing = upload(2)
    rpc({ oneofKind: "finishUpload", finishUpload: { uploadId: failing } }, "finishUpload")
    const failed = rpc({ oneofKind: "finishUpload", finishUpload: { uploadId: failing } }, "finishUpload").state
    expect(failed).toMatchObject({ oneofKind: "failed", failed: { retryable: true } })

    expect(
      error({
        oneofKind: "sendMessage",
        sendMessage: { peerId: chatInputPeer(chat.id), randomId: 1n, media: { media: { oneofKind: "photo", photo: { photoId: 123n } } } },
      }).code,
    ).toBe(RpcError_Code.MEDIA_NOT_OWNED)
    pushes.length = 0
    const sent = rpc(
      {
        oneofKind: "sendMessage",
        sendMessage: {
          peerId: chatInputPeer(chat.id),
          randomId: 99n,
          message: "a photo",
          media: { media: { oneofKind: "photo", photo: { photoId: photo.id } } },
        },
      },
      "sendMessage",
    )
    const message = sent.updates.flatMap((update) => (update.update.oneofKind === "newMessage" ? [update.update.newMessage.message!] : []))[0]!
    expect(message.media?.media.oneofKind).toBe("photo")
    // The account's other session gets it with its media too.
    const pushed = pushedUpdates(pushes).find((update) => update.update.oneofKind === "newMessage")
    expect(pushed?.update.oneofKind === "newMessage" && pushed.update.newMessage.message?.media?.media.oneofKind).toBe("photo")
    // A retry lands once.
    rpc(
      {
        oneofKind: "sendMessage",
        sendMessage: { peerId: chatInputPeer(chat.id), randomId: 99n, media: { media: { oneofKind: "photo", photo: { photoId: photo.id } } } },
      },
      "sendMessage",
    )
    expect(server.messagesWithRandomId(99n)).toHaveLength(1)
    // The uploaded bytes are what GET_FILE_PART serves.
    const part = rpc(
      { oneofKind: "getFilePart", getFilePart: { fileUniqueId: finished.complete.fileUniqueId, offset: 0n, limit: 512 * 1024 } },
      "getFilePart",
    )
    expect(part.data).toEqual(body)
  })
})

describe("demo realtime", () => {
  it("pushes compose actions, with a direct message's user as its peer", () => {
    const { account, server, pushes, rpc } = setup()
    const thread = account.chats.find((plan) => plan.peerUserId == null)!
    server.composeAction(thread.id, thread.others[0]!, "typing")
    server.composeAction(thread.id, thread.others[0]!, null)
    const direct = account.chats.find((plan) => plan.peerUserId != null)!
    server.composeAction(direct.id, direct.peerUserId!, "recordingVoice")
    const actions = pushedUpdates(pushes).flatMap((update) =>
      update.update.oneofKind === "updateComposeAction" ? [update.update.updateComposeAction] : [],
    )
    expect(actions.map((action) => action.action)).toEqual([
      UpdateComposeAction_ComposeAction.TYPING,
      UpdateComposeAction_ComposeAction.NONE,
      UpdateComposeAction_ComposeAction.RECORDING_VOICE,
    ])
    expect(actions[2]!.peerId?.type).toEqual({ oneofKind: "user", user: { userId: direct.peerUserId } })
    // The account's own compose action is answered and noted.
    rpc(
      {
        oneofKind: "sendComposeAction",
        sendComposeAction: { peerId: chatInputPeer(thread.id), action: UpdateComposeAction_ComposeAction.TYPING },
      },
      "sendComposeAction",
    )
    expect(server.ownCompose).toMatchObject({ chatId: thread.id.toString(), action: UpdateComposeAction_ComposeAction.TYPING })
  })
})

describe("demo membership", () => {
  it("adds and removes participants of a private thread, journaled for sync", () => {
    const { account, server, rpc, error } = setup()
    const thread = account.chats.find((plan) => plan.isPublic === false)!
    const inside = new Set(server.participantsOf(thread.id).map((entry) => entry.userId))
    const outsider = server.spaceMembersOf(thread.spaceId).find((id) => !inside.has(id))!
    const before = server.bucketSeq(`chat:${thread.id}`)
    const added = rpc({ oneofKind: "addChatParticipant", addChatParticipant: { chatId: thread.id, userId: outsider } }, "addChatParticipant")
    expect(added.participant?.userId).toBe(outsider)
    expect(added.users[0]?.id).toBe(outsider)
    const roster = rpc({ oneofKind: "getChatParticipants", getChatParticipants: { chatId: thread.id } }, "getChatParticipants")
    expect(roster.participants.map((entry) => entry.userId)).toContain(outsider)
    rpc({ oneofKind: "removeChatParticipant", removeChatParticipant: { chatId: thread.id, userId: outsider } }, "removeChatParticipant")
    const page = rpc(
      {
        oneofKind: "getUpdates",
        getUpdates: GetUpdatesInput.create({
          bucket: { type: { oneofKind: "chat", chat: { peerId: chatInputPeer(thread.id) } } },
          startSeq: BigInt(before),
        }),
      },
      "getUpdates",
    )
    expect(page.updates.map((update) => update.update.oneofKind)).toEqual(["participantAdd", "participantDelete"])
    const publicThread = account.chats.find((plan) => plan.isPublic === true)!
    expect(error({ oneofKind: "addChatParticipant", addChatParticipant: { chatId: publicThread.id, userId: outsider } }).code).toBe(
      RpcError_Code.BAD_REQUEST,
    )
    const members = rpc({ oneofKind: "getSpaceMembers", getSpaceMembers: { spaceId: thread.spaceId! } }, "getSpaceMembers")
    expect(members.members.some((member) => member.role === 0)).toBe(true)
    expect(members.users.length).toBe(members.members.length)
  })
})

describe("demo dialog actions", () => {
  it("answers archive, pin, mark unread, read all, modes and settings, and replays them through the user bucket", () => {
    const { account, server, rpc, pushes } = setup()
    const chat = account.chats.find(
      (plan) => plan.count > 5 && plan.peerUserId == null && !plan.pinned && server.unreadCount(plan.id) > 0,
    )!
    const peerId = chatInputPeer(chat.id)
    const before = server.bucketSeq("user")
    pushes.length = 0

    const archived = rpc({ oneofKind: "updateDialogArchived", updateDialogArchived: { peerId, archived: true } }, "updateDialogArchived")
    expect(archived.updates[0]?.update.oneofKind).toBe("dialogArchived")
    expect(archived.updates[0]?.seq).toBeUndefined()
    const pinned = rpc({ oneofKind: "updateDialogOrder", updateDialogOrder: { peerId, pinned: true } }, "updateDialogOrder")
    expect(pinned.dialog).toMatchObject({ pinned: true, archived: true })
    expect(pinned.dialog?.pinnedOrder).toBeTruthy()
    rpc({ oneofKind: "markAsUnread", markAsUnread: { peerId } }, "markAsUnread")
    rpc(
      {
        oneofKind: "updateDialogNotificationSettings",
        updateDialogNotificationSettings: { peerId, notificationSettings: { mode: DialogNotificationSettings_Mode.NONE } },
      },
      "updateDialogNotificationSettings",
    )
    rpc({ oneofKind: "updateDialogFollowMode", updateDialogFollowMode: { peerId, followMode: 1 } }, "updateDialogFollowMode")
    // "Mark as Read" without a max ID reads to the latest message and clears the mark.
    const read = rpc({ oneofKind: "readMessages", readMessages: { peerId, readActivity: true } }, "readMessages")
    expect(read.updates.map((update) => update.update.oneofKind).sort()).toEqual(["markAsUnread", "updateReadMaxId"])
    expect(server.unreadCount(chat.id)).toBe(0)

    // Another session of the account was told; the session that asked was not.
    expect(pushedUpdates(pushes).map((update) => update.update.oneofKind)).toContain("dialogArchived")
    const replay = rpc(
      {
        oneofKind: "getUpdates",
        getUpdates: GetUpdatesInput.create({ bucket: { type: { oneofKind: "user", user: {} } }, startSeq: BigInt(before) }),
      },
      "getUpdates",
    )
    expect(replay.updates.map((update) => update.update.oneofKind)).toEqual([
      "dialogArchived",
      "chatOpen",
      "markAsUnread",
      "dialogNotificationSettings",
      "dialogFollowMode",
      "markAsUnread",
      "updateReadMaxId",
    ])
    expect(replay.sidecars?.dialogs.find((dialog) => dialog.chatId === chat.id)).toMatchObject({
      archived: true,
      pinned: true,
      unreadMark: false,
      notificationSettings: { mode: DialogNotificationSettings_Mode.NONE },
    })

    const settings = rpc(
      {
        oneofKind: "updateUserSettings",
        updateUserSettings: { userSettings: { notificationSettings: { silent: true } } },
      },
      "updateUserSettings",
    )
    expect(settings.updates[0]?.update.oneofKind).toBe("updateUserSettings")
    const current = rpc({ oneofKind: "getUserSettings", getUserSettings: {} }, "getUserSettings").userSettings
    expect(current?.notificationSettings).toMatchObject({ silent: true, mode: 1 })
  })

  it("pins messages for everyone in the chat", () => {
    const { account, server, rpc } = setup()
    const chat = account.chats.find((plan) => plan.count > 5)!
    const latest = server.lazy(chat.id)!.latest()!.id
    const pinned = rpc(
      { oneofKind: "pinMessage", pinMessage: { peerId: chatInputPeer(chat.id), messageId: latest, unpin: false } },
      "pinMessage",
    )
    expect(pinned.updates[0]?.update).toMatchObject({ oneofKind: "pinnedMessages", pinnedMessages: { messageIds: [latest] } })
    expect(rpc({ oneofKind: "getChat", getChat: GetChatInput.create({ peerId: chatInputPeer(chat.id) }) }, "getChat").pinnedMessageIds).toEqual([latest])
  })
})

describe("demo search", () => {
  const findOld = (account: ReturnType<typeof createDemoAccount>, plan: DemoChatPlan) => {
    for (let id = BigInt(plan.count - 300); id > 0n; id -= 1n) {
      if (account.holeAt(plan, id)) continue
      const word = account.messageAt(plan, id).text.split(/\s+/).find((candidate) => /^[a-z]{7,}$/.test(candidate))
      if (word) return { id, word }
    }
    throw new Error("no word")
  }

  it("searches a lazy chat beyond its latest page, pages by offset, counts and filters", () => {
    const { account, rpc, server } = setup("medium")
    const busiest = account.chats.slice().sort((left, right) => right.count - left.count)[0]!
    const { id, word } = findOld(account, busiest)
    const search = (extra: Partial<Extract<Input, { oneofKind: "searchMessages" }>["searchMessages"]>) =>
      rpc({ oneofKind: "searchMessages", searchMessages: { peerId: chatInputPeer(busiest.id), queries: [word], ...extra } }, "searchMessages")
    const count = search({ countOnly: true }).totalCount!
    expect(count).toBeGreaterThan(0)
    const hits: Message[] = []
    let offsetId: bigint | undefined
    for (let round = 0; round < 100; round += 1) {
      const page = search({ limit: 20, ...(offsetId != null ? { offsetId } : {}) }).messages
      hits.push(...page)
      if (page.length < 20) break
      offsetId = page.at(-1)!.id
    }
    expect(hits).toHaveLength(count)
    expect(hits.map((hit) => hit.id)).toContain(id)
    expect(hits.every((hit) => (hit.message ?? "").toLowerCase().includes(word))).toBe(true)
    // Newest first.
    expect(hits.map((hit) => hit.id)).toEqual(hits.map((hit) => hit.id).sort((a, b) => (a > b ? -1 : 1)))
    const photos = rpc(
      { oneofKind: "searchMessages", searchMessages: { peerId: chatInputPeer(busiest.id), queries: [], filter: SearchMessagesFilter.FILTER_PHOTOS, limit: 30 } },
      "searchMessages",
    ).messages
    expect(photos.length).toBeGreaterThan(0)
    expect(photos.every((message) => message.media?.media.oneofKind === "photo")).toBe(true)
    expect(server.materializedChats()).toBe(0)
    const people = rpc({ oneofKind: "searchUsers", searchUsers: { query: account.users[0]!.firstName.slice(0, 3) } }, "searchUsers")
    expect(people.users.length).toBeGreaterThan(0)
  })
})

describe("demo bot actions", () => {
  const botMessage = (account: ReturnType<typeof createDemoAccount>, kind: "actions" | "form") =>
    allSeeded(account).find(({ message }) =>
      kind === "actions"
        ? extrasOf(message)?.actions
        : extrasOf(message)?.blockContent?.blocks.some((block) => block.kind.oneofKind === "form"),
    )!

  it("answers buttons after a delay, fails on a control, and closes a submitted form", () => {
    const { account, server, rpc, error, scheduled, pushes } = setup("medium")
    const buttons = botMessage(account, "actions")
    const invoke = { peerId: chatInputPeer(buttons.plan.id), messageId: buttons.message.id, actionId: "approve" }
    const answered = rpc({ oneofKind: "invokeMessageAction", invokeMessageAction: invoke }, "invokeMessageAction")
    expect(answered.interactionId).toBeGreaterThan(0n)
    pushes.length = 0
    scheduled.splice(0).forEach((run) => run())
    const answer = pushedUpdates(pushes).find((update) => update.update.oneofKind === "messageActionAnswered")
    expect(answer?.update).toMatchObject({ messageActionAnswered: { interactionId: answered.interactionId } })
    expect(error({ oneofKind: "invokeMessageAction", invokeMessageAction: { ...invoke, actionId: "nope" } }).code).toBe(
      RpcError_Code.BAD_REQUEST,
    )
    server.actionSettings.failNext = 1
    expect(error({ oneofKind: "invokeMessageAction", invokeMessageAction: invoke }).code).toBe(RpcError_Code.INTERNAL_ERROR)
    rpc({ oneofKind: "invokeMessageAction", invokeMessageAction: invoke }, "invokeMessageAction")

    const form = botMessage(account, "form")
    rpc(
      {
        oneofKind: "invokeMessageAction",
        invokeMessageAction: {
          peerId: chatInputPeer(form.plan.id),
          messageId: form.message.id,
          actionId: "release-checklist",
          form: { values: [{ fieldId: "notify", value: { oneofKind: "toggle", toggle: true }, redacted: false }] },
        },
      },
      "invokeMessageAction",
    )
    pushes.length = 0
    scheduled.splice(0).forEach((run) => run())
    const edit = pushedUpdates(pushes).find((update): update is Update & { update: { oneofKind: "editMessage" } } => update.update.oneofKind === "editMessage")
    const block = edit?.update.editMessage.message?.blockContent?.blocks.find((entry) => entry.kind.oneofKind === "form")
    expect(block?.kind.oneofKind === "form" && block.kind.form.closed).toBe(true)
  })
})

describe("demo persistence", () => {
  it("keeps dialog changes, pins, participants, sent media, reactions and settings across a restart", () => {
    const first = setup()
    const { account, server, rpc } = first
    const chat = account.chats.find((plan) => plan.isPublic === false && plan.count > 3)!
    const peerId = chatInputPeer(chat.id)
    rpc({ oneofKind: "updateDialogArchived", updateDialogArchived: { peerId, archived: true } }, "updateDialogArchived")
    rpc({ oneofKind: "updateDialogOrder", updateDialogOrder: { peerId, pinned: true } }, "updateDialogOrder")
    const latest = server.lazy(chat.id)!.latest()!.id
    rpc({ oneofKind: "pinMessage", pinMessage: { peerId, messageId: latest, unpin: false } }, "pinMessage")
    rpc({ oneofKind: "addReaction", addReaction: { peerId, messageId: latest, emoji: "🎯" } }, "addReaction")
    const inside = new Set(server.participantsOf(chat.id).map((entry) => entry.userId))
    const outsider = server.spaceMembersOf(chat.spaceId).find((id) => !inside.has(id))!
    server.addParticipant(chat.id, outsider)
    const sent = server.postWithContent({
      chatId: chat.id,
      fromId: chat.others[0]!,
      text: "",
      extras: { media: photoSpec(3, "tall"), entities: [] },
    })
    rpc({ oneofKind: "updateUserSettings", updateUserSettings: { userSettings: { notificationSettings: { silent: true } } } }, "updateUserSettings")

    const state = JSON.parse(JSON.stringify(server.persistedState(), (_key, value) => (typeof value === "bigint" ? String(value) : value))) as unknown
    expect(isDemoPersistedState(state)).toBe(true)
    expect(isDemoPersistedState({ ...(state as object), version: 1 })).toBe(false)

    const second = setup()
    second.server.restore(state as never)
    const dialog = second.rpc({ oneofKind: "getChat", getChat: GetChatInput.create({ peerId }) }, "getChat")
    expect(dialog.dialog).toMatchObject({ archived: true, pinned: true })
    expect(dialog.pinnedMessageIds).toEqual([latest])
    expect(second.server.participantsOf(chat.id).map((entry) => entry.userId)).toContain(outsider)
    const page = history(second.rpc, chat.id, 3)
    expect(page.find((message) => message.id === sent.id)?.media?.media.oneofKind).toBe("photo")
    expect(page.find((message) => message.id === latest)?.reactions?.reactions.map((reaction) => reaction.emoji)).toContain("🎯")
    expect(
      second.rpc({ oneofKind: "getUserSettings", getUserSettings: {} }, "getUserSettings").userSettings?.notificationSettings?.silent,
    ).toBe(true)
  })
})

describe("demo control protocol", () => {
  it("validates the new commands", () => {
    expect(isDemoCommand({ kind: "deliver", content: "tallPhoto" })).toBe(true)
    expect(isDemoCommand({ kind: "deliver", content: "hologram" })).toBe(false)
    expect(isDemoCommand({ kind: "typing", chatId: "1000", ms: 5_000 })).toBe(true)
    expect(isDemoCommand({ kind: "typing", action: "dancing" })).toBe(false)
    expect(isDemoCommand({ kind: "activity", level: "busy" })).toBe(true)
    expect(isDemoCommand({ kind: "activity", level: "loud" })).toBe(false)
    expect(isDemoCommand({ kind: "media", uploadLatencyMs: 800, inlineData: true })).toBe(true)
    expect(isDemoCommand({ kind: "media", failNext: "1" })).toBe(false)
    expect(isDemoCommand({ kind: "actions", failNext: 1 })).toBe(true)
    expect(isDemoCommand({ kind: "participants", action: "add", chatId: "1004" })).toBe(true)
    expect(isDemoCommand({ kind: "participants", action: "kick", chatId: "1004" })).toBe(false)
    expect(isDemoCommand({ kind: "otherDevice", action: "archive", chatId: "1004" })).toBe(true)
    expect(isDemoCommand({ kind: "otherUser", action: "pin", chatId: "1004" })).toBe(true)
  })
})
