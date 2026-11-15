import { RpcCall, type Method } from "@inline-chat/protocol/core"

// Mirrors protobuf-ts PartialMessage, which keeps oneof groups whole.
type PartialField<T> = T extends Date | Uint8Array | bigint | boolean | string | number
  ? T
  : T extends Array<infer U>
    ? Array<PartialField<U>>
    : T extends ReadonlyArray<infer U>
      ? ReadonlyArray<PartialField<U>>
      : T extends { oneofKind: string } | { oneofKind: undefined }
        ? T
        : T extends object
          ? { [K in keyof T]?: PartialField<T[K]> }
          : T

/**
 * An RPC input whose selected message may omit fields. Omitted fields take
 * their proto defaults (0, "", false, empty lists) before encoding, so
 * `{ oneofKind: "getChats", getChats: {} }` is a valid call.
 */
export type RpcInput = RpcCall["input"] extends infer U
  ? U extends unknown
    ? { [P in keyof U]: P extends "oneofKind" ? U[P] : PartialField<U[P]> }
    : never
  : never

/** Fills proto defaults into a possibly partial input so the encoder never sees undefined. */
export const normalizeRpcInput = (method: Method, input: RpcInput): RpcCall["input"] =>
  // reflectionMergePartial creates the selected oneof member (and nested
  // messages) through each type's create(), which sets every default.
  RpcCall.create({ method, input: input as RpcCall["input"] }).input
