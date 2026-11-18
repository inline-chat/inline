/**
 * Boot: everything the page creates once, in order, before the first render.
 * Framework-free; `main.tsx` calls `boot()` and renders `App` with the
 * services it returns. Nothing here waits on the network: the auth store is
 * read from IndexedDB (local), the core connects in its worker, and the view
 * chunks load in parallel while the gate shows a neutral frame.
 *
 * Order (README, "Boot sequence"):
 *  1. mark `inline.boot.start`; the app log with its ring buffer; the boot
 *     snapshot, read synchronously before any await and before a core exists
 *  2. the web platform (with the link allowlist)
 *  3. the service worker (production only)
 *  4. in development, `?demo=` picks the demo connector (dynamic import)
 *  5. the auth store with browser persistence (or an in-memory one for the demo)
 *  6. the preferences store; the sign-in flows (loaded on first use, not in
 *     the initial bundle), the sign-in model factory, the sign-out
 *  7. the runtime (`AppModel` and per-session wiring), the window keyboard,
 *     the focus guard, the appearance commands
 *  8. view chunks requested for the phase; work deferred until after the
 *     first paint (`warmup.ts`); the services object
 *  9. in development, `globalThis.__inlineApp`
 */

import { AuthStore, BrowserAuthSessionPersistence } from "@inline/auth/core"
import { safeLink } from "@inline/chat-ui"
import { getServerUrl } from "@inline/config"
import { CORE_PROTOCOL_VERSION } from "@inline/core-protocol"
import type { UserID } from "@inline/ids"
import { Log, LogRingBuffer } from "@inline/log"
import { createWebPlatform } from "@inline/platform"
import { browserClock, browserScheduler, effect, signal } from "@inline/reactive"
import { browserClock as timelineClock, browserFrames } from "@inline/timeline"
import type { AppearanceController } from "@inline/ui/theme"
import { appearanceCommands } from "@inline/ui/theme"
import { createBrowserHistory, detectPlatform, encodeDestination, parseLink, toAppUrl } from "@inline/view"
import type { AccountConnector } from "@inline/view/features"
import { BUILD_ID } from "../core/build"
import { connectAccount } from "../core/connect"
import { createPermissionPrompt, type PermissionPrompt } from "../features/notifications/permission"
import { broadcastPreferencesChannel, PreferencesStore, webPreferencesStorage } from "../features/settings/preferences"
import type { ServiceWorkerController } from "../sw/register"
import { readBootSnapshot } from "./boot-snapshot"
import { buildDiagnostics } from "./diagnostics"
import { eraseAccountEmoji } from "./emoji-storage"
import { bindFocusGuard, bindWindowKeyboard } from "./focus"
import { createSessionHistory } from "./history-session"
import { browserAfterPaint, createBootMetrics, type BootMetrics } from "./perf"
import { AppRuntime } from "./runtime"
import type { AppServices, AppViews } from "./services"
import { createAuthFlows, LazySignIn } from "./signin-loader"
import { queueAccountStorageSweep } from "./storage-sweep"
import { chunkImporters, firstPaint, type ChunkName } from "./view-chunks"
import { loadable } from "./views"
import { Warmup } from "./warmup"
import { readDemoParams, rememberedDemoSearch } from "./demo-params"

/** Where Quick Search keeps an account's usage (`quickSearchUsageStorageKey` in its feature, which loads later). */
const quickSearchUsageKey = (userId: UserID): string => `inline:quick-search-usage:${userId}`

/** Where the session record lives (IndexedDB, with a cross-tab broadcast). Same key as the earlier web app. */
export const AUTH_STORAGE_KEY = "inline-web-session"

/** The server's sign-in codes are 6 digits; the screen submits as soon as they are typed. */
const CODE_LENGTH = 6

/** Keys the notifications channel by server, as link keys its locks. */
const notifyOrigin = (): string => {
  try {
    return new URL(getServerUrl()).origin
  } catch {
    return "default"
  }
}

const isExternalLink = (url: string): boolean => {
  const link = safeLink(url)
  return link !== undefined && link.kind !== "app"
}

export type BootOptions = {
  /** The document appearance controller, started first thing in `main.tsx`. */
  readonly appearance: AppearanceController
  /** Created at the top of `main.tsx`, so `inline.boot.start` is the module's start. */
  readonly metrics: BootMetrics
}

export const boot = async (options: BootOptions): Promise<AppServices> => {
  const { metrics, appearance } = options
  const logs = new LogRingBuffer(500)
  const log = new Log("App", { recordSinks: [logs], sink: import.meta.env.DEV ? undefined : false })

  // The boot snapshot (boot-snapshot/README.md): read now, synchronously, so
  // the first render can paint the sidebar and the last chat from it. The
  // auth persistence's logout tombstone (a sign-out that did not finish)
  // rules it out before anything is painted.
  const browserStorage = (() => {
    try {
      return localStorage
    } catch {
      return undefined
    }
  })()
  const snapshotRead = readBootSnapshot(browserStorage, {
    buildId: BUILD_ID,
    signedOut: () => browserStorage?.getItem(`${AUTH_STORAGE_KEY}:logout-pending`) === "1",
    now: () => performance.now(),
  })
  log.info("boot snapshot", {
    kind: snapshotRead.kind,
    ...(snapshotRead.kind === "snapshot" ? { chars: snapshotRead.chars, ms: snapshotRead.ms } : {}),
    ...(snapshotRead.kind === "discarded" ? { reason: snapshotRead.reason } : {}),
  })

  const platform = createWebPlatform({ isSafeExternalUrl: isExternalLink })
  const scheduler = browserScheduler()
  const warmup = new Warmup({
    afterPaint: browserAfterPaint,
    idle: (task) => void scheduler.idle(() => task()),
    timeout: (fn, ms) => {
      const handle = setTimeout(fn, ms)
      return () => clearTimeout(handle)
    },
    onError: (error) => log.warn("deferred load", { error }),
  })

  let runtimeRef: AppRuntime<LazySignIn> | undefined
  // The service worker registers after the first paint (it is not needed to
  // paint, and registering competes with it). Its module is loaded then too.
  let serviceWorker: ServiceWorkerController | undefined
  warmup.add(async () => {
    const { registerServiceWorker } = await chunkImporters.serviceWorker()
    serviceWorker = registerServiceWorker({
      enabled: import.meta.env.PROD && platform.info.kind === "web",
      buildId: BUILD_ID,
      feed: platform.updates,
      // A send in flight or a composer with text: never reload this tab on its own.
      hasUnsavedWork: () => runtimeRef?.unsavedWork.has() ?? true,
      onError: (error) => log.warn("service worker", { error }),
    })
  })
  const clearServiceWorkerCaches = async () => {
    if (serviceWorker) return serviceWorker.clearCaches()
    const { clearServiceWorkerCaches: clear } = await chunkImporters.serviceWorker()
    await clear(globalThis.caches)
  }

  // Development only: a seeded demo account against a simulated server, no sign-in.
  let connect: AccountConnector = connectAccount
  let demoUserId: UserID | undefined
  // The labs build (tooling/vite.labs.config.ts) also enables it, so the whole
  // app can be checked in a production build; `bun run build` never does.
  if (import.meta.env.DEV || __INLINE_DEMO__) {
    const demo = readDemoParams(rememberedDemoSearch())
    if (demo) {
      const { connectDemoAccount } = await import("../core/demo/connect-demo")
      let first: ReturnType<typeof connectDemoAccount> | undefined = connectDemoAccount(demo)
      demoUserId = first.userId
      Object.defineProperty(globalThis, "__inlineDemo", { configurable: true, get: () => first?.demo })
      connect = (userId) => {
        const connection = first && first.userId === userId ? first : connectDemoAccount(demo)
        first = undefined
        Object.defineProperty(globalThis, "__inlineDemo", { configurable: true, value: connection.demo })
        return connection
      }
      log.info("demo", { scale: demo.scale })
    }
  }

  const authStore = demoUserId
    ? new AuthStore()
    : new AuthStore({ storage: new BrowserAuthSessionPersistence(AUTH_STORAGE_KEY) })
  if (demoUserId) await authStore.login({ userId: demoUserId, token: "demo" })
  // The boot sweep (security.md): account storage no session in this browser owns, on the idle lane.
  queueAccountStorageSweep({ warmup, demo: demoUserId !== undefined, authStore, log })

  // Device-wide preferences (settings/README.md): created before any view reads them.
  const preferences = new PreferencesStore({
    storage: webPreferencesStorage(browserStorage ?? null),
    ...(typeof BroadcastChannel === "function"
      ? { channel: broadcastPreferencesChannel(new BroadcastChannel("inline-preferences")) }
      : {}),
  })

  // Electron's system spellchecker follows the same setting as the composer's `spellcheck`.
  const spellcheck = platform.spellcheck
  if (spellcheck.available) effect(() => spellcheck.setEnabled(preferences.spellCheck.get()))

  // The sign-in model, the API client and the sign-out flow load on first use.
  const authFlows = createAuthFlows({ authStore, storage: () => browserStorage ?? null, load: chunkImporters.authFlows })
  // The account's data is erased by the app model when the auth store reports the end,
  // so the flow's own erase hook is not passed.
  const signOut = demoUserId
    ? () => authStore.logout()
    : async () => {
        let flows
        try {
          flows = await authFlows()
        } catch {
          // The flows could not load (offline, first visit): end the session locally.
          return authStore.logout()
        }
        return flows.module.signOut({ authStore, api: flows.api, clock: flows.module.systemClock })
      }

  // The address bar, wrapped so entries from before a sign-out read as `/` (history-session.ts).
  const history = createSessionHistory(createBrowserHistory(window), {
    storage: (() => {
      try {
        return sessionStorage
      } catch {
        return undefined
      }
    })(),
  })

  const notificationPrompt = signal<PermissionPrompt | undefined>(undefined)
  const runtime = new AppRuntime<LazySignIn>({
    authStore,
    createSignIn: (deps) =>
      new LazySignIn(() =>
        authFlows().then(({ module, api }) =>
          module.createSignInModel({ api, authStore, clock: module.systemClock, signOut: deps.signOut }),
        ),
      ),
    signInHold: {
      held: (signIn, userId) => signIn.held.get() && signIn.signedInUserId() === userId,
      release: (signIn) => signIn.release(),
    },
    connect,
    platform,
    keyboardPlatform: detectPlatform({ navigator, desktop: false }),
    clock: browserClock(),
    metrics,
    storage: localStorage,
    buildId: BUILD_ID,
    protocol: CORE_PROTOCOL_VERSION,
    history: () => history,
    eraseAccountData: async (userId) => {
      try {
        localStorage.removeItem(quickSearchUsageKey(userId))
      } catch {
        // Storage unavailable: nothing was kept.
      }
      // Emoji recents and skin tone (emoji-session.ts).
      eraseAccountEmoji(browserStorage, userId)
      // The replica is erased by the core (session signOut); the workspace by the app model;
      // the layout and the boot snapshot by the runtime, before this runs.
      await clearServiceWorkerCaches()
    },
    signOut,
    bootSnapshot: {
      ...(snapshotRead.kind === "snapshot" ? { initial: snapshotRead.snapshot } : {}),
      scheduler,
      elapsed: () => performance.now(),
    },
    opener: (destination) => {
      window.open(toAppUrl(destination, location.origin), "_blank", "noopener,noreferrer")
    },
    log,
    // The permission prompt at once (its banner is on the first frame); message notifications
    // (only the leading context shows them) and the badge after the first paint (notifications-chunk.ts).
    attachSession: {
      ownsBadge: true,
      attach: (session, current) => {
        notificationPrompt.set(createPermissionPrompt({ notifications: platform.notifications, storage: localStorage }))
        let ended = false
        let detach: (() => void) | undefined
        warmup.add(async () => {
          const chunk = await chunkImporters.notifications()
          if (ended) return
          detach = chunk.attachMessageNotifications({
            session,
            platform,
            role: current.role,
            clock: { now: () => Date.now() },
            channel: new BroadcastChannel(`inline-notify/${demoUserId ? "demo" : notifyOrigin()}/${session.userId}`),
            settings: { soundEnabled: () => preferences.notificationSounds.peek() },
            badgeEnabled: preferences.appBadge,
          })
        })
        return () => {
          ended = true
          notificationPrompt.set(undefined)
          detach?.()
        }
      },
    },
  })
  runtimeRef = runtime

  bindWindowKeyboard(window, runtime.app.keyboard)
  bindFocusGuard(window, () => runtime.restoreFocus())
  for (const spec of appearanceCommands(appearance)) runtime.app.registry.register(spec)

  // The chunks (view-chunks.ts, which the bundle measurement reads too).
  const views: AppViews = {
    signIn: loadable(() => chunkImporters.signIn().then((module) => module.SignInScreen)),
    shell: loadable(() => chunkImporters.shell().then((module) => module.Shell)),
    quickSearch: loadable(chunkImporters.quickSearch),
    settings: loadable(chunkImporters.settings),
    content: loadable(chunkImporters.content),
    find: loadable(chunkImporters.find),
    mentions: loadable(chunkImporters.mentions),
    attachments: loadable(chunkImporters.attachments),
    chatInfo: loadable(chunkImporters.chatInfo),
    mediaViewer: loadable(chunkImporters.mediaViewer),
    layers: loadable(chunkImporters.layers),
  }
  // What each phase needs before its first paint (`firstPaint`): the shell, or the sign-in
  // screen and the flows (which `LazySignIn` also starts; the same load).
  const firstPaintLoads: Partial<Record<ChunkName, () => Promise<unknown>>> = {
    shell: () => views.shell.load(),
    signIn: () => views.signIn.load(),
    authFlows: () => authFlows().catch(() => undefined),
  }
  effect(() => {
    const phase = runtime.app.phase.get()
    if (phase.kind !== "signedIn" && phase.kind !== "signedOut") return
    for (const name of firstPaint[phase.kind]) void firstPaintLoads[name]?.()
  })

  const services: AppServices = {
    runtime,
    views,
    appearance,
    platform,
    preferences,
    warmup,
    deviceName: () => authFlows().then((flows) => flows.device.deviceName),
    buildId: BUILD_ID,
    update: platform.updater.state,
    notificationPrompt,
    applyUpdate: () => platform.updater.apply(),
    reload: () => location.reload(),
    copyDiagnostics: async () => {
      const session = runtime.app.session.peek()
      const text = buildDiagnostics({
        buildId: BUILD_ID,
        phase: runtime.app.phase.peek().kind,
        ...(session ? { status: session.status.peek(), core: session.coreResource.peek() } : {}),
        role: runtime.role.peek(),
        panes: session ? session.workspace.panes.peek().map((pane) => encodeDestination(pane.entries[pane.index]?.destination ?? { kind: "empty" })) : [],
        measures: metrics.measures(),
        logs: logs.snapshot(),
        userAgent: navigator.userAgent,
      })
      try {
        await navigator.clipboard.writeText(text)
        return true
      } catch {
        return false
      }
    },
    openExternal: (url) => void platform.links.openExternal(url),
    copyText: async (text) => {
      // TODO(contract): the platform has no clipboard capability yet (Electron would use its own).
      try {
        await navigator.clipboard.writeText(text)
        return true
      } catch {
        return false
      }
    },
    parseAppLink: (href) => parseLink(href),
    safeUrl: (url) => safeLink(url, { bareDomain: true })?.href ?? null,
    timeZone: Intl.DateTimeFormat().resolvedOptions().timeZone,
    timelineClock,
    frames: browserFrames,
    nextFrame: (fn) => void requestAnimationFrame(() => fn()),
    codeLength: CODE_LENGTH,
    emoji: { services: chunkImporters.emoji, pickers: chunkImporters.emojiPickers },
  }

  if (import.meta.env.DEV || __INLINE_DEMO__) {
    // Read now: the history binding rewrites the address once a session starts.
    const search = `${location.search}&${rememberedDemoSearch()}`
    void import("./dev-snapshot").then((module) =>
      module.exposeAppSnapshot(runtime, { renderCounts: new URLSearchParams(search).get("renderCounts") === "1" }),
    )
  }
  return services
}

export { createBootMetrics }
