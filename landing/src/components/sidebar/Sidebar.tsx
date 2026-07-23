import * as stylex from "@stylexjs/stylex"
import { SidebarHeader } from "~/components/sidebar/SidebarHeader"
import { SidebarChatItem } from "~/components/sidebar/SidebarChatItem"
import { useHomeDialogs } from "~/hooks/data"
import { getChats, getMe } from "@inline/client"
import { useQuery } from "@inline/client/react/useQuery"

export const Sidebar = () => {
  const dialogs = useHomeDialogs()

  useQuery(getChats())
  useQuery(getMe())

  return (
    <div {...stylex.props(styles.sidebar)}>
      <SidebarHeader />

      <div {...stylex.props(styles.sectionHeader)}>Chats</div>

      <div {...stylex.props(styles.scrollView)}>
        <div {...stylex.props(styles.list)}>
          {dialogs.map((dialog) => (
            <SidebarChatItem key={dialog.id} dialog={dialog} />
          ))}
        </div>
      </div>
    </div>
  )
}

const styles = stylex.create({
  sidebar: {
    position: "relative",
    overflow: "hidden",
    flexGrow: 0,
    display: "flex",
    flexDirection: "column",
  },
  userLabel: {
    paddingLeft: 12,
    paddingRight: 12,
    fontSize: 12,
    color: "rgba(20,20,20,0.6)",
  },
  sectionHeader: {
    paddingLeft: 12,
    paddingRight: 12,
    marginTop: 14,
    marginBottom: 6,
    fontSize: 11,
    textTransform: "uppercase",
    letterSpacing: 0.6,
    color: "rgba(20,20,20,0.5)",
  },
  scrollView: {
    overflow: "scroll",
  },
  list: {
    display: "flex",
    flexDirection: "column",
    gap: 2,
  },
})
