import { getBotConfigurationCatalog } from "@in/server/functions/bot.getConfigurationCatalog"
import type { HandlerContext } from "@in/server/realtime/types"
import type {
  GetBotConfigurationCatalogInput,
  GetBotConfigurationCatalogResult,
} from "@inline-chat/protocol/core"

export const getBotConfigurationCatalogHandler = (
  input: GetBotConfigurationCatalogInput,
  context: HandlerContext,
): Promise<GetBotConfigurationCatalogResult> =>
  getBotConfigurationCatalog(input, {
    currentSessionId: context.sessionId,
    currentUserId: context.userId,
  })
