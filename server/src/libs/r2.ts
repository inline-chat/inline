import { S3Client } from "bun"
import { R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_BUCKET, R2_ENDPOINT } from "@in/server/env"

let r2: S3Client | undefined = undefined

export const getR2 = (): S3Client | undefined => {
  if (!R2_ACCESS_KEY_ID || !R2_SECRET_ACCESS_KEY || !R2_BUCKET || !R2_ENDPOINT) {
    return undefined
  }

  if (!r2) {
    r2 = new S3Client({
      accessKeyId: R2_ACCESS_KEY_ID,
      secretAccessKey: R2_SECRET_ACCESS_KEY,
      bucket: R2_BUCKET,
      endpoint: R2_ENDPOINT,
    })
  }

  return r2
}
