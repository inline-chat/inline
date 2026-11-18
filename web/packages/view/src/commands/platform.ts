/**
 * Platforms for shortcuts. A platform is an operating system plus a surface:
 * the desktop app (Electron, which can bind window and tab shortcuts) or a
 * browser tab (which cannot). Detection takes its inputs by injection.
 */

export type OS = "mac" | "windows" | "linux"
export type Surface = "desktop" | "browser"

export type Platform = { readonly os: OS; readonly surface: Surface }

export const allOSes: readonly OS[] = ["mac", "windows", "linux"]

export const allPlatforms: readonly Platform[] = [
  { os: "mac", surface: "desktop" },
  { os: "windows", surface: "desktop" },
  { os: "linux", surface: "desktop" },
  { os: "mac", surface: "browser" },
  { os: "windows", surface: "browser" },
  { os: "linux", surface: "browser" },
]

const osLabels: Record<OS, string> = { mac: "Mac", windows: "Windows", linux: "Linux" }

export const platformLabel = (platform: Platform): string =>
  platform.surface === "desktop" ? `${osLabels[platform.os]} app` : `Browser on ${osLabels[platform.os]}`

export const platformKey = (platform: Platform): string => `${platform.surface}-${platform.os}`

/** The parts of `navigator` used for detection. */
export type NavigatorLike = {
  readonly userAgentData?: { readonly platform?: string } | undefined
  readonly platform?: string
  readonly userAgent?: string
}

/**
 * The OS whose modifier conventions apply. Apple platforms (including iPad
 * with a keyboard) use Cmd; everything else uses Ctrl, and anything that is
 * not Mac or Windows is treated as Linux.
 */
export const detectOS = (navigator: NavigatorLike | undefined): OS => {
  const hint = `${navigator?.userAgentData?.platform ?? ""} ${navigator?.platform ?? ""} ${navigator?.userAgent ?? ""}`.toLowerCase()
  if (/mac|iphone|ipad|ipod|ios/.test(hint)) return "mac"
  if (/win/.test(hint)) return "windows"
  if (/linux|x11|cros|android|bsd/.test(hint)) return "linux"
  return "windows"
}

export const detectPlatform = (input: { readonly navigator?: NavigatorLike; readonly desktop?: boolean }): Platform => ({
  os: detectOS(input.navigator),
  surface: input.desktop ? "desktop" : "browser",
})
