import type { OperatingSystem, PlatformInfo } from "../platform"
import type { WebNavigatorLike } from "./env"

/**
 * The operating system from User-Agent Client Hints where present (Chromium),
 * otherwise the user agent string. An iPad asking for the desktop site
 * reports a Mac user agent; touch points tell it apart.
 */
export const detectOperatingSystem = (navigator: WebNavigatorLike): OperatingSystem => {
  const hinted = navigator.userAgentData?.platform?.toLowerCase()
  if (hinted) {
    if (hinted === "macos") return "mac"
    if (hinted === "windows") return "windows"
    if (hinted === "linux") return "linux"
    if (hinted === "chrome os" || hinted === "chromeos") return "chromeos"
    if (hinted === "android") return "android"
    if (hinted === "ios") return "ios"
  }
  const ua = navigator.userAgent
  if (/iPhone|iPad|iPod/.test(ua)) return "ios"
  if (/Android/.test(ua)) return "android"
  if (/CrOS/.test(ua)) return "chromeos"
  if (/Macintosh|Mac OS X/.test(ua)) return (navigator.maxTouchPoints ?? 0) > 1 ? "ios" : "mac"
  if (/Windows/.test(ua)) return "windows"
  if (/Linux|X11/.test(ua)) return "linux"
  return "unknown"
}

export const usesMetaModifier = (os: OperatingSystem): boolean => os === "mac" || os === "ios"

export const webPlatformInfo = (navigator: WebNavigatorLike): PlatformInfo => {
  const os = detectOperatingSystem(navigator)
  return {
    kind: "web",
    os,
    shortcutModifier: usesMetaModifier(os) ? "meta" : "ctrl",
    surface: "tab",
  }
}
