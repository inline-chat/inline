import {
  markAsUnread,
  readMessages,
  updateDialogOrder,
  updateDialogOpen,
  type Dialog,
  type RealtimeService,
} from "@inline/client"
import { dialogPeerRoute, inputPeer } from "~/inline/data/peer"

export const sidebarChatPath = (dialog: Dialog) => {
  const peer = dialogPeerRoute(dialog)
  return `/chat/${peer.peerKind}/${peer.peerId}`
}

export const toggleSidebarChatPinned = ({
  dialog,
  realtime,
}: {
  dialog: Dialog
  realtime: RealtimeService
}) =>
  realtime.mutateAccepted(
    updateDialogOrder({
      peerId: inputPeer(dialogPeerRoute(dialog)),
      pinned: !dialog.pinned,
    }),
  )

export const toggleSidebarChatRead = ({
  dialog,
  realtime,
}: {
  dialog: Dialog
  realtime: RealtimeService
}) => {
  const peerId = inputPeer(dialogPeerRoute(dialog))
  const unread = Boolean(
    dialog.unreadMark || (dialog.unreadCount ?? 0) > 0,
  )
  return realtime.mutateAccepted(
    unread ? readMessages({ peerId }) : markAsUnread({ peerId }),
  )
}

/** Native Inbox close: leave the active route first, then persist open=false. */
export const closeSidebarChat = ({
  dialog,
  currentPath,
  openAllChats,
  realtime,
}: {
  dialog: Dialog
  currentPath: string
  openAllChats: () => void
  realtime: RealtimeService
}) => {
  if (currentPath === sidebarChatPath(dialog)) {
    openAllChats()
  }
  return realtime.mutateAccepted(
    updateDialogOpen({
      peerId: inputPeer(dialogPeerRoute(dialog)),
      open: false,
    }),
  )
}
