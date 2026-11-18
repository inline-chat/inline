/**
 * The one platform fact the kit needs: which modifier means "command".
 * Cmd on Apple platforms, Ctrl elsewhere. The shortcut matcher in
 * `@inline/view` owns everything else about shortcuts.
 */

import type { KeyInput } from "./dom"

export type PlatformKind = "mac" | "other"

export const detectPlatform = (): PlatformKind => {
  if (typeof navigator === "undefined") return "other"
  const data = (navigator as Navigator & { userAgentData?: { platform?: string } }).userAgentData
  const name = data?.platform || navigator.platform || navigator.userAgent
  return /mac|iphone|ipad|ipod/i.test(name) ? "mac" : "other"
}

/** True when the platform's command modifier is held (Cmd on Mac, Ctrl elsewhere). */
export const hasCommandModifier = (event: Pick<KeyInput, "metaKey" | "ctrlKey">, platform: PlatformKind): boolean =>
  platform === "mac" ? !!event.metaKey : !!event.ctrlKey
