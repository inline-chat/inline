/**
 * The find lab's wiring, framework-free: a stand-in core over generated
 * messages, the real store client, `coreFindSource`, `FindInChatModel`, the
 * real command registry and keyboard dispatcher with the find commands, and
 * a plain scrolling list standing in for the timeline (the lab owns its
 * scroll; the real chat pane passes the timeline controller's jump).
 */

import type { ChatID, MessageID, UserID } from "@inline/ids"
import { browserClock, browserScheduler, computed, createStoreClient, signal, type ReadSignal, type StoreClient } from "@inline/reactive"
import { CommandRegistry, KeyboardDispatcher, detectPlatform, type Platform } from "@inline/view"
import { bindWindowKeyboard } from "../../app/focus"
import {
  FindInChatModel,
  chatSelectionText,
  coreFindSource,
  coreServerFindSource,
  registerFindCommands,
  type FindJump,
  type FindSender,
} from "../../features/find"
import type { SearchRange } from "@inline/core-protocol"
import { LAB_ME, LabCore, generateMessages, type LabCoreMode, type LabServerMode } from "./lab-core"

const senders: Record<string, FindSender> = {
  "1": { name: "You" },
  "2": { name: "Ada Lovelace" },
  "3": { name: "Grace Hopper" },
  "4": { name: "مریم میرزاخانی" },
  "5": { name: "Linus Pauling" },
}

export type LabHighlight = { readonly messageId: MessageID; readonly ranges: readonly SearchRange[]; readonly seq: number }

export class FindLab {
  readonly core: LabCore
  readonly client: StoreClient
  readonly model: FindInChatModel
  readonly registry = new CommandRegistry()
  readonly keyboard: KeyboardDispatcher
  readonly platform: Platform
  readonly highlight = signal<LabHighlight | undefined>(undefined)
  readonly jumps = signal<readonly FindJump[]>([])
  focusRestores = 0
  #listElement: HTMLElement | null = null
  readonly #rowHighlights = new Map<MessageID, ReadSignal<LabHighlight | undefined>>()
  readonly #unbind: (() => void)[] = []

  constructor(options: { messages?: number } = {}) {
    this.core = new LabCore(generateMessages(options.messages ?? 4000))
    this.client = createStoreClient({ endpoint: this.core, scheduler: browserScheduler() })
    this.platform = detectPlatform({ navigator })
    this.model = new FindInChatModel({
      chatId: "1" as ChatID,
      source: coreFindSource(this.client),
      server: coreServerFindSource(this.client),
      clock: browserClock(),
      jump: (target) => this.#jump(target),
      captureFocus: () => {
        const before = document.activeElement
        return () => {
          this.focusRestores++
          if (before instanceof HTMLElement && before.isConnected && before !== document.body) before.focus({ preventScroll: true })
          else this.#listElement?.focus({ preventScroll: true })
        }
      },
    })
    this.keyboard = new KeyboardDispatcher({ registry: this.registry, platform: this.platform })
    const target = signal(this.model)
    this.#unbind.push(
      registerFindCommands(this.registry, {
        target,
        readSelection: () => chatSelectionText(document, this.#listElement),
      }),
      bindWindowKeyboard(window, this.keyboard),
    )
  }

  sender = (fromId: UserID, out: boolean): FindSender => (out || fromId === LAB_ME ? { name: "You" } : (senders[fromId] ?? { name: "Unknown" }))

  /** The lab list's highlight for one row (only the jumped-to row changes). */
  rowHighlight(messageId: MessageID): ReadSignal<LabHighlight | undefined> {
    let value = this.#rowHighlights.get(messageId)
    if (!value) {
      value = computed(() => {
        const current = this.highlight.get()
        return current?.messageId === messageId ? current : undefined
      })
      this.#rowHighlights.set(messageId, value)
    }
    return value
  }

  /** Part for the lab's message list. */
  readonly listPart = {
    attach: (element: HTMLElement) => {
      this.#listElement = element
      element.scrollTop = element.scrollHeight
      return () => {
        if (this.#listElement === element) this.#listElement = null
      }
    },
  }

  listElement(): HTMLElement | null {
    return this.#listElement
  }

  setDelay(ms: number): void {
    this.core.settings = { ...this.core.settings, delayMs: Math.max(0, Math.floor(ms)) }
  }

  setMode(mode: LabCoreMode): void {
    this.core.settings = { ...this.core.settings, mode }
  }

  /** Where the server's matches come from (see `LabCore`); takes effect on the next query. */
  setServer(server: LabServerMode): void {
    this.core.settings = { ...this.core.settings, server }
  }

  #jump(target: FindJump): void {
    this.jumps.set([...this.jumps.peek(), target].slice(-50))
    this.highlight.set({ messageId: target.messageId, ranges: target.ranges, seq: (this.highlight.peek()?.seq ?? 0) + 1 })
    const list = this.#listElement
    const row = list?.querySelector<HTMLElement>(`[data-message-id="${target.messageId}"]`)
    if (!list || !row) return
    // The lab's stand-in for `jumpToMessage`: center the row (the lab owns this list's scroll).
    list.scrollTop = Math.max(0, row.offsetTop - list.clientHeight / 2 + row.offsetHeight / 2)
  }

  dispose(): void {
    for (const unbind of this.#unbind) unbind()
    this.model.dispose()
    this.client.dispose()
    this.core.close()
  }
}
