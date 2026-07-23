import {
  useLocation,
  useNavigate,
  useRouter,
} from "@tanstack/react-router"
import * as stylex from "@stylexjs/stylex"
import { Icon } from "~/ui/Icon"
import { InlineIconButton } from "~/ui/InlineIconButton"
import { InlineMenu, type InlineMenuItem } from "~/ui/InlineMenu"
import { useInlineAppearancePreferences } from "~/inline/preferences/InlineAppearancePreferencesContext"
import { useMemo } from "react"
import { useInlineToast } from "~/ui/InlineToast"

export function SidebarFooter({
  onCreateThread,
}: {
  onCreateThread: () => Promise<void>
}) {
  const navigate = useNavigate()
  const router = useRouter()
  const location = useLocation()
  const { preferences, update } = useInlineAppearancePreferences()
  const toast = useInlineToast()
  const viewItems = useMemo<readonly InlineMenuItem[]>(
    () => [
      {
        label: "Large Sidebar Items",
        checked: preferences.sidebarItemSize === "large",
        onSelect: () => update({ sidebarItemSize: "large" }),
      },
      {
        label: "Compact Sidebar Items",
        checked: preferences.sidebarItemSize === "compact",
        onSelect: () => update({ sidebarItemSize: "compact" }),
      },
      {
        label: "Bubble Messages",
        checked: preferences.messageStyle === "bubble",
        separatorBefore: true,
        onSelect: () => update({ messageStyle: "bubble" }),
      },
      {
        label: "Minimal Messages",
        checked: preferences.messageStyle === "minimal",
        onSelect: () => update({ messageStyle: "minimal" }),
      },
    ],
    [preferences.messageStyle, preferences.sidebarItemSize, update],
  )
  const newItems = useMemo<readonly InlineMenuItem[]>(
    () => [
      {
        label: "New Thread",
        icon: "newThread",
        onSelect: () => {
          void onCreateThread().catch((cause) => {
            toast.show(
              cause instanceof Error
                ? cause.message
                : "Could not create a new thread.",
              "error",
            )
          })
        },
      },
    ],
    [onCreateThread, toast],
  )

  return (
    <footer {...stylex.props(styles.root)}>
      <InlineMenu
        side="top"
        items={viewItems}
        trigger={
          <InlineIconButton aria-label="View Options" title="View Options">
            <Icon name="sliders" size={14} />
          </InlineIconButton>
        }
      />
      <span {...stylex.props(styles.flex)} />
      <InlineMenu
        side="top"
        align="end"
        items={newItems}
        trigger={
          <InlineIconButton aria-label="New" title="New">
            <Icon name="plus" size={15} />
          </InlineIconButton>
        }
      />
      <InlineIconButton
        aria-label="Settings"
        title="Settings"
        selected={location.pathname === "/settings"}
        onClick={() => {
          // Settings has no async product dependency. Resolve its route match
          // before changing history so the cached account view replaces the
          // current detail atomically without a transition cover.
          void router
            .preloadRoute({ to: "/settings" })
            .then(() => navigate({ to: "/settings" }))
        }}
      >
        <Icon name="gear" size={14} />
      </InlineIconButton>
    </footer>
  )
}

const styles = stylex.create({
  root: {
    minHeight: 38,
    display: "flex",
    alignItems: "center",
    gap: 2,
    paddingInline: 12,
    paddingBlock: 6,
    flexShrink: 0,
  },
  flex: {
    flex: 1,
  },
})
