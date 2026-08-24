import {
  Method,
  type CreateDialogFolderInput,
  type CreateDialogFolderResult,
  type DeleteDialogFolderInput,
  type DeleteDialogFolderResult,
  type UpdateDialogFolderInput,
  type UpdateDialogFolderResult,
} from "@inline-chat/protocol/core"
import { Functions } from "@in/server/functions"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { HandlerContext } from "@in/server/realtime/types"

export const createDialogFolderMethod = Method.CREATE_DIALOG_FOLDER
export const updateDialogFolderMethod = Method.UPDATE_DIALOG_FOLDER
export const deleteDialogFolderMethod = Method.DELETE_DIALOG_FOLDER

export async function createDialogFolderHandler(
  input: CreateDialogFolderInput,
  context: HandlerContext,
): Promise<CreateDialogFolderResult> {
  return Functions.messages.createDialogFolder(input, functionContext(context))
}

export async function updateDialogFolderHandler(
  input: UpdateDialogFolderInput,
  context: HandlerContext,
): Promise<UpdateDialogFolderResult> {
  return Functions.messages.updateDialogFolder(
    {
      folderId: positiveSafeId(input.folderId),
      titleUpdate: input.titleUpdate,
      emojiUpdate: input.emojiUpdate,
      pinnedOrderUpdate: input.pinnedOrderUpdate,
      order: input.order,
    },
    functionContext(context),
  )
}

export async function deleteDialogFolderHandler(
  input: DeleteDialogFolderInput,
  context: HandlerContext,
): Promise<DeleteDialogFolderResult> {
  return Functions.messages.deleteDialogFolder(
    {
      folderId: positiveSafeId(input.folderId),
      disposition: input.disposition,
    },
    functionContext(context),
  )
}

function functionContext(context: HandlerContext) {
  return {
    currentUserId: context.userId,
    currentSessionId: context.sessionId,
  }
}

function positiveSafeId(value: bigint): number {
  const id = Number(value)
  if (!Number.isSafeInteger(id) || id <= 0) throw RealtimeRpcError.BadRequest()
  return id
}
