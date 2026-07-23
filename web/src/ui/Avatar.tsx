import type { User } from "@inline/client"
import * as stylex from "@stylexjs/stylex"
import { useInlineMediaUrl } from "~/inline/media/InlineMediaContext"
import { inlineTinyThumbnailDataUrl } from "~/inline/media/InlineTinyThumbnail"

const initials = (user?: User) => {
  const first = user?.firstName?.trim().at(0)
  const last = user?.lastName?.trim().at(0)
  return `${first ?? ""}${last ?? ""}`.toUpperCase() || "?"
}

export function UserAvatar({
  user,
  size = 32,
}: {
  user?: User
  size?: number
}) {
  const remoteUrl = user?.profilePhoto?.cdnUrl
  const url = useInlineMediaUrl(user?.profilePhoto?.fileUniqueId ?? remoteUrl, remoteUrl)
  const tinyThumbnailUrl = inlineTinyThumbnailDataUrl(
    user?.profilePhoto?.strippedThumb,
  )
  return (
    <span
      aria-hidden="true"
      style={{ width: size, height: size }}
      {...stylex.props(styles.avatar)}
    >
      {!tinyThumbnailUrl ? initials(user) : null}
      {tinyThumbnailUrl ? (
        <img
          src={tinyThumbnailUrl}
          alt=""
          {...stylex.props(styles.image, styles.tinyThumbnail)}
        />
      ) : null}
      {url ? (
        <img
          src={url}
          alt=""
          {...stylex.props(styles.image)}
        />
      ) : null}
    </span>
  )
}

export function ThreadAvatar({ emoji, size = 32 }: { emoji?: string; size?: number }) {
  return (
    <span
      aria-hidden="true"
      style={{ width: size, height: size, fontSize: size * 0.55 }}
      {...stylex.props(styles.avatar, styles.thread)}
    >
      {emoji?.trim() || "💬"}
    </span>
  )
}

const styles = stylex.create({
  avatar: {
    position: "relative",
    display: "inline-flex",
    flexShrink: 0,
    alignItems: "center",
    justifyContent: "center",
    overflow: "hidden",
    borderRadius: "50%",
    backgroundColor: "light-dark(#dadada, #4a4a4e)",
    color: "light-dark(rgba(0, 0, 0, 0.55), rgba(255, 255, 255, 0.72))",
    fontSize: 11,
    fontWeight: 600,
    userSelect: "none",
  },
  image: {
    position: "absolute",
    inset: 0,
    width: "100%",
    height: "100%",
    objectFit: "cover",
  },
  tinyThumbnail: {
    filter: "blur(5px) saturate(1.25)",
    transform: "scale(1.15)",
  },
  thread: {
    borderRadius: 9,
    backgroundColor: "light-dark(rgba(0, 0, 0, 0.055), rgba(255, 255, 255, 0.075))",
  },
})
