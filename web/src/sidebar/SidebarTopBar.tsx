import { DbObjectKind, type Space } from "@inline/client"
import type { SpaceID } from "@inline/ids"
import * as stylex from "@stylexjs/stylex"
import { useCallback, useMemo } from "react"
import { useAppSpace } from "~/app/AppSpaceContext"
import { useInlineQuery } from "~/inline/data/react"
import { colors, metrics } from "../styles/tokens.stylex"
import { Icon } from "~/ui/Icon"
import { InlineMenu, type InlineMenuItem } from "~/ui/InlineMenu"

const allSpaces = () => true

export function SidebarTopBar() {
  const { selectedSpaceId, selectSpace } = useAppSpace()
  const spaces = useInlineQuery<DbObjectKind.Space, Space>("spaces", DbObjectKind.Space, allSpaces)
  const selectedSpace = spaces.find((space) => space.id === selectedSpaceId)
  const choose = useCallback(
    (spaceId?: SpaceID) => {
      selectSpace(spaceId)
    },
    [selectSpace],
  )
  const items = useMemo<readonly InlineMenuItem[]>(
    () => [
      {
        label: "Home",
        icon: "home",
        checked: selectedSpaceId == null,
        onSelect: () => choose(),
      },
      ...spaces
        .slice()
        .sort((a, b) => a.name.localeCompare(b.name))
        .map((space) => ({
          label: space.name,
          checked: space.id === selectedSpaceId,
          onSelect: () => choose(space.id),
        })),
    ],
    [choose, selectedSpaceId, spaces],
  )

  return (
    <header data-inline-sidebar-topbar {...stylex.props(styles.root)}>
      {selectedSpaceId != null ? (
        <button type="button" aria-label="Home" onClick={() => choose()} {...stylex.props(styles.home)}>
          <Icon name="home" size={15} />
        </button>
      ) : null}
      <div {...stylex.props(styles.location)}>
        <InlineMenu
          items={items}
          trigger={
            <button
              type="button"
              aria-label="Choose space"
              {...stylex.props(styles.locationButton)}
            >
              <span {...stylex.props(styles.locationIcon)}>{selectedSpace ? "✦" : <Icon name="home" size={14} />}</span>
              <span {...stylex.props(styles.locationTitle)}>{selectedSpace?.name ?? "Home"}</span>
              <Icon name="chevronDown" size={13} />
            </button>
          }
        >
          {null}
        </InlineMenu>
      </div>
    </header>
  )
}

const styles = stylex.create({
  root: {
    height: metrics.toolbarHeight,
    display: "flex",
    alignItems: "center",
    gap: 5,
    paddingInline: 10,
    position: "relative",
    flexShrink: 0,
    WebkitAppRegion: "drag",
  },
  home: {
    width: 26,
    height: 26,
    display: "grid",
    placeItems: "center",
    padding: 0,
    borderRadius: 7,
    backgroundColor: {
      default: "transparent",
      ":hover": colors.hovered,
    },
    color: colors.textSecondary,
    WebkitAppRegion: "no-drag",
  },
  location: {
    minWidth: 0,
    position: "relative",
    flex: 1,
  },
  locationButton: {
    width: "100%",
    height: 28,
    display: "flex",
    alignItems: "center",
    gap: 7,
    paddingInline: 6,
    borderRadius: 7,
    backgroundColor: {
      default: "transparent",
      ":hover": colors.hovered,
    },
    color: colors.textPrimary,
    fontSize: 13,
    WebkitAppRegion: "no-drag",
  },
  locationIcon: {
    width: 18,
    height: 18,
    display: "grid",
    placeItems: "center",
    color: colors.textSecondary,
  },
  locationTitle: {
    minWidth: 0,
    overflow: "hidden",
    flex: 1,
    fontWeight: 500,
    textAlign: "left",
    textOverflow: "ellipsis",
    whiteSpace: "nowrap",
  },
})
