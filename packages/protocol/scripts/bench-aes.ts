// bun scripts/bench-aes.ts — prints AES-IGE and carrier CTR cost per backend.
import { randomBytes } from "node:crypto"
import { makePureAesBackend } from "../src/secure/aesPure.js"
import { nodeAesBackend } from "../src/secure/node.js"

const random = (length: number): Uint8Array => Uint8Array.from(randomBytes(length))
const bestOf = (iterations: number, run: () => void): number => {
  let best = Number.POSITIVE_INFINITY
  for (let index = 0; index < iterations; index += 1) {
    const started = performance.now()
    run()
    best = Math.min(best, performance.now() - started)
  }
  return best
}

const key = random(32)
const iv = random(32)
for (const backend of [makePureAesBackend(), nodeAesBackend]) {
  for (const size of [4096, 65536, 512 * 1024 + 48]) {
    const plaintext = random(size)
    const ciphertext = backend.igeEncrypt(plaintext, key, iv)
    const ctr = backend.createCtr(key, iv.subarray(0, 16))
    const encrypt = bestOf(5, () => backend.igeEncrypt(plaintext, key, iv))
    const decrypt = bestOf(5, () => backend.igeDecrypt(ciphertext, key, iv))
    const stream = bestOf(5, () => ctr.process(plaintext))
    console.log(
      `${backend.name.padEnd(12)} ${String(size).padStart(7)} B  ige-encrypt ${encrypt.toFixed(2).padStart(8)} ms` +
      `  ige-decrypt ${decrypt.toFixed(2).padStart(8)} ms  ctr ${stream.toFixed(2).padStart(8)} ms`,
    )
  }
}
