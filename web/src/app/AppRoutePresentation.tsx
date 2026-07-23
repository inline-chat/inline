import {
  createContext,
  useCallback,
  useContext,
  useEffect,
  useLayoutEffect,
  useMemo,
  useRef,
  useState,
  type ReactNode,
} from "react"
import {
  useRouter,
  useRouterState,
} from "@tanstack/react-router"

type AppRoutePresentationValue = {
  targetPath?: string
  begin: (targetPath: string) => void
  finish: (targetPath: string) => void
}

const AppRoutePresentationContext =
  createContext<AppRoutePresentationValue | null>(null)

export function AppRoutePresentationProvider({
  children,
}: {
  children: ReactNode
}) {
  const [targetPath, setTargetPath] = useState<string | undefined>(() => {
    if (typeof window === "undefined") return undefined
    const initialPath = window.location.pathname
    return initialPath.startsWith("/chat/")
      ? initialPath
      : undefined
  })
  const router = useRouter()
  const resolvedPath = useRouterState({
    select: (state) =>
      state.resolvedLocation?.pathname ?? state.location.pathname,
  })
  const resolvedPathRef = useRef(resolvedPath)
  resolvedPathRef.current = resolvedPath
  const begin = useCallback((nextTargetPath: string) => {
    setTargetPath(nextTargetPath)
  }, [])
  const finish = useCallback((finishedTargetPath: string) => {
    setTargetPath((current) =>
      current === finishedTargetPath ? undefined : current,
    )
  }, [])
  const value = useMemo(
    () => ({ targetPath, begin, finish }),
    [begin, finish, targetPath],
  )

  useEffect(() => {
    return router.history.subscribe(() => {
      const nextPath = router.history.location.pathname
      if (nextPath === resolvedPathRef.current) return
      if (!nextPath.startsWith("/chat/")) return
      // This subscription can run while TanStack is committing a navigation.
      // A normal state update joins the pending route work and commits before
      // the browser's next paint; forcing a nested React flush here is invalid.
      begin(nextPath)
    })
  }, [begin, router])

  return (
    <AppRoutePresentationContext.Provider value={value}>
      {children}
    </AppRoutePresentationContext.Provider>
  )
}

export const useAppRoutePresentation = () => {
  const value = useContext(AppRoutePresentationContext)
  if (!value) {
    throw new Error(
      "useAppRoutePresentation must be used within AppRoutePresentationProvider",
    )
  }
  return value
}

/** Marks a synchronously rendered app surface as ready in the same commit. */
export const useAppRoutePresentationReady = (path: string) => {
  const { finish } = useAppRoutePresentation()
  useLayoutEffect(() => {
    finish(path)
  }, [finish, path])
}
