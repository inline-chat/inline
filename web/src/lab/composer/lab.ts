/**
 * The composer lab's state: a real `ComposerModel` over fake `send` and
 * `saveDraft` functions whose outcomes the page chooses, a fake member list
 * for mentions, and a record of what the composer did, mirrored as plain data
 * on `globalThis.__composerLab` for browser automation. Framework-free.
 */

import { safeLink } from "@inline/chat-ui"
import {
  createInternalClipboard,
  pasteModuleIfLoaded,
  randomClipboardKey,
  type ComposerEntity,
  type SendKey,
  type SendOutcome,
  type SendRequest,
  type Trigger,
} from "@inline/composer"
import { appClipboard, CLIPBOARD_KEY_STORAGE } from "../../features/composer/clipboard-key"
import { messageId, userId, type MessageID } from "@inline/ids"
import { computed, effect, signal, type Dispose } from "@inline/reactive"
import {
  createComposerModel,
  listenTypeAnywhere,
  type ComposerModel,
  type ComposerSuggestion,
  type MessagePreview,
} from "../../features/composer"

export type SendMode = "accept" | "reject-storage" | "uncertain" | "hold"
export type MentionSource = "instant" | "delayed" | "none"
export type LabTheme = "system" | "light" | "dark"
export type LabDir = "ltr" | "rtl"
export type LabWidth = "wide" | "narrow"

export const SEND_MODE_LABELS: Record<SendMode, string> = {
  accept: "Accept after delay",
  "reject-storage": "Reject: storage full",
  uncertain: "Uncertain (throws)",
  hold: "Hold until settled by hand",
}

type SavedDraft = { text: string; entities: ComposerEntity[]; revision: number }

const people = [
  { id: "11", name: "Ada Lovelace", username: "ada" },
  { id: "12", name: "Alan Turing", username: "alan" },
  { id: "13", name: "Grace Hopper", username: "grace" },
  { id: "14", name: "Katherine Johnson", username: "katherine" },
  { id: "15", name: "Edsger Dijkstra", username: "edsger" },
  { id: "16", name: "مریم میرزاخانی", username: "maryam" },
  { id: "17", name: "長谷川 さくら", username: "sakura" },
]

const emoji = [
  { code: "smile", glyph: "😄" },
  { code: "thumbsup", glyph: "👍" },
  { code: "tada", glyph: "🎉" },
  { code: "eyes", glyph: "👀" },
  { code: "rocket", glyph: "🚀" },
  { code: "heart", glyph: "❤️" },
]

const commands = [
  { name: "rename", description: "Rename this chat" },
  { name: "clear", description: "Clear the composer" },
  { name: "thread", description: "Start a thread" },
]

const messages: Record<string, MessagePreview & { entities?: ComposerEntity[] }> = {
  "101": { senderName: "Ada Lovelace", text: "The engine might compose elaborate pieces of music." },
  "102": { senderName: "You", text: "Shipping the composer lab today", entities: [{ type: "bold", offset: 0, length: 8 }] },
  "103": { senderName: "مریم میرزاخانی", text: "سلام، فردا جلسه داریم؟" },
}

const LAST_OWN_MESSAGE = messageId("102")

const matches = (query: string, ...words: string[]) => {
  const q = query.toLowerCase()
  return words.some((w) => w.toLowerCase().split(/\s+/).some((part) => part.startsWith(q)))
}

const mentionRows = (query: string): ComposerSuggestion[] =>
  people
    .filter((p) => query === "" || matches(query, p.name, p.username))
    .map((p) => ({
      id: `user-${p.id}`,
      title: p.name,
      subtitle: `@${p.username}`,
      avatar: { name: p.name, seed: p.id },
      item: { kind: "mention", atom: { type: "mention", userId: userId(p.id) }, label: `@${p.name}` },
    }))

export class ComposerLab {
  readonly sendMode = signal<SendMode>("accept")
  readonly delayMs = signal(600)
  readonly sendKey = signal<SendKey>("enter")
  readonly mentionSource = signal<MentionSource>("instant")
  readonly otherSources = signal(true)
  readonly theme = signal<LabTheme>("system")
  readonly dir = signal<LabDir>("ltr")
  readonly width = signal<LabWidth>("wide")
  readonly placeholder = signal("Message")
  readonly spellcheck = signal(true)

  readonly lastSend = signal<SendRequest | null>(null)
  readonly savedDraft = signal<SavedDraft | null>(null)
  readonly events = signal<readonly string[]>([])
  /** Suggestions accepted (their `onAccept` ran), in order: `kind:id`. */
  readonly accepted = signal<readonly string[]>([])
  /** Bumped by lab actions whose effect is not a signal (paste module, clipboard key). */
  readonly #tick = signal(0)
  /** A send in "hold" mode, waiting for a button. */
  readonly held = signal<((outcome: SendOutcome) => void) | null>(null)

  #delayed = signal<Readonly<Record<string, ComposerSuggestion[]>>>({})
  #timers = new Set<ReturnType<typeof setTimeout>>()
  #messageList: HTMLElement | null = null

  readonly model: ComposerModel = createComposerModel({
    safeUrl: (url) => safeLink(url)?.href ?? null,
    sendKey: this.sendKey,
    send: (request) => this.#send(request),
    saveDraft: (text, entities, revision) => {
      this.savedDraft.set({ text, entities, revision })
      this.#log(`draft saved r${revision} (${text.length} chars)`)
    },
    suggest: (trigger) => this.#suggest(trigger),
    describeMessage: (id) => this.#describe(id),
    onEditLast: () => {
      const last = messages[LAST_OWN_MESSAGE]!
      this.model.composer.startEdit({ messageId: LAST_OWN_MESSAGE }, { text: last.text, entities: last.entities ?? [] })
      this.#log("Up in empty composer: editing the last message")
      return true
    },
    onEscapeEmpty: () => {
      this.#log("Escape in empty composer: focus to the message list")
      this.#messageList?.focus({ preventScroll: true })
    },
    onFiles: (files) => this.#log(`files: ${files.map((f) => f.name).join(", ")}`),
  })

  /** Everything the panel prints; lazy, so it reads the model only once observed. */
  readonly snapshot = computed(() => {
    const doc = this.model.composer.doc.get()
    return {
      doc: { text: doc.text, entities: doc.entities, selection: doc.selection, revision: doc.revision },
      canSend: this.model.composer.canSend.get(),
      sending: this.model.composer.sending.get(),
      error: this.model.composer.error.get(),
      errorText: this.model.errorText.get(),
      reply: this.model.composer.reply.get(),
      editing: this.model.composer.editing.get(),
      autocomplete: this.model.composer.autocomplete.get(),
      suggestions: this.model.autocomplete.suggestions.get().map((s) => s.id),
      popupOpen: this.model.autocomplete.isOpen.get(),
      activeSuggestion: this.model.autocomplete.cursor.get()?.listbox.activeId.get() ?? null,
      focused: this.model.focused.get(),
      sendKey: this.sendKey.get(),
      sendMode: this.sendMode.get(),
      lastSend: this.lastSend.get(),
      savedDraft: this.savedDraft.get(),
      events: this.events.get(),
      acceptedSuggestions: this.accepted.get(),
      autocompleteChunk: this.model.autocomplete.chunk.get() !== null,
      cursorReady: this.model.autocomplete.cursor.get() !== null,
      ...this.#clipboardState(),
    }
  })

  #clipboardState() {
    this.#tick.get()
    let keyStored = false
    try {
      keyStored = globalThis.localStorage?.getItem(CLIPBOARD_KEY_STORAGE) !== null
    } catch {
      keyStored = false
    }
    return {
      pasteModuleLoaded: pasteModuleIfLoaded() !== null,
      latePaste: this.model.composer.hasLatePaste(),
      clipboardKeyStored: keyStored,
    }
  }

  // -------------------------------------------------------------------------
  // Clipboard checks (cross-tab rich paste, late paste)

  /** The composer's own payload for the current selection (what a copy writes), tagged with this browser's key. */
  payloadForSelection(): string {
    this.#tick.set(this.#tick.peek() + 1)
    return appClipboard.serialize(this.model.composer.selectedContent())
  }

  /** Paste a payload (from another tab's `payloadForSelection`) with its plain text; returns the entities inserted. */
  pasteInternal(raw: string, text: string): ComposerEntity[] {
    const before = this.model.composer.doc.peek().entities.length
    this.model.composer.paste({ internal: raw, text })
    const after = this.model.composer.doc.peek().entities
    this.#log(`pasted internal payload: ${after.length - before} entities`)
    return after.slice(before)
  }

  /** A payload a foreign page could make: a mention under another key. It must paste as plain text. */
  forgedPayload(text = "@Ada Lovelace", userIdText = "999"): string {
    return createInternalClipboard(randomClipboardKey).serialize({
      text,
      entities: [{ type: "mention", offset: 0, length: text.length, userId: userId(userIdText) }],
    })
  }

  /** Paste HTML (bold): parsed at once when the paste module is here, else late. */
  pasteHtml(html = "<b>bold</b> pasted", text = "bold pasted"): void {
    this.model.composer.paste({ html, text })
    this.#tick.set(this.#tick.peek() + 1)
    void this.model.composer.latePastes().then(() => this.#tick.set(this.#tick.peek() + 1))
  }

  // -------------------------------------------------------------------------
  // Fakes

  #send(request: SendRequest): Promise<SendOutcome> {
    this.lastSend.set(request)
    const mode = this.sendMode.peek()
    this.#log(`send ${request.kind} r${request.revision}: ${mode}`)
    if (mode === "hold") {
      return new Promise((resolve) => this.held.set(resolve))
    }
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.#timers.delete(timer)
        if (mode === "accept") resolve({ status: "accepted" })
        else if (mode === "reject-storage") resolve({ status: "rejected", reason: "storageFull" })
        else reject(new Error("outcome unknown"))
      }, this.delayMs.peek())
      this.#timers.add(timer)
    })
  }

  settleHeld(outcome: SendOutcome): void {
    const resolve = this.held.peek()
    if (!resolve) return
    this.held.set(null)
    this.#log(`held send settled: ${outcome.status}`)
    resolve(outcome)
  }

  #suggest(trigger: Trigger): ComposerSuggestion[] {
    return this.#rows(trigger).map((row) => ({ ...row, onAccept: () => this.#accepted(row.id) }))
  }

  #accepted(id: string): void {
    this.accepted.set([...this.accepted.peek(), id])
    this.#log(`accepted ${id}`)
  }

  #rows(trigger: Trigger): ComposerSuggestion[] {
    if (trigger.kind === "mention") {
      const source = this.mentionSource.get()
      if (source === "none") return []
      if (source === "instant") return mentionRows(trigger.query)
      // Delayed: rows arrive 300 ms later through a signal, as a search would.
      const cached = this.#delayed.get()[trigger.query]
      if (cached) return cached
      const timer = setTimeout(() => {
        this.#timers.delete(timer)
        this.#delayed.set({ ...this.#delayed.peek(), [trigger.query]: mentionRows(trigger.query) })
      }, 300)
      this.#timers.add(timer)
      return []
    }
    if (!this.otherSources.get()) return []
    if (trigger.kind === "emoji") {
      return emoji
        .filter((e) => e.code.startsWith(trigger.query.toLowerCase()))
        .map((e) => ({ id: `emoji-${e.code}`, title: `:${e.code}:`, glyph: e.glyph, item: { kind: "emoji", text: e.glyph } }))
    }
    return commands
      .filter((c) => c.name.startsWith(trigger.query.toLowerCase()))
      .map((c) => ({ id: `command-${c.name}`, title: `/${c.name}`, subtitle: c.description, item: { kind: "command", text: c.name } }))
  }

  #describe(id: MessageID): MessagePreview | null {
    const message = messages[id]
    return message ? { senderName: message.senderName ?? "", text: message.text } : null
  }

  #log(line: string): void {
    const time = new Date().toISOString().slice(11, 23)
    this.events.set([...this.events.peek().slice(-29), `${time} ${line}`])
  }

  // -------------------------------------------------------------------------
  // Toggles

  setReply(on: boolean, id = "101"): void {
    this.model.composer.setReply(on ? { messageId: messageId(id) } : null)
  }

  setEditing(on: boolean): void {
    if (!on) {
      this.model.composer.cancelEdit()
      return
    }
    const message = messages["102"]!
    this.model.composer.startEdit({ messageId: LAST_OWN_MESSAGE }, { text: message.text, entities: message.entities ?? [] })
  }

  /** A stored draft with a mention, bold text and a Persian line, restored as switching chats does. */
  loadSampleDraft(): void {
    const text = "Hi @Ada Lovelace, the **plan** is ready\nسلام، فردا جلسه داریم؟"
    const mention = "@Ada Lovelace"
    const plain = text.replace("**plan**", "plan")
    this.model.composer.setDraft({
      text: plain,
      entities: [
        { type: "mention", offset: 3, length: mention.length, userId: userId("11") },
        { type: "bold", offset: plain.indexOf("plan"), length: 4 },
      ],
      revision: this.model.composer.doc.peek().revision + 1,
    })
    this.#log("sample draft restored")
  }

  // -------------------------------------------------------------------------
  // DOM

  /** The fake message list that Escape hands focus to. */
  readonly messageList = {
    attach: (element: HTMLElement) => {
      this.#messageList = element
      return () => {
        if (this.#messageList === element) this.#messageList = null
      }
    },
  }

  /** Type anywhere to focus, as the app shell will do. */
  installTypeAnywhere(doc: Document): Dispose {
    return listenTypeAnywhere(doc, () => this.model, (key) => this.#log(`type anywhere: focused for "${key}"`))
  }

  /** Mirror the state on `globalThis.__composerLab` as plain data. */
  expose(): Dispose {
    const stop = effect(() => {
      const snapshot = this.snapshot.get()
      ;(globalThis as { __composerLab?: unknown }).__composerLab = JSON.parse(JSON.stringify(snapshot)) as unknown
    })
    ;(globalThis as { __composerLabControls?: unknown }).__composerLabControls = {
      setSendMode: (mode: SendMode) => this.sendMode.set(mode),
      setDelay: (ms: number) => this.delayMs.set(ms),
      setSendKey: (key: SendKey) => this.sendKey.set(key),
      setMentionSource: (source: MentionSource) => this.mentionSource.set(source),
      setReply: (on: boolean) => this.setReply(on),
      setEditing: (on: boolean) => this.setEditing(on),
      settleHeld: (status: "accepted" | "rejected") =>
        this.settleHeld(status === "accepted" ? { status } : { status, reason: "storageFull" }),
      loadSampleDraft: () => this.loadSampleDraft(),
      focus: () => this.model.focus(),
      payloadForSelection: () => this.payloadForSelection(),
      pasteInternal: (raw: string, text: string) => this.pasteInternal(raw, text),
      forgedPayload: (text?: string, id?: string) => this.forgedPayload(text, id),
      pasteHtml: (html?: string, text?: string) => this.pasteHtml(html, text),
      selectAll: () => this.model.composer.selectAll(),
    }
    return stop
  }

  dispose(): void {
    for (const timer of this.#timers) clearTimeout(timer)
    this.#timers.clear()
    this.model.dispose()
  }
}

export const applyTheme = (theme: LabTheme) => {
  document.documentElement.style.colorScheme = theme === "system" ? "light dark" : theme
}

export const applyDir = (dir: LabDir) => {
  document.documentElement.dir = dir
}
