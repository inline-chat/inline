/**
 * Development and the labs build only (loaded with a dynamic import under
 * `import.meta.env.DEV` or the labs build's `__INLINE_DEMO__`, so it is not in the
 * production bundle): `globalThis.__inlineApp` returns
 * the app's state as plain data for browser automation. A getter, so every
 * read is fresh. Holds IDs and counts, never message text or tokens.
 *
 * With `?renderCounts=1` (the perf lab), a render counter is installed in
 * the app's own module instance and exposed as `__inlineApp.renderCounts`
 * (`counts()`, `reset()`): components that call `countRender` (timeline
 * rows and list, sidebar rows and list, the palette) are counted.
 */

import { createRenderCounter, type RenderCounter } from "@inline/reactive/react/testing"
import { encodeDestination } from "@inline/view"
import { destinationChatId } from "@inline/view/features"
import type { AppRuntime } from "./runtime"

export type AppSnapshot = {
  phase: string
  status: string | null
  core: unknown
  role: string | null
  panes: { id: string; path: string; focused: boolean; chatRows: number | null }[]
  sidebarCount: number | null
  openChatRows: number | null
  /**
   * The focused pane's chat: its dialog's unread count and read marker as the
   * chat model feeds the timeline, and where its first rows came from
   * (`memory`, `sqlite` or `network`; null until opened).
   */
  openChat: {
    chatId: string
    rows: number
    unreadCount: number | null
    readMaxId: string | null
    source: string | null
  } | null
  /** Present with `?renderCounts=1`. */
  renderCounts?: { counts(): Record<string, number>; reset(): void }
  measures: readonly { name: string; ms: number }[]
  unsavedWork: boolean
}

/** What the snapshot reads from the runtime (any `AppRuntime` fits). */
type SnapshotRuntime = Pick<AppRuntime, "role" | "metrics" | "unsavedWork" | "openChats"> & {
  readonly app: Pick<AppRuntime["app"], "session"> & { readonly phase: { peek(): { readonly kind: string } } }
}

export const appSnapshot = (runtime: SnapshotRuntime, renderCounts?: RenderCounter): AppSnapshot => {
  const phase = runtime.app.phase.peek()
  const session = runtime.app.session.peek()
  const focusedId = session?.workspace.focusedPaneId.peek()
  const rowsOf = (chatId: string | undefined) => {
    if (!session || chatId === undefined) return null
    const model = session.chats.peek(chatId as Parameters<typeof session.chats.peek>[0])
    return model ? model.rowKeys.peek().length : null
  }
  const focusedChatId = (() => {
    const pane = session?.workspace.panes.peek().find((candidate) => candidate.id === focusedId)
    const destination = pane?.entries[pane.index]?.destination
    return destination ? destinationChatId(destination) : undefined
  })()
  const openModel = session && focusedChatId !== undefined ? session.chats.peek(focusedChatId) : undefined
  const panes =
    session?.workspace.panes.peek().map((pane) => {
      const destination = pane.entries[pane.index]?.destination ?? { kind: "empty" as const }
      return {
        id: pane.id,
        path: encodeDestination(destination),
        focused: pane.id === focusedId,
        chatRows: rowsOf(destinationChatId(destination)),
      }
    }) ?? []
  return {
    phase: phase.kind,
    status: session ? session.status.peek() : null,
    core: session?.coreResource.peek() ?? null,
    role: runtime.role.peek() ?? null,
    panes,
    sidebarCount: session ? session.sidebar.items.peek().length : null,
    openChatRows: panes.find((pane) => pane.focused)?.chatRows ?? null,
    openChat: openModel
      ? {
          chatId: openModel.chatId,
          rows: openModel.rowKeys.peek().length,
          unreadCount: openModel.readState.peek()?.unreadCount ?? null,
          readMaxId: openModel.readState.peek()?.readMaxId ?? null,
          source: (focusedId !== undefined ? runtime.openChats.get(focusedId)?.source.peek() : undefined) ?? null,
        }
      : null,
    ...(renderCounts ? { renderCounts: { counts: () => renderCounts.counts(), reset: () => renderCounts.reset() } } : {}),
    measures: runtime.metrics.measures(),
    unsavedWork: runtime.unsavedWork.has(),
  }
}

export const exposeAppSnapshot = (runtime: SnapshotRuntime, options: { renderCounts?: boolean } = {}): void => {
  const counter = options.renderCounts ? createRenderCounter() : undefined
  Object.defineProperty(globalThis, "__inlineApp", {
    configurable: true,
    get: () => appSnapshot(runtime, counter),
  })
}
