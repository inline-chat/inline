/**
 * The pane area: one pane per workspace pane, left to right, each showing
 * the view for its current destination through the registry
 * (`pane-registry.ts` decides the kind; `paneViews` maps it to a view).
 * Clicking or focusing inside a pane focuses it in the workspace, which is
 * what the address bar and Back follow.
 */

import { useSignal } from "@inline/reactive/react"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import { emptyDestination, type Destination, type PaneId, type PaneState } from "@inline/view"
import * as stylex from "@stylexjs/stylex"
import { memo, type ComponentType, type ReactNode } from "react"
import { ChatPane } from "../features/chat"
import { ChunkPane } from "./ChunkPane"
import { destinationDescription, destinationTitle, paneViewKind, type PaneViewKind } from "./pane-registry"
import type { AppServices } from "./services"
import type { ShellModel } from "./shell-model"
import { SidebarToggle } from "./SidebarColumn"
import { StripTitle, TitleStrip } from "./TitleStrip"

/** What every pane view receives. */
export type PaneViewProps = {
  readonly services: AppServices
  readonly shell: ShellModel
  readonly paneId: PaneId
  readonly destination: Destination
  /** Controls for the leading edge of the pane's title strip (the sidebar toggle while it is hidden). */
  readonly leading: ReactNode
}

function ChatPaneView(props: PaneViewProps) {
  return <ChatPane services={props.services} shell={props.shell} paneId={props.paneId} leading={props.leading} />
}

function EmptyPane(props: PaneViewProps) {
  return (
    <div {...stylex.props(styles.pane)}>
      <TitleStrip leading={props.leading} />
      <p {...stylex.props(styles.centered)}>No chat selected</p>
    </div>
  )
}

/** A destination whose view is not built yet: says where the pane is, and navigation keeps working. */
function UnbuiltPane(props: PaneViewProps) {
  const title = destinationTitle(props.destination)
  return (
    <div {...stylex.props(styles.pane)}>
      <TitleStrip leading={props.leading}>
        <StripTitle>{title}</StripTitle>
      </TitleStrip>
      <div {...stylex.props(styles.centered, styles.column)}>
        <p {...stylex.props(styles.text)}>{title} isn't available in this version yet.</p>
        <code dir="ltr" {...stylex.props(styles.path)}>
          {destinationDescription(props.destination)}
        </code>
      </div>
    </div>
  )
}

/** Chat info (`/c/<id>/info`): its body, model included, is the chat info chunk. */
function ChatInfoPaneView(props: PaneViewProps) {
  const destination = props.destination.kind === "chatInfo" ? props.destination : undefined
  return (
    <ChunkPane title="Chat Info" leading={props.leading} chunk={props.services.views.chatInfo} failedText="Chat info couldn't load." scrolls>
      {(chunk) =>
        destination ? (
          <chunk.ChatInfoBody
            key={destination.chatId}
            services={props.services}
            shell={props.shell}
            paneId={props.paneId}
            chatId={destination.chatId}
            tab={destination.tab}
          />
        ) : null
      }
    </ChunkPane>
  )
}

/** Settings (`/settings/<page>`): its body, model included, is the settings chunk. */
function SettingsPaneView(props: PaneViewProps) {
  return (
    <ChunkPane title="Settings" leading={props.leading} chunk={props.services.views.settings} failedText="Settings couldn't load.">
      {(chunk) => (
        <chunk.SettingsBody services={props.services} shell={props.shell} paneId={props.paneId} destination={props.destination} />
      )}
    </ChunkPane>
  )
}

/** The registry: destination kind to view. */
export const paneViews: Record<PaneViewKind, ComponentType<PaneViewProps>> = {
  chat: ChatPaneView,
  chatInfo: ChatInfoPaneView,
  settings: SettingsPaneView,
  empty: EmptyPane,
  unbuilt: UnbuiltPane,
}

export function PaneArea(props: { services: AppServices; shell: ShellModel }) {
  const panes = useSignal(props.shell.session.workspace.panes)
  const collapsed = useSignal(props.shell.sidebarCollapsed)
  return (
    <div {...stylex.props(styles.area)}>
      {panes.map((pane, index) => (
        <PaneFrame
          key={pane.id}
          services={props.services}
          shell={props.shell}
          pane={pane}
          separated={index > 0}
          showToggle={collapsed && index === 0}
        />
      ))}
    </div>
  )
}

const PaneFrame = memo(function PaneFrame(props: {
  services: AppServices
  shell: ShellModel
  pane: PaneState
  separated: boolean
  showToggle: boolean
}) {
  const { pane, shell } = props
  const destination = pane.entries[pane.index]?.destination ?? emptyDestination
  const View = paneViews[paneViewKind(destination)]
  const focus = () => {
    if (shell.session.workspace.focusedPaneId.peek() !== pane.id) shell.session.workspace.focus(pane.id)
  }
  return (
    <section
      aria-label={destinationTitle(destination)}
      onFocusCapture={focus}
      onPointerDownCapture={focus}
      {...stylex.props(styles.frame, props.separated && styles.separated)}
    >
      <View
        services={props.services}
        shell={shell}
        paneId={pane.id}
        destination={destination}
        leading={props.showToggle ? <SidebarToggle shell={shell} /> : null}
      />
    </section>
  )
})

const styles = stylex.create({
  area: {
    display: "flex",
    blockSize: "100%",
    minInlineSize: 0,
    minBlockSize: 0,
  },
  frame: {
    display: "flex",
    flexDirection: "column",
    flexGrow: 1,
    flexBasis: 0,
    minInlineSize: 0,
    minBlockSize: 0,
    backgroundColor: color.windowBackground,
  },
  separated: {
    borderInlineStartWidth: 1,
    borderInlineStartStyle: "solid",
    borderInlineStartColor: color.separator,
  },
  pane: {
    display: "flex",
    flexDirection: "column",
    blockSize: "100%",
    minBlockSize: 0,
  },
  centered: {
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    flexGrow: 1,
    margin: 0,
    color: color.secondaryLabel,
    fontFamily: font.familySystem,
    fontSize: font.sizeBody,
  },
  column: {
    flexDirection: "column",
    gap: space.sm,
  },
  text: {
    margin: 0,
  },
  path: {
    fontFamily: font.familyMono,
    fontSize: font.sizeCallout,
    color: color.tertiaryLabel,
  },
})
