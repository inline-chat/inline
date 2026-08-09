import type { Chat, Dialog } from "@inline/client"
import type { ChatID, DialogID } from "@inline/ids"

export type InboxProjectionRow = {
  dialog: Dialog
  chat?: Chat
  depth: number
  semanticParentDialogId?: DialogID
  parentDialogId?: DialogID
  childCount: number
  isExpanded: boolean
  detached: boolean
  /** The row and every structurally attached descendant, including hidden rows. */
  closeGroupDialogs: readonly Dialog[]
}

type ProjectionInput = {
  dialogs: readonly Dialog[]
  chatsById: ReadonlyMap<ChatID, Chat>
  collapsedDialogIds?: ReadonlySet<DialogID>
  detachedDialogIds?: ReadonlySet<DialogID>
  selectedDialogId?: DialogID
}

/**
 * Projects the Inbox as a stable pre-order hierarchy without changing durable
 * dialog ordering. A reply stays attached only while its parent is resident.
 * A pinned reply above an unpinned parent is deliberately detached, matching
 * the native Inbox rule that pinning a child must not pull its parent lane up.
 */
export const projectInbox = ({
  dialogs,
  chatsById,
  collapsedDialogIds = new Set(),
  detachedDialogIds = new Set(),
  selectedDialogId,
}: ProjectionInput): InboxProjectionRow[] => {
  const inputByChatId = new Map<ChatID, Dialog>()
  for (const dialog of dialogs) {
    if (!inputByChatId.has(dialog.chatId)) {
      inputByChatId.set(dialog.chatId, dialog)
    }
  }

  const semanticParentById = new Map<DialogID, DialogID>()
  const attachedParentById = new Map<DialogID, DialogID>()
  const childrenByParentId = new Map<DialogID, Dialog[]>()
  const roots: Dialog[] = []

  for (const dialog of dialogs) {
    const chat = chatsById.get(dialog.chatId)
    const parent = chat?.parentChatId
      ? inputByChatId.get(chat.parentChatId)
      : undefined
    if (!parent || parent.id === dialog.id) {
      roots.push(dialog)
      continue
    }
    semanticParentById.set(dialog.id, parent.id)
    const pinnedAboveParent = Boolean(dialog.pinned && !parent.pinned)
    if (detachedDialogIds.has(dialog.id) || pinnedAboveParent) {
      roots.push(dialog)
      continue
    }
    attachedParentById.set(dialog.id, parent.id)
    const siblings = childrenByParentId.get(parent.id) ?? []
    siblings.push(dialog)
    childrenByParentId.set(parent.id, siblings)
  }

  // A selected reply is always revealed even if one of its ancestors was
  // locally collapsed. This avoids a route whose active row has disappeared.
  const revealedParentIds = new Set<DialogID>()
  let ancestor = selectedDialogId
    ? attachedParentById.get(selectedDialogId)
    : undefined
  while (ancestor && !revealedParentIds.has(ancestor)) {
    revealedParentIds.add(ancestor)
    ancestor = attachedParentById.get(ancestor)
  }

  const closeGroup = (root: Dialog) => {
    const group: Dialog[] = []
    const seen = new Set<DialogID>()
    const visit = (dialog: Dialog) => {
      if (seen.has(dialog.id)) return
      seen.add(dialog.id)
      group.push(dialog)
      for (const child of childrenByParentId.get(dialog.id) ?? []) {
        visit(child)
      }
    }
    visit(root)
    return group
  }

  const rows: InboxProjectionRow[] = []
  const visited = new Set<DialogID>()
  const consumeHidden = (parentId: DialogID) => {
    for (const child of childrenByParentId.get(parentId) ?? []) {
      if (visited.has(child.id)) continue
      visited.add(child.id)
      consumeHidden(child.id)
    }
  }
  const append = (
    dialog: Dialog,
    depth: number,
    parentDialogId?: DialogID,
  ) => {
    if (visited.has(dialog.id)) return
    visited.add(dialog.id)
    const children = childrenByParentId.get(dialog.id) ?? []
    const isExpanded =
      children.length > 0 &&
      (!collapsedDialogIds.has(dialog.id) ||
        revealedParentIds.has(dialog.id))
    rows.push({
      dialog,
      chat: chatsById.get(dialog.chatId),
      depth,
      semanticParentDialogId: semanticParentById.get(dialog.id),
      parentDialogId,
      childCount: children.length,
      isExpanded,
      detached:
        semanticParentById.has(dialog.id) && parentDialogId == null,
      closeGroupDialogs: closeGroup(dialog),
    })
    if (!isExpanded) {
      consumeHidden(dialog.id)
      return
    }
    for (const child of children) {
      append(child, depth + 1, dialog.id)
    }
  }

  for (const root of roots) append(root, 0)
  // Invalid cycles or duplicate parent data must remain visible rather than
  // silently dropping a chat from the Inbox.
  for (const dialog of dialogs) append(dialog, 0)
  return rows
}
