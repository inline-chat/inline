import * as stylex from "@stylexjs/stylex"
import { PropsWithChildren, ReactNode } from "react"

export const MainTabBar = () => {
  return (
    <div {...stylex.props(styles.tabBar)}>
      <MainTabItem kind={MainTabItem.Kinds.Picker} />
      <MainTabItem kind={MainTabItem.Kinds.Home} active={true} />
    </div>
  )
}

const MainTabItem = ({ kind, active = false }: { kind: Kinds; active?: boolean }) => {
  let icon
  switch (kind) {
    case Kinds.Picker:
      icon = "🏢"
      break

    case Kinds.Home:
      icon = "🏠"
      break

    case Kinds.Space:
      icon = <SpaceIcon />
      break
  }

  return (
    <div {...stylex.props(styles.tabItem, active && styles.activeTabItem)}>
      <div {...stylex.props(styles.iconView)}>{icon}</div>
    </div>
  )
}

const SpaceIcon = () => {
  return <div>S</div>
}

enum Kinds {
  Picker = 0,
  Home = 1,
  Space = 2,
}
MainTabItem.Kinds = Kinds

const styles = stylex.create({
  tabBar: {
    appRegion: "drag",
    height: 44,
    width: "100%",
    display: "flex",
    flexDirection: "row",
    paddingTop: 5,
  },

  tabItem: {
    width: "auto",
    height: 34,
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    appRegion: "no-drag", // prevents hover

    paddingLeft: 10,
    paddingRight: 10,
    borderRadius: 10,
    marginRight: 6,

    backgroundColor: {
      default: "rgba(0,0,0,0.0)",
      ":hover": "rgba(0,0,0,0.1)",
    },
  },

  activeTabItem: {
    backgroundColor: "rgba(255,255,255,1)",
  },

  iconView: {
    width: 21,
    height: 21,
    display: "flex",
    alignItems: "center",
    justifyContent: "center",
    borderRadius: 7,
    backgroundColor: "rgba(0,0,0,0.05)",
  },
})
