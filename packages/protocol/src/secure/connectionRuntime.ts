/**
 * Everything the portable Inline Protocol V3 connection needs from its host.
 * Nothing in this file or in `connection.ts` touches Node, the DOM, or any
 * global I/O: a Node host injects `ws`, `node:crypto` and `node:zlib`; a browser
 * or worker host injects `WebSocket`, `crypto.getRandomValues` and
 * `DecompressionStream`. Tests inject a loopback socket and a virtual clock.
 */
import type { AesBackend } from "./aesBackend.js"

/** WebSocket ready states, shared by the browser API and the `ws` package. */
export const InlineProtocolSocketState = {
  connecting: 0,
  open: 1,
  closing: 2,
  closed: 3,
} as const

/** The socket surface the connection writes to. Binary frames only. */
export interface InlineProtocolSocket {
  readonly readyState: number
  /** Bytes queued by the host but not yet written; used for outbound backpressure. */
  readonly bufferedAmount: number
  send(data: Uint8Array): void
  close(code?: number, reason?: string): void
}

/** Callbacks the host adapter calls. `onMessage` receives one whole binary frame. */
export interface InlineProtocolSocketHandlers {
  onOpen(): void
  onMessage(frame: Uint8Array): void
  onClose(code: number, reason: string): void
  onError(error: unknown): void
}

/**
 * Opens a socket to `url` and reports its lifecycle through `handlers`. The
 * adapter must deliver binary frames as bytes it no longer mutates, and must
 * report a text frame through `onError`.
 */
export type InlineProtocolSocketFactory = (
  url: string,
  handlers: InlineProtocolSocketHandlers,
) => InlineProtocolSocket

export type InlineProtocolTimerHandle = unknown

export interface InlineProtocolTimers {
  setTimeout(callback: () => void, delayMs: number): InlineProtocolTimerHandle
  clearTimeout(handle: InlineProtocolTimerHandle): void
  /**
   * Optional hint that a timer must not keep the host alive by itself (Node's
   * `unref`). Used for the rotation and acknowledgement timers only.
   */
  unref?(handle: InlineProtocolTimerHandle): void
}

export interface InlineProtocolClock {
  /** Wall-clock Unix milliseconds. Used only before an authenticated server sample exists. */
  wallMilliseconds(): number
  /** A monotonic clock in milliseconds; elapsed time between authenticated samples. */
  monotonicMilliseconds(): number
}

/**
 * Inflates a gzip member. Must fail (throw or reject) once the output would
 * exceed `maximumOutputBytes`. Browsers only offer an asynchronous inflater
 * (`DecompressionStream`), so the result may be a promise.
 */
export type InlineProtocolGunzip = (
  packed: Uint8Array,
  maximumOutputBytes: number,
) => Uint8Array | Promise<Uint8Array>

export interface InlineProtocolRuntime {
  webSocket: InlineProtocolSocketFactory
  /** A CSPRNG. */
  randomBytes(length: number): Uint8Array
  gunzip: InlineProtocolGunzip
  /**
   * AES backend for records and the carrier. Record and carrier code read one
   * process-wide backend (`setAesBackend`), so a provided backend is installed
   * globally when a connection opens. Omit it to keep the current backend.
   */
  aes?: AesBackend
  timers?: InlineProtocolTimers
  clock?: InlineProtocolClock
}

type GlobalTimers = {
  setTimeout(callback: () => void, delayMs: number): unknown
  clearTimeout(handle: unknown): void
}

/** The host's global timers. Present in every supported runtime (browsers, workers, Node, Bun). */
export const globalInlineProtocolTimers = (): InlineProtocolTimers => {
  const host = globalThis as unknown as GlobalTimers
  return {
    setTimeout: (callback, delayMs) => host.setTimeout(callback, delayMs),
    clearTimeout: (handle) => host.clearTimeout(handle),
    unref: (handle) => {
      const timer = handle as { unref?: () => void } | null
      if (timer !== null && typeof timer === "object" && typeof timer.unref === "function") timer.unref()
    },
  }
}

/** `Date.now` and `performance.now`, falling back to `Date.now` where `performance` is absent. */
export const globalInlineProtocolClock = (): InlineProtocolClock => {
  const performanceClock = (globalThis as { performance?: { now(): number } }).performance
  return {
    wallMilliseconds: () => Date.now(),
    monotonicMilliseconds: performanceClock ? () => performanceClock.now() : () => Date.now(),
  }
}

const BASE64URL_ALPHABET = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_"
const BASE64URL_VALUES = (() => {
  const values = new Int16Array(128).fill(-1)
  for (let index = 0; index < BASE64URL_ALPHABET.length; index += 1) values[BASE64URL_ALPHABET.charCodeAt(index)] = index
  // Accept the standard alphabet too; pinned keys are published as base64url.
  values["+".charCodeAt(0)] = 62
  values["/".charCodeAt(0)] = 63
  return values
})()

/** Decodes unpadded or padded base64url (or base64) without `Buffer` or `atob`. */
export const decodeBase64Url = (value: string): Uint8Array => {
  const input = value.replace(/=+$/, "")
  if (input.length % 4 === 1) throw new RangeError("Invalid base64url length")
  const output = new Uint8Array(Math.floor((input.length * 3) / 4))
  let buffer = 0
  let bits = 0
  let offset = 0
  for (let index = 0; index < input.length; index += 1) {
    const code = input.charCodeAt(index)
    const digit = code < 128 ? BASE64URL_VALUES[code]! : -1
    if (digit < 0) throw new RangeError("Invalid base64url character")
    buffer = (buffer << 6) | digit
    bits += 6
    if (bits >= 8) {
      bits -= 8
      output[offset] = (buffer >> bits) & 0xff
      offset += 1
    }
  }
  return output
}
