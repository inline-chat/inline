import {
  createContext,
  useContext,
  type ReactNode,
} from "react"
import type { InlineMessageDraftsService } from "./InlineMessageDrafts"

const InlineMessageDraftsContext =
  createContext<InlineMessageDraftsService | null>(null)

export function InlineMessageDraftsProvider({
  drafts,
  children,
}: {
  drafts: InlineMessageDraftsService
  children: ReactNode
}) {
  return (
    <InlineMessageDraftsContext.Provider value={drafts}>
      {children}
    </InlineMessageDraftsContext.Provider>
  )
}

export const useInlineMessageDrafts = () => {
  const drafts = useContext(InlineMessageDraftsContext)
  if (!drafts) {
    throw new Error(
      "useInlineMessageDrafts must be used within InlineRuntime",
    )
  }
  return drafts
}
