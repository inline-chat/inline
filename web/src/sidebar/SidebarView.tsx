import {
  DbObjectKind,
  useInlineClient,
  type Chat,
  type Dialog,
} from "@inline/client"
import { useLocation, useNavigate } from "@tanstack/react-router"
import * as stylex from "@stylexjs/stylex"
import { useCallback, useMemo } from "react"
import { useAppSpace } from "~/app/AppSpaceContext"
import { isSidebarChatListDialog, sortSidebarDialogs } from "~/inline/data/chat-list"
import { useInlineQuery } from "~/inline/data/react"
import { useInlineRuntimeState } from "~/inline/runtime/InlineRuntimeContext"
import { colors } from "../styles/tokens.stylex"
import { SidebarActionRow } from "./SidebarActionRow"
import { SidebarChatItem } from "./SidebarChatItem"
import { SidebarFooter } from "./SidebarFooter"
import { SidebarTopBar } from "./SidebarTopBar"
import {
  closeSidebarChat,
  toggleSidebarChatPinned,
  toggleSidebarChatRead,
} from "./SidebarChatActions"
import { NewThreadAction } from "./NewThreadAction"
import { SidebarNewThreadRow } from "./SidebarNewThreadRow"
import { useInlineAppearancePreferences } from "~/inline/preferences/InlineAppearancePreferencesContext"
import { useInlineToast } from "~/ui/InlineToast"
import { SidebarLoadingRowsView } from "./SidebarLoadingRowsView"

const allChats = () => true

export function SidebarView() {
  const navigate = useNavigate()
  const location = useLocation()
  const { selectedSpaceId } = useAppSpace()
  const { auth, realtime } = useInlineClient()
  const { cacheReady } = useInlineRuntimeState()
  const { preferences } = useInlineAppearancePreferences()
  const toast = useInlineToast()
  const largeItems = preferences.sidebarItemSize === "large"
  const predicate = useCallback(
    (dialog: Dialog) => isSidebarChatListDialog(dialog, selectedSpaceId ?? undefined),
    [selectedSpaceId],
  )
  const dialogs = useInlineQuery<DbObjectKind.Dialog, Dialog>(
    `sidebar:${selectedSpaceId ?? "home"}`,
    DbObjectKind.Dialog,
    predicate,
  )
  const chats = useInlineQuery<DbObjectKind.Chat, Chat>(
    "sidebar-chat-metadata",
    DbObjectKind.Chat,
    allChats,
  )
  const ordered = useMemo(() => {
    const chatsById = new Map(chats.map((chat) => [chat.id, chat]))
    return sortSidebarDialogs(dialogs, chatsById)
  }, [chats, dialogs])
  const closeChat = useCallback(
    (dialog: Dialog) => {
      void closeSidebarChat({
        dialog,
        currentPath: location.pathname,
        openAllChats: () => {
          void navigate({ to: "/chats" })
        },
        realtime,
      })
        .catch((cause: unknown) => {
          console.error("Could not close Inline chat from sidebar", cause)
          toast.show("Could not close chat", "error")
        })
    },
    [location.pathname, navigate, realtime, toast],
  )
  const togglePinned = useCallback(
    (dialog: Dialog) => {
      void toggleSidebarChatPinned({ dialog, realtime }).catch(
        (cause: unknown) => {
          console.error("Could not update Inline sidebar pin", cause)
          toast.show("Could not update pin", "error")
        },
      )
    },
    [realtime, toast],
  )
  const toggleRead = useCallback(
    (dialog: Dialog) => {
      void toggleSidebarChatRead({ dialog, realtime }).catch(
        (cause: unknown) => {
          console.error("Could not update Inline chat read state", cause)
          toast.show("Could not update read state", "error")
        },
      )
    },
    [realtime, toast],
  )
  const createNewThread = useCallback(async () => {
    await NewThreadAction.start({
      realtime,
      currentUserId: auth.getState().currentUserId,
      spaceId: selectedSpaceId,
      openThread: (chatId) => {
        void navigate({
          to: "/chat/$peerKind/$peerId",
          params: {
            peerKind: "chat",
            peerId: String(chatId),
          },
        })
      },
    })
  }, [auth, navigate, realtime, selectedSpaceId])

  return (
    <aside
      data-inline-sidebar
      data-inline-sidebar-item-size={preferences.sidebarItemSize}
      {...stylex.props(styles.root)}
    >
      <SidebarTopBar />
      <div {...stylex.props(styles.scroll)}>
        <SidebarActionRow
          icon="bubble"
          title="All Chats"
          selected={location.pathname === "/chats"}
          onClick={() => void navigate({ to: "/chats" })}
        />
        <div {...stylex.props(styles.separator)} />
        {!cacheReady ? <SidebarLoadingRowsView /> : null}
        {cacheReady
          ? ordered.map((dialog) => (
              <SidebarChatItem
                key={dialog.id}
                dialog={dialog}
                large={largeItems}
                onClose={closeChat}
                onTogglePinned={togglePinned}
                onToggleRead={toggleRead}
              />
            ))
          : null}
        {cacheReady ? (
          <SidebarNewThreadRow
            large={largeItems}
            onCreate={createNewThread}
          />
        ) : null}
      </div>
      <SidebarFooter onCreateThread={createNewThread} />
    </aside>
  )
}

const styles = stylex.create({
  root: {
    minWidth: 0,
    minHeight: 0,
    display: "flex",
    flexDirection: "column",
    overflow: "hidden",
    backgroundColor: colors.sidebar,
  },
  scroll: {
    minHeight: 0,
    flex: 1,
    overflowX: "hidden",
    overflowY: "auto",
    paddingBlock: 2,
  },
  separator: {
    height: 1,
    marginBlock: "8px 7px",
    marginInline: 17,
    backgroundColor: colors.separator,
  },
})
