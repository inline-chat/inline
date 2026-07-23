import {
  updateDialogFollowMode,
  type Dialog,
  type RealtimeService,
} from "@inline/client"
import { DialogFollowMode } from "@inline-chat/protocol/core"
import { dialogPeerRoute, inputPeer } from "~/inline/data/peer"

export type ChatToolbarFollowPresentation = {
  title: "Follow Thread" | "Unfollow Thread"
  tooltip: string
  icon: "eye" | "check"
}

export const chatToolbarFollowPresentation = (
  isFollowing: boolean,
): ChatToolbarFollowPresentation => ({
  title: isFollowing ? "Unfollow Thread" : "Follow Thread",
  icon: isFollowing ? "check" : "eye",
  tooltip: isFollowing
    ? "Stop adding this thread in my sidebar for every message (will be shown only for mention and replies)"
    : "Add to my sidebar on new messages",
})

export const toggleReplyThreadFollow = ({
  dialog,
  realtime,
}: {
  dialog: Dialog
  realtime: RealtimeService
}) => {
  const isFollowing = dialog.followMode === DialogFollowMode.FOLLOWING
  return realtime.mutateAccepted(
    updateDialogFollowMode({
      peerId: inputPeer(dialogPeerRoute(dialog)),
      selection: isFollowing ? "unfollowed" : "following",
    }),
  )
}
