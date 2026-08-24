import { getR2 } from "@in/server/libs/r2"

const STAGING_PREFIX = "inline-upload-parts/v1"

export interface UploadPartStore {
  put(input: {
    uploadId: Uint8Array
    partIndex: number
    sha256: Uint8Array
    data: Uint8Array
  }): Promise<string>
  read(objectKey: string): Promise<Uint8Array>
  remove(objectKey: string): Promise<void>
}

const requireR2 = () => {
  const r2 = getR2()
  if (!r2) throw new UploadPartStorageUnavailableError()
  return r2
}

const objectKey = ({
  uploadId,
  partIndex,
  sha256,
}: {
  uploadId: Uint8Array
  partIndex: number
  sha256: Uint8Array
}): string => {
  const id = Buffer.from(uploadId).toString("base64url")
  const digest = Buffer.from(sha256).toString("hex")
  return `${STAGING_PREFIX}/${id}/${partIndex}-${digest}`
}

export class R2UploadPartStore implements UploadPartStore {
  async put(input: {
    uploadId: Uint8Array
    partIndex: number
    sha256: Uint8Array
    data: Uint8Array
  }): Promise<string> {
    const key = objectKey(input)
    await requireR2().file(key).write(input.data, { type: "application/octet-stream" })
    return key
  }

  async read(key: string): Promise<Uint8Array> {
    try {
      return new Uint8Array(await requireR2().file(key).arrayBuffer())
    } catch (cause) {
      throw new UploadPartStorageUnavailableError({ cause })
    }
  }

  async remove(key: string): Promise<void> {
    await requireR2().file(key).delete()
  }
}

export class UploadPartStorageUnavailableError extends Error {
  constructor(options?: ErrorOptions) {
    super("Upload part storage is unavailable", options)
    this.name = "UploadPartStorageUnavailableError"
  }
}
