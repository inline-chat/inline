import type {
  AddSpaceUrlPreviewExclusionInput,
  AddSpaceUrlPreviewExclusionResult,
  GetSpaceUrlPreviewExclusionsInput,
  GetSpaceUrlPreviewExclusionsResult,
  RemoveSpaceUrlPreviewExclusionInput,
  RemoveSpaceUrlPreviewExclusionResult,
} from "@inline-chat/protocol/core"
import { Functions } from "@in/server/functions"
import { RealtimeRpcError } from "@in/server/realtime/errors"
import type { HandlerContext } from "@in/server/realtime/types"

export async function getSpaceUrlPreviewExclusionsHandler(
  input: GetSpaceUrlPreviewExclusionsInput,
  context: HandlerContext,
): Promise<GetSpaceUrlPreviewExclusionsResult> {
  if (input.spaceId <= 0n) {
    throw RealtimeRpcError.SpaceIdInvalid()
  }

  return Functions.spaces.getUrlPreviewExclusions(input, {
    currentSessionId: context.sessionId,
    currentUserId: context.userId,
  })
}

export async function addSpaceUrlPreviewExclusionHandler(
  input: AddSpaceUrlPreviewExclusionInput,
  context: HandlerContext,
): Promise<AddSpaceUrlPreviewExclusionResult> {
  if (input.spaceId <= 0n || input.host.trim().length === 0) {
    throw RealtimeRpcError.BadRequest()
  }

  return Functions.spaces.addUrlPreviewExclusion(input, {
    currentSessionId: context.sessionId,
    currentUserId: context.userId,
  })
}

export async function removeSpaceUrlPreviewExclusionHandler(
  input: RemoveSpaceUrlPreviewExclusionInput,
  context: HandlerContext,
): Promise<RemoveSpaceUrlPreviewExclusionResult> {
  if (input.spaceId <= 0n || input.exclusionId <= 0n) {
    throw RealtimeRpcError.BadRequest()
  }

  return Functions.spaces.removeUrlPreviewExclusion(input, {
    currentSessionId: context.sessionId,
    currentUserId: context.userId,
  })
}
