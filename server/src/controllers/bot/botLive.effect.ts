import { Layer } from "effect"
import { SessionAuthenticationLive } from "../pluginsLive.effect"
import { BotAuthorizationLive } from "./authLive.effect"
import { BotRouteGroup } from "./bot.effect"
import { BotOperationsLive } from "./operationsLive.effect"

export const BotAdaptersLive = Layer.mergeAll(
  SessionAuthenticationLive,
  BotAuthorizationLive,
  BotOperationsLive,
)

export const BotRouteGroupLive =
  BotRouteGroup.handlers.pipe(
    Layer.provide(BotAdaptersLive),
  )
