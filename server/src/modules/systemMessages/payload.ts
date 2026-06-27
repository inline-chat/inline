import {
  type PinnedMessageSystemMessage,
  type SystemMessage as SystemMessagePayload,
  SystemMessage as SystemMessageCodec,
  type ThreadBacklinkSystemMessage,
} from "@in/server/protocol/server"
import type { MessageType } from "@protobuf-ts/runtime"
import { decryptBinary, encryptBinary, type EncryptedData } from "@in/server/modules/encryption/encryption"

export const SystemMessage: MessageType<SystemMessagePayload> = SystemMessageCodec
export type SystemMessage = SystemMessagePayload
export type { PinnedMessageSystemMessage, ThreadBacklinkSystemMessage }

export function encryptSystemMessagePayload(payload: SystemMessagePayload): EncryptedData {
  return encryptBinary(SystemMessage.toBinary(payload))
}

export function decryptSystemMessagePayload(data: EncryptedData): SystemMessagePayload {
  return SystemMessage.fromBinary(decryptBinary(data))
}
