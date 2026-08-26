import { createHmac } from "node:crypto"
import { Encryption2 } from "@in/server/modules/encryption/encryption2"

const MAX_REF_BYTES = 512
const SOURCE_PAYLOAD_VERSION = 1

export type AgentSourceRefs = {
  correlationRef?: string
  itemRef?: string
}

function normalizedRef(value: string | undefined): string | undefined {
  if (value === undefined) return undefined
  const byteLength = Buffer.byteLength(value, "utf8")
  if (value.trim().length === 0 || byteLength > MAX_REF_BYTES) {
    throw new Error("agent session reference must contain 1 to 512 UTF-8 bytes")
  }
  return value
}

function hmacKey(): Buffer {
  const value = process.env["ENCRYPTION_KEY"]
  if (!value || !/^[a-fA-F0-9]{64}$/.test(value)) {
    throw new Error("a valid ENCRYPTION_KEY is required for agent session references")
  }
  return Buffer.from(value, "hex")
}

function frame(parts: readonly string[]): Buffer {
  const buffers: Buffer[] = []
  for (const part of parts) {
    const value = Buffer.from(part, "utf8")
    const length = Buffer.allocUnsafe(4)
    length.writeUInt32BE(value.length)
    buffers.push(length, value)
  }
  return Buffer.concat(buffers)
}

export function agentSessionHash(provider: number, instanceRef: string, sessionRef: string): Buffer {
  const instance = normalizedRef(instanceRef)!
  const session = normalizedRef(sessionRef)!
  return createHmac("sha256", hmacKey())
    .update("inline-agent-session-v1\0")
    .update(frame([String(provider), instance, session]))
    .digest()
}

export function agentSourceHash(kind: "correlation" | "item", ref: string): Buffer {
  const value = normalizedRef(ref)!
  return createHmac("sha256", hmacKey())
    .update(`inline-agent-${kind}-v1\0`)
    .update(frame([value]))
    .digest()
}

export function encryptAgentRef(ref: string): Buffer {
  return Encryption2.encrypt(Buffer.from(normalizedRef(ref)!, "utf8"))
}

export function decryptAgentRef(payload: Buffer): string {
  return normalizedRef(Encryption2.decryptToString(payload))!
}

export function normalizeAgentSourceRefs(input: AgentSourceRefs): AgentSourceRefs {
  const correlationRef = normalizedRef(input.correlationRef)
  const itemRef = normalizedRef(input.itemRef)
  if (!correlationRef && !itemRef) {
    throw new Error("an item_ref or correlation_ref is required")
  }
  return { correlationRef, itemRef }
}

export function encryptAgentSourceRefs(input: AgentSourceRefs): Buffer {
  const refs = normalizeAgentSourceRefs(input)
  const correlation = Buffer.from(refs.correlationRef ?? "", "utf8")
  const item = Buffer.from(refs.itemRef ?? "", "utf8")
  const payload = Buffer.allocUnsafe(6 + correlation.length + item.length)
  payload.writeUInt8(SOURCE_PAYLOAD_VERSION, 0)
  payload.writeUInt8((refs.correlationRef ? 1 : 0) | (refs.itemRef ? 2 : 0), 1)
  payload.writeUInt16BE(correlation.length, 2)
  correlation.copy(payload, 4)
  const itemLengthOffset = 4 + correlation.length
  payload.writeUInt16BE(item.length, itemLengthOffset)
  item.copy(payload, itemLengthOffset + 2)
  return Encryption2.encrypt(payload)
}

export function decryptAgentSourceRefs(encrypted: Buffer): AgentSourceRefs {
  const payload = Encryption2.decryptBinary(encrypted)
  if (payload.length < 6 || payload.readUInt8(0) !== SOURCE_PAYLOAD_VERSION) {
    throw new Error("unsupported agent source reference payload")
  }
  const flags = payload.readUInt8(1)
  const correlationLength = payload.readUInt16BE(2)
  const itemLengthOffset = 4 + correlationLength
  if (itemLengthOffset + 2 > payload.length) throw new Error("invalid agent source reference payload")
  const itemLength = payload.readUInt16BE(itemLengthOffset)
  if (itemLengthOffset + 2 + itemLength !== payload.length) {
    throw new Error("invalid agent source reference payload")
  }
  const correlationRef = (flags & 1) !== 0
    ? normalizedRef(payload.subarray(4, itemLengthOffset).toString("utf8"))
    : undefined
  const itemRef = (flags & 2) !== 0
    ? normalizedRef(payload.subarray(itemLengthOffset + 2).toString("utf8"))
    : undefined
  return normalizeAgentSourceRefs({ correlationRef, itemRef })
}
