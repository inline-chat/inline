import type { UserID } from "@inline/ids"
import {
  getInlineAccountCore,
  retainInlineAccountCore,
} from "../core/InlineAccountCoreRegistry"
import type { InlineAccountCore } from "../core/InlineAccountCore"

export type InlineRuntimeCore = InlineAccountCore

export type InlineRuntimeCoreBinding = {
  core: InlineRuntimeCore
  retain: () => () => void
}

export const getInlineRuntimeCoreBinding = (
  userId: UserID,
): InlineRuntimeCoreBinding => {
  const core = getInlineAccountCore(userId)
  return {
    core,
    retain: () => retainInlineAccountCore(core),
  }
}

export const acquireInlineRuntimeCore = (userId: UserID) => {
  const binding = getInlineRuntimeCoreBinding(userId)
  return {
    core: binding.core,
    release: binding.retain(),
  }
}
