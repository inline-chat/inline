/**
 * The app under test, in a same-origin iframe pointed at `/?demo=<scale>`.
 *
 * Why an iframe and not the app mounted into the lab's document: the app is
 * then exactly as shipped (its own document, boot, styles, content policy,
 * service worker, history binding); a journey can reload it to measure a real
 * warm start; and the app's history binding rewrites its own URL to
 * `/c/<id>`, which in the lab's document would replace the lab's address.
 * Same origin lets the lab read `contentWindow.__inlineApp`, the app's
 * performance timeline and its DOM, and drive it.
 *
 * The cost: the frame shares the lab's main thread (the lab stays idle while
 * a journey measures, and renders its table between journeys); the service
 * worker controls both documents; the frame's size is the app's window size;
 * and the app's module instances are its own, so the lab cannot install a
 * render counter inside it (see "Needs" in the README).
 */

import type { CoreResource } from "@inline/core-protocol"
import type { AppSnapshot } from "../../app/dev-snapshot"
import type { DemoControl } from "../../core/demo/control"
import type { FrameWaiter } from "../timeline/frames"
import { WaitTimeoutError } from "../timeline/frames"
import { ConditionTimeoutError, withTimeout, type AppWindow } from "./probes"

export const BOOT_TIMEOUT_MS = 60_000

export class AppFrame {
  /** Increases on every document load of the frame; journeys key per-load state by it. */
  loads = 0
  #search = ""

  constructor(
    readonly iframe: HTMLIFrameElement,
    private readonly waiter: FrameWaiter,
  ) {}

  /** The demo query the frame was loaded with. */
  get search(): string {
    return this.#search
  }

  win(): AppWindow {
    const win = this.iframe.contentWindow as AppWindow | null
    if (!win || this.loads === 0) throw new Error("The app frame is not loaded.")
    return win
  }

  doc(): Document {
    const doc = this.iframe.contentDocument
    if (!doc || this.loads === 0) throw new Error("The app frame is not loaded.")
    return doc
  }

  /** `__inlineApp`, the app's automation snapshot (labs build and development only). */
  app(): AppSnapshot {
    const snapshot = this.win().__inlineApp
    if (!snapshot) {
      throw new Error("The app did not expose __inlineApp. Use the labs build (tooling/vite.labs.config.ts) or the dev server.")
    }
    return snapshot
  }

  /** `__inlineDemo`, the demo world's control channel. */
  demo(): DemoControl {
    const demo = this.win().__inlineDemo
    if (!demo) throw new Error("The app did not expose __inlineDemo: it is not running a demo account.")
    return demo
  }

  /** Read the snapshot, or undefined while the app has not exposed it. */
  peekApp(): AppSnapshot | undefined {
    try {
      return (this.iframe.contentWindow as AppWindow | null)?.__inlineApp
    } catch {
      return undefined
    }
  }

  /** Load `/` with the demo query and wait until the app is signed in, the core ready and sidebar rows painted. */
  async load(search: string): Promise<void> {
    this.#search = search
    const loaded = this.#nextLoad()
    this.iframe.src = `/${search}`
    await withTimeout(loaded, BOOT_TIMEOUT_MS, "the app frame to load")
    await this.waitReady()
  }

  /** Reload the app's current page (its own URL, `/c/<id>` when a chat is open); the demo choice is remembered for the tab. */
  async reload(): Promise<void> {
    const loaded = this.#nextLoad()
    this.win().location.reload()
    await withTimeout(loaded, BOOT_TIMEOUT_MS, "the app frame to reload")
    await this.waitReady()
  }

  #nextLoad(): Promise<void> {
    return new Promise((resolve) => {
      this.iframe.addEventListener(
        "load",
        () => {
          this.loads += 1
          resolve()
        },
        { once: true },
      )
    })
  }

  async waitReady(timeoutMs = BOOT_TIMEOUT_MS): Promise<void> {
    const describe = () => {
      const app = this.peekApp()
      if (!app) return "__inlineApp not exposed yet"
      const core = app.core as CoreResource | null
      return `phase ${app.phase}, core ${core?.phase ?? "none"}, sidebar ${app.sidebarCount ?? "none"}`
    }
    await this.until(
      () => {
        const app = this.peekApp()
        if (!app || app.phase !== "signedIn") return false
        if ((app.core as CoreResource | null)?.phase !== "ready") return false
        if ((app.sidebarCount ?? 0) === 0) return false
        return this.iframe.contentDocument?.querySelector("[data-sidebar-key]") != null
      },
      "the app to be signed in with the core ready and sidebar rows painted",
      timeoutMs,
      describe,
    )
  }

  /** Frames (of the lab's window, which shares the app's) until `condition` holds, or a named timeout. */
  async until(condition: () => boolean, what: string, timeoutMs: number, describe?: () => string): Promise<void> {
    try {
      await this.waiter.until(condition, what, { maxFrames: 1, maxMs: timeoutMs })
    } catch (error) {
      if (error instanceof WaitTimeoutError) throw new ConditionTimeoutError(what, timeoutMs, describe?.())
      throw error
    }
  }

  // -------------------------------------------------------------------------
  // The app's surfaces, found by the attributes their READMEs document

  /** The focused pane's message list scroller (`[data-timeline-scroller]`). One pane is assumed. */
  scroller(): HTMLElement | null {
    return this.doc().querySelector<HTMLElement>("[data-timeline-scroller]")
  }

  timelineContent(scroller = this.scroller()): HTMLElement | null {
    return scroller?.querySelector<HTMLElement>("[data-timeline-content]") ?? null
  }

  /** The timeline's root (scroller, status overlay and the latest button). */
  timelineRoot(scroller = this.scroller()): HTMLElement | null {
    return scroller?.parentElement ?? null
  }

  keyedRows(content = this.timelineContent()): HTMLElement[] {
    return content ? Array.from(content.querySelectorAll<HTMLElement>(":scope > [data-timeline-key]")) : []
  }

  /** The visible "Jump to latest" button, when it is shown (its wrapper is `inert` while hidden). */
  latestButton(): HTMLElement | null {
    const button = this.doc().querySelector<HTMLElement>('[aria-label^="Jump to latest"]')
    if (!button || button.closest("[inert]")) return null
    return button
  }

  composerEditor(): HTMLElement | null {
    return this.doc().querySelector<HTMLElement>('[data-focus-region="composer"] [role="textbox"][contenteditable="true"]')
  }

  /** Sidebar rows in the DOM, in list order (`aria-posinset`); rows are windowed and absolutely positioned. */
  sidebarRows(): HTMLElement[] {
    return Array.from(this.doc().querySelectorAll<HTMLElement>("[data-sidebar-key]")).sort(
      (a, b) => position(a) - position(b),
    )
  }

  sidebarRow(key: string): HTMLElement | null {
    return this.doc().querySelector<HTMLElement>(`[data-sidebar-key="${CSS.escape(key)}"]`)
  }

  selectedSidebarRow(): HTMLElement | null {
    return this.doc().querySelector<HTMLElement>('[data-sidebar-key][aria-selected="true"]')
  }

  sidebarListbox(): HTMLElement | null {
    return this.doc().querySelector("[data-sidebar-key]")?.closest<HTMLElement>('[role="listbox"]') ?? null
  }

  /** The sidebar's scrolling element: the listbox's nearest scrollable ancestor. */
  sidebarScroller(): HTMLElement | null {
    const win = this.win()
    let element: HTMLElement | null = this.sidebarListbox()
    while (element) {
      const overflow = win.getComputedStyle(element).overflowY
      if ((overflow === "auto" || overflow === "scroll") && element.scrollHeight > element.clientHeight) return element
      element = element.parentElement
    }
    return null
  }
}

const position = (element: Element) => Number(element.getAttribute("aria-posinset") ?? Number.MAX_SAFE_INTEGER)
