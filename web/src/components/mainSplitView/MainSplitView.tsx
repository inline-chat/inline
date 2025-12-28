import * as stylex from "@stylexjs/stylex"
import { PropsWithChildren, ReactNode } from "react"
import { MainTabBar } from "~/components/mainTabBar/MainTabBar"
import { Spacer } from "~/components/primitives/primitives"

export const MainSplitView = ({ children }: { children: ReactNode }) => {
  return <div {...stylex.props(styles.container)}>{children}</div>
}

const MainSidebar = ({ children }: { children?: ReactNode }) => {
  return (
    <div {...stylex.props(styles.sidebar)}>
      <div {...stylex.props(styles.topBar)} />
      <Spacer h={44} />
      {children}
    </div>
  )
}

const MainContentView = ({ children }: { children: ReactNode }) => {
  return (
    <div {...stylex.props(styles.content)}>
      <MainTabBar />
      <div {...stylex.props(styles.innerContent)}>{children}</div>
    </div>
  )
}

// const MainTabBar = ({ children }: { children: ReactNode }) => {
//   return (
//     <div {...stylex.props(styles.tabBar)}>
//       <div {...stylex.props(styles.innerContent)}>{children}</div>
//     </div>
//   )
// }

MainSplitView.Sidebar = MainSidebar
MainSplitView.Content = MainContentView

const styles = stylex.create({
  topBar: {
    appRegion: "drag",
    height: 42,
    width: "100%",
    position: "absolute",
    top: 0,
    left: 0,
    right: 0,
    zIndex: 100,
  },

  container: {
    height: "100%",
    width: "100%",
    display: "flex",
    overflow: "hidden",

    backgroundColor: "rgba(255,255,255,0.3)", // theme
  },

  sidebar: {
    width: 240,
    display: "flex",
    flexDirection: "column",
    overflow: "hidden",
    position: "relative",
  },

  content: {
    height: "100%",
    flexGrow: 1,
    // paddingTop: 6,
    paddingBottom: 6,
    paddingRight: 6,
    paddingLeft: 6,

    display: "flex",
    flexDirection: "column",
    justifyContent: "center",
    alignItems: "center",
  },

  innerContent: {
    maxHeight: "100%",
    flexGrow: 1,
    width: "100%",
    position: "relative",
    borderRadius: 11,
    backgroundColor: "white", // theme
    boxShadow: "0px 1px 3px rgba(0,0,0,0.09)",
  },
})
