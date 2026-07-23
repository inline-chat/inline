import { createContext, useContext, useEffect, useState, type ReactNode } from "react"
import { InlineMediaRepository, type InlineMediaHandle } from "./InlineMediaRepository"

const InlineMediaContext = createContext<InlineMediaRepository | undefined>(undefined)

export function InlineMediaProvider({
  repository,
  children,
}: {
  repository: InlineMediaRepository
  children: ReactNode
}) {
  return <InlineMediaContext.Provider value={repository}>{children}</InlineMediaContext.Provider>
}

export function useInlineMediaUrl(key: string | undefined, remoteUrl: string | undefined) {
  const repository = useContext(InlineMediaContext)
  const [loaded, setLoaded] = useState<{
    key: string
    remoteUrl: string
    url: string
  }>()

  // The account owner is the sole byte-acquisition path for keyed photos and
  // avatars. Giving the remote URL to <img> while the owner also fetches it
  // creates two independent downloads and bypasses the tiny-thumbnail phase.
  // A renderer-hot Blob remains synchronously available through peek().
  const url = !key || !remoteUrl || !repository
    ? remoteUrl
    : repository.peek(key, remoteUrl) ??
      (loaded?.key === key && loaded.remoteUrl === remoteUrl
        ? loaded.url
        : undefined)

  useEffect(() => {
    if (!key || !remoteUrl || !repository) {
      setLoaded(undefined)
      return
    }

    let active = true
    let handle: InlineMediaHandle | undefined
    const controller = new AbortController()
    setLoaded(undefined)
    void repository
      .acquire(key, remoteUrl, {
        signal: controller.signal,
      })
      .then((next) => {
        handle = next
        if (active) {
          setLoaded({ key, remoteUrl, url: next.url })
        } else {
          next.release()
        }
      })
      .catch(() => undefined)

    return () => {
      active = false
      controller.abort()
      handle?.release()
    }
  }, [key, remoteUrl, repository])

  return url
}

/** Large playable media stays on the browser's native Range pipeline. A
 * route-preloaded full Blob may still win synchronously, but this hook never
 * asks the account worker to materialize a streamable URL as one Blob. */
export function useInlineStreamingMediaUrl(
  key: string | undefined,
  remoteUrl: string | undefined,
) {
  const repository = useContext(InlineMediaContext)
  return (
    (key && repository?.peek(key, remoteUrl)) ||
    remoteUrl
  )
}
