/** The development demo parameter, read without touching anything else (`boot.ts` uses it under `import.meta.env.DEV`). */

export type DemoScale = "small" | "medium" | "large"

/** `?demo=small|medium|large[&seed=N][&storage=opfs|memory]`, development builds only. */
export const readDemoParams = (
  search: string,
): { scale: DemoScale; seed?: number; storage?: "opfs" | "memory" } | undefined => {
  const params = new URLSearchParams(search)
  const scale = params.get("demo")
  if (scale !== "small" && scale !== "medium" && scale !== "large") return undefined
  const seed = Number(params.get("seed"))
  const storage = params.get("storage")
  return {
    scale,
    ...(params.has("seed") && Number.isSafeInteger(seed) && seed >= 0 ? { seed } : {}),
    ...(storage === "opfs" || storage === "memory" ? { storage } : {}),
  }
}

const DEMO_SEARCH_KEY = "inline.demo.search"

/**
 * The demo query string for this tab. Navigation rewrites the URL, so the
 * choice is remembered for the tab's lifetime: a reload stays in the demo.
 * `?demo=off` leaves it.
 */
export const rememberedDemoSearch = (
  search: string = location.search,
  storage: Pick<Storage, "getItem" | "setItem" | "removeItem"> | undefined = safeSessionStorage(),
): string => {
  const params = new URLSearchParams(search)
  if (params.get("demo") === "off") {
    storage?.removeItem(DEMO_SEARCH_KEY)
    return ""
  }
  if (params.has("demo")) {
    storage?.setItem(DEMO_SEARCH_KEY, search)
    return search
  }
  return storage?.getItem(DEMO_SEARCH_KEY) ?? ""
}

const safeSessionStorage = () => {
  try {
    return globalThis.sessionStorage
  } catch {
    return undefined
  }
}
