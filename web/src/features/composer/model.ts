/**
 * The composer view model: the composer package's controller plus what the
 * view around it needs (the autocomplete list, focus, the reply and edit
 * banners, error wording, the send key hint) and the DOM parts the view hands
 * its elements to. Framework-free. The caller creates it (one per chat) and
 * keeps it, because the chat pane drives it too: `setReply`, `startEdit`,
 * `setDraft` and `focus` are the pane's commands.
 *
 *     const model = useModel(() => createComposerModel({ send, saveDraft, safeUrl, ... }), [chatId])
 *     <ComposerView model={model} placeholder="Message" />
 */

import {
  attachComposer,
  createComposerController,
  detectPlatform,
  writeSelection,
  type ComposerClassNames,
  type ComposerController,
  type ComposerOptions,
  type Platform,
  type SendKey,
} from "@inline/composer"
import type { MessageID } from "@inline/ids"
import { computed, effect, scoped, signal, untracked, type Dispose, type ReadSignal } from "@inline/reactive"
import { hideLayer, placeLayer, showLayer, trackLayer, type Part, type Rect } from "@inline/ui"
import {
  createComposerAutocomplete,
  type ComposerAutocomplete,
  type ComposerAutocompleteOptions,
  type SuggestFn,
} from "./autocomplete"
import { appClipboard } from "./clipboard-key"
import { clampRect, elementRect, textRect } from "./dom"
import { escapeLeavesComposer, sendErrorText, sendHint } from "./text"

/** What a banner shows about the message being replied to or edited. */
export type MessagePreview = {
  /** For a reply: "Reply to {senderName}". */
  senderName?: string
  /** One line of the message, already shortened (`previewText` in `@inline/chat-ui`). */
  text: string
}

export type ComposerBanner = {
  kind: "reply" | "edit"
  messageId: MessageID
  /** Null while the message is not available locally; the banner still shows and can be dismissed. */
  preview: MessagePreview | null
}

export type ComposerModelOptions = Omit<ComposerOptions, "onAutocompleteKey" | "sendKey" | "platform"> & {
  /** The send key preference; a signal follows the setting live. Default `enter`. */
  sendKey?: SendKey | ReadSignal<SendKey>
  /** Default: detected from the browser. */
  platform?: Platform
  /** Rows for the active `@`, `:` or `/` trigger. Called inside a computed; may read signals. */
  suggest?: SuggestFn
  /** The reply or edit target's sender and text. Called inside a computed; may read signals. */
  describeMessage?: (messageId: MessageID) => MessagePreview | null
  /** Escape in an empty composer: move focus to the message list. */
  onEscapeEmpty?: () => void
  /** Words for a rejected send's reason. Default `sendErrorText`. */
  errorText?: (reason: string) => string
  /** The autocomplete chunk, already loaded (tests, labs), or its loader. Default: loaded on the first trigger. */
  autocompleteChunk?: ComposerAutocompleteOptions["chunk"]
}

export type SurfaceOptions = {
  /** Class names for lines, marks and atoms (StyleX output from the view). */
  classNames?: ComposerClassNames
  /** Initial `spellcheck`; the view keeps the attribute current afterwards. Default true. */
  spellcheck?: boolean
}

export type ComposerModel = {
  /** The composer package's controller: document, commands, send, reply, edit, drafts. */
  readonly composer: ComposerController
  readonly autocomplete: ComposerAutocomplete
  readonly platform: Platform
  readonly sendKey: ReadSignal<SendKey>
  /** Text and hint for the send key, e.g. "↩ to send, ⇧↩ for a new line". */
  readonly sendHint: ReadSignal<string>
  /** No text in the model and no composition in progress: show the placeholder. */
  readonly empty: ReadSignal<boolean>
  readonly focused: ReadSignal<boolean>
  readonly banner: ReadSignal<ComposerBanner | null>
  /** The rejected send's reason in words, or null. Cleared by the next edit. */
  readonly errorText: ReadSignal<string | null>
  /** The editable surface. */
  surface(options?: SurfaceOptions): Part
  /** The autocomplete popup element (`popover="manual"`). */
  readonly popup: Part
  /** Focus the editor without scrolling, with the caret where the model has it. Returns false before the surface is attached. */
  focus(): boolean
  /** Send (or save the edit). The composer clears only after the core accepts. */
  send(): void
  /** Clear the reply, or cancel the edit (restoring the stashed draft). */
  dismissBanner(): void
  dispose(): void
}

const isSignal = <T>(value: unknown): value is ReadSignal<T> =>
  typeof value === "object" && value !== null && "peek" in value && "get" in value

const sameBanner = (a: ComposerBanner | null, b: ComposerBanner | null) =>
  a === b ||
  (a !== null &&
    b !== null &&
    a.kind === b.kind &&
    a.messageId === b.messageId &&
    a.preview?.senderName === b.preview?.senderName &&
    a.preview?.text === b.preview?.text)

/** Placement of the autocomplete: above the trigger character, flipping below when there is no room. */
const POPUP_PLACEMENT = { placement: "top-start", offset: 6, padding: 8 } as const

export const createComposerModel = (options: ComposerModelOptions): ComposerModel => {
  const [model, disposeScope] = scoped(() => build(options))
  return {
    ...model,
    dispose: () => {
      model.dispose()
      disposeScope()
    },
  }
}

const build = (options: ComposerModelOptions): ComposerModel => {
  const {
    sendKey: sendKeyOption,
    platform: platformOption,
    suggest,
    describeMessage,
    onEscapeEmpty,
    errorText: errorTextOption,
    autocompleteChunk,
    ...rest
  } = options
  const platform = platformOption ?? detectPlatform()
  const sendKey: ReadSignal<SendKey> = isSignal<SendKey>(sendKeyOption) ? sendKeyOption : signal<SendKey>(sendKeyOption ?? "enter")

  const focused = signal(false)
  const composing = signal(false)
  let surfaceElement: HTMLElement | null = null

  // The autocomplete is created after the controller it reads; the key hook reaches it lazily.
  let autocomplete: ComposerAutocomplete | null = null
  const composer = createComposerController({
    ...rest,
    // Rich paste between this app's tabs: payloads tagged with the browser's key.
    clipboard: rest.clipboard ?? appClipboard,
    sendKey,
    platform,
    onAutocompleteKey: (key) => autocomplete?.handleKey(key) ?? false,
  })
  autocomplete = createComposerAutocomplete({
    trigger: composer.autocomplete,
    focused,
    accept: (item) => composer.acceptAutocomplete(item),
    ...(suggest ? { suggest } : {}),
    ...(autocompleteChunk ? { chunk: autocompleteChunk } : {}),
  })
  const list = autocomplete

  const empty = computed(() => composer.doc.get().text.length === 0 && !composing.get())

  const banner = computed<ComposerBanner | null>(
    () => {
      const editing = composer.editing.get()
      const reply = composer.reply.get()
      const target = editing ? { kind: "edit" as const, messageId: editing.messageId } : reply ? { kind: "reply" as const, messageId: reply.messageId } : null
      if (!target) return null
      let preview: MessagePreview | null = null
      try {
        preview = describeMessage?.(target.messageId) ?? null
      } catch {
        preview = null
      }
      return { ...target, preview }
    },
    { equals: sameBanner },
  )

  const describeError = errorTextOption ?? sendErrorText
  const errorText = computed(() => {
    const reason = composer.error.get()
    return reason === null ? null : describeError(reason)
  })

  const hint = computed(() => sendHint(sendKey.get(), platform))

  // -------------------------------------------------------------------------
  // DOM parts

  const surface = (surfaceOptions: SurfaceOptions = {}): Part => ({
    attach: (element) => {
      surfaceElement = element
      const detach = attachComposer(element, composer, {
        ...(surfaceOptions.classNames ? { classNames: surfaceOptions.classNames } : {}),
        spellcheck: surfaceOptions.spellcheck ?? true,
      })
      element.setAttribute("aria-autocomplete", "list")

      const onFocus = () => focused.set(true)
      const onBlur = () => focused.set(false)
      const onCompositionStart = () => composing.set(true)
      const onCompositionEnd = () => composing.set(false)
      // Registered after the binding's own keydown, so it sees what the binding took.
      const onKeyDown = (event: KeyboardEvent) => {
        if (!onEscapeEmpty) return
        if (!escapeLeavesComposer(event, { empty: composer.doc.peek().text.length === 0 })) return
        event.preventDefault()
        onEscapeEmpty()
      }
      element.addEventListener("focus", onFocus)
      element.addEventListener("blur", onBlur)
      element.addEventListener("compositionstart", onCompositionStart)
      element.addEventListener("compositionend", onCompositionEnd)
      element.addEventListener("keydown", onKeyDown)
      focused.set(element.ownerDocument.activeElement === element)

      const stopAria = effect(() => {
        // The list exists once the autocomplete chunk is here (the first trigger).
        const cursor = list.cursor.get()
        if (cursor) element.setAttribute("aria-controls", cursor.listbox.id)
        const active = list.activeDescendant.get()
        if (active === null) element.removeAttribute("aria-activedescendant")
        else element.setAttribute("aria-activedescendant", active)
      })

      return () => {
        stopAria()
        element.removeEventListener("focus", onFocus)
        element.removeEventListener("blur", onBlur)
        element.removeEventListener("compositionstart", onCompositionStart)
        element.removeEventListener("compositionend", onCompositionEnd)
        element.removeEventListener("keydown", onKeyDown)
        detach()
        if (surfaceElement === element) surfaceElement = null
        focused.set(false)
        composing.set(false)
      }
    },
  })

  /** The trigger character's box, kept inside the surface's visible area; the surface itself as a fallback. */
  const anchorRect = (): Rect | null => {
    const root = surfaceElement
    if (!root) return null
    const visible = elementRect(root)
    const trigger = composer.autocomplete.peek()
    const box = trigger ? textRect(root, trigger.range.from, trigger.range.from + 1) : null
    return box ? clampRect(box, visible) : visible
  }

  const popup: Part = {
    attach: (element) => {
      const view = element.ownerDocument.defaultView
      let stopTracking: Dispose | null = null
      let frame = 0
      /**
       * Place again before the next paint. The rows for a new query render in
       * a microtask after the signal changes, so a placement made in the
       * change itself measures the old rows; the frame callback runs after
       * that render and before paint, so the first painted frame is right.
       */
      const placeBeforePaint = () => {
        if (!view || frame) return
        frame = view.requestAnimationFrame(() => {
          frame = 0
          if (list.isOpen.peek()) placeLayer(element, { anchor: anchorRect, ...POPUP_PLACEMENT })
        })
      }
      const stopOpen = effect(() => {
        const open = list.isOpen.get()
        untracked(() => {
          stopTracking?.()
          stopTracking = null
          if (!open) {
            hideLayer(element)
            return
          }
          showLayer(element)
          // Scroll, resize and the popup's own size changes.
          stopTracking = trackLayer(element, { anchor: anchorRect, ...POPUP_PLACEMENT })
          placeBeforePaint()
        })
      })
      // The anchor moves when the surface grows or its lines reflow.
      const stopFollow = effect(() => {
        composer.doc.get()
        list.suggestions.get()
        untracked(() => {
          if (list.isOpen.peek()) placeBeforePaint()
        })
      })
      return () => {
        if (frame && view) view.cancelAnimationFrame(frame)
        stopFollow()
        stopOpen()
        stopTracking?.()
        hideLayer(element)
      }
    },
  }

  const focus = (): boolean => {
    const root = surfaceElement
    if (!root) return false
    if (root.ownerDocument.activeElement !== root) {
      root.focus({ preventScroll: true })
      // Programmatic focus puts the browser's caret at the start; put the model's back.
      writeSelection(root, composer.doc.peek().selection)
    }
    return true
  }

  return {
    composer,
    autocomplete: list,
    platform,
    sendKey,
    sendHint: hint,
    empty,
    focused,
    banner,
    errorText,
    surface,
    popup,
    focus,
    send: () => {
      void composer.send()
    },
    dismissBanner: () => {
      if (composer.editing.peek()) composer.cancelEdit()
      else composer.setReply(null)
    },
    dispose: () => {
      list.dispose()
      composer.dispose()
    },
  }
}
