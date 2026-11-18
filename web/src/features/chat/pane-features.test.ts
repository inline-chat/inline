import type { ChatRow, ComposeActivity, Entity, FindInChatHit, QueryDescriptor, SubId, UserRow } from "@inline/core-protocol"
import { chatId as toChatId, messageId as toMessageId, userId as toUserId, type ChatID, type MessageID, type SpaceID } from "@inline/ids"
import { computed, signal, type ReadSignal } from "@inline/reactive"
import { createManualClock, ToastQueue } from "@inline/ui"
import { AccountSession, actionHandle } from "@inline/view/features"
import { afterEach, describe, expect, it } from "vitest"
import { combinedSuggest, type EmojiModules } from "../../app/emoji-session"
import { wireSessionQuickSearch } from "../../app/quick-search-session"
import { ShellModel } from "../../app/shell-model"
import { memoryStorage } from "../../app/test-fixtures"
import { testHarness, type TestHarness } from "../chat-info/testing"
import * as emojiLight from "../emoji"
import type { EmojiChunk } from "../emoji"
import { findCommandIds } from "../find/commands"
import { FindInChatModel } from "../find/find-model"
import { coreFindSource, coreServerFindSource } from "../find/find-source"
import { createComposeReporter } from "../typing/outgoing"
import { createChatComposer } from "./chat-composer"
import { ChatFind } from "./chat-find"
import { ChatMentions } from "./chat-mentions"
import { ComposerEmojiSlot } from "./composer-emoji"
import { ChatPaneModel, paneDestination, type OpenChat } from "./chat-pane-model"
import type { FindChunk } from "./find-chunk"
import type { ConfirmRequest } from "./message-actions"
import * as mentionsChunk from "./mentions-chunk"

/** A name as it appears inside a typing sentence: isolated for bidirectional text. */
const N = (name: string) => `\u2068${name}\u2069`

/**
 * What this pass mounted in the chat pane, at the pane's level, over the
 * real session, store client and the feature models (a scripted core that
 * answers chats, users, participants, compose activity and intents):
 * find in chat per chat (created on the first Mod+F, disposed with the
 * chat, its jump reaching the timeline and the row highlight), the
 * composer's real `@` suggestions and the rule-14 notice, the header's
 * subtitle priority with typing, and this user's typing reported from the
 * composer.
 */

const me = toUserId("1")
const uid = (n: number) => toUserId(String(n))
const cid = (n: number) => toChatId(String(n))

const users: UserRow[] = [
  { kind: "user", id: uid(2), firstName: "Ada", lastName: "Lovelace", username: "ada" },
  { kind: "user", id: uid(3), firstName: "Alan", lastName: "Turing", username: "alan" },
  { kind: "user", id: uid(7), firstName: "Helper", bot: true },
]
const thread: ChatRow = { kind: "chat", id: cid(100), title: "Launch" }
const direct: ChatRow = { kind: "chat", id: cid(200), peerUserId: uid(2) }
const botChat: ChatRow = { kind: "chat", id: cid(300), peerUserId: uid(7) }

const chunkOf = <T>(module: T) => {
  const value = signal<T | undefined>(undefined)
  let loads = 0
  return {
    value: value as ReadSignal<T | undefined>,
    load: async () => {
      loads += 1
      value.set(module)
      return module
    },
    loads: () => loads,
  }
}

const flushAll = async (h: TestHarness) => {
  for (let i = 0; i < 4; i++) {
    await h.flush()
    for (let j = 0; j < 10; j++) await Promise.resolve()
  }
}

let h: TestHarness | undefined
afterEach(() => {
  h?.dispose()
  h = undefined
})

const setup = async () => {
  h = testHarness({ me })
  const t = h
  t.core.setUsers(users)
  for (const chat of [thread, direct, botChat]) {
    t.core.setChat(chat)
    t.client.subscribe({ kind: "chat", chatId: chat.id })
  }
  const session = new AccountSession({
    userId: me,
    token: "t",
    connect: () => ({ core: t.core.endpoint, client: t.client, close: () => {} }),
    clock: t.time,
  })
  const paneId = session.workspace.focusedPaneId.peek()
  const pane = new ChatPaneModel({
    session,
    timeZone: "UTC",
    clock: { now: () => t.time.now(), setTimeout: () => () => {} },
    frames: { request: () => () => {} },
  })
  pane.follow(paneDestination(session.workspace, paneId))
  const shell = new ShellModel({
    runtime: { storage: memoryStorage(), attachShell: () => () => {} },
    session,
    toasts: new ToastQueue({ clock: createManualClock() }),
    nextFrame: (fn) => void fn(),
  })
  const open = async (chatId: ChatID) => {
    session.workspace.open({ kind: "chat", chatId })
    await flushAll(t)
    return pane.current.peek() as OpenChat
  }
  await flushAll(t)
  return { h: t, session, paneId, pane, shell, open }
}

const subOf = (h: TestHarness, kind: QueryDescriptor["kind"]): SubId | undefined => {
  let found: SubId | undefined
  const live = new Map<SubId, QueryDescriptor>()
  for (const command of h.core.scripted.posted) {
    if (command.kind === "subscribe") live.set(command.sub, command.query)
    if (command.kind === "unsubscribe") live.delete(command.sub)
  }
  for (const [sub, query] of live) if (query.kind === kind) found = sub
  return found
}

const hit12: FindInChatHit = {
  messageId: toMessageId("12"),
  fromId: uid(2),
  date: 1_800_000_000,
  out: false,
  text: "launch day",
  ranges: [[0, 6]],
  cursor: "c1",
}

const answerFind = (s: { h: TestHarness }, hits: FindInChatHit[]) => {
  const sub = subOf(s.h, "findInChat")
  expect(sub).toBeDefined()
  s.h.core.scripted.patch({
    resources: [
      {
        sub: sub!,
        value: {
          kind: "search",
          status: "done",
          result: { kind: "findInChat", hits, hasOlder: false, hasNewer: false, indexComplete: true, truncated: false },
        },
      },
    ],
  })
}

describe("find in chat in the pane", () => {
  const findChunk = () =>
    chunkOf({ FindInChatModel, coreFindSource, coreServerFindSource, FindBar: (() => null) as unknown as FindChunk["FindBar"] } as FindChunk)

  it("creates the model on the first Mod+F for the focused pane's chat, and disposes it with the chat", async () => {
    const s = await setup()
    const chat = await s.open(thread.id)
    const chunk = findChunk()
    const jumps: MessageID[] = []
    const find = new ChatFind({
      chatId: chat.chatId,
      chunk,
      client: s.session.client,
      clock: s.h.time,
      jumpTo: (messageId) => {
        jumps.push(messageId)
        chat.timeline.jumpToMessage(messageId, { highlight: true })
      },
      peekMessage: () => undefined,
    })
    const unregister = s.shell.registerFind(s.paneId, find, () => null)
    expect(s.shell.findTarget.peek()).toBe(find)
    // Nothing loads before the first use.
    expect(chunk.loads()).toBe(0)
    expect(find.model.peek()).toBeUndefined()
    expect(s.session.registry.isEnabled(findCommandIds.find)).toBe(true)

    expect(s.session.registry.run(findCommandIds.find)).toBe(true)
    await flushAll(s.h)
    const model = find.model.peek()
    expect(model).toBeInstanceOf(FindInChatModel)
    expect(model?.chatId).toBe(thread.id)
    expect(find.isOpen.peek()).toBe(true)
    expect(chunk.loads()).toBe(1)

    // A search, its answer, and a step: the jump reaches the timeline and the row's highlight.
    model!.setText("launch")
    s.h.time.advance(120)
    await flushAll(s.h)
    answerFind(s, [hit12])
    await flushAll(s.h)
    model!.setShowsResults(false)
    model!.next()
    expect(jumps).toEqual([toMessageId("12")])
    expect(find.active.peek()).toEqual({ messageId: toMessageId("12"), ranges: [[0, 6]] })
    // No row in the store for it: ranges are clipped to an empty text, so the row shows none.
    expect(find.highlights.rangesFor(`${thread.id}:12`).peek()).toBeUndefined()

    // Closing clears the highlight.
    model!.close()
    expect(find.active.peek()).toBeUndefined()

    // Leaving the chat disposes the model.
    unregister()
    find.dispose()
    expect(find.model.peek()).toBeUndefined()
    expect(model!.isOpen.peek()).toBe(false)
    expect(s.shell.findTarget.peek()).toBeUndefined()
    expect(s.session.registry.isEnabled(findCommandIds.find)).toBe(false)
  })

  it("puts the active match's ranges on its row, clipped to its text, and clears them on close", async () => {
    const s = await setup()
    const chat = await s.open(thread.id)
    const rowId = `${thread.id}:12`
    const find = new ChatFind({
      chatId: chat.chatId,
      chunk: findChunk(),
      client: s.session.client,
      clock: s.h.time,
      jumpTo: () => {},
      peekMessage: (messageId) => ({ kind: "message", id: rowId, chatId: thread.id, messageId, text: "the launch" }) as never,
    })
    const ranges = find.highlights.rangesFor(rowId)
    find.open({ seed: "launch" })
    await flushAll(s.h)
    s.h.time.advance(120)
    await flushAll(s.h)
    answerFind(s, [{ ...hit12, text: "the launch", ranges: [[4, 10], [8, 40]] }])
    await flushAll(s.h)
    const model = find.model.peek()!
    expect(model.text.peek()).toBe("launch")
    model.setShowsResults(false)
    model.next()
    expect(ranges.peek()).toEqual([[4, 10]])
    find.close()
    expect(ranges.peek()).toBeUndefined()
    find.dispose()
  })
})

describe("server search", () => {
  it("find in chat asks the server in this chat too, and merges its hits with the device's by message ID", async () => {
    const s = await setup()
    const chat = await s.open(thread.id)
    const find = new ChatFind({
      chatId: chat.chatId,
      chunk: chunkOf({ FindInChatModel, coreFindSource, coreServerFindSource, FindBar: (() => null) as unknown as FindChunk["FindBar"] } as FindChunk),
      client: s.session.client,
      clock: s.h.time,
      jumpTo: () => {},
      peekMessage: () => undefined,
    })
    find.open({ seed: "launch" })
    await flushAll(s.h)
    s.h.time.advance(400)
    await flushAll(s.h)
    answerFind(s, [hit12])
    const queries = s.h.core.scripted.posted.flatMap((command) => (command.kind === "subscribe" ? [command.query] : []))
    const server = queries.filter((query) => query.kind === "searchServerMessages")
    expect(server.length).toBeGreaterThan(0)
    expect(server[0]).toMatchObject({ kind: "searchServerMessages", request: { chatId: thread.id, query: "launch" } })
    // The server holds an older match the device does not: both are listed, newest first, the device's copy kept.
    // The page request (the other one is the exact count, `countOnly`).
    let serverSub: SubId | undefined
    for (const command of s.h.core.scripted.posted) {
      if (command.kind === "subscribe" && command.query.kind === "searchServerMessages" && !command.query.request.countOnly) serverSub = command.sub
    }
    expect(serverSub).toBeDefined()
    if (serverSub !== undefined) {
      const { cursor: _cursor, ...remote12 } = hit12
      s.h.core.scripted.patch({
        resources: [
          {
            sub: serverSub,
            value: {
              kind: "remoteSearch",
              status: "done",
              result: { kind: "messages", chatId: thread.id, hits: [remote12, { ...remote12, messageId: toMessageId("4"), text: "launch plan" }] },
            },
          },
        ],
      })
    }
    await flushAll(s.h)
    const model = find.model.peek()!
    expect(model.hits.peek().map((hit) => [hit.messageId, hit.remote === true])).toEqual([
      [toMessageId("12"), false],
      [toMessageId("4"), true],
    ])
    find.dispose()
  })

  it("a jump to a server hit the device has not loaded opens a window around it (`ensure { around }`)", async () => {
    const s = await setup()
    const chat = await s.open(thread.id)
    const find = new ChatFind({
      chatId: chat.chatId,
      chunk: chunkOf({ FindInChatModel, coreFindSource, coreServerFindSource, FindBar: (() => null) as unknown as FindChunk["FindBar"] } as FindChunk),
      client: s.session.client,
      clock: s.h.time,
      // The pane's: the timeline brings the message into view, asking the core for its window when it is not loaded.
      jumpTo: (messageId) => chat.timeline.jumpToMessage(messageId, { highlight: true }),
      peekMessage: () => undefined,
    })
    find.open({ seed: "launch" })
    await flushAll(s.h)
    s.h.time.advance(400)
    await flushAll(s.h)
    answerFind(s, [])
    let serverSub: SubId | undefined
    for (const command of s.h.core.scripted.posted) {
      if (command.kind === "subscribe" && command.query.kind === "searchServerMessages" && !command.query.request.countOnly) serverSub = command.sub
    }
    const { cursor: _cursor, ...remote } = hit12
    s.h.core.scripted.patch({
      resources: [
        {
          sub: serverSub!,
          value: { kind: "remoteSearch", status: "done", result: { kind: "messages", chatId: thread.id, hits: [{ ...remote, messageId: toMessageId("4") }] } },
        },
      ],
    })
    await flushAll(s.h)
    const model = find.model.peek()!
    expect(model.hits.peek().map((hit) => hit.remote === true)).toEqual([true])
    model.setShowsResults(false)
    model.next()
    await flushAll(s.h)
    const window = subOf(s.h, "chatWindow")
    const ensures = s.h.core.scripted.posted.filter((command) => command.kind === "ensure" && command.sub === window)
    expect(ensures.at(-1)).toMatchObject({ kind: "ensure", range: { around: toMessageId("4") } })
    find.dispose()
  })

  it("Quick Search asks the server for people (searchUsers); its messages stay local", async () => {
    const s = await setup()
    const wiring = wireSessionQuickSearch(s.session, { clock: s.h.time })
    wiring.open()
    wiring.model.setQuery("ada")
    await flushAll(s.h)
    s.h.time.advance(400)
    await flushAll(s.h)
    const queries = s.h.core.scripted.posted.flatMap((command) => (command.kind === "subscribe" ? [command.query] : []))
    expect(queries).toContainEqual(expect.objectContaining({ kind: "searchUsers", request: expect.objectContaining({ query: "ada" }) }))
    expect(queries.some((query) => query.kind === "searchServerMessages")).toBe(false)
    wiring.dispose()
  })
})

describe("mentions in the composer", () => {
  const composerFor = (chat: OpenChat, s: Awaited<ReturnType<typeof setup>>, extra: Partial<Parameters<typeof createChatComposer>[0]> = {}) =>
    createChatComposer({
      chat,
      paneId: s.paneId,
      safeUrl: (url) => url,
      shell: s.shell,
      unsaved: { register: () => () => {}, onFlush: () => () => {} },
      focusTimeline: () => {},
      ...extra,
    })

  it("gives the composer real suggestions, loading the mention models on the first @", async () => {
    const s = await setup()
    s.h.core.setParticipants(thread.id, [me, uid(2), uid(3)], { complete: true })
    const chat = await s.open(thread.id)
    const chunk = chunkOf(mentionsChunk)
    const mentions = new ChatMentions({
      chatId: chat.chatId,
      viewerId: me,
      client: s.session.client,
      chat: chat.model,
      chunk,
      notify: () => {},
    })
    const composer = composerFor(chat, s, { suggest: mentions.suggest })
    const titles = computed(() => composer.model.autocomplete.suggestions.get().map((row) => row.title))
    expect(titles.get()).toEqual([])
    expect(chunk.loads()).toBe(0)

    composer.model.composer.insertText("@")
    expect(titles.get()).toEqual([])
    await flushAll(s.h)
    expect(chunk.loads()).toBe(1)
    expect(titles.get()).toEqual(expect.arrayContaining(["Ada Lovelace", "Alan Turing"]))
    expect(titles.get()).not.toContain("1")

    composer.model.composer.insertText("ala")
    expect(titles.get()[0]).toBe("Alan Turing")

    composer.dispose()
    mentions.dispose()
    expect(mentions.loaded.peek()).toBeUndefined()
  })

  it("says so when a send mentions someone outside the private thread (rule 14)", async () => {
    const s = await setup()
    s.h.core.setParticipants(thread.id, [me, uid(2)], { complete: true })
    const chat = await s.open(thread.id)
    const notices: { title: string; description?: string }[] = []
    const mentions = new ChatMentions({
      chatId: chat.chatId,
      viewerId: me,
      client: s.session.client,
      chat: chat.model,
      chunk: chunkOf(mentionsChunk),
      notify: (notice) => void notices.push(notice),
      nameOf: (userId) => users.find((user) => user.id === userId)?.firstName,
    })
    await mentions.load()
    await flushAll(s.h)
    const mention = (userId: string): Entity => ({ type: "mention", offset: 0, length: 4, userId: toUserId(userId) }) as Entity

    // Someone with access: nothing to say.
    expect(await mentions.afterSend([mention("2")])).toEqual({ kind: "none" })
    expect(notices).toEqual([])
    // Someone outside, with no way to add them wired: the decision, and a notice.
    const decision = await mentions.afterSend([mention("3")])
    expect(decision.kind === "prompt" || decision.kind === "autoAdd").toBe(true)
    expect(notices).toEqual([expect.objectContaining({ title: "Alan isn't in this thread" })])
    mentions.dispose()
  })

  const ruleFourteen = async (chat: ChatRow, mode: "confirm" | "hold" = "confirm") => {
    const s = await setup()
    s.h.core.setChat(chat)
    s.h.core.setParticipants(thread.id, [me, uid(2)], { complete: true })
    s.h.core.intentMode = mode
    const open = await s.open(thread.id)
    const notices: { title: string; description?: string; tone?: string; action?: { label: string; onAction: () => void } }[] = []
    const asked: ConfirmRequest[] = []
    const intents = (what: "addChatParticipants" | "removeChatParticipant") =>
      (what === "addChatParticipants" ? s.h.core.intentsOf("addChatParticipants") : s.h.core.intentsOf("removeChatParticipant")) as unknown[]
    const mentions = new ChatMentions({
      chatId: open.chatId,
      viewerId: me,
      client: s.session.client,
      chat: open.model,
      chunk: chunkOf(mentionsChunk),
      notify: (notice) => void notices.push(notice),
      nameOf: (userId) => users.find((user) => user.id === userId)?.firstName,
      addParticipants: (userIds) =>
        actionHandle(s.session.client.intent({ kind: "addChatParticipants", chatId: open.chatId, userIds: [...userIds] }), "add them to this thread", {
          store: s.session.client.store,
          tracker: s.session.intents,
        }),
      removeParticipant: (userId) =>
        actionHandle(s.session.client.intent({ kind: "removeChatParticipant", chatId: open.chatId, userId }), "remove them from this thread", {
          store: s.session.client.store,
          tracker: s.session.intents,
        }),
      ask: (request) => void asked.push(request),
    })
    await mentions.load()
    await flushAll(s.h)
    return { s, mentions, notices, asked, intents }
  }
  const mentionOf = (userId: string): Entity => ({ type: "mention", offset: 0, length: 4, userId: toUserId(userId) }) as Entity

  it("asks before adding someone a send mentioned outside the private thread, and adds them on confirm (rule 14, prompt)", async () => {
    const r = await ruleFourteen(thread)
    expect(await r.mentions.afterSend([mentionOf("3")])).toEqual({ kind: "prompt", userIds: [uid(3)] })
    expect(r.asked).toEqual([expect.objectContaining({ title: "Add Alan to this thread?", confirmLabel: "Add", destructive: false })])
    // Nothing is posted until the user answers.
    expect(r.intents("addChatParticipants")).toEqual([])
    r.asked[0]!.run()
    await flushAll(r.s.h)
    expect(r.intents("addChatParticipants")).toEqual([{ kind: "addChatParticipants", chatId: thread.id, userIds: [uid(3)] }])
    expect(r.notices).toEqual([expect.objectContaining({ title: "Added Alan to this thread" })])
    expect(r.notices[0]!.action).toBeUndefined()
    r.mentions.dispose()
  })

  it("adds at once with Undo when the sender may remove people, and asks nothing twice while the add is on its way (rule 14, auto-add)", async () => {
    const r = await ruleFourteen({ ...thread, createdBy: me })
    expect(await r.mentions.afterSend([mentionOf("3")])).toEqual({ kind: "autoAdd", userIds: [uid(3)] })
    await flushAll(r.s.h)
    expect(r.asked).toEqual([])
    expect(r.intents("addChatParticipants")).toEqual([{ kind: "addChatParticipants", chatId: thread.id, userIds: [uid(3)] }])
    const added = r.notices.find((notice) => notice.title === "Added Alan to this thread")
    expect(added?.action?.label).toBe("Undo")
    added!.action!.onAction()
    await flushAll(r.s.h)
    expect(r.intents("removeChatParticipant")).toEqual([{ kind: "removeChatParticipant", chatId: thread.id, userId: uid(3) }])
    r.mentions.dispose()
  })

  it("auto-adds when the sender is an admin of the thread's space, not its creator (rule 14, with the viewer's membership)", async () => {
    const space = "40" as SpaceID
    const r = await ruleFourteen({ ...thread, spaceId: space, createdBy: uid(2) })
    // Before the space's list arrives the viewer's role is unknown: the decision asks.
    expect(subOf(r.s.h, "spaceMembers")).toBeDefined()
    r.s.h.core.setSpaceMembers(space, [{ userId: me, role: "admin" }, { userId: uid(2) }, { userId: uid(3) }])
    await flushAll(r.s.h)
    expect(await r.mentions.afterSend([mentionOf("3")])).toEqual({ kind: "autoAdd", userIds: [uid(3)] })
    await flushAll(r.s.h)
    expect(r.asked).toEqual([])
    expect(r.intents("addChatParticipants")).toEqual([{ kind: "addChatParticipants", chatId: thread.id, userIds: [uid(3)] }])
    r.mentions.dispose()
    expect(subOf(r.s.h, "spaceMembers")).toBeUndefined()
  })

  it("asks when the sender is a plain member of the thread's space (rule 14)", async () => {
    const space = "40" as SpaceID
    const r = await ruleFourteen({ ...thread, spaceId: space, createdBy: uid(2) })
    r.s.h.core.setSpaceMembers(space, [{ userId: me, role: "member" }, { userId: uid(2) }, { userId: uid(3) }])
    await flushAll(r.s.h)
    expect(await r.mentions.afterSend([mentionOf("3")])).toEqual({ kind: "prompt", userIds: [uid(3)] })
    r.mentions.dispose()
  })

  it("leaves people an add is on its way for out of the next decision, and says so when the add is refused", async () => {
    const r = await ruleFourteen({ ...thread, createdBy: me }, "hold")
    await r.mentions.afterSend([mentionOf("3")])
    expect(await r.mentions.afterSend([mentionOf("3")])).toEqual({ kind: "none" })
    expect(r.intents("addChatParticipants")).toHaveLength(1)
    r.s.h.core.settleHeld("rejected", "server")
    await flushAll(r.s.h)
    expect(r.notices.at(-1)).toMatchObject({ title: "Couldn't add them to this thread", tone: "error" })
    r.mentions.dispose()
  })
})

describe("emoji in the pane", () => {
  /** The real emoji light half and table; the pickers' chunk is a stand-in (views). A drawability check without a canvas. */
  const emojiModules = (): EmojiModules => ({
    services: async () => ({
      createEmojiSuggest: emojiLight.createEmojiSuggest,
      createEmojiServices: (options) =>
        emojiLight.createEmojiServices({ ...options, support: emojiLight.createEmojiSupport({ probe: () => undefined, schedule: () => {} } as never) }),
    }),
    pickers: async () => ({}) as EmojiChunk,
  })
  const settle = async (s: { h: TestHarness }) => {
    for (let i = 0; i < 30; i++) {
      await flushAll(s.h)
      await new Promise((resolve) => setTimeout(resolve, 0))
    }
  }

  it("lists emoji for `:` and people for `@` in one composer, and the first Add Reaction loads the emoji picker", async () => {
    const s = await setup()
    s.h.core.setParticipants(thread.id, [me, uid(2), uid(3)], { complete: true })
    const chat = await s.open(thread.id)
    // One shell per session: this one with emoji.
    s.shell.dispose()
    const shell = new ShellModel({
      runtime: { storage: memoryStorage(), attachShell: () => () => {} },
      session: s.session,
      toasts: new ToastQueue({ clock: createManualClock() }),
      nextFrame: (fn) => void fn(),
      emoji: emojiModules(),
    })
    const mentions = new ChatMentions({ chatId: chat.chatId, viewerId: me, client: s.session.client, chat: chat.model, chunk: chunkOf(mentionsChunk), notify: () => {} })
    const composer = createChatComposer({
      chat,
      paneId: s.paneId,
      safeUrl: (url) => url,
      shell,
      unsaved: { register: () => () => {}, onFlush: () => () => {} },
      focusTimeline: () => {},
      suggest: combinedSuggest(mentions.suggest, shell.emoji),
    })
    const titles = computed(() => composer.model.autocomplete.suggestions.get().map((row) => row.title))
    expect(shell.emoji?.services.peek()).toBeUndefined()

    composer.model.composer.insertText(":thumbsup")
    expect(titles.get()).toEqual([])
    await settle(s)
    expect(titles.get()[0]).toBe(":thumbsup:")

    composer.model.composer.insertText(" @")
    await settle(s)
    expect(titles.get()).toEqual(expect.arrayContaining(["Ada Lovelace", "Alan Turing"]))

    composer.dispose()
    mentions.dispose()
    shell.dispose()
    // Add Reaction before the warm-up: the picker's code starts loading with it.
    const fresh = new ShellModel({ runtime: { storage: memoryStorage(), attachShell: () => () => {} }, session: s.session, emoji: emojiModules() })
    const target = { chatId: thread.id, rowId: `${thread.id}:1`, messageId: toMessageId("1"), row: { text: "hi" } } as never
    fresh.messageActions.openPicker(target)
    await settle(s)
    expect(fresh.emoji?.services.peek()).toBeDefined()
    expect(fresh.emoji?.pickers.peek()).toBeDefined()
    fresh.dispose()
  })

  it("names reaction chips once the table is warmed (the rows' `emojiEngine`)", async () => {
    const s = await setup()
    s.shell.dispose()
    const shell = new ShellModel({ runtime: { storage: memoryStorage(), attachShell: () => () => {} }, session: s.session, emoji: emojiModules() })
    expect(shell.emojiEngine.peek()).toBeUndefined()
    await shell.emoji?.warmData()
    await settle(s)
    expect(shell.emojiEngine.peek()?.lookup("👍")?.label).toBe("thumbs up")
    shell.dispose()
  })

  it("the composer's emoji button: a stand-in until the pickers are here, which loads them and opens the picker; a choice goes in at the caret", async () => {
    const s = await setup()
    const chat = await s.open(thread.id)
    const opened: string[] = []
    let onInsert: ((emoji: string) => void) | undefined
    class FakeComposerPicker {
      constructor(options: { onInsert: (emoji: string) => void }) {
        onInsert = options.onInsert
      }
      open() {
        opened.push("open")
      }
      dispose() {}
    }
    const modules: EmojiModules = { ...emojiModules(), pickers: async () => ({ ComposerEmojiPicker: FakeComposerPicker }) as unknown as EmojiChunk }
    s.shell.dispose()
    const shell = new ShellModel({ runtime: { storage: memoryStorage(), attachShell: () => () => {} }, session: s.session, emoji: modules })
    const composer = createChatComposer({
      chat,
      paneId: s.paneId,
      safeUrl: (url) => url,
      shell,
      unsaved: { register: () => () => {}, onFlush: () => () => {} },
      focusTimeline: () => {},
    })
    const slot = new ComposerEmojiSlot({
      emoji: shell.emoji!,
      insert: (value) => {
        composer.model.composer.insertText(value)
        composer.model.focus()
      },
    })
    expect(slot.picker.peek()).toBeUndefined()
    slot.request()
    await settle(s)
    expect(slot.picker.peek()).toBeInstanceOf(FakeComposerPicker)
    expect(opened).toEqual(["open"])
    onInsert?.("🎉")
    expect(composer.model.composer.doc.peek().text).toBe("🎉")
    slot.dispose()
    composer.dispose()
    shell.dispose()
  })
})

describe("what the shell hands the sidebar and the rows", () => {
  it("gives each sidebar row its chat's compose activity from one subscription (`typingFor`)", async () => {
    const s = await setup()
    const row = s.shell.typingFor({ chatId: thread.id } as Parameters<typeof s.shell.typingFor>[0])
    const other = s.shell.typingFor({ chatId: direct.id } as Parameters<typeof s.shell.typingFor>[0])
    expect(row?.peek()).toMatchObject({ typing: false })
    s.h.core.setCompose([{ chatId: thread.id, userId: uid(2), action: "typing" }])
    await flushAll(s.h)
    expect(row?.peek()).toMatchObject({ typing: true, status: { kind: "typing", text: `${N("Ada Lovelace")} is typing` } })
    expect(other?.peek()).toMatchObject({ typing: false })
    expect(s.h.core.scripted.posted.filter((command) => command.kind === "subscribe" && command.query.kind === "composeActions")).toHaveLength(1)
    s.shell.dispose()
    expect(subOf(s.h, "composeActions")).toBeUndefined()
  })
})

describe("typing", () => {
  const compose = (chatId: ChatID, userId: string, action: ComposeActivity["action"] = "typing"): ComposeActivity => ({
    chatId,
    userId: toUserId(userId),
    action,
  })

  const coreSub = (s: Awaited<ReturnType<typeof setup>>) => subOf(s.h, "core")

  it("puts typing in the header subtitle after the connection state and before the DM details", async () => {
    const s = await setup()
    const chat = await s.open(thread.id)
    expect(chat.subtitle.peek()).toEqual({ kind: "none" })

    s.h.core.setCompose([compose(thread.id, "2")])
    await flushAll(s.h)
    expect(chat.subtitle.peek()).toEqual({ kind: "typing", text: `${N("Ada Lovelace")} is typing` })
    expect(chat.activity.peek()?.kind).toBe("typing")

    // Other activity takes the same place.
    s.h.core.setCompose([compose(thread.id, "3", "uploadingPhoto")])
    await flushAll(s.h)
    expect(chat.subtitle.peek()).toEqual({ kind: "typing", text: `${N("Alan")} is sending photo` })
    expect(chat.activity.peek()?.kind).toBe("sending")

    // The connection state wins over typing.
    s.h.core.scripted.patch({
      resources: [
        {
          sub: coreSub(s)!,
          value: { kind: "core", phase: "ready", connection: "waitingForNetwork", storage: "persistent", buildId: "b" },
        },
      ],
    })
    await flushAll(s.h)
    s.h.time.advance(2_000)
    await flushAll(s.h)
    expect(chat.subtitle.peek().kind).toBe("connection")
  })

  it(`${N("shows a bot direct message's details only while nobody")} is typing`, async () => {
    const s = await setup()
    const chat = await s.open(botChat.id)
    expect(chat.subtitle.peek()).toEqual({ kind: "bot" })
    s.h.core.setCompose([compose(botChat.id, "7")])
    await flushAll(s.h)
    expect(chat.subtitle.peek()).toEqual({ kind: "typing", text: "typing" })
    s.h.core.setCompose([])
    await flushAll(s.h)
    expect(chat.subtitle.peek()).toEqual({ kind: "bot" })
  })

  it("reports this user's typing from the composer's input, and stops it on send and when the composer empties", async () => {
    const s = await setup()
    const chat = await s.open(direct.id)
    const reporter = createComposeReporter({ chatId: direct.id, clock: s.h.time, client: s.session.client })
    const composer = createChatComposer({
      chat,
      paneId: s.paneId,
      safeUrl: (url) => url,
      shell: s.shell,
      unsaved: { register: () => () => {}, onFlush: () => () => {} },
      focusTimeline: () => {},
      reporter,
    })
    const actions = () => s.h.core.intentsOf("composeAction").map((intent) => intent.action)
    await flushAll(s.h)
    expect(actions()).toEqual([])

    composer.model.composer.insertText("h")
    await flushAll(s.h)
    expect(actions()).toEqual(["typing"])
    // Within 3 s, more input sends nothing more.
    composer.model.composer.insertText("i")
    await flushAll(s.h)
    expect(actions()).toEqual(["typing"])

    // Send: the stop goes out with the message.
    composer.model.send()
    await flushAll(s.h)
    expect(actions()).toEqual(["typing", null])
    expect(s.h.core.intentsOf("sendText")).toHaveLength(1)

    // Typing again reports at once; emptying the composer stops it.
    composer.model.composer.insertText("x")
    await flushAll(s.h)
    expect(actions()).toEqual(["typing", null, "typing"])
    composer.model.composer.setDraft({ text: "", revision: composer.model.composer.doc.peek().revision + 1 })
    await flushAll(s.h)
    expect(actions()).toEqual(["typing", null, "typing", null])

    // Disposing the composer disposes its reporter.
    composer.dispose()
    expect(reporter.current()).toBeNull()
  })
})
