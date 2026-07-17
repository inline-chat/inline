import { Layer } from "effect"
import {
  IdentityOperationsLive,
} from "../modules/auth/identityOperationsLive.effect"
import {
  SessionAuthenticationLive,
} from "./pluginsLive.effect"

export const IdentityAdaptersLive = Layer.merge(
  IdentityOperationsLive,
  SessionAuthenticationLive,
)
