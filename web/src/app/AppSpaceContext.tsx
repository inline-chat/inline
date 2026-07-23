import { createContext, useContext } from "react"
import type { SpaceID } from "@inline/ids"

export type AppSpaceContextValue = {
  selectedSpaceId?: SpaceID
  selectSpace: (spaceId?: SpaceID) => void
}

export const AppSpaceContext = createContext<AppSpaceContextValue>({
  selectSpace: () => undefined,
})

export const useAppSpace = () => useContext(AppSpaceContext)
