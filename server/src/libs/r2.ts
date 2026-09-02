import { S3Client } from "@aws-sdk/client-s3"
import { R2_ACCESS_KEY_ID, R2_SECRET_ACCESS_KEY, R2_BUCKET, R2_ENDPOINT } from "@in/server/env"

let r2: Bun.S3Client | undefined = undefined
let r2Aws: { bucket: string; client: S3Client } | undefined

export const getR2 = (): Bun.S3Client | undefined => {
  if (!R2_ACCESS_KEY_ID || !R2_SECRET_ACCESS_KEY || !R2_BUCKET || !R2_ENDPOINT) {
    return undefined
  }

  if (!r2) {
    r2 = new Bun.S3Client({
      accessKeyId: R2_ACCESS_KEY_ID,
      secretAccessKey: R2_SECRET_ACCESS_KEY,
      bucket: R2_BUCKET,
      endpoint: R2_ENDPOINT,
    })
  }

  return r2
}

/** AWS transport used by operations that require an AbortSignal-aware request. */
export const getR2Aws = (): { bucket: string; client: S3Client } | undefined => {
  if (!R2_ACCESS_KEY_ID || !R2_SECRET_ACCESS_KEY || !R2_BUCKET || !R2_ENDPOINT) {
    return undefined
  }

  if (!r2Aws) {
    r2Aws = {
      bucket: R2_BUCKET,
      client: new S3Client({
        credentials: {
          accessKeyId: R2_ACCESS_KEY_ID,
          secretAccessKey: R2_SECRET_ACCESS_KEY,
        },
        endpoint: R2_ENDPOINT,
        region: "auto",
        requestChecksumCalculation: "WHEN_REQUIRED",
      }),
    }
  }

  return r2Aws
}
