import { Layer } from "effect"
import {
  HealthOperationsLive,
} from "./healthLive.effect"
import {
  IntegrationOperationsLive,
} from "./integrations/integrationsRouterLive.effect"
import {
  MediaOperationsLive,
} from "./mediaLive.effect"
import {
  SessionAuthenticationLive,
} from "./pluginsLive.effect"
import {
  RootPageOperationsLive,
} from "./rootLive.effect"
import {
  ThereOperationsLive,
} from "./extra/thereLive.effect"
import {
  WaitlistOperationsLive,
} from "./extra/waitlistLive.effect"
import {
  EmailUnsubscribeOperationsLive,
} from "./extra/emailUnsubscribeLive.effect"
import {
  AuxiliaryRouteGroup,
} from "./auxiliary.effect"

const AuxiliaryOperationsLive = Layer.mergeAll(
  HealthOperationsLive,
  IntegrationOperationsLive,
  MediaOperationsLive,
  RootPageOperationsLive,
  SessionAuthenticationLive,
  ThereOperationsLive,
  WaitlistOperationsLive,
  EmailUnsubscribeOperationsLive,
)

export const AuxiliaryRouteGroupLive =
  AuxiliaryRouteGroup.handlers.pipe(
    Layer.provide(AuxiliaryOperationsLive),
  )
