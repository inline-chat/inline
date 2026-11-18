import {
  DialogNotificationSettings_Mode,
  type Dialog as ProtocolDialog,
  type DialogFolder as ProtocolDialogFolder,
  type DialogNotificationSettings,
  type UpdateUnreadActivity,
} from "@inline-chat/protocol/core"
import { inlineId, messageId, type MessageID } from "@inline/ids"
import type { Db } from "../../database"
import {
  DbObjectKind,
  type Dialog,
  type DialogFolder,
  type DialogNotificationMode,
} from "../../database/models"

/*
 * Per-dialog state the sidebar and notifications need: notification mode,
 * folder, translation and unread activity (mentions and reactions), after
 * InlineKit's `Dialog` columns and `ChatActivityItem`.
 */

/** Absent settings, or an unspecified mode, follow the global settings. */
export const dialogNotificationMode = (
  settings: DialogNotificationSettings | undefined,
): DialogNotificationMode | undefined => {
  switch (settings?.mode) {
    case DialogNotificationSettings_Mode.ALL:
      return "all"
    case DialogNotificationSettings_Mode.MENTIONS:
      return "mentions"
    case DialogNotificationSettings_Mode.NONE:
      return "none"
    default:
      return undefined
  }
}

export const protocolDialogNotificationMode = (
  mode: DialogNotificationMode | undefined,
): DialogNotificationSettings | undefined => {
  switch (mode) {
    case "all":
      return { mode: DialogNotificationSettings_Mode.ALL }
    case "mentions":
      return { mode: DialogNotificationSettings_Mode.MENTIONS }
    case "none":
      return { mode: DialogNotificationSettings_Mode.NONE }
    default:
      return undefined
  }
}

/**
 * The fields a full dialog snapshot carries for this state. Notification
 * mode, folder and translation are authoritative (absent means unset);
 * activity counts are absent when the server did not compute them, so the
 * stored value is kept.
 */
export const dialogSnapshotState = (
  dialog: ProtocolDialog,
  existing: Dialog | undefined,
): Pick<
  Dialog,
  | "notificationMode"
  | "folderId"
  | "translationEnabled"
  | "unreadMentionsCount"
  | "unreadReactionsCount"
  | "unreadMentionIds"
  | "unreadReactionIds"
> => {
  const mentions = dialog.unreadMentionsCount ?? existing?.unreadMentionsCount
  const reactions = dialog.unreadReactionsCount ?? existing?.unreadReactionsCount
  return {
    notificationMode: dialogNotificationMode(dialog.notificationSettings),
    folderId: dialog.folderId == null ? undefined : inlineId(dialog.folderId),
    translationEnabled: dialog.translationEnabled ?? undefined,
    unreadMentionsCount: mentions,
    unreadReactionsCount: reactions,
    unreadMentionIds: mentions === 0 ? undefined : existing?.unreadMentionIds,
    unreadReactionIds: reactions === 0 ? undefined : existing?.unreadReactionIds,
  }
}

export const dialogFolderModel = (folder: ProtocolDialogFolder): DialogFolder => ({
  kind: DbObjectKind.DialogFolder,
  id: inlineId(folder.id),
  ...(folder.title != null ? { title: folder.title } : {}),
  order: folder.order,
  ...(folder.emoji != null ? { emoji: folder.emoji } : {}),
  ...(folder.pinnedOrder != null ? { pinnedOrder: folder.pinnedOrder } : {}),
})

export const putDialogFolder = (db: Db, folder: ProtocolDialogFolder) => {
  db.replace(dialogFolderModel(folder))
}

const mergeIds = (
  current: readonly MessageID[] | undefined,
  add: readonly bigint[],
  remove: ReadonlySet<string>,
) => {
  const ids = new Set((current ?? []).filter((id) => !remove.has(String(id))))
  for (const id of add) {
    if (!remove.has(String(id))) ids.add(messageId(id))
  }
  const sorted = Array.from(ids).sort((left, right) =>
    BigInt(left) < BigInt(right) ? -1 : BigInt(left) > BigInt(right) ? 1 : 0,
  )
  return sorted.length > 0 ? sorted : undefined
}

/**
 * Apply `unreadActivity` to a stored dialog. Counts are the server's after
 * the change; message IDs are added and cleared as sets, so a duplicate
 * delivery changes nothing. Clearing wins over adding in the same update.
 */
export const applyUnreadActivity = (
  db: Db,
  dialog: Dialog,
  update: UpdateUnreadActivity,
) => {
  const cleared = new Set(update.clearedMessageIds.map(String))
  db.replace({
    ...dialog,
    unreadMentionsCount: update.unreadMentionsCount,
    unreadReactionsCount: update.unreadReactionsCount,
    unreadMentionIds:
      update.unreadMentionsCount === 0
        ? undefined
        : mergeIds(dialog.unreadMentionIds, update.unreadMentionIds, cleared),
    unreadReactionIds:
      update.unreadReactionsCount === 0
        ? undefined
        : mergeIds(dialog.unreadReactionIds, update.unreadReactionIds, cleared),
  })
}
