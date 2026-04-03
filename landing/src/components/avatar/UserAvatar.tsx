import { User } from "@inline/client"
import * as stylex from "@stylexjs/stylex"
import { useCachedImage } from "../../lib/imageCache"

export const UserAvatar = ({ user, size = 32 }: { user: User; size?: number }) => {
  const photo = user.profilePhoto
  const { imageProps } = useCachedImage(photo?.fileUniqueId, photo?.cdnUrl)

  return (
    <div {...stylex.props(styles.circle)} style={{ width: size, height: size }}>
      <img {...stylex.props(styles.image)} {...imageProps} loading="eager" />
    </div>
  )
}

const styles = stylex.create({
  circle: {
    borderRadius: "50%",
    overflow: "hidden",
  },

  image: {
    width: "100%",
    height: "100%",
    objectFit: "cover",
  },
})
