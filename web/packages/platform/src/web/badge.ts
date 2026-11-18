/**
 * The web badge and window title. The badge shows in three places: a
 * `(3) ` prefix on the tab title, the favicon, and the Badging API where it
 * exists (installed web apps). The title prefix is why the badge and
 * `window.setTitle` share one writer.
 */

import { signal, type ReadSignal } from "@inline/reactive"
import { badgeLabel, createBadgeController } from "../badge-policy"
import type { Badge } from "../platform"
import type { LinkElementLike, WebEnv } from "./env"

export interface TitleAndBadge {
  readonly badge: Badge
  readonly title: ReadSignal<string>
  setTitle(title: string): void
  dispose(): void
}

export const createWebTitleAndBadge = (env: WebEnv): TitleAndBadge => {
  const { document, navigator } = env
  const title = signal(document.title)
  const shown = signal(0)

  const writeTitle = () => {
    const label = badgeLabel(shown.peek())
    const base = title.peek()
    document.title = label ? `(${label}) ${base}` : base
  }

  const favicon = env.favicon ? createFaviconBadge(env) : null

  const applyAppBadge = (count: number) => {
    try {
      const pending =
        count > 0 ? navigator.setAppBadge?.call(navigator, count) : navigator.clearAppBadge?.call(navigator)
      // Rejects when the page is not an installed app; that is fine.
      pending?.catch(() => {})
    } catch {
      // Not supported here.
    }
  }

  const controller = createBadgeController({
    clock: env.clock,
    apply: (count) => {
      shown.set(count)
      writeTitle()
      favicon?.show(count)
      applyAppBadge(count)
    },
  })

  return {
    badge: {
      set: (count, options) => controller.set(count, options?.immediate === true),
      count: shown,
    },
    title,
    setTitle(next) {
      title.set(next)
      writeTitle()
    },
    dispose() {
      controller.dispose()
      favicon?.dispose()
      document.title = title.peek()
    },
  }
}

const createFaviconBadge = (env: WebEnv) => {
  const { document } = env
  const renderer = env.favicon
  let link = document.querySelector('link[rel~="icon"]') as LinkElementLike | null
  if (!link) {
    link = document.createElement("link") as LinkElementLike
    link.rel = "icon"
    link.href = "/favicon.ico"
    document.head?.appendChild(link)
  }
  const element = link
  const baseHref = element.href
  let generation = 0

  return {
    show(count: number) {
      const current = ++generation
      const label = badgeLabel(count)
      if (!label || !renderer) {
        element.href = baseHref
        return
      }
      void renderer.render(baseHref, label).then((url) => {
        // A later count supersedes a render still in flight.
        if (current !== generation || !url) return
        element.href = url
      })
    },
    dispose() {
      generation++
      element.href = baseHref
    },
  }
}
