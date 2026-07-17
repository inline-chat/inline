import { Layer } from "effect"
import {
  AuthRouteGroup,
} from "./auth.effect"
import {
  IdentityAdaptersLive,
} from "./identityLive.effect"
import {
  OAuthAdapterLive,
} from "./oauthLive.effect"

export const AuthRouteGroupLive =
  AuthRouteGroup.handlers.pipe(
    Layer.provide(
      Layer.merge(
        IdentityAdaptersLive,
        OAuthAdapterLive,
      ),
    ),
  )
