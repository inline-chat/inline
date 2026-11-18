/**
 * The signed-in window, as the Mac app lays it out: the sidebar on the
 * leading side and the pane area on the other, in a resizable split whose
 * sizes and collapse are kept per account. The status the session reports
 * picks a surface: a full-pane screen when the data cannot be used, a quiet
 * banner for storage, nothing for ready (connection states live in the chat
 * header). Loaded as its own chunk.
 *
 * After its first paint the shell loads the code it did not need to paint
 * (`shell-warmup.ts`): message content at once (a frame and a task after the
 * paint: rows on screen are waiting for it), then on the idle lane, in the
 * order of `afterFirstPaint` in `view-chunks.ts`, the message action layers,
 * the menu kit, the composer's autocomplete and paste, emoji, Quick Search
 * and Settings, and last the emoji table. Each also loads on first intent.
 *
 * Toasts: the kit's region sits in the inline-end, block-end corner of the
 * message list of the chat pane mounted last (each attaches `shell.toasts.container`),
 * above the composer, never over it.
 */

import { browserClock } from "@inline/reactive"
import { useElement, useModel, useSignal } from "@inline/reactive/react"
import { SplitView, ToastRegion } from "@inline/ui/react"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import type { AccountSession } from "@inline/view/features"
import * as stylex from "@stylexjs/stylex"
import { attachmentStripChunk } from "../features/composer/strip-chunk"
import { PaneArea } from "./PaneArea"
import { browserAfterPaint } from "./perf"
import type { AppServices } from "./services"
import { MAIN_PANE, ShellModel, SIDEBAR_PANE } from "./shell-model"
import { SidebarColumn } from "./SidebarColumn"
import { NotificationPromptBanner, StatusBanner, StatusScreen } from "./StatusSurfaces"
import { queueShellWarmup, shellWarmers } from "./shell-warmup"

export function Shell(props: { services: AppServices; session: AccountSession }) {
  const { services, session } = props
  const shell = useModel(
    () =>
      new ShellModel({
        runtime: services.runtime,
        session,
        nextFrame: services.nextFrame,
        document,
        copyText: services.copyText,
        origin: location.origin,
        attachmentsChunk: services.views.attachments,
        attachmentStrip: () => attachmentStripChunk.load(),
        mediaViewerChunk: services.views.mediaViewer,
        messageLayers: async (callbacks) => {
          const chunk = await services.views.layers.load()
          if (!chunk) throw new Error("Message layers did not load")
          return chunk.kitLayers(callbacks)
        },
        keyboard: services.runtime.app.keyboard,
        emoji: services.emoji,
        quickSearch: async () => {
          const chunk = await services.views.quickSearch.load()
          if (!chunk) throw new Error("Quick Search did not load")
          // Local message search, and people from the server (`searchUsers`). The server's message
          // search covers one chat, so it is find in chat's second source, not Quick Search's.
          return (current) =>
            chunk.wireSessionQuickSearch(current, {
              clock: browserClock(),
              storage: localStorage,
              keyboard: services.runtime.app.keyboard,
            })
        },
      }),
    [session],
  )
  const marker = useModel(() => (_element: HTMLElement) => {
    services.runtime.metrics.markAfterPaint("shellPaint")
    const { views } = services
    // Content right after the paint (rows on screen wait for it); the rest on the idle lane (shell-warmup.ts).
    queueShellWarmup({
      afterPaint: browserAfterPaint,
      warmup: services.warmup,
      warmers: shellWarmers({
        content: () => views.content.load(),
        layers: () => shell.messageActions.loadLayers(),
        quickSearch: () => shell.loadQuickSearch(),
        settings: () => views.settings.load(),
        ...(shell.emoji ? { emoji: shell.emoji } : {}),
      }),
    })
  })
  const paintRef = useElement(marker)
  const surface = useSignal(shell.surface)
  if (surface.kind === "screen" && surface.screen === "signingOut") {
    // The core is erasing the account and refuses every intent: nothing here may act until the gate moves on.
    return (
      <div ref={paintRef} {...stylex.props(styles.window)}>
        <StatusScreen services={services} screen="signingOut" />
      </div>
    )
  }
  return (
    <div ref={paintRef} {...stylex.props(styles.window)}>
      <SplitView
        controller={shell.split}
        style={styles.split}
        panes={[
          { id: SIDEBAR_PANE, content: <SidebarColumn services={services} shell={shell} /> },
          { id: MAIN_PANE, content: <MainColumn services={services} shell={shell} /> },
        ]}
      />
      <QuickSearch services={services} shell={shell} />
      <MessageLayers services={services} shell={shell} />
      <ToastRegion queue={shell.toasts} />
      <MediaViewerLayer services={services} shell={shell} />
    </div>
  )
}

/** The reaction picker and the confirmation alert, once their chunk is there (both closed until asked). */
function MessageLayers(props: { services: AppServices; shell: ShellModel }) {
  const chunk = useSignal(props.services.views.layers.value)
  const layers = useSignal(props.shell.messageActions.layers)
  if (!chunk || !layers) return null
  return <chunk.MessageActionLayers actions={props.shell.messageActions} layers={layers} emoji={props.shell.emoji} />
}

/** The media viewer while one is open (its chunk loaded on the first photo or video opened). */
function MediaViewerLayer(props: { services: AppServices; shell: ShellModel }) {
  const chunk = useSignal(props.services.views.mediaViewer.value)
  const viewer = useSignal(props.shell.mediaViewer?.viewer ?? noViewer)
  if (!chunk || !viewer) return null
  return <chunk.MediaViewer model={viewer} />
}

const noViewer = { get: () => undefined, peek: () => undefined }

/** The palette, once Quick Search's chunk is there (a closed `<dialog>`: nothing shows until it opens). */
function QuickSearch(props: { services: AppServices; shell: ShellModel }) {
  const chunk = useSignal(props.services.views.quickSearch.value)
  const wiring = useSignal(props.shell.quickSearch)
  if (!chunk || !wiring) return null
  return <chunk.QuickSearchPalette quickSearch={wiring} />
}

function MainColumn(props: { services: AppServices; shell: ShellModel }) {
  const surface = useSignal(props.shell.surface)
  const core = useSignal(props.shell.session.coreResource)
  if (surface.kind === "screen") {
    return <StatusScreen services={props.services} screen={surface.screen} failure={core?.failure} />
  }
  return (
    <main {...stylex.props(styles.main)}>
      {surface.kind === "banner" && <StatusBanner banner={surface.banner} />}
      <NotificationPromptBanner services={props.services} />
      <div {...stylex.props(styles.panes)}>
        <PaneArea services={props.services} shell={props.shell} />
      </div>
    </main>
  )
}

const styles = stylex.create({
  window: {
    blockSize: "100%",
    backgroundColor: color.windowBackground,
    color: color.label,
    fontFamily: font.familySystem,
    fontSize: font.sizeBody,
  },
  split: {
    blockSize: "100%",
  },
  main: {
    display: "flex",
    flexDirection: "column",
    blockSize: "100%",
    minInlineSize: 0,
  },
  panes: {
    flexGrow: 1,
    minBlockSize: 0,
  },
})
