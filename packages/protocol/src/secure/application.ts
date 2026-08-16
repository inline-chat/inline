import { concatBytes, int32LE, readInt32LE, uint32LE } from "./bytes.js"
import { TlReader, encodeTlBytes } from "./tl.js"

export const INLINE_RESULT_CONSTRUCTOR = 0xac3ddc54
export const INLINE_UPDATE_CONSTRUCTOR = 0xdc412c98
export const INLINE_INVOKE_CONSTRUCTOR = 0xeb7d4aa6
export const INLINE_REALTIME_LAYER = 3

export type InlineApplicationObject =
  | { kind: "invoke"; layer: number; payload: Uint8Array }
  | { kind: "result"; payload: Uint8Array }
  | { kind: "update"; payload: Uint8Array }

export const encodeInlineInvoke = (payload: Uint8Array, layer = INLINE_REALTIME_LAYER): Uint8Array =>
  concatBytes(uint32LE(INLINE_INVOKE_CONSTRUCTOR), int32LE(layer), encodeTlBytes(payload))

export const encodeInlineResult = (payload: Uint8Array): Uint8Array =>
  concatBytes(uint32LE(INLINE_RESULT_CONSTRUCTOR), encodeTlBytes(payload))

export const encodeInlineUpdate = (payload: Uint8Array): Uint8Array =>
  concatBytes(uint32LE(INLINE_UPDATE_CONSTRUCTOR), encodeTlBytes(payload))

export const decodeInlineApplicationObject = (bytes: Uint8Array): InlineApplicationObject => {
  if (bytes.length < 8) throw new RangeError("Truncated Inline application object")
  const constructor = readInt32LE(bytes, 0) >>> 0
  const reader = new TlReader(bytes.slice(4))
  if (constructor === INLINE_INVOKE_CONSTRUCTOR) {
    const layer = reader.readInt()
    const payload = reader.readBytes()
    reader.expectEnd()
    return { kind: "invoke", layer, payload }
  }
  const payload = reader.readBytes()
  reader.expectEnd()
  if (constructor === INLINE_RESULT_CONSTRUCTOR) return { kind: "result", payload }
  if (constructor === INLINE_UPDATE_CONSTRUCTOR) return { kind: "update", payload }
  throw new RangeError("Unknown Inline application constructor")
}
