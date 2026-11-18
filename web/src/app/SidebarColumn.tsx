/**
 * The sidebar column: its title strip (the toggle and the update
 * affordance), the chat list (`SidebarView` from `web/src/features/sidebar/`
 * over the session's `SidebarModel`), and the account footer with Sign Out.
 */

import { useElement, useSignal } from "@inline/reactive/react"
import { Button, IconButton } from "@inline/ui/react"
import { color } from "@inline/ui/tokens/color.stylex"
import { font } from "@inline/ui/tokens/font.stylex"
import { space } from "@inline/ui/tokens/space.stylex"
import { userDisplayName } from "@inline/chat-ui"
import * as stylex from "@stylexjs/stylex"
import { FOCUS_REGION_ATTRIBUTE } from "./focus"
import { SidebarIcon } from "./icons"
import { SidebarView } from "../features/sidebar"
import type { AppServices } from "./services"
import type { ShellModel } from "./shell-model"
import { UpdateButton } from "./StatusSurfaces"
import { StripTitle, TitleStrip } from "./TitleStrip"

export function SidebarColumn(props: { services: AppServices; shell: ShellModel }) {
  const { shell, services } = props
  const ref = useElement(shell.sidebarElement)
  return (
    <nav ref={ref} aria-label="Sidebar" {...{ [FOCUS_REGION_ATTRIBUTE]: "sidebar" }} {...stylex.props(styles.column)}>
      <TitleStrip
        tone="sidebar"
        leading={<SidebarToggle shell={shell} />}
        trailing={<UpdateButton services={services} />}
      >
        <StripTitle>Inline</StripTitle>
      </TitleStrip>
      <div {...stylex.props(styles.list)}>
        <SidebarView
          model={shell.session.sidebar}
          ready={shell.sidebarReady}
          actions={shell.session.actions.sidebarActionsFor}
          typingFor={shell.typingFor}
          handle={shell.sidebarHandle}
        />
      </div>
      <AccountFooter services={services} shell={shell} />
    </nav>
  )
}

export function SidebarToggle(props: { shell: ShellModel }) {
  const collapsed = useSignal(props.shell.sidebarCollapsed)
  return (
    <IconButton
      label={collapsed ? "Show Sidebar" : "Hide Sidebar"}
      icon={<SidebarIcon />}
      size="small"
      aria-expanded={!collapsed}
      onClick={() => props.shell.toggleSidebar()}
    />
  )
}

function AccountFooter(props: { services: AppServices; shell: ShellModel }) {
  const me = useSignal(props.shell.session.me)
  return (
    <footer {...stylex.props(styles.footer)}>
      <span {...stylex.props(styles.name)}>
        <span dir="auto">{me ? userDisplayName(me) : ""}</span>
      </span>
      <Button size="small" variant="plain" onClick={() => void props.services.runtime.signOut()}>
        Sign Out
      </Button>
    </footer>
  )
}

const styles = stylex.create({
  column: {
    display: "flex",
    flexDirection: "column",
    blockSize: "100%",
    minInlineSize: 0,
    backgroundColor: color.sidebarBackground,
  },
  list: {
    display: "flex",
    flexDirection: "column",
    flexGrow: 1,
    minBlockSize: 0,
  },
  footer: {
    display: "flex",
    alignItems: "center",
    gap: space.md,
    flexShrink: 0,
    paddingBlock: space.sm,
    paddingInline: space.lg,
    borderBlockStartWidth: 1,
    borderBlockStartStyle: "solid",
    borderBlockStartColor: color.separator,
  },
  name: {
    flexGrow: 1,
    textAlign: "start",
    minInlineSize: 0,
    overflow: "hidden",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
    color: color.secondaryLabel,
    fontFamily: font.familySystem,
    fontSize: font.sizeCallout,
  },
})
