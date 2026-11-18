/**
 * The model host with a media core: the media package's scripted transfer
 * server answers upload RPCs and serves signed HTTP ranges, and the byte
 * store outlives a restart, as OPFS would. Upload completions are given the
 * media object the real server returns (the transfer server leaves it out).
 */
import { Method, type RpcResult, type UploadComplete } from "@inline-chat/protocol/core"
import type { MediaResource } from "@inline/core-protocol"
import { MemoryByteStore, systemClock, type MediaRpcCall } from "../../media"
import { TransferServer } from "../../media/testing/transfer-server"
import type { CoreHostOptions } from "../core-host"
import { ModelHost } from "./model-host"
import type { TestContext } from "./fixtures"

let mediaIds = 9_000n
const idsByFile = new Map<string, bigint>()

export const withMedia = (complete: UploadComplete, mimeType: string | undefined): UploadComplete => {
  if (complete.media.oneofKind) return complete
  const id = idsByFile.get(complete.fileUniqueId) ?? mediaIds++
  idsByFile.set(complete.fileUniqueId, id)
  const date = 1n
  if (mimeType?.startsWith("image/")) {
    return {
      ...complete,
      media: {
        oneofKind: "photo",
        photo: {
          id,
          date,
          format: 1,
          fileUniqueId: complete.fileUniqueId,
          sizes: [{ type: "f", w: 800, h: 600, size: 0, fileUniqueId: complete.fileUniqueId } as never],
        },
      },
    } as UploadComplete
  }
  return {
    ...complete,
    media: {
      oneofKind: "document",
      document: { id, date, fileName: "file", mimeType: mimeType ?? "", size: 0n, fileUniqueId: complete.fileUniqueId } as never,
    },
  } as UploadComplete
}

export class MediaModelHost extends ModelHost {
  readonly transfers: TransferServer
  readonly bytes: MemoryByteStore

  constructor(options: { host?: Partial<CoreHostOptions> } = {}) {
    const transfers = new TransferServer(systemClock)
    const bytes = new MemoryByteStore(systemClock)
    const holder: { rpc?: MediaRpcCall } = {}
    super({
      host: {
        media: {
          store: () => bytes,
          rpc: (method, input, signal) => holder.rpc!(method, input, signal),
          fetch: (input, init) => transfers.fetch(input, init),
        },
        searchStartDelayMs: 1_000,
        ...options.host,
      },
    })
    this.transfers = transfers
    this.bytes = bytes
    holder.rpc = this.rpc
  }

  private readonly rpc: MediaRpcCall = async (method, input, signal) => {
    const result: RpcResult["result"] = await this.transfers.call(method, input, signal)
    const fill = (complete: UploadComplete | undefined) => {
      if (!complete) return complete
      const row = Array.from(this.transfers.uploads.values()).find(
        (upload) => (upload as { complete?: UploadComplete }).complete?.fileUniqueId === complete.fileUniqueId,
      ) as { input?: { mimeType?: string } } | undefined
      const mimeType =
        row?.input?.mimeType ?? (input.oneofKind === "createUpload" ? input.createUpload.mimeType : undefined)
      return withMedia(complete, mimeType)
    }
    if (method === Method.FINISH_UPLOAD && result.oneofKind === "finishUpload") {
      const state = result.finishUpload.state
      if (state.oneofKind === "complete") {
        return { ...result, finishUpload: { state: { oneofKind: "complete", complete: fill(state.complete)! } } }
      }
    }
    if (method === Method.CREATE_UPLOAD && result.oneofKind === "createUpload" && result.createUpload.complete) {
      return { ...result, createUpload: { ...result.createUpload, complete: fill(result.createUpload.complete) } }
    }
    if (method === Method.GET_UPLOAD_STATE && result.oneofKind === "getUploadState" && result.getUploadState.complete) {
      return { ...result, getUploadState: { ...result.getUploadState, complete: fill(result.getUploadState.complete) } }
    }
    return result
  }
}

export const mediaOf = (ui: TestContext, sub: number) => ui.state.resources.get(sub) as MediaResource | undefined

export const blobBytes = async (blob: Blob | undefined) => (blob ? new Uint8Array(await blob.arrayBuffer()) : undefined)
