import type { Chat, Dialog } from "@inline/client"
import {
  compareInlineIds,
  type ChatID,
  type SpaceID,
} from "@inline/ids"

const compareStable = (left: Dialog, right: Dialog) =>
  compareInlineIds(right.id, left.id)

const activityDate = (
  dialog: Dialog,
  chatsById: ReadonlyMap<ChatID, Chat>,
) =>
  chatsById.get(dialog.chatId)?.date ?? 0

export const isSidebarChatListDialog = (
  dialog: Dialog,
  selectedSpaceId?: SpaceID,
) =>
  !dialog.archived &&
  !dialog.chatListHidden &&
  (dialog.open === true || dialog.pinned === true) &&
  (selectedSpaceId == null || dialog.spaceId === selectedSpaceId)

const ordered = (
  leftOrder: string | undefined,
  rightOrder: string | undefined,
  left: Dialog,
  right: Dialog,
) => {
  if (leftOrder != null && rightOrder != null) {
    return leftOrder.localeCompare(rightOrder) || compareStable(left, right)
  }
  if (leftOrder != null) return -1
  if (rightOrder != null) return 1
  return compareStable(left, right)
}

export const sortSidebarDialogs = (
  dialogs: Dialog[],
  _chatsById: ReadonlyMap<ChatID, Chat>,
) =>
  dialogs.slice().sort((left, right) => {
    const leftPinned = Boolean(left.pinned)
    const rightPinned = Boolean(right.pinned)
    if (leftPinned !== rightPinned) return leftPinned ? -1 : 1

    if (leftPinned && rightPinned) {
      return ordered(left.pinnedOrder, right.pinnedOrder, left, right)
    }
    return ordered(left.order, right.order, left, right)
  })

export const sortAllChatsDialogs = (
  dialogs: Dialog[],
  chatsById: ReadonlyMap<ChatID, Chat>,
) =>
  dialogs.slice().sort((left, right) => {
    const dateDifference = activityDate(right, chatsById) - activityDate(left, chatsById)
    return dateDifference || compareStable(left, right)
  })

export const dialogActivityDate = (
  dialog: Dialog,
  chatsById: ReadonlyMap<ChatID, Chat>,
) => activityDate(dialog, chatsById)
