import { createContext, useContext } from "react"
import type { InlineCoreSnapshot } from "../core/InlineCoreProtocol"
import type { FullChatProgressiveService } from "../core/FullChatProgressiveService"

export const InlineRuntimeStateContext =
  createContext<InlineCoreSnapshot | null>(null)

export const FullChatProgressiveContext =
  createContext<FullChatProgressiveService | null>(null)

export const useInlineRuntimeState = () => {
  const state = useContext(InlineRuntimeStateContext)
  if (!state) {
    throw new Error(
      "useInlineRuntimeState must be used within InlineRuntime",
    )
  }
  return state
}

export const useFullChatProgressive = () => {
  const service = useContext(FullChatProgressiveContext)
  if (!service) {
    throw new Error(
      "useFullChatProgressive must be used within InlineRuntime",
    )
  }
  return service
}
