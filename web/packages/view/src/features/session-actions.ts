/**
 * Message and sidebar actions: the message commands in the session's
 * registry (keyboard, menus, command bar), the action list of one message
 * row for its context menu and hover capsule, and the sidebar row's basic
 * menu. Set, order and shortcuts follow the Mac app
 * (`InlineMac/Views/Message/MessageView.swift` `createMessageMenu`,
 * `Features/Sidebar/Collection/SidebarNativeRowView.swift`).
 *
 * The chat model does what the core can do (delete, cancel, resend,
 * reactions); what only a view can do (put the composer in reply or edit
 * mode, write the clipboard, open the reaction picker, show a notice) goes
 * through hooks the app attaches. An action whose hook is missing is left
 * out of the lists and its command is disabled.
 */

import {
  rowKey,
  type ActionAnswer,
  type Intent,
  type MessageRow,
  type MessageRowId,
  type RowKey,
} from "@inline/core-protocol"
import type { ChatID, MessageID, UserID } from "@inline/ids"
import { computed, signal, type ReadSignal, type StoreClient } from "@inline/reactive"
import type { Platform } from "../commands/platform"
import type { CommandRegistry, CommandSpec } from "../commands/registry"
import { formatCombo } from "../commands/shortcut"
import type { Destination } from "../workspace/destination"
import type { ChatModel } from "./chat-model"
import { actionHandle, type ActionHandle, type ActionNotice, type IntentTracker } from "./intent-outcome"
import { messageAbilities, type MessageAbilities } from "./message-abilities"
import type { SidebarItem } from "./sidebar-model"

export const messageCommandIds = {
  reply: "message.reply",
  edit: "message.edit",
  addReaction: "message.addReaction",
  copyLink: "message.copyLink",
  copyText: "message.copyText",
  resend: "message.resend",
  cancel: "message.cancel",
  delete: "message.delete",
} as const

/** One message, as actions and hooks see it. */
export type MessageTarget = {
  readonly chatId: ChatID
  readonly rowId: MessageRowId
  /** The row's key in the view store. */
  readonly key: RowKey
  /** Absent for a send the server has not acknowledged. */
  readonly messageId?: MessageID
  readonly row: MessageRow
}

/** What only a view can do. Each is optional; without it the action is left out. */
export type ActionHooks = {
  /** Reply to the message in its chat's composer. */
  readonly reply?: (target: MessageTarget) => void
  /** Put its chat's composer in edit mode with the message's text and entities. */
  readonly edit?: (target: MessageTarget) => void
  /** Write the message's text to the clipboard (the row has the entities for rich copy). */
  readonly copyText?: (text: string, target: MessageTarget) => void
  /** Write a link to the clipboard: `{ kind: "message" }` or `{ kind: "chat" }`. */
  readonly copyLink?: (destination: Destination) => void
  /** Open the emoji picker for the message; `anchor` is the quick action's rectangle when there is one. */
  readonly openReactionPicker?: (target: MessageTarget, anchor?: unknown) => void
  /** Show a refusal or an uncertain outcome (a toast). */
  readonly notify?: (notice: ActionNotice) => void
  /** Show a bot's answer to a button or form (a toast or an alert). */
  readonly answer?: (answer: ActionAnswer) => void
  /**
   * True while the user has text selected in the message list. Copy Text's
   * shortcut then leaves Cmd/Ctrl+C to the browser, which copies the selection.
   */
  readonly isTextSelected?: () => boolean
  /**
   * Ask before deleting a sent message; call `proceed` when the user confirms
   * and nothing when they decline. Every delete path goes through it: the row
   * menu, the quick action, the keyboard command and the command bar. Without
   * the hook a delete runs at once. Cancelling a message that is still
   * sending never asks.
   */
  readonly confirmDelete?: (target: MessageTarget, proceed: () => void) => void
}

/** The icons the message row views draw (`MessageActionIcon` in `web/src/features/message`). */
export type MessageRowActionIcon = "reply" | "react" | "copy" | "copyLink" | "edit" | "delete" | "resend"

/**
 * One action of a message row, in the shape the row views take
 * (`MessageAction` in `web/src/features/message/actions.ts`).
 */
export type MessageRowAction = {
  readonly id: string
  readonly label: string
  readonly icon?: MessageRowActionIcon
  /** Shortcut hint for the menu, from the registry for the platform ("⌘R", "Ctrl+E"). */
  readonly shortcut?: string
  readonly enabled: boolean
  readonly destructive?: boolean
  /** Also a hover and focus quick action. */
  readonly quick?: boolean
  readonly group?: string
  readonly run: (invocation: { readonly rowId: MessageRowId; readonly via: "quick" | "menu"; readonly anchor?: unknown }) => void
}

/** One entry of a sidebar row's menu, in the shape the sidebar takes (`SidebarAction`). */
export type SidebarRowAction =
  | {
      readonly kind?: "action"
      readonly id: string
      readonly label: string
      readonly shortcut?: string
      readonly enabled?: boolean
      readonly destructive?: boolean
      readonly run: () => void
    }
  /** A choice among siblings, shown checked when current (the Notifications modes). */
  | { readonly kind: "radio"; readonly id: string; readonly label: string; readonly checked: boolean; readonly run: () => void }
  | { readonly kind: "submenu"; readonly id: string; readonly label: string; readonly actions: readonly SidebarRowAction[] }
  | { readonly kind: "separator"; readonly id: string }

/** A dialog's notification modes in the Mac's order and words (`DialogNotificationSettingSelection`); absent is Default. */
export const SIDEBAR_NOTIFICATION_MODES: readonly { readonly mode: "default" | "all" | "mentions" | "none"; readonly label: string }[] = [
  { mode: "default", label: "Default" },
  { mode: "all", label: "All" },
  { mode: "mentions", label: "Mentions" },
  { mode: "none", label: "None" },
]

/** The chat a message row ID belongs to (`${chatId}:...`). */
export const chatIdOfRowId = (rowId: MessageRowId): ChatID | undefined => {
  const colon = rowId.indexOf(":")
  return colon > 0 ? (rowId.slice(0, colon) as ChatID) : undefined
}

export type SessionActionsOptions = {
  readonly client: StoreClient
  readonly viewerId: UserID
  /** The resident chat model of a chat (`ChatCache.peek`). Actions on a chat that is not resident are disabled. */
  readonly chat: (chatId: ChatID) => ChatModel | undefined
  readonly intents?: IntentTracker
  /** For the menus' shortcut hints. Without it menus show none. */
  readonly platform?: Platform
}

export class SessionActions {
  /** The message holding keyboard focus in a message list, which the message commands act on. */
  readonly focused: ReadSignal<MessageTarget | undefined>

  readonly #options: SessionActionsOptions
  readonly #focusedRowId = signal<MessageRowId | undefined>(undefined)
  readonly #hooks = signal<ActionHooks>({})
  #registry: CommandRegistry | undefined
  #unregister: (() => void) | undefined

  constructor(options: SessionActionsOptions) {
    this.#options = options
    const store = options.client.store
    this.focused = computed(() => {
      const rowId = this.#focusedRowId.get()
      if (rowId === undefined) return undefined
      const row = store.row("message", rowId).get()
      return row ? targetOf(row) : undefined
    })
  }

  /** The hooks the app attaches. Returns a function that detaches them. */
  attach(hooks: ActionHooks): () => void {
    this.#hooks.set(hooks)
    return () => {
      if (this.#hooks.peek() === hooks) this.#hooks.set({})
    }
  }

  /** The message list reports the row holding keyboard focus (undefined when none). */
  setFocused(rowId: MessageRowId | undefined): void {
    this.#focusedRowId.set(rowId)
  }

  // MARK: - Commands

  /** Register the message commands. Returns a function that unregisters them. */
  register(registry: CommandRegistry): () => void {
    this.#registry = registry
    const disposers = this.#commands().map((spec) => registry.register(spec))
    this.#unregister = () => {
      for (const dispose of disposers) dispose()
    }
    return () => this.dispose()
  }

  dispose(): void {
    this.#unregister?.()
    this.#unregister = undefined
    this.#registry = undefined
  }

  #commands(): CommandSpec[] {
    const ids = messageCommandIds
    const can = (ability: keyof MessageAbilities, hook?: keyof ActionHooks): ReadSignal<boolean> =>
      computed(() => {
        const target = this.focused.get()
        if (!target) return false
        if (hook && !this.#hooks.get()[hook]) return false
        return messageAbilities(target.row, this.#options.viewerId)[ability]
      })
    const onFocused = (run: (target: MessageTarget) => void) => () => {
      const target = this.focused.peek()
      if (target) run(target)
    }
    const copyText = can("copyText", "copyText")
    const common = { category: "message", scope: "timeline", whileTyping: "never" } as const
    return [
      {
        ...common,
        id: ids.reply,
        title: "Reply",
        // Mac: Cmd+R. A browser owns Cmd/Ctrl+R (reload).
        shortcuts: { default: "Mod+R", browser: { default: [] } },
        enabled: can("reply", "reply"),
        run: onFocused((target) => this.reply(target)),
      },
      {
        ...common,
        id: ids.edit,
        title: "Edit",
        shortcuts: { default: "Mod+E" },
        enabled: can("edit", "edit"),
        run: onFocused((target) => this.editMessage(target)),
      },
      {
        ...common,
        id: ids.addReaction,
        title: "Add Reaction…",
        // The Mac menu shows Cmd+E here too, where Edit already has it; left unbound.
        enabled: can("react", "openReactionPicker"),
        run: onFocused((target) => this.openReactionPicker(target)),
      },
      {
        ...common,
        id: ids.copyLink,
        title: "Copy Message Link",
        enabled: can("copyLink", "copyLink"),
        run: onFocused((target) => this.copyLink(target)),
      },
      {
        ...common,
        id: ids.copyText,
        title: "Copy Text",
        shortcuts: { default: "Mod+C" },
        // Read when the key is pressed: a text selection keeps the browser's copy.
        enabled: {
          get: () => copyText.get(),
          peek: () => copyText.peek() && this.#hooks.peek().isTextSelected?.() !== true,
        },
        run: onFocused((target) => this.copyText(target)),
      },
      {
        ...common,
        id: ids.resend,
        title: "Resend",
        enabled: can("resend"),
        run: onFocused((target) => void this.resend(target)),
      },
      {
        ...common,
        id: ids.cancel,
        title: "Cancel",
        enabled: can("cancel"),
        run: onFocused((target) => void this.delete(target)),
      },
      {
        ...common,
        id: ids.delete,
        title: "Delete",
        // Mac: Cmd+Delete, for Delete and for Cancel on a message still sending.
        shortcuts: { default: "Mod+Backspace" },
        enabled: computed(() => {
          const target = this.focused.get()
          if (!target) return false
          const abilities = messageAbilities(target.row, this.#options.viewerId)
          return abilities.delete || abilities.cancel
        }),
        run: onFocused((target) => void this.delete(target)),
      },
    ]
  }

  // MARK: - What each action does

  reply(target: MessageTarget): void {
    this.#hooks.peek().reply?.(target)
  }

  editMessage(target: MessageTarget): void {
    this.#hooks.peek().edit?.(target)
  }

  openReactionPicker(target: MessageTarget, anchor?: unknown): void {
    this.#hooks.peek().openReactionPicker?.(target, anchor)
  }

  copyText(target: MessageTarget): void {
    this.#hooks.peek().copyText?.(target.row.text, target)
  }

  copyLink(target: MessageTarget): void {
    if (target.messageId === undefined) return
    this.#hooks.peek().copyLink?.({ kind: "message", chatId: target.chatId, messageId: target.messageId })
  }

  /**
   * Delete the message, or cancel it while it is sending. With a
   * `confirmDelete` hook a sent message is deleted only after the user
   * confirms, and this returns undefined (the outcome still reaches `notify`).
   * Refusals go to `notify`.
   */
  delete(target: MessageTarget): ActionHandle | undefined {
    const confirm = this.#hooks.peek().confirmDelete
    if (confirm && !messageAbilities(target.row, this.#options.viewerId).cancel) {
      confirm(target, () => void this.#deleteNow(target))
      return undefined
    }
    return this.#deleteNow(target)
  }

  #deleteNow(target: MessageTarget): ActionHandle | undefined {
    const chat = this.#options.chat(target.chatId)
    if (!chat) return undefined
    return this.#report(chat.deleteRows([target.key]))
  }

  resend(target: MessageTarget): ActionHandle | undefined {
    const chat = this.#options.chat(target.chatId)
    if (!chat) return undefined
    return this.#report(chat.resend(target.key))
  }

  /** Add or remove the viewer's reaction (a reaction chip or the picker). Refusals go to `notify`. */
  toggleReaction(target: MessageTarget, emoji: string): ActionHandle | undefined {
    const chat = this.#options.chat(target.chatId)
    if (!chat || target.messageId === undefined) return undefined
    return this.#report(chat.toggleReaction(target.messageId, emoji))
  }

  /** Press a bot button. The bot's answer goes to `answer`, a refusal to `notify`. */
  invokeAction(target: MessageTarget, actionId: string): ActionHandle | undefined {
    const chat = this.#options.chat(target.chatId)
    if (!chat || target.messageId === undefined) return undefined
    return this.#report(chat.invokeAction(target.messageId, actionId))
  }

  // MARK: - Action lists

  /** The target of a message row ID, when its row is in the store. */
  target(rowId: MessageRowId): MessageTarget | undefined {
    const row = this.#options.client.store.peekRow(rowKey("message", rowId)) as MessageRow | undefined
    return row?.kind === "message" ? targetOf(row) : undefined
  }

  /**
   * A message row's actions in menu order, in the shape the row views take
   * (`MessageActionsController`'s `actionsFor`). Reads the row and the hooks
   * tracked, so a menu built in a computed follows them.
   *
   * Order (Mac `createMessageMenu`): Reply, Edit, Add Reaction…; Copy
   * Message Link, Copy Text; Resend, then Cancel or Delete. Only what applies
   * to the row is listed: a message still sending has Copy Text and Cancel; a
   * failed one Copy Text, Resend and Delete.
   */
  actionsFor = (rowId: MessageRowId): readonly MessageRowAction[] => {
    const store = this.#options.client.store
    const row = store.row("message", rowId).get()
    if (!row) return []
    const target = targetOf(row)
    const hooks = this.#hooks.get()
    const abilities = messageAbilities(row, this.#options.viewerId)
    const resident = this.#options.chat(target.chatId) !== undefined
    const actions: MessageRowAction[] = []
    const hint = (id: string) => this.#shortcutHint(id)
    const add = (action: Omit<MessageRowAction, "shortcut"> & { command?: string }) => {
      const { command, ...rest } = action
      const shortcut = command ? hint(command) : undefined
      actions.push({ ...rest, ...(shortcut ? { shortcut } : {}) })
    }
    if (abilities.reply && hooks.reply) {
      add({ id: "reply", label: "Reply", icon: "reply", group: "reply", enabled: true, command: messageCommandIds.reply, run: () => this.reply(target) })
    }
    if (abilities.edit && hooks.edit) {
      add({ id: "edit", label: "Edit", icon: "edit", group: "reply", enabled: true, command: messageCommandIds.edit, run: () => this.editMessage(target) })
    }
    if (abilities.react && hooks.openReactionPicker) {
      add({
        id: "react",
        label: "Add Reaction…",
        icon: "react",
        group: "reply",
        quick: true,
        enabled: resident,
        run: (invocation) => this.openReactionPicker(target, invocation.anchor),
      })
    }
    if (abilities.copyLink && hooks.copyLink) {
      add({ id: "copyLink", label: "Copy Message Link", icon: "copyLink", group: "copy", enabled: true, run: () => this.copyLink(target) })
    }
    if (abilities.copyText && hooks.copyText) {
      add({ id: "copyText", label: "Copy Text", icon: "copy", group: "copy", enabled: true, command: messageCommandIds.copyText, run: () => this.copyText(target) })
    }
    if (abilities.resend) {
      add({ id: "resend", label: "Resend", icon: "resend", group: "state", enabled: resident, run: () => void this.resend(target) })
    }
    if (abilities.cancel) {
      add({ id: "cancel", label: "Cancel", icon: "delete", group: "state", enabled: resident, command: messageCommandIds.delete, run: () => void this.delete(target) })
    } else if (abilities.delete) {
      add({
        id: "delete",
        label: "Delete",
        icon: "delete",
        group: "state",
        destructive: true,
        enabled: resident,
        command: messageCommandIds.delete,
        run: () => void this.delete(target),
      })
    }
    return actions
  }

  /**
   * A sidebar row's basic menu (Mac `SidebarNativeRowView`): for a temporary
   * row Close from Sidebar and Keep in Sidebar; otherwise Pin or Unpin, Mark
   * Read or Mark Unread, Close from Sidebar (when open), Archive or
   * Unarchive, then the dialog's settings: Notifications ▸ Default, All,
   * Mentions, None (radio, the current mode checked: `setDialogNotifications`)
   * and, for a thread, Follow Thread or Unfollow Thread (`setDialogFollow`);
   * then Copy Link (with the `copyLink` hook). Each maps to the dialog intent
   * of the same name; refusals go to `notify`.
   */
  sidebarActionsFor = (item: SidebarItem): readonly SidebarRowAction[] => {
    const hooks = this.#hooks.get()
    const chatId = item.chatId
    const actions: SidebarRowAction[] = []
    const intent = (what: string, value: Intent) => () => void this.#dialogIntent(value, what)
    const close = { id: "close", label: "Close from Sidebar", run: intent("close the chat", { kind: "setDialogOpen", chatId, open: false }) }
    if (item.temporary === true) {
      actions.push(close)
      actions.push({ kind: "separator", id: "temporary" })
      actions.push({ id: "keep", label: "Keep in Sidebar", run: intent("keep the chat", { kind: "setDialogOpen", chatId, open: true }) })
    } else {
      actions.push({
        id: "pin",
        label: item.pinned ? "Unpin" : "Pin",
        run: intent(item.pinned ? "unpin the chat" : "pin the chat", { kind: "setDialogPinned", chatId, pinned: !item.pinned }),
      })
      actions.push(
        item.hasUnread
          ? { id: "read", label: "Mark Read", run: intent("mark the chat read", { kind: "readAll", chatId }) }
          : { id: "read", label: "Mark Unread", run: intent("mark the chat unread", { kind: "markUnread", chatId }) },
      )
      if (item.open !== false) actions.push(close)
      const archived = item.archived === true
      actions.push({
        id: "archive",
        label: archived ? "Unarchive" : "Archive",
        run: intent(archived ? "unarchive the chat" : "archive the chat", {
          kind: "setDialogArchived",
          chatId,
          archived: !archived,
        }),
      })
      actions.push({ kind: "separator", id: "settings" })
      const current = item.notificationMode ?? "default"
      actions.push({
        kind: "submenu",
        id: "notifications",
        label: "Notifications",
        actions: SIDEBAR_NOTIFICATION_MODES.map(({ mode, label }) => ({
          kind: "radio" as const,
          id: `notifications-${mode}`,
          label,
          checked: current === mode,
          run: intent("change the chat's notifications", { kind: "setDialogNotifications", chatId, mode }),
        })),
      })
      // Threads only: a direct message cannot be followed (the Mac shows Follow for threads).
      if (item.peerUserId === undefined) {
        const following = item.followMode === "following"
        actions.push({
          id: "follow",
          label: following ? "Unfollow Thread" : "Follow Thread",
          run: intent(following ? "unfollow the thread" : "follow the thread", {
            kind: "setDialogFollow",
            chatId,
            mode: following ? "unfollowed" : "following",
          }),
        })
      }
    }
    if (hooks.copyLink) {
      actions.push({ kind: "separator", id: "link" })
      actions.push({ id: "copyLink", label: "Copy Link", run: () => this.#hooks.peek().copyLink?.({ kind: "chat", chatId }) })
    }
    return actions
  }

  #dialogIntent(intent: Intent, what: string): ActionHandle {
    const { client, intents } = this.#options
    return this.#report(actionHandle(client.intent(intent), what, { store: client.store, ...(intents ? { tracker: intents } : {}) }))
  }

  /** Tell the user about a refusal or an uncertain outcome, once; pass a bot's answer on. */
  #report(handle: ActionHandle): ActionHandle {
    void handle.then((first) => {
      if (first.status !== "accepted") {
        this.#hooks.peek().notify?.(first.notice)
        return
      }
      void handle.outcome.then((outcome) => {
        if (outcome.status === "confirmed") {
          if (outcome.answer) this.#hooks.peek().answer?.(outcome.answer)
        } else {
          this.#hooks.peek().notify?.(outcome.notice)
        }
      })
    })
    return handle
  }

  #shortcutHint(commandId: string): string | undefined {
    const platform = this.#options.platform
    const command = this.#registry?.get(commandId)
    if (!platform || !command) return undefined
    const combo = command.shortcutsFor(platform)[0]
    return combo ? formatCombo(combo, platform.os) : undefined
  }
}

const targetOf = (row: MessageRow): MessageTarget => ({
  chatId: row.chatId,
  rowId: row.id,
  key: rowKey("message", row.id),
  ...(row.messageId !== undefined ? { messageId: row.messageId } : {}),
  row,
})
