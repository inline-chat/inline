import type {
  GetSpaceSettingsInput,
  GetSpaceSettingsResult,
  ToggleSpaceGridInput,
  ToggleSpaceGridResult,
} from "@inline-chat/protocol/core"
import { Functions } from "@in/server/functions"
import type { HandlerContext } from "@in/server/realtime/types"

export async function getSpaceSettingsHandler(
  input: GetSpaceSettingsInput,
  context: HandlerContext,
): Promise<GetSpaceSettingsResult> {
  return Functions.spaces.getSettings(input, {
    currentSessionId: context.sessionId,
    currentUserId: context.userId,
  })
}

export async function toggleSpaceGridHandler(
  input: ToggleSpaceGridInput,
  context: HandlerContext,
): Promise<ToggleSpaceGridResult> {
  return Functions.spaces.toggleGrid(input, {
    currentSessionId: context.sessionId,
    currentUserId: context.userId,
  })
}
