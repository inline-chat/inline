import type { UserID } from "@inline/ids"
import { authSession } from "../auth/auth-session-core"
import { InlineCoreRendererRegistry } from "../core/InlineCoreRendererRegistry"
import type { InlineCoreRendererClient } from "../core/InlineCoreRendererClient"

export type InlineRuntimeCore = InlineCoreRendererClient

export type InlineRuntimeCoreBinding = {
  core: InlineRuntimeCore
  retain: () => () => void
}

const rendererRegistry = new InlineCoreRendererRegistry()

export const getInlineRuntimeCoreBinding = (
  userId: UserID,
): InlineRuntimeCoreBinding => {
  const core = rendererRegistry.get(userId, authSession)
  return {
    core,
    retain: () => rendererRegistry.retain(core),
  }
}

export const acquireInlineRuntimeCore = (userId: UserID) => {
  const binding = getInlineRuntimeCoreBinding(userId)
  return {
    core: binding.core,
    release: binding.retain(),
  }
}

export const replaceUnresponsiveInlineRuntimeCore = (
  core: InlineRuntimeCore,
) => rendererRegistry.replaceUnresponsiveBootOwner(core, authSession)
