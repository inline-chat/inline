import {
  AbortMultipartUploadCommand,
  CompleteMultipartUploadCommand,
  CreateMultipartUploadCommand,
  DeleteObjectCommand,
  HeadObjectCommand,
  S3Client,
  UploadPartCommand,
} from "@aws-sdk/client-s3"
import { R2_ACCESS_KEY_ID, R2_BUCKET, R2_ENDPOINT, R2_SECRET_ACCESS_KEY } from "@in/server/env"

let r2MultipartClient: S3Client | undefined

const getR2MultipartClient = (): S3Client | undefined => {
  if (!R2_ACCESS_KEY_ID || !R2_SECRET_ACCESS_KEY || !R2_BUCKET || !R2_ENDPOINT) {
    return undefined
  }

  if (!r2MultipartClient) {
    r2MultipartClient = new S3Client({
      region: "auto",
      endpoint: R2_ENDPOINT,
      forcePathStyle: true,
      credentials: {
        accessKeyId: R2_ACCESS_KEY_ID,
        secretAccessKey: R2_SECRET_ACCESS_KEY,
      },
    })
  }

  return r2MultipartClient
}

const getRequiredBucket = (): string => {
  if (!R2_BUCKET) {
    throw new Error("R2_BUCKET is not configured")
  }
  return R2_BUCKET
}

export async function createMultipartUploadForR2(key: string, contentType: string): Promise<string> {
  const client = getR2MultipartClient()
  if (!client) {
    throw new Error("R2 multipart client is not initialized")
  }

  const response = await client.send(
    new CreateMultipartUploadCommand({
      Bucket: getRequiredBucket(),
      Key: key,
      ContentType: contentType,
    }),
  )

  if (!response.UploadId) {
    throw new Error("Failed to create multipart upload")
  }

  return response.UploadId
}

export async function uploadPartToR2Multipart(args: {
  key: string
  uploadId: string
  partNumber: number
  body: Uint8Array
}): Promise<string> {
  const client = getR2MultipartClient()
  if (!client) {
    throw new Error("R2 multipart client is not initialized")
  }

  const response = await client.send(
    new UploadPartCommand({
      Bucket: getRequiredBucket(),
      Key: args.key,
      UploadId: args.uploadId,
      PartNumber: args.partNumber,
      Body: args.body,
    }),
  )

  if (!response.ETag) {
    throw new Error("R2 did not return ETag for uploaded part")
  }

  return response.ETag
}

export async function completeR2MultipartUpload(args: {
  key: string
  uploadId: string
  parts: Array<{ partNumber: number; eTag: string }>
}): Promise<void> {
  const client = getR2MultipartClient()
  if (!client) {
    throw new Error("R2 multipart client is not initialized")
  }

  await client.send(
    new CompleteMultipartUploadCommand({
      Bucket: getRequiredBucket(),
      Key: args.key,
      UploadId: args.uploadId,
      MultipartUpload: {
        Parts: args.parts.map((part) => ({
          PartNumber: part.partNumber,
          ETag: part.eTag,
        })),
      },
    }),
  )
}

export async function abortR2MultipartUpload(key: string, uploadId: string): Promise<void> {
  const client = getR2MultipartClient()
  if (!client) {
    throw new Error("R2 multipart client is not initialized")
  }

  await client.send(
    new AbortMultipartUploadCommand({
      Bucket: getRequiredBucket(),
      Key: key,
      UploadId: uploadId,
    }),
  )
}

export async function getR2ObjectSize(key: string): Promise<number | null> {
  const client = getR2MultipartClient()
  if (!client) {
    throw new Error("R2 multipart client is not initialized")
  }

  const response = await client.send(
    new HeadObjectCommand({
      Bucket: getRequiredBucket(),
      Key: key,
    }),
  )

  if (response.ContentLength == null) {
    return null
  }

  return Number(response.ContentLength)
}

export async function deleteObjectFromR2(key: string): Promise<void> {
  const client = getR2MultipartClient()
  if (!client) {
    throw new Error("R2 multipart client is not initialized")
  }

  await client.send(
    new DeleteObjectCommand({
      Bucket: getRequiredBucket(),
      Key: key,
    }),
  )
}
