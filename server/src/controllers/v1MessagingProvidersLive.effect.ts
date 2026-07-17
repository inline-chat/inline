import { Layer } from "effect"
import { SessionAuthenticationLive } from "./pluginsLive.effect"
import { V1MessagingProvidersRouteGroup } from "./v1MessagingProviders.effect"
import { V1MessagingOperationsLive } from "./v1MessagingOperationsLive.effect"
import { V1ProviderOperationsLive } from "./v1ProviderOperationsLive.effect"
import { V1UploadOperationsLive } from "./v1UploadOperationsLive.effect"

export const V1MessagingProvidersRouteGroupLive = V1MessagingProvidersRouteGroup.handlers.pipe(
  Layer.provide(
    Layer.mergeAll(
      V1MessagingOperationsLive,
      V1ProviderOperationsLive,
      V1UploadOperationsLive,
      SessionAuthenticationLive,
    ),
  ),
)
