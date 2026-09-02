export const IDENTITY_STORAGE_FORMAT = "identity_v1" as const

export type NativeUploadStorageFormat = typeof IDENTITY_STORAGE_FORMAT

export interface StorageFrameContext {
  readonly uploadId: Uint8Array
  readonly partIndex: number
  readonly logicalByteCount: number
  readonly logicalSha256: Uint8Array
}

export interface StoredFrameDescriptor extends StorageFrameContext {
  readonly storedByteCount: number
  readonly storedSha256: Uint8Array
}

export interface StorageObjectContext {
  readonly uploadId: Uint8Array
  readonly logicalByteCount: bigint
  readonly logicalSha256: Uint8Array
  /** Ordered lengths split the multipart object back into immutable frames. */
  readonly frames: readonly StoredFrameDescriptor[]
}

export interface StorageFrameEncoding {
  readonly bytes: Uint8Array
  readonly format: NativeUploadStorageFormat
}

/**
 * Versioned boundary applied before any upload byte reaches object storage.
 * Future authenticated encryption belongs here so staging and publication use
 * the same immutable encoded frames.
 */
export interface StorageFormatCodec {
  readonly format: NativeUploadStorageFormat
  encodeFrame(bytes: Uint8Array, context: StorageFrameContext): StorageFrameEncoding
  decodeObject(
    stream: ReadableStream<Uint8Array>,
    context: StorageObjectContext,
  ): ReadableStream<Uint8Array>
}

export class IdentityStorageFormatCodec implements StorageFormatCodec {
  readonly format = IDENTITY_STORAGE_FORMAT

  encodeFrame(bytes: Uint8Array, _context: StorageFrameContext): StorageFrameEncoding {
    return { bytes, format: this.format }
  }

  decodeObject(
    stream: ReadableStream<Uint8Array>,
    _context: StorageObjectContext,
  ): ReadableStream<Uint8Array> {
    return stream
  }
}

const identityCodec = new IdentityStorageFormatCodec()

export const storageCodecFor = (format: string | null): StorageFormatCodec | undefined => {
  if (format === IDENTITY_STORAGE_FORMAT) return identityCodec
  return undefined
}
