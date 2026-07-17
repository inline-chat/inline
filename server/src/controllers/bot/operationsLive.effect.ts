import { Layer } from "effect"
import {
  BotOperations,
  makeBotOperations,
} from "./operations.effect"
import { botOperationHandlers } from "./operations"

export const BotOperationsLive = Layer.succeed(
  BotOperations,
  makeBotOperations(botOperationHandlers),
)
