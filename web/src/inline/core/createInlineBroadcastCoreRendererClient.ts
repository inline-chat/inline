import type { AuthSession, AuthStore } from "@inline/client/core"
import { InlineBroadcastCoreCoordinator } from "./InlineBroadcastCoreCoordinator"
import { InlineCoreRendererClient } from "./InlineCoreRendererClient"

export const createInlineBroadcastCoreRendererClient = ({
  auth,
  session,
}: {
  auth: AuthStore
  session: AuthSession
}) => {
  const coordinator = new InlineBroadcastCoreCoordinator(
    session.userId,
  )
  return new InlineCoreRendererClient({
    port: coordinator.port,
    owner: coordinator,
    auth,
    session,
  })
}
