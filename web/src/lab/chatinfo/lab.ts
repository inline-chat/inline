/**
 * The chat info lab's state: a scripted core (`FakeChatCore`) with a
 * generated space of several hundred people in mixed scripts, chats for each
 * participants fallback, a member list that completes after a delay, and
 * incoming typing from one, two or many people (expired after 6 s like the
 * core does). Over it run the real models: participants, chat info, mention
 * suggestions (fed to a real composer model), incoming typing and the
 * outgoing compose reporter.
 *
 * `state()` is plain data for automation (`globalThis.__chatInfoLab`);
 * `control()` is the operations (`globalThis.__chatInfoLabControl`).
 */

import type { ChatMediaFilter, ChatRow, ComposeActionKind, ComposeActivity, DialogRow, MessageRow, UserGroupRow, UserRow } from "@inline/core-protocol"
import { rowKey } from "@inline/core-protocol"
import { chatId as toChatId, spaceId as toSpaceId, userId as toUserId, type ChatID, type DialogID, type UserID } from "@inline/ids"
import { safeLink } from "@inline/chat-ui"
import { browserClock, browserScheduler, computed, createStoreClient, signal, untracked, type ReadSignal, type StoreClient } from "@inline/reactive"
import { IntentTracker } from "@inline/view/features"
import type { ChatInfoTab } from "@inline/view"
import { createChatInfoModel, type ChatInfoModel, type ChatInfoPaneTab } from "../../features/chat-info/chat-info-model"
import { CHAT_MEDIA_FILTERS, type ChatMediaTabId } from "../../features/chat-info/chat-media-model"
import { cdnMediaSources } from "../../features/content/sources"
import { createParticipantsModel, type ParticipantsModel } from "../../features/chat-info/participants-model"
import { FakeChatCore, type IntentMode } from "../../features/chat-info/testing"
import { createComposerModel, type ComposerModel } from "../../features/composer/model"
import { createMentionSuggestions, recentSenders, type MentionSuggestions } from "../../features/mentions"
import { createComposeReporter, type ComposeReporter } from "../../features/typing/outgoing"
import { createChatTyping, type ChatTypingModel } from "../../features/typing/typing-model"

export type Scenario = "private" | "big" | "subthread" | "reply" | "public" | "direct" | "bot"
export const SCENARIOS: readonly Scenario[] = ["private", "big", "subthread", "reply", "public", "direct", "bot"]
export const SCENARIO_LABELS: Record<Scenario, string> = {
  private: "Private thread",
  big: "Big thread (completes late)",
  subthread: "Subthread",
  reply: "Reply thread",
  public: "Public thread",
  direct: "Direct message",
  bot: "Bot",
}
export const INTENT_MODES: readonly IntentMode[] = ["confirm", "hold", "reject", "storageFull", "uncertain", "unavailable"]
export type LabDir = "ltr" | "rtl"

const ME = toUserId("1")
const SPACE = toSpaceId("7")
const uid = (n: number) => toUserId(String(n))
const cid = (n: number) => toChatId(String(n))

const CHAT_OF: Record<Scenario, ChatID> = {
  private: cid(10),
  big: cid(40),
  subthread: cid(11),
  reply: cid(12),
  public: cid(20),
  direct: cid(30),
  bot: cid(31),
}

// Names in several scripts, so ordering, matching and right-to-left rows get exercised.
const FIRST = [
  "Ada", "Alan", "Grace", "Émile", "Zoë", "Søren", "Łukasz", "José", "Chloé", "Björn",
  "مریم", "علی", "سارا", "رضا", "نگار", "فاطمه", "محمد", "يوسف", "ليلى", "كريم",
  "Юлия", "Дмитрий", "Ελένη", "Νίκος", "さくら", "健太", "美咲", "伟", "芳", "민준",
  "Priya", "Arjun", "Oluwaseun", "Chidi", "Mateo", "Lucía", "Noa", "Yael", "Kai", "Aiyana",
]
const LAST = [
  "Lovelace", "Turing", "Hopper", "Borel", "Ångström", "Kierkegaard", "Wałęsa", "Núñez", "Dubois", "Borg",
  "میرزاخانی", "رضایی", "احمدی", "کریمی", "حسینی", "الخوارزمی", "", "Иванова", "Παπαδόπουλος", "田中",
  "佐藤", "王", "김", "Sharma", "Adeyemi", "García", "Cohen", "Kahananui", "", "Okafor",
]

const generateUsers = (count: number): UserRow[] => {
  const users: UserRow[] = [{ kind: "user", id: ME, firstName: "Mo", lastName: "Rajabi", username: "mo" }]
  for (let i = 0; i < count; i++) {
    const first = FIRST[i % FIRST.length]!
    const last = LAST[(i * 7) % LAST.length]!
    const bot = i % 97 === 13
    users.push({
      kind: "user",
      id: uid(100 + i),
      firstName: bot ? `${first} Bot` : first,
      ...(last && !bot ? { lastName: last } : {}),
      ...(i % 3 === 0 ? { username: `${bot ? "bot_" : ""}user${100 + i}` } : {}),
      ...(bot ? { bot: true } : {}),
    })
  }
  return users
}

const dialogOf = (chat: ChatRow, extra: Partial<DialogRow> = {}): DialogRow => ({
  kind: "dialog",
  id: `9${chat.id}` as DialogID,
  chatId: chat.id,
  pinned: false,
  archived: false,
  open: true,
  unreadCount: 0,
  unreadMark: false,
  ...extra,
})

type Models = {
  participants: ParticipantsModel
  info: ChatInfoModel
  mentions: MentionSuggestions
  typing: ChatTypingModel
  reporter: ComposeReporter
  composer: ComposerModel
  stopFollow: () => void
}

export class ChatInfoLab {
  readonly core = new FakeChatCore({ me: ME })
  readonly client: StoreClient
  readonly tracker: IntentTracker
  readonly clock = browserClock()

  readonly scenario = signal<Scenario>("private")
  readonly offline = signal(false)
  readonly intentMode = signal<IntentMode>("confirm")
  readonly dir = signal<LabDir>("ltr")
  readonly narrow = signal(false)
  readonly completeDelayMs = signal(1_500)
  readonly opened = signal<readonly UserID[]>([])
  readonly copied = signal<readonly string[]>([])
  readonly events = signal<readonly string[]>([])
  /** Notices the pane's model reported (the app shows them as toasts). */
  readonly notices = signal<readonly string[]>([])
  /** Photos and videos opened, files downloaded, links opened. */
  readonly mediaActions = signal<readonly string[]>([])
  readonly models: ReadSignal<Models>
  /** Shared media rows per filter (newest first) and how many are "on the server" past them. */
  readonly #media = new Map<ChatMediaFilter, { rows: MessageRow[]; older: number }>()

  readonly users: UserRow[]
  readonly #models: ReturnType<typeof signal<Models>>
  #compose: ComposeActivity[] = []
  readonly #expiry = new Map<string, ReturnType<typeof setTimeout>>()
  readonly #timers = new Set<ReturnType<typeof setTimeout>>()
  readonly #messageRows = signal<readonly { key: string; fromId: UserID }[]>([])

  constructor(memberCount = 480) {
    this.client = createStoreClient({ endpoint: this.core.endpoint, scheduler: browserScheduler() })
    this.tracker = new IntentTracker({ core: this.core.endpoint, store: this.client.store })
    this.users = generateUsers(memberCount)
    this.#seed()
    // Dialog rows arrive with the sidebar in the app.
    this.client.subscribe({ kind: "sidebar", mode: "all" })
    this.#models = signal(this.#create(this.scenario.peek()))
    this.models = this.#models
  }

  // MARK: Data

  #seed() {
    const core = this.core
    core.setUsers(this.users)
    const people = this.users.slice(1)
    const groups: UserGroupRow[] = [
      { kind: "userGroup", id: "500", spaceId: SPACE, name: "Design", description: "Product design", memberCount: 3, userIds: [uid(100), uid(101), uid(110)], currentUserIsMember: false },
      { kind: "userGroup", id: "501", spaceId: SPACE, name: "Engineering", memberCount: 12, userIds: people.slice(20, 32).map((u) => u.id), currentUserIsMember: true },
      { kind: "userGroup", id: "502", spaceId: SPACE, name: "طراحی", description: "تیم طراحی", memberCount: 2, userIds: [uid(110), uid(111)], currentUserIsMember: false },
    ]
    core.setGroups(groups)
    const chats: ChatRow[] = [
      { kind: "chat", id: cid(10), title: "Launch plan", emoji: "🚀", spaceId: SPACE, createdBy: ME },
      { kind: "chat", id: cid(11), title: "Launch copy", parentChatId: cid(10), spaceId: SPACE },
      { kind: "chat", id: cid(12), parentChatId: cid(11), parentMessageId: "77" as never, spaceId: SPACE },
      { kind: "chat", id: cid(20), title: "General", spaceId: SPACE, isPublic: true },
      { kind: "chat", id: cid(30), peerUserId: uid(100) },
      { kind: "chat", id: cid(31), peerUserId: uid(113) },
      { kind: "chat", id: cid(40), title: "Everyone (big)", spaceId: SPACE },
    ]
    for (const chat of chats) {
      core.setChat(chat)
      core.setDialog(dialogOf(chat))
    }
    core.setParticipants(cid(10), [ME, ...people.slice(0, 60).map((u) => u.id)], { groupIds: ["500", "502"] })
    core.setParticipants(cid(11), [uid(150)])
    core.setParticipants(cid(12), [uid(151)])
    core.setSpaceMembers(
      SPACE,
      this.users.map((user, index) => ({
        userId: user.id,
        role: index === 3 ? "owner" : index % 41 === 5 ? "admin" : "member",
        ...(index % 17 === 9 ? { canAccessPublicChats: false } : {}),
        date: 1_700_000_000 + index * 3_600,
      })),
    )
    this.#loadBig()
    this.#seedMedia()
  }

  /** Shared media of the private thread: 60 photos and videos (20 more "on the server"), files, voice, links. */
  #seedMedia() {
    const chat = cid(10)
    let next = 1_000
    const message = (extra: Partial<MessageRow>): MessageRow => {
      next += 1
      return {
        kind: "message",
        id: `${chat}:${next}` as MessageRow["id"],
        chatId: chat,
        messageId: String(next) as never,
        fromId: this.users[1 + (next % 20)]!.id,
        out: next % 5 === 0,
        date: 1_763_000_000 - next * 3_600,
        text: "",
        state: "sent",
        ...extra,
      }
    }
    const photo = (n: number) => ({ id: String(n) as never, sizes: [{ type: "f", width: 800, height: 600 }] })
    const visual = (count: number) =>
      Array.from({ length: count }, (_, i) =>
        i % 6 === 5
          ? message({ media: { kind: "video", video: { id: String(i) as never, width: 1280, height: 720, duration: 5 + i, size: 1_000, thumbnail: photo(i) } } })
          : message({ media: { kind: "photo", photo: photo(i) } }),
      )
    this.#media.set("photosVideos", { rows: visual(60), older: 20 })
    this.#media.set("files", {
      rows: ["Q4 plan.pdf", "خلاصه.docx", "invoice\u202Efdp.exe", "data.csv"].map((fileName, i) =>
        message({ media: { kind: "document", document: { id: String(i) as never, fileName, mimeType: "application/pdf", size: 120_000 * (i + 1) } } }),
      ),
      older: 0,
    })
    this.#media.set("voice", { rows: [message({ media: { kind: "voice", voice: { id: "1" as never, duration: 42, size: 9_000, mimeType: "audio/ogg" } as never } })], older: 0 })
    this.#media.set("links", {
      rows: [
        message({ text: "https://inline.chat/docs", entities: [{ type: "url", offset: 0, length: 24 }] }),
        message({ text: "spec", entities: [{ type: "textUrl", offset: 0, length: 4, url: "https://example.com/spec" }] }),
      ],
      older: 0,
    })
    for (const [filter, entry] of this.#media) this.core.setChatMedia(chat, filter, entry.rows, { hasMore: entry.older > 0, fetched: true })
    this.#visual = visual
  }

  #visual: ((count: number) => MessageRow[]) | undefined

  /** The next "server page" of a tab: what `ensure older` would bring. */
  nextPage(tab: ChatMediaTabId) {
    const filter = CHAT_MEDIA_FILTERS[tab]
    const entry = this.#media.get(filter)
    if (!entry) return
    const more = filter === "photosVideos" && this.#visual ? this.#visual(Math.min(entry.older, 20)) : []
    entry.rows = [...entry.rows, ...more]
    entry.older -= more.length
    this.core.setChatMedia(cid(10), filter, entry.rows, { hasMore: entry.older > 0, fetched: true })
    this.#log(`${tab}: page of ${more.length}`)
  }

  /** Put a tab's list in a state: loading (with its rows), failed, empty, or back to normal. */
  setMediaState(tab: ChatMediaTabId, state: "loading" | "failed" | "empty" | "normal") {
    const filter = CHAT_MEDIA_FILTERS[tab]
    const entry = this.#media.get(filter) ?? { rows: [], older: 0 }
    const rows = state === "empty" ? [] : entry.rows
    this.core.setChatMedia(cid(10), filter, rows, {
      loading: state === "loading",
      failed: state === "failed",
      hasMore: state === "failed" || (state === "normal" && entry.older > 0),
      fetched: state !== "loading" && state !== "failed",
    })
  }

  /** The case a retried remove produces: the server refuses, the refetched list no longer has them. */
  refusedButGone(index: number) {
    const models = this.#models.peek()
    const key = models.info.members.ids.peek()[index]
    const item = key ? models.participants.member(key).peek() : undefined
    if (!key || item?.kind !== "user") return
    this.setIntentMode("reject")
    models.info.members.requestRemove(key)
    models.info.members.confirmRemove()
    const chat = CHAT_OF[this.scenario.peek()]
    const remaining = this.core.participantIds(chat).filter((id) => id !== item.userId)
    this.#later(200, () => this.core.setParticipants(chat, remaining, { loading: true }))
    this.#later(600, () => this.core.setParticipants(chat, remaining))
  }

  /** The big thread starts with a partial list and completes after `completeDelayMs`. */
  #loadBig() {
    const people = this.users.slice(1).map((u) => u.id)
    this.core.setParticipants(cid(40), [ME, ...people.slice(0, 40)], { complete: false, loading: true, groupIds: [] })
    this.#later(this.completeDelayMs.peek(), () => this.completeRoster())
  }

  completeRoster() {
    this.core.setParticipants(cid(40), [ME, ...this.users.slice(1).map((u) => u.id)], { complete: true, loading: false })
    this.#log("big thread: list complete")
  }

  // MARK: Models

  #create(scenario: Scenario): Models {
    const chatId = CHAT_OF[scenario]
    const client = this.client
    const participants = createParticipantsModel({ client, chatId, viewerId: ME, clock: this.clock })
    const dialogKey = rowKey("dialog", `9${chatId}`)
    const info = createChatInfoModel({
      client,
      chatId,
      viewerId: ME,
      participants,
      dialog: computed(() => client.store.rowByKey(dialogKey).get() as DialogRow | undefined),
      intents: this.tracker,
      offline: this.offline,
      onTabChange: (tab: ChatInfoTab | undefined) => this.#log(`tab → ${tab ?? "settings (no destination tab)"}`),
      onOpenProfile: (userId) => {
        this.opened.set([...this.opened.peek(), userId])
        this.#log(`open profile ${userId}`)
      },
      copyText: async (text) => {
        this.copied.set([...this.copied.peek(), text])
        await globalThis.navigator?.clipboard?.writeText(text)
      },
      clock: this.clock,
      media: {
        sources: cdnMediaSources(),
        onOpenMedia: (input) => this.#mediaAction(`open ${input.kind} ${input.rowId}`),
        onDownload: (input) => this.#mediaAction(`download ${input.rowId}`),
        onOpenLink: (url) => this.#mediaAction(`link ${url}`),
      },
      onNotice: (notice) => this.notices.set([...this.notices.peek().slice(-9), `${notice.kind}: ${notice.title}. ${notice.text}`]),
    })
    // Recent speakers from a stand-in message window.
    const rows = this.#messageRows
    const recent = recentSenders({
      rowKeys: computed(() => rows.get().map((row) => row.key as never)),
      row: (key) => computed(() => rows.get().find((row) => row.key === key)),
    })
    const mentions = createMentionSuggestions({
      client,
      viewerId: ME,
      participants,
      recentSenders: recent,
      directPeers: signal([
        { userId: uid(100), lastMessageDate: 1_790_000_000, pinned: true },
        { userId: uid(113), lastMessageDate: 1_789_000_000 },
        { userId: uid(400), lastMessageDate: 1_788_000_000 },
      ]),
    })
    const typing = createChatTyping({ client, chatId })
    const reporter = createComposeReporter({ chatId, clock: this.clock, client })
    const composer = createComposerModel({
      safeUrl: (url) => safeLink(url)?.href ?? null,
      send: () => ({ status: "accepted" }),
      suggest: mentions.suggest,
    })
    const stopFollow = reporter.followComposer(composer.composer.doc)
    return { participants, info, mentions, typing, reporter, composer, stopFollow }
  }

  #dispose(models: Models) {
    models.stopFollow()
    models.reporter.dispose()
    models.composer.dispose()
    models.typing.dispose()
    models.mentions.dispose()
    models.info.dispose()
    models.participants.dispose()
  }

  setScenario(scenario: Scenario) {
    if (scenario === this.scenario.peek()) return
    const previous = this.#models.peek()
    this.scenario.set(scenario)
    this.#models.set(this.#create(scenario))
    this.#dispose(previous)
    if (scenario === "big" && this.#bigComplete() === false) this.#log("big thread: loading…")
  }

  #bigComplete(): boolean {
    return this.#models.peek().participants.complete.peek()
  }

  /** Reload the big thread's list as partial, completing after the delay again. */
  restartBig() {
    this.#loadBig()
  }

  // MARK: Settings outcomes

  setIntentMode(mode: IntentMode) {
    this.intentMode.set(mode)
    this.core.intentMode = mode
  }

  settleHeld(status: "confirmed" | "rejected" | "uncertain") {
    this.core.settleHeld(status)
  }

  // MARK: Incoming typing (the core's 6 s expiry is emulated here)

  typing(count: number, action: ComposeActionKind = "typing") {
    const scenario = this.scenario.peek()
    const chatId = CHAT_OF[scenario]
    // A direct message has one other person: its peer.
    const people =
      scenario === "direct" ? [uid(100)] : scenario === "bot" ? [uid(113)] : this.users.slice(1, 1 + count).map((u) => u.id)
    for (const userId of people) this.#activity(chatId, userId, action)
    this.#log(`incoming ${action} from ${people.length}`)
  }

  #activity(chatId: ChatID, userId: UserID, action: ComposeActionKind) {
    const key = `${chatId}:${userId}`
    this.#compose = [...this.#compose.filter((entry) => `${entry.chatId}:${entry.userId}` !== key), { chatId, userId, action }]
    this.core.setCompose(this.#compose)
    const previous = this.#expiry.get(key)
    if (previous) clearTimeout(previous)
    this.#expiry.set(
      key,
      setTimeout(() => {
        this.#expiry.delete(key)
        this.#compose = this.#compose.filter((entry) => `${entry.chatId}:${entry.userId}` !== key)
        this.core.setCompose(this.#compose)
      }, 6_000),
    )
  }

  clearTyping() {
    for (const timer of this.#expiry.values()) clearTimeout(timer)
    this.#expiry.clear()
    this.#compose = []
    this.core.setCompose([])
  }

  // MARK: Recent speakers and membership changes

  /** A message from someone, so they rank as a recent speaker in mentions. */
  speak(index: number) {
    const user = this.users[index]
    if (!user) return
    const rows = this.#messageRows.peek()
    this.#messageRows.set([...rows, { key: `m${rows.length + 1}`, fromId: user.id }])
    this.#log(`${user.firstName ?? user.id} spoke`)
  }

  /** Rename one participant: one row renders. */
  rename(index: number) {
    const user = this.users[index]
    if (!user) return
    const next: UserRow = { ...user, lastName: `${user.lastName ?? ""}·` }
    this.users[index] = next
    this.core.setUser(next)
    this.#log(`renamed ${user.id}`)
  }

  // MARK: Plumbing

  #later(ms: number, fn: () => void) {
    const timer = setTimeout(() => {
      this.#timers.delete(timer)
      fn()
    }, ms)
    this.#timers.add(timer)
  }

  #mediaAction(line: string) {
    this.mediaActions.set([...this.mediaActions.peek().slice(-9), line])
    this.#log(line)
  }

  #log(event: string) {
    this.events.set([...this.events.peek().slice(-39), event])
  }

  /** `state()` as a signal for the lab's panel: follows the store, the lab's own signals and the controls. */
  readonly snapshot: ReadSignal<ReturnType<ChatInfoLab["state"]>> = computed(() => {
    const models = this.models.get()
    this.client.store.revision.get()
    this.events.get()
    this.offline.get()
    this.intentMode.get()
    this.dir.get()
    models.typing.status.get()
    models.info.copyState.get()
    models.info.tabsController.selectedId.get()
    models.info.list.activeId.get()
    models.composer.composer.autocomplete.get()
    for (const id of ["notifications", "follow", "pin", "archive", "unread"] as const) models.info.control(id).get()
    this.notices.get()
    this.mediaActions.get()
    models.info.members.ids.get()
    models.info.members.state.get()
    models.info.members.question.get()
    models.info.addPeople.isOpen.get()
    models.info.addPeople.matches.get()
    models.info.addPeople.picked.get()
    models.info.mediaGrid.active.get()
    models.info.mediaGrid.columns.get()
    return untracked(() => this.state())
  })

  /** Everything worth asserting, as plain data. */
  state() {
    const models = this.models.peek()
    const { info, participants, mentions, typing } = models
    const ids = participants.ids.peek()
    const query = (() => {
      const trigger = models.composer.composer.autocomplete.peek()
      return trigger?.kind === "mention" ? trigger.query : null
    })()
    return {
      scenario: this.scenario.peek(),
      chatId: CHAT_OF[this.scenario.peek()],
      header: info.header.peek(),
      tabs: info.tabs.peek().map((tab) => tab.id),
      selectedTab: info.tabsController.selectedId.peek(),
      participants: {
        source: participants.source.peek(),
        status: participants.status.peek(),
        complete: participants.complete.peek(),
        count: ids.length,
        counts: participants.counts.peek(),
        first: ids.slice(0, 8).map((key) => participants.member(key).peek()?.name ?? null),
        active: info.list.activeId.peek(),
      },
      settings: info.settings.peek(),
      controls: Object.fromEntries((["notifications", "follow", "pin", "archive", "unread"] as const).map((id) => [id, info.control(id).peek()])),
      copyState: info.copyState.peek(),
      mentionQuery: query,
      suggestions: query === null ? [] : mentions.rows(query).map((row) => ({ id: row.id, title: row.title, label: row.item.kind === "mention" ? row.item.label : null })),
      typing: typing.status.peek() ?? null,
      outgoing: this.core
        .intentsOf("composeAction")
        .slice(-10)
        .map((intent) => intent.action),
      intents: this.core.intents.slice(-10).map((entry) => entry.intent.kind),
      intentMode: this.intentMode.peek(),
      offline: this.offline.peek(),
      opened: this.opened.peek(),
      copied: this.copied.peek(),
      events: this.events.peek(),
      dir: this.dir.peek(),
      members: {
        canAdd: info.members.canAdd.peek(),
        canManage: info.members.canManage.peek(),
        shown: info.members.ids.peek().length,
        state: info.members.state.peek(),
        question: info.members.question.peek(),
        dialogOpen: info.removeDialog.isOpen.peek(),
        picker: {
          open: info.addPeople.isOpen.peek(),
          query: info.addPeople.query.peek(),
          matches: info.addPeople.matches.peek().slice(0, 6).map((c) => c.name),
          picked: info.addPeople.pickedPeople.peek().map((c) => c.name),
          active: info.addPeople.listbox.activeId.peek(),
        },
      },
      media: Object.fromEntries(
        (["media", "files", "voice", "links"] as const).map((tab) => {
          const model = info.mediaTab(tab)
          return [tab, { count: model.ids.peek().length, footer: model.footer.peek(), resource: model.resource.peek() ?? null }]
        }),
      ),
      grid: { active: info.mediaGrid.active.peek(), columns: info.mediaGrid.columns.peek() },
      ensures: this.core.ensures.slice(-5).map((entry) => entry.range),
      mediaActions: this.mediaActions.peek(),
      notices: this.notices.peek(),
    }
  }

  control() {
    return {
      setScenario: (scenario: Scenario) => this.setScenario(scenario),
      setIntentMode: (mode: IntentMode) => this.setIntentMode(mode),
      settleHeld: (status: "confirmed" | "rejected" | "uncertain") => this.settleHeld(status),
      setOffline: (offline: boolean) => this.offline.set(offline),
      completeRoster: () => this.completeRoster(),
      restartBig: () => this.restartBig(),
      typing: (count: number, action?: ComposeActionKind) => this.typing(count, action),
      clearTyping: () => this.clearTyping(),
      speak: (index: number) => this.speak(index),
      rename: (index: number) => this.rename(index),
      mentionRows: (query: string) => this.models.peek().mentions.rows(query).map((row) => row.title),
      selectTab: (id: ChatInfoPaneTab) => this.models.peek().info.tabsController.select(id),
      nextPage: (tab: ChatMediaTabId) => this.nextPage(tab),
      setMediaState: (tab: ChatMediaTabId, state: "loading" | "failed" | "empty" | "normal") => this.setMediaState(tab, state),
      gridKey: (key: string) => this.models.peek().info.mediaGrid.handleKey(key),
      openAddPeople: () => this.models.peek().info.addPeople.open(),
      pickerQuery: (query: string) => this.models.peek().info.addPeople.setQuery(query),
      pickerKey: (key: string) => this.models.peek().info.addPeople.handleKey(key),
      addPeople: (indexes: readonly number[]) =>
        this.models.peek().info.members.add(indexes.flatMap((index) => (this.users[index] ? [this.users[index]!.id] : []))),
      requestRemove: (index: number) => {
        const key = this.models.peek().info.members.ids.peek()[index]
        if (key) this.models.peek().info.members.requestRemove(key)
      },
      confirmRemove: () => this.models.peek().info.members.confirmRemove(),
      cancelRemove: () => this.models.peek().info.members.cancelRemove(),
      rowActions: (index: number) => {
        const key = this.models.peek().info.members.ids.peek()[index]
        return key ? this.models.peek().info.participantActions(key).map((entry) => ("label" in entry ? entry.label : entry.type)) : []
      },
      refusedButGone: (index: number) => this.refusedButGone(index),
      setNotifications: (mode: "default" | "all" | "mentions" | "none") => this.models.peek().info.setNotifications(mode),
      setPinned: (pinned: boolean) => this.models.peek().info.setPinned(pinned),
      setFollowing: (following: boolean) => this.models.peek().info.setFollowing(following),
      setArchived: (archived: boolean) => this.models.peek().info.setArchived(archived),
      markUnread: () => this.models.peek().info.markUnread(),
      typeInComposer: (text: string) => {
        const composer = this.models.peek().composer.composer
        composer.insertText(text)
      },
      setDir: (dir: LabDir) => this.setDir(dir),
      setNarrow: (narrow: boolean) => this.narrow.set(narrow),
    }
  }

  setDir(dir: LabDir) {
    this.dir.set(dir)
    document.documentElement.dir = dir
  }

  expose() {
    Object.defineProperty(globalThis, "__chatInfoLab", { get: () => this.state(), configurable: true })
    Object.defineProperty(globalThis, "__chatInfoLabControl", { value: this.control(), configurable: true })
  }
}
