import { FILES_PATH_PREFIX } from "@in/server/config"
import { getR2 } from "@in/server/libs/r2"

export { FILES_PATH_PREFIX } from "@in/server/config"

export const getSignedUrl = (path: string) => {
  let r2 = getR2()
  if (!r2) return null

  let url = r2.file(`${FILES_PATH_PREFIX}/${path}`).presign({
    acl: "public-read",
    expiresIn: 60 * 60 * 24 * 7, // 1 week
  })
  return url
}
