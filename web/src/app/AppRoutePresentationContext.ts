import { createContext, useContext } from "react"

type CompleteAppRoutePresentation = (path: string) => void

const AppRoutePresentationContext =
  createContext<CompleteAppRoutePresentation>(() => undefined)

export const AppRoutePresentationProvider =
  AppRoutePresentationContext.Provider

export const useAppRoutePresentation = () =>
  useContext(AppRoutePresentationContext)
