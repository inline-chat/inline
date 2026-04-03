import { PropsWithChildren } from "react"
import * as stylex from "@stylexjs/stylex"

export const SidebarHeader = () => {
  return <div {...stylex.props(styles.sidebarHeader)}>🏠 Home</div>
}

const styles = stylex.create({
  sidebarHeader: {
    height: 42,
    width: "100%",
    position: "relative",
  },
})
