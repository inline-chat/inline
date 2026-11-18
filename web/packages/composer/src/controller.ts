import type { MessageID } from "@inline/ids"
import { batch, browserClock, computed, signal, type Clock, type ReadSignal } from "@inline/reactive"
import {
  activeMarks,
  applyBoldShortcut,
  canRedo,
  canUndo,
  collapsed,
  createDoc,
  deleteBackward,
  deleteForward,
  deleteRange,
  deleteSelection,
  detectTrigger,
  diffText,
  emptyHistory,
  expandRange,
  insertAtom,
  insertContent,
  insertLineBreak,
  insertText,
  isMarkActive,
  markBoundary,
  record,
  redo as redoStep,
  removeLink,
  replace,
  replaceRange,
  sameTrigger,
  selectAll,
  selectionRange,
  setLink,
  setSelection,
  sliceContent,
  toggleMark,
  trimmedContent,
  undo as undoStep,
  type AtomSpec,
  type ComposerEntity,
  type DeleteUnit,
  type DocState,
  type EditKind,
  type History,
  type HistoryOptions,
  type Mark,
  type MarkType,
  type Range,
  type Selection,
  type Trigger,
} from "./model"
import { keyCommand, type AutocompleteKey, type KeyInput, type Platform, type SendKey } from "./keys"
import { loadPasteModule, pasteModuleIfLoaded, type PasteModule } from "./clipboard"
import {
  documentClipboard,
  plainContent,
  quickPaste,
  type ClipboardContent,
  type HtmlParser,
  type InternalClipboard,
  type PastedContent,
  type UrlPolicy,
} from "./internal"

/**
 * The composer controller: the document, its history and everything around
 * it (send, reply, edit, drafts, autocomplete, keys), framework-free. A view
 * reads its signals through the reactive bindings; the DOM binding
 * (`attachComposer`) feeds it input and renders its document.
 */

export type ReplyTarget = { messageId: MessageID }
export type EditTarget = { messageId: MessageID }

export type SendRequest = {
  kind: "send" | "edit"
  /** Trimmed text and the entities that go with it. */
  text: string
  entities: ComposerEntity[]
  /** The document revision that was sent; the draft revision it consumes. */
  revision: number
  replyTo?: ReplyTarget
  edit?: EditTarget
}

/**
 * `accepted` means the intent was committed durably (for a send: with the
 * optimistic row and the consumption of the draft revision, in one
 * transaction). Anything else keeps the text in the composer.
 */
export type SendOutcome = { status: "accepted" } | { status: "rejected"; reason?: string }

export type AutocompleteItem =
  | { kind: "mention"; atom: AtomSpec; label: string }
  | { kind: "emoji"; text: string }
  | { kind: "command"; text: string }

export type ComposerOptions = {
  /** Commit the message. The composer clears only after `accepted`. */
  send: (request: SendRequest) => Promise<SendOutcome> | SendOutcome
  /** Persist the draft. Called after a pause in typing and on flush; not while editing a message. */
  saveDraft?: (text: string, entities: ComposerEntity[], revision: number) => void
  /** The link allowlist from `chat-ui`, for paste and `setLink`. */
  safeUrl: UrlPolicy
  /** A draft to start from, restored synchronously. */
  initial?: { text: string; entities?: readonly ComposerEntity[]; revision: number }
  clock?: Clock
  /** Start: 300 ms. */
  draftDebounceMs?: number
  sendKey?: SendKey | ReadSignal<SendKey>
  platform?: Platform
  history?: HistoryOptions
  /** Up in an empty composer. Return true if an edit started. */
  onEditLast?: () => boolean
  /** Arrow, Enter, Tab and Escape while a trigger is active. Return true if the list handled it. */
  onAutocompleteKey?: (key: AutocompleteKey, trigger: Trigger) => boolean
  /** Mod+K. */
  onRequestLink?: () => void
  /** Files pasted or dropped. Attachments are not part of this package yet. */
  onFiles?: (files: readonly File[]) => void
  /** Something other than text that makes the message sendable (attachments). */
  hasAttachments?: ReadSignal<boolean>
  /** HTML parser for paste; see `defaultHtmlParser`. */
  parseHtml?: HtmlParser
  /**
   * Writes and recognizes the composer's own clipboard payloads (`./internal`).
   * Default `documentClipboard` (this document only); the app passes one keyed
   * per browser so its tabs honor each other's copies.
   */
  clipboard?: InternalClipboard
  /** Loads the HTML paste module. Default `loadPasteModule` (tests inject one). */
  loadPaste?: () => Promise<PasteModule>
}

/** Where an offset of `before` is after one change; at the change's start it stays before inserted text. */
const mapOffset = (offset: number, change: { from: number; to: number; inserted: string } | null): number => {
  if (!change || offset <= change.from) return offset
  if (offset >= change.to) return offset + change.inserted.length - (change.to - change.from)
  return change.from + change.inserted.length
}

export type ComposerController = ReturnType<typeof createComposerController>

const readValue = <T>(value: T | ReadSignal<T>): T =>
  typeof value === "object" && value !== null && "peek" in value ? (value as ReadSignal<T>).peek() : (value as T)

export const createComposerController = (options: ComposerOptions) => {
  const clock = options.clock ?? browserClock()
  const debounceMs = options.draftDebounceMs ?? 300
  const platform = options.platform ?? "other"

  const initial = options.initial
    ? createDoc({ text: options.initial.text, entities: options.initial.entities ?? [], revision: options.initial.revision })
    : createDoc()
  const doc = signal<DocState>(initial)
  const history = signal<History>(emptyHistory())
  const reply = signal<ReplyTarget | null>(null)
  const editing = signal<EditTarget | null>(null)
  const sending = signal(false)
  const error = signal<string | null>(null)
  const dismissed = signal<Trigger | null>(null)
  /** The origin of the last document change; the DOM binding skips re-rendering its own read-back. */
  let lastOrigin: "dom" | "model" = "model"

  let stash: { doc: DocState; history: History } | null = null
  let lastSaved = initial.revision
  let saveTimer: unknown = null
  let disposed = false

  // -------------------------------------------------------------------------
  // Derived state

  const trigger = computed(() => detectTrigger(doc.get()), { equals: sameTrigger })
  const autocomplete = computed<Trigger | null>(() => {
    const current = trigger.get()
    const gone = dismissed.get()
    if (!current) return null
    if (gone && gone.kind === current.kind && gone.range.from === current.range.from) return null
    return current
  })
  const canSend = computed(() => {
    if (sending.get()) return false
    if (/\S/u.test(doc.get().text)) return true
    return !editing.get() && (options.hasAttachments?.get() ?? false)
  })
  const marks = computed<Mark[]>(() => {
    const d = doc.get()
    return activeMarks(d, selectionRange(d.selection))
  }, {
    equals: (a, b) => a.length === b.length && a.every((m, i) => m.type === b[i]?.type && m.url === b[i]?.url),
  })
  const undoable = computed(() => canUndo(history.get()))
  const redoable = computed(() => canRedo(history.get()))

  // -------------------------------------------------------------------------
  // Drafts

  const saveNow = () => {
    if (saveTimer !== null) {
      clock.clearTimeout(saveTimer)
      saveTimer = null
    }
    if (editing.peek() || !options.saveDraft) return
    const current = doc.peek()
    if (current.revision === lastSaved) return
    lastSaved = current.revision
    options.saveDraft(current.text, [...current.entities], current.revision)
  }

  const scheduleSave = () => {
    if (disposed || editing.peek() || !options.saveDraft) return
    if (doc.peek().revision === lastSaved) return
    if (saveTimer !== null) clock.clearTimeout(saveTimer)
    saveTimer = clock.setTimeout(() => {
      saveTimer = null
      saveNow()
    }, debounceMs)
  }

  const cancelSave = () => {
    if (saveTimer !== null) clock.clearTimeout(saveTimer)
    saveTimer = null
  }

  // -------------------------------------------------------------------------
  // Applying changes

  const setDoc = (next: DocState, origin: "dom" | "model") => {
    const before = doc.peek()
    if (next === before) return
    lastOrigin = origin
    doc.set(next)
    if (next.revision !== before.revision) {
      error.set(null)
      scheduleSave()
    }
  }

  /** Apply an edit, record it in the history, and run the bold shortcut after typing. */
  const commit = (next: DocState, kind: EditKind, origin: "dom" | "model" = "model") => {
    const before = doc.peek()
    if (next === before) return false
    batch(() => {
      history.set(record(history.peek(), before, next, kind, clock.now(), options.history))
      setDoc(next, origin)
      if (kind === "typing" && next.text.charCodeAt(next.selection.focus - 1) === 42) {
        const bolded = applyBoldShortcut(next)
        if (bolded !== next) {
          history.set(record(history.peek(), next, bolded, "structural", clock.now(), options.history))
          setDoc(bolded, "model")
        }
      }
    })
    return true
  }

  const edit = (fn: (state: DocState) => DocState, kind: EditKind) => commit(fn(doc.peek()), kind)

  // -------------------------------------------------------------------------
  // Commands

  const send = async (): Promise<boolean> => {
    if (!canSend.peek()) return false
    const current = doc.peek()
    const content = trimmedContent(current)
    const replyTo = reply.peek()
    const target = editing.peek()
    const request: SendRequest = {
      kind: target ? "edit" : "send",
      text: content.text,
      entities: content.entities,
      revision: current.revision,
    }
    if (replyTo && !target) request.replyTo = replyTo
    if (target) request.edit = target
    // The send commits this revision; a pending save of it must not land after.
    if (!target) cancelSave()
    sending.set(true)
    let outcome: SendOutcome
    try {
      outcome = await options.send(request)
    } catch {
      outcome = { status: "rejected", reason: "failed" }
    }
    if (disposed) return outcome.status === "accepted"
    batch(() => {
      sending.set(false)
      if (outcome.status !== "accepted") {
        error.set(outcome.reason ?? "rejected")
        scheduleSave()
        return
      }
      const now = doc.peek()
      if (now.revision !== current.revision) {
        // The user kept typing while the intent was committed: keep their text.
        scheduleSave()
        return
      }
      if (target) {
        finishEdit()
        return
      }
      const cleared = createDoc({ revision: now.revision + 1 })
      // The core consumed the draft with the send; the empty draft is already true there.
      lastSaved = cleared.revision
      history.set(emptyHistory())
      reply.set(null)
      dismissed.set(null)
      setDoc(cleared, "model")
    })
    return outcome.status === "accepted"
  }

  const finishEdit = () => {
    const saved = stash
    stash = null
    batch(() => {
      editing.set(null)
      const current = doc.peek()
      const restored = saved
        ? { ...saved.doc, revision: current.revision + 1, pendingMarks: null }
        : createDoc({ revision: current.revision + 1 })
      // Identical to the draft saved before the edit started.
      lastSaved = restored.revision
      history.set(saved?.history ?? emptyHistory())
      setDoc(restored, "model")
    })
  }

  const startEdit = (target: EditTarget, content: { text: string; entities?: readonly ComposerEntity[] }) => {
    if (!editing.peek()) {
      saveNow()
      stash = { doc: doc.peek(), history: history.peek() }
    }
    const current = doc.peek()
    batch(() => {
      editing.set(target)
      reply.set(null)
      history.set(emptyHistory())
      setDoc(createDoc({ text: content.text, entities: content.entities ?? [], revision: current.revision + 1 }), "model")
    })
  }

  const acceptAutocomplete = (item: AutocompleteItem): boolean => {
    const active = autocomplete.peek()
    if (!active) return false
    const state = doc.peek()
    let next: DocState
    if (item.kind === "mention") {
      next = insertAtom(state, item.atom, item.label, { range: active.range })
    } else if (item.kind === "emoji") {
      next = replaceRange(state, active.range, { text: item.text })
    } else {
      const text = item.text.startsWith("/") ? item.text : `/${item.text}`
      next = replaceRange(state, active.range, {
        text: `${text} `,
        entities: [{ type: "botCommand", offset: 0, length: text.length }],
      })
    }
    return commit(next, "structural")
  }

  const handleKeyDown = (input: KeyInput): boolean => {
    const state = doc.peek()
    const active = autocomplete.peek()
    const command = keyCommand(input, {
      platform,
      sendKey: readValue(options.sendKey ?? "enter"),
      autocomplete: active !== null,
      empty: state.text.length === 0,
    })
    if (!command) return false
    switch (command.kind) {
      case "autocomplete": {
        if (!active) return false
        if (options.onAutocompleteKey?.(command.key, active)) return true
        if (command.key === "dismiss") {
          dismissed.set(active)
          return true
        }
        // Not handled by a list: fall through to the plain meaning of the key.
        const plainCommand = keyCommand(input, {
          platform,
          sendKey: readValue(options.sendKey ?? "enter"),
          autocomplete: false,
          empty: state.text.length === 0,
        })
        if (plainCommand?.kind === "send") {
          void send()
          return true
        }
        if (plainCommand?.kind === "newline") {
          edit(insertLineBreak, "structural")
          return true
        }
        return false
      }
      case "send":
        void send()
        return true
      case "newline":
        edit(insertLineBreak, "structural")
        return true
      case "editLast":
        if (editing.peek()) return false
        return options.onEditLast?.() ?? false
      case "escape":
        if (editing.peek()) {
          cancelEdit()
          return true
        }
        if (reply.peek()) {
          reply.set(null)
          return true
        }
        return false
      case "undo":
        undo()
        return true
      case "redo":
        redo()
        return true
      case "toggleMark":
        toggleFormat(command.mark)
        return true
      case "link":
        if (!options.onRequestLink) return false
        options.onRequestLink()
        return true
    }
  }

  const undo = () => {
    const result = undoStep(history.peek(), doc.peek())
    if (!result) return false
    batch(() => {
      history.set(result.history)
      setDoc(result.state, "model")
    })
    return true
  }

  const redo = () => {
    const result = redoStep(history.peek(), doc.peek())
    if (!result) return false
    batch(() => {
      history.set(result.history)
      setDoc(result.state, "model")
    })
    return true
  }

  const toggleFormat = (mark: MarkType | Mark) => {
    const before = doc.peek()
    const next = toggleMark(before, mark)
    if (next === before) return
    if (next.revision === before.revision) {
      // Pending marks at a caret: not an edit, but typing after it is a new step.
      batch(() => {
        history.set(markBoundary(history.peek()))
        setDoc(next, "model")
      })
      return
    }
    commit(next, "structural")
  }

  const cancelEdit = () => {
    if (editing.peek()) finishEdit()
  }

  /**
   * Read back a change the browser made to the text (typing, IME, spelling
   * correction). The model decides entities; the binding re-renders a line
   * only if the browser's DOM differs from what the model renders.
   */
  const applyDomText = (text: string, selection: Selection) => {
    const before = doc.peek()
    const caret = selection.anchor === selection.focus ? selection.focus : undefined
    const change = diffText(before.text, text, caret)
    if (!change) {
      selectFromDom(selection)
      return
    }
    const range = expandRange(before, { from: change.from, to: change.to })
    const typingAtCaret =
      change.from === change.to &&
      before.selection.anchor === before.selection.focus &&
      before.selection.focus === change.from
    const marksFor = activeMarks(before, range)
    let next = replace(before, range, { text: change.inserted, marks: marksFor }, { keepPendingMarks: typingAtCaret })
    // The DOM's selection wins when it is consistent with the new text.
    next = setSelectionKeepingPending(next, selection, typingAtCaret)
    const kind: EditKind =
      change.inserted === ""
        ? "deleting"
        : change.from === change.to && !change.inserted.includes("\n")
          ? "typing"
          : "structural"
    commit(next, kind, "dom")
  }

  const setSelectionKeepingPending = (state: DocState, selection: Selection, keep: boolean): DocState => {
    const moved = setSelection(state, selection)
    return keep && moved !== state ? { ...moved, pendingMarks: state.pendingMarks } : moved
  }

  const selectFromDom = (selection: Selection) => {
    const before = doc.peek()
    const next = setSelection(before, selection)
    if (next === before) return
    batch(() => {
      history.set(markBoundary(history.peek()))
      setDoc(next, "dom")
    })
  }

  // -------------------------------------------------------------------------
  // Paste and drop. Plain text and the composer's own payloads insert at once;
  // HTML needs the paste module, loaded on first use. A paste that arrives
  // before it is parsed late and inserted where the caret was when it was
  // pasted, with everything typed meanwhile kept after it (in order).

  const clipboard = options.clipboard ?? documentClipboard
  let pasteModule: PasteModule | null = options.loadPaste ? null : pasteModuleIfLoaded()
  /** Late pastes, in the order they arrived. */
  let lateQueue: Promise<void> = Promise.resolve()
  let latePending = 0

  const parseNow = (content: ClipboardContent, plain: boolean): PastedContent | null => {
    const quick = quickPaste(content, { safeUrl: options.safeUrl, plain, clipboard })
    if (quick) return quick
    pasteModule ??= options.loadPaste ? pasteModule : pasteModuleIfLoaded()
    if (!pasteModule) return null
    return pasteModule.sanitizePaste(content, {
      safeUrl: options.safeUrl,
      clipboard,
      ...(options.parseHtml ? { parseHtml: options.parseHtml } : {}),
    })
  }

  /** Parse when the module is here, then insert `range` of `before` mapped onto the current document. */
  const insertLate = (content: ClipboardContent, before: DocState, range: Range, moveFrom?: Range) => {
    latePending += 1
    const module = (options.loadPaste ?? loadPasteModule)()
    lateQueue = lateQueue
      .then(() => module)
      .then(
        (module) => {
          pasteModule = module
          if (disposed) return
          const parsed = module.sanitizePaste(content, {
            safeUrl: options.safeUrl,
            clipboard,
            ...(options.parseHtml ? { parseHtml: options.parseHtml } : {}),
          })
          if (parsed.text === "") return
          const now = doc.peek()
          if (now.revision === before.revision && sameSelectionOf(now, before)) {
            if (moveFrom) applyDrop(parsed, range.from, moveFrom)
            else commit(replaceRange(now, range, parsed), "structural")
            return
          }
          // The text changed meanwhile: put the paste where it was asked for.
          const change = diffText(before.text, now.text, now.selection.focus)
          const from = mapOffset(range.from, change)
          const to = Math.max(from, mapOffset(range.to, change))
          const inserted = replaceRange(now, { from, to }, parsed)
          const grow = inserted.text.length - now.text.length
          const keep = (offset: number) => (offset >= to ? offset + grow : offset <= from ? offset : from + parsed.text.length)
          commit(setSelection(inserted, { anchor: keep(now.selection.anchor), focus: keep(now.selection.focus) }), "structural")
        },
        () => {
          // The module could not load: the plain text is still the user's.
          if (disposed) return
          const fallback = content.text ? plainContent({ text: content.text }) : null
          if (fallback && fallback.text !== "") commit(insertContent(doc.peek(), fallback), "structural")
        },
      )
      .finally(() => {
        latePending -= 1
      })
  }

  const sameSelectionOf = (a: DocState, b: DocState) =>
    a.selection.anchor === b.selection.anchor && a.selection.focus === b.selection.focus

  /** Returns true when the paste was taken (inserted now, or queued until the paste module arrives). */
  const paste = (content: ClipboardContent, pasteOptions: { plain?: boolean } = {}) => {
    const parsed = parseNow(content, pasteOptions.plain === true)
    if (parsed) {
      if (parsed.text === "") return false
      return edit((state) => insertContent(state, parsed), "structural")
    }
    const before = doc.peek()
    insertLate(content, before, selectionRange(before.selection))
    return true
  }

  const applyDrop = (parsed: PastedContent, at: number, moveFrom?: Range) => {
    let state = doc.peek()
    let target = at
    if (moveFrom) {
      const source = expandRange(state, moveFrom)
      if (target > source.from && target < source.to) return false
      state = deleteRange(state, source)
      if (target >= source.to) target -= source.to - source.from
    }
    state = setSelection(state, collapsed(target))
    const point = selectionRange(state.selection)
    return commit(replaceRange(state, point, parsed), "structural")
  }

  /** Insert text or content dropped at `at`; `moveFrom` when it was dragged from inside the composer. */
  const drop = (content: ClipboardContent, at: number, moveFrom?: Range) => {
    const parsed = parseNow(content, false)
    if (parsed) {
      if (parsed.text === "") return false
      return applyDrop(parsed, at, moveFrom)
    }
    insertLate(content, doc.peek(), { from: at, to: at }, moveFrom)
    return true
  }

  const dispose = () => {
    if (disposed) return
    saveNow()
    disposed = true
  }

  return {
    // State
    doc: doc as ReadSignal<DocState>,
    canSend,
    autocomplete,
    reply: reply as ReadSignal<ReplyTarget | null>,
    editing: editing as ReadSignal<EditTarget | null>,
    sending: sending as ReadSignal<boolean>,
    error: error as ReadSignal<string | null>,
    marks,
    canUndo: undoable,
    canRedo: redoable,
    platform,
    /** Whether the last document change came from DOM read-back. For the binding. */
    lastChangeFromDom: () => lastOrigin === "dom",

    // Text
    insertText: (text: string) => edit((s) => insertText(s, text), "typing"),
    insertLineBreak: () => edit(insertLineBreak, "structural"),
    deleteBackward: (unit: DeleteUnit = "grapheme") => edit((s) => deleteBackward(s, unit), "deleting"),
    deleteForward: (unit: DeleteUnit = "grapheme") => edit((s) => deleteForward(s, unit), "deleting"),
    deleteSelection: () => edit(deleteSelection, "structural"),
    /** Apply any model operation as one history step. */
    apply: (fn: (state: DocState) => DocState, kind: EditKind = "structural") => edit(fn, kind),
    applyDomText,
    setSelection: selectFromDom,
    selectAll: () => selectFromDom(selectAll(doc.peek()).selection),
    selectedContent: () => sliceContent(doc.peek()),

    // Formatting
    toggleMark: toggleFormat,
    isMarkActive: (type: MarkType) => isMarkActive(doc.peek(), type),
    /** Link the selection. Returns false if the URL policy refuses it. */
    setLink: (url: string, label?: string) => {
      const safe = options.safeUrl(url)
      if (!safe) return false
      return edit((s) => setLink(s, safe, label), "structural")
    },
    removeLink: () => edit(removeLink, "structural"),

    // Autocomplete
    acceptAutocomplete,
    dismissAutocomplete: () => {
      const active = autocomplete.peek()
      if (active) dismissed.set(active)
    },
    insertAtom: (atom: AtomSpec, label: string) => edit((s) => insertAtom(s, atom, label), "structural"),

    // History
    undo,
    redo,

    // Clipboard
    paste,
    drop,
    /** The composer's own clipboard payload for this content (copy, cut, drag). */
    clipboardPayload: (content: { text: string; entities: readonly ComposerEntity[] }) => clipboard.serialize(content),
    /** Pastes waiting for the paste module. */
    hasLatePaste: () => latePending > 0,
    /** Resolves when every late paste has been inserted (tests, the lab). */
    latePastes: () => lateQueue,
    pasteFiles: (files: readonly File[]) => {
      if (files.length === 0 || !options.onFiles) return false
      options.onFiles(files)
      return true
    },

    // Send, reply, edit
    send,
    setReply: (target: ReplyTarget | null) => reply.set(target),
    startEdit,
    cancelEdit,
    handleKeyDown,

    // Drafts
    /** Replace the content with a stored draft (switching chats), without saving it back. */
    setDraft: (draft: { text: string; entities?: readonly ComposerEntity[]; revision: number }) => {
      cancelSave()
      stash = null
      const next = createDoc({ text: draft.text, entities: draft.entities ?? [], revision: draft.revision })
      lastSaved = next.revision
      batch(() => {
        editing.set(null)
        reply.set(null)
        error.set(null)
        dismissed.set(null)
        history.set(emptyHistory())
        lastOrigin = "model"
        doc.set(next)
      })
    },
    /** Save a pending draft now: `visibilitychange` to hidden, `pagehide`, switching chats. */
    flushDraft: saveNow,
    /** Whether a draft change is waiting for its debounce. */
    hasPendingDraft: () => saveTimer !== null,
    dispose,
  }
}
