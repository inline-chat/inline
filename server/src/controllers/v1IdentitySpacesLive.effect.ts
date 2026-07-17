import { Layer } from "effect"
import { SessionAuthenticationLive } from "./pluginsLive.effect"
import { V1IdentitySpacesRouteGroup } from "./v1IdentitySpaces.effect"
import { V1IdentitySpacesOperationsLive } from "./v1IdentitySpacesOperationsLive.effect"

export const V1IdentitySpacesRouteGroupLive = V1IdentitySpacesRouteGroup.handlers.pipe(
  Layer.provide(Layer.merge(V1IdentitySpacesOperationsLive, SessionAuthenticationLive)),
)
