import { afterAll, beforeAll, describe, expect, test } from "bun:test"
import { randomBytes } from "node:crypto"
import {
  AesCtrStream,
  aesIgeDecrypt,
  aesIgeEncrypt,
  decryptRecordWithMetadata,
  encryptRecord,
  getAesBackend,
  hexToBytes,
  setAesBackend,
  type AesBackend,
} from "../src/secure/index.js"
import { makePureAesBackend } from "../src/secure/aesPure.js"
import { nodeAesBackend } from "../src/secure/node.js"
import { portableCoreV1Vector } from "../src/vectors.js"

const pure = makePureAesBackend()
const random = (length: number): Uint8Array => Uint8Array.from(randomBytes(length))
const sizes = [16, 32, 48, 64, 496, 1024, 4096, 65536, 512 * 1024 + 48]

const withBackend = <T>(backend: AesBackend, run: () => T): T => {
  const previous = setAesBackend(backend)
  try { return run() } finally { setAesBackend(previous) }
}

describe("AES backends", () => {
  test("the portable backend is the default", () => {
    expect(getAesBackend().name).toBe("pure-js")
  })

  test("node:crypto IGE matches the portable backend and round-trips", () => {
    for (const size of sizes) {
      const key = random(32)
      const iv = random(32)
      const plaintext = random(size)
      const expected = pure.igeEncrypt(plaintext, key, iv)
      const actual = nodeAesBackend.igeEncrypt(plaintext, key, iv)
      expect(Buffer.from(actual).equals(Buffer.from(expected))).toBe(true)
      expect(Buffer.from(nodeAesBackend.igeDecrypt(expected, key, iv)).equals(Buffer.from(plaintext))).toBe(true)
      expect(Buffer.from(pure.igeDecrypt(actual, key, iv)).equals(Buffer.from(plaintext))).toBe(true)
    }
  })

  test("node:crypto CTR matches the portable backend across arbitrary chunk boundaries", () => {
    const key = random(32)
    const iv = random(16)
    const input = random(70_000)
    const expected = pure.createCtr(key, iv).process(input)
    const chunked = nodeAesBackend.createCtr(key, iv)
    const pieces: Uint8Array[] = []
    for (let offset = 0, step = 1; offset < input.length; offset += step, step = (step * 7 + 3) % 5000 + 1) {
      pieces.push(chunked.process(input.subarray(offset, Math.min(input.length, offset + step))))
    }
    expect(Buffer.concat(pieces.map((piece) => Buffer.from(piece))).equals(Buffer.from(expected))).toBe(true)
    // Counter carry across the 32-bit boundary.
    const carryIv = hexToBytes("000000000000000000000000ffffffff")
    expect(Buffer.from(nodeAesBackend.createCtr(key, carryIv).process(input.subarray(0, 4096)))
      .equals(Buffer.from(pure.createCtr(key, carryIv).process(input.subarray(0, 4096))))).toBe(true)
  })

  test("backends return copies, never views of cipher buffers", () => {
    const key = random(32)
    const out = nodeAesBackend.createCtr(key, random(16)).process(random(100))
    expect(out.constructor).toBe(Uint8Array)
    const ige = nodeAesBackend.igeDecrypt(random(64), key, random(32))
    expect(ige.constructor).toBe(Uint8Array)
  })

  test("the frozen portable vector decrypts and re-encrypts identically under node:crypto", () => {
    withBackend(nodeAesBackend, () => {
      const vector = portableCoreV1Vector
      const authKey = hexToBytes(vector.authKeyHex)
      const record = hexToBytes(vector.recordHex)
      const decrypted = decryptRecordWithMetadata(record, authKey, {
        direction: "client-to-server",
        sessionId: BigInt(`0x${vector.sessionId}`),
        validServerSalts: new Set([BigInt(`0x${vector.serverSalt}`)]),
        nowSeconds: Number(vector.messageId.split(":")[0]),
      })
      expect(Buffer.from(decrypted.fields.body).equals(Buffer.from(hexToBytes(vector.bodyHex)))).toBe(true)
      expect(decrypted.quickAckId).toBe(vector.quickAckId)
      const encrypted = encryptRecord(authKey, "client-to-server", decrypted.fields, hexToBytes(vector.paddingHex))
      expect(Buffer.from(encrypted).equals(Buffer.from(record))).toBe(true)
    })
  })

  test("AesCtrStream and aesIge* honor the installed backend", () => {
    const key = random(32)
    const iv = random(32)
    const data = random(4096)
    const viaPure = withBackend(pure, () => aesIgeEncrypt(data, key, iv))
    const viaNode = withBackend(nodeAesBackend, () => aesIgeEncrypt(data, key, iv))
    expect(Buffer.from(viaNode).equals(Buffer.from(viaPure))).toBe(true)
    expect(Buffer.from(withBackend(nodeAesBackend, () => aesIgeDecrypt(viaNode, key, iv))).equals(Buffer.from(data))).toBe(true)
    const stream = withBackend(nodeAesBackend, () => new AesCtrStream(key, iv.subarray(0, 16)))
    expect(Buffer.from(stream.process(data)).equals(Buffer.from(pure.createCtr(key, iv.subarray(0, 16)).process(data)))).toBe(true)
  })
})

describe("AES backend performance regression", () => {
  const previous = getAesBackend()
  beforeAll(() => { setAesBackend(nodeAesBackend) })
  afterAll(() => { setAesBackend(previous) })

  const bestOf = (iterations: number, run: () => void): number => {
    let best = Number.POSITIVE_INFINITY
    for (let index = 0; index < iterations; index += 1) {
      const started = performance.now()
      run()
      best = Math.min(best, performance.now() - started)
    }
    return best
  }

  test("a 512 KiB record costs well under the pure-JS budget", () => {
    const key = random(32)
    const iv = random(32)
    const plaintext = random(512 * 1024 + 48)
    const ciphertext = aesIgeEncrypt(plaintext, key, iv)
    const stream = new AesCtrStream(key, iv.subarray(0, 16))
    // Measured locally: ~20 ms encrypt, ~20 ms decrypt, <1 ms CTR with node:crypto,
    // against 90–200 ms and 50–330 ms for the pure backend. Budgets are loose for CI.
    expect(bestOf(3, () => aesIgeEncrypt(plaintext, key, iv))).toBeLessThan(60)
    expect(bestOf(3, () => aesIgeDecrypt(ciphertext, key, iv))).toBeLessThan(60)
    expect(bestOf(3, () => stream.process(plaintext))).toBeLessThan(10)
  })
})
