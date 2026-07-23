import * as stylex from "@stylexjs/stylex"
import type { SpaceID } from "@inline/ids"
import { useMemo, useState } from "react"
import { AppSpaceContext } from "./AppSpaceContext"
import { AppRouteOutlet } from "./AppRouteOutlet"
import { SidebarView } from "~/sidebar/SidebarView"
import { colors, metrics } from "../styles/tokens.stylex"
import { InlineAppearancePreferencesProvider } from "~/inline/preferences/InlineAppearancePreferencesContext"
import { InlineToastProvider } from "~/ui/InlineToast"

export function AppShell() {
  const [selectedSpaceId, selectSpace] = useState<SpaceID>()
  const space = useMemo(() => ({ selectedSpaceId, selectSpace }), [selectedSpaceId])

  return (
    <InlineAppearancePreferencesProvider>
      <InlineToastProvider>
        <AppSpaceContext.Provider value={space}>
          <div data-inline-app-shell {...stylex.props(styles.window)}>
            <SidebarView />
            <main data-inline-app-detail {...stylex.props(styles.detail)}>
              <AppRouteOutlet />
            </main>
          </div>
        </AppSpaceContext.Provider>
      </InlineToastProvider>
    </InlineAppearancePreferencesProvider>
  )
}

const styles = stylex.create({
  window: {
    width: "100%",
    height: "100%",
    display: "grid",
    gridTemplateColumns: `minmax(${metrics.sidebarMinWidth}, ${metrics.sidebarIdealWidth}) minmax(315px, 1fr)`,
    overflow: "hidden",
    backgroundColor: colors.window,
    color: colors.textPrimary,
  },
  detail: {
    minWidth: 315,
    minHeight: 0,
    position: "relative",
    overflow: "hidden",
    borderLeftWidth: 1,
    borderLeftStyle: "solid",
    borderLeftColor: colors.separator,
    backgroundColor: colors.content,
  },
})
