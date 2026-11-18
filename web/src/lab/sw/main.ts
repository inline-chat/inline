/**
 * Service worker lab: registration state, the update feed as the platform
 * sees it, the worker's caches and their entries, and the update controls.
 * Meaningful only in a production build served by `vite preview`; see
 * `lab-sw.html`.
 */

import { createUpdateFeed } from "@inline/platform"
import { effect } from "@inline/reactive"
import { CACHE_PREFIX } from "../../sw/protocol"
import { registerServiceWorker } from "../../sw/register"

const element = (id: string): HTMLElement => {
  const found = document.getElementById(id)
  if (!found) throw new Error(`Missing #${id}`)
  return found
}

const stateOut = element("state")
const cachesOut = element("caches")
const logOut = element("log")
const unsaved = element("unsaved") as HTMLInputElement

const log = (line: string): void => {
  logOut.textContent = `${new Date().toISOString().slice(11, 23)} ${line}\n${logOut.textContent ?? ""}`
}

const { updater, feed } = createUpdateFeed()

const sw = registerServiceWorker({
  enabled: import.meta.env.PROD,
  buildId: __INLINE_BUILD_ID__,
  feed,
  hasUnsavedWork: () => unsaved.checked,
  onError: (error) => log(`error: ${error instanceof Error ? error.message : String(error)}`),
})

const describeWorker = (worker: ServiceWorker | null | undefined): string =>
  worker ? `${new URL(worker.scriptURL).pathname} (${worker.state})` : "none"

const renderState = async (): Promise<void> => {
  const container = "serviceWorker" in navigator ? navigator.serviceWorker : undefined
  const registration = await container?.getRegistration().catch(() => undefined)
  stateOut.textContent = JSON.stringify(
    {
      build: __INLINE_BUILD_ID__,
      production: import.meta.env.PROD,
      secureContext: globalThis.isSecureContext,
      status: sw.status(),
      updater: updater.state.get(),
      controller: describeWorker(container?.controller),
      registration: registration
        ? {
            scope: registration.scope,
            installing: describeWorker(registration.installing),
            waiting: describeWorker(registration.waiting),
            active: describeWorker(registration.active),
          }
        : "none",
    },
    null,
    2,
  )
}

const renderCaches = async (): Promise<void> => {
  if (typeof caches === "undefined") {
    cachesOut.textContent = "Cache Storage is unavailable here."
    return
  }
  const lines: string[] = []
  for (const name of await caches.keys()) {
    const cache = await caches.open(name)
    const requests = await cache.keys()
    lines.push(`${name}${name.startsWith(CACHE_PREFIX) ? "" : " (not ours)"}: ${requests.length} entries`)
    for (const request of requests) lines.push(`  ${new URL(request.url).pathname}`)
  }
  cachesOut.textContent = lines.length > 0 ? lines.join("\n") : "No caches."
}

const render = (): void => {
  void renderState()
  void renderCaches()
}

sw.subscribe((status) => {
  log(`status: ${status.phase}, update ${status.update.status}, pending ${status.pending}`)
  render()
})
effect(() => {
  log(`updater: ${JSON.stringify(updater.state.get())}`)
})

element("check").addEventListener("click", () => {
  log("checking for an update")
  void sw.checkForUpdate().then(render)
})
element("apply").addEventListener("click", () => {
  log("apply (does nothing unless the updater is ready)")
  updater.apply()
})
element("refresh").addEventListener("click", render)
element("clear").addEventListener("click", () => {
  void sw.clearCaches().then(() => {
    log("caches cleared")
    render()
  })
})
element("unregister").addEventListener("click", () => {
  void sw.unregister().then(() => {
    log("unregistered; reload to see the page without a worker")
    render()
  })
})
navigator.serviceWorker?.addEventListener("controllerchange", () => {
  log("controllerchange")
  render()
})

render()
