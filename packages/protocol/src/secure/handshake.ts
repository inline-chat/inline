import { aesIgeDecrypt, aesIgeEncrypt, sha1Digest, sha256Digest } from "./crypto.js"
import { concatBytes, equalBytes, hexToBytes, reverseBytes, xorBytes } from "./bytes.js"
import { encodeTlBytes } from "./tl.js"

export const TELEGRAM_DH_PRIME = hexToBytes(
  "c71caeb9c6b1c9048e6c522f70f13f73980d40238e3e21c14934d037563d930f" +
  "48198a0aa7c14058229493d22530f4dbfa336f6e0ac925139543aed44cce7c372" +
  "0fd51f69458705ac68cd4fe6b6b13abdc9746512969328454f18faf8c595f642" +
  "477fe96bb2a941d5bcd1d4ac8cc49880708fa9b378e3c4f3a9060bee67cf9a4a" +
  "4a695811051907e162753b56b0f6b410dba74d8a84b2a14b3144e0ef1284754f" +
  "d17ed950d5965b4b9dd46582db1178d169c6bc465b0d6ff9ca3928fef5b9ae4e" +
  "418fc15e83ebea0f87fa9ff5eed70050ded2849f47bf959d956850ce929851f0d" +
  "8115f635b105ee2e4e15d04b2454bf6f4fadf034b10403119cd8e3b92fcc5b",
)

export type RandomBytes = (length: number) => Uint8Array

export class RsaPadRetry extends Error {
  constructor() { super("RSA_PAD candidate is not below the modulus") }
}

export const bigEndianBytesToBigInt = (bytes: Uint8Array): bigint => {
  let value = 0n
  for (const byte of bytes) value = (value << 8n) | BigInt(byte)
  return value
}

export const bigIntToBigEndianBytes = (value: bigint, length: number): Uint8Array => {
  if (value < 0n) throw new RangeError("Cannot encode a negative integer")
  const output = new Uint8Array(length)
  let remaining = value
  for (let index = length - 1; index >= 0; index -= 1) {
    output[index] = Number(remaining & 0xffn)
    remaining >>= 8n
  }
  if (remaining !== 0n) throw new RangeError("Integer does not fit the requested width")
  return output
}

export const modPow = (base: bigint, exponent: bigint, modulus: bigint): bigint => {
  if (modulus <= 0n || exponent < 0n) throw new RangeError("Invalid modular exponentiation")
  let result = 1n
  let factor = ((base % modulus) + modulus) % modulus
  let power = exponent
  while (power > 0n) {
    if ((power & 1n) === 1n) result = (result * factor) % modulus
    factor = (factor * factor) % modulus
    power >>= 1n
  }
  return result
}

export interface RsaPadIntermediate {
  dataWithPadding: Uint8Array
  dataWithHash: Uint8Array
  aesEncrypted: Uint8Array
  keyAesEncrypted: Uint8Array
  encryptedData: Uint8Array
}

export const rsaPadAttempt = (
  serializedInner: Uint8Array,
  randomPadding: Uint8Array,
  tempKey: Uint8Array,
  modulusBytes: Uint8Array,
  exponentBytes: Uint8Array,
): RsaPadIntermediate => {
  if (serializedInner.length > 144 || serializedInner.length + randomPadding.length !== 192) {
    throw new RangeError("RSA_PAD inner data and padding must total 192 bytes")
  }
  if (tempKey.length !== 32 || modulusBytes.length !== 256 || exponentBytes.length === 0) {
    throw new RangeError("Invalid RSA_PAD key material")
  }
  const dataWithPadding = concatBytes(serializedInner, randomPadding)
  const dataWithHash = concatBytes(reverseBytes(dataWithPadding), sha256Digest(tempKey, dataWithPadding))
  const aesEncrypted = aesIgeEncrypt(dataWithHash, tempKey, new Uint8Array(32))
  const keyAesEncrypted = concatBytes(xorBytes(tempKey, sha256Digest(aesEncrypted)), aesEncrypted)
  const modulus = bigEndianBytesToBigInt(modulusBytes)
  const candidate = bigEndianBytesToBigInt(keyAesEncrypted)
  if (candidate >= modulus) throw new RsaPadRetry()
  const encryptedData = bigIntToBigEndianBytes(modPow(candidate, bigEndianBytesToBigInt(exponentBytes), modulus), 256)
  return { dataWithPadding, dataWithHash, aesEncrypted, keyAesEncrypted, encryptedData }
}

export const rsaPad = (
  serializedInner: Uint8Array,
  modulus: Uint8Array,
  exponent: Uint8Array,
  randomBytes: RandomBytes,
  maximumAttempts = 64,
): RsaPadIntermediate => {
  if (serializedInner.length > 144) throw new RangeError("RSA_PAD inner data exceeds 144 bytes")
  for (let attempt = 0; attempt < maximumAttempts; attempt += 1) {
    try {
      return rsaPadAttempt(
        serializedInner,
        randomBytes(192 - serializedInner.length),
        randomBytes(32),
        modulus,
        exponent,
      )
    } catch (error) {
      if (!(error instanceof RsaPadRetry)) throw error
    }
  }
  throw new RsaPadRetry()
}

export const deriveTemporaryAes = (
  newNonce: Uint8Array,
  serverNonce: Uint8Array,
): { key: Uint8Array; iv: Uint8Array } => {
  if (newNonce.length !== 32 || serverNonce.length !== 16) throw new RangeError("Invalid handshake nonce length")
  const nonceServer = sha1Digest(newNonce, serverNonce)
  const serverNonceHash = sha1Digest(serverNonce, newNonce)
  return {
    key: concatBytes(nonceServer, serverNonceHash.slice(0, 12)),
    iv: concatBytes(serverNonceHash.slice(12, 20), sha1Digest(newNonce, newNonce), newNonce.slice(0, 4)),
  }
}

export const encryptDhInner = (
  serializedInner: Uint8Array,
  padding: Uint8Array,
  newNonce: Uint8Array,
  serverNonce: Uint8Array,
): Uint8Array => {
  if (padding.length > 15 || (20 + serializedInner.length + padding.length) % 16 !== 0) {
    throw new RangeError("DH inner padding must be the unique 0...15-byte aligned length")
  }
  const { key, iv } = deriveTemporaryAes(newNonce, serverNonce)
  return aesIgeEncrypt(concatBytes(sha1Digest(serializedInner), serializedInner, padding), key, iv)
}

export const decryptDhInner = (
  encrypted: Uint8Array,
  serializedLength: number,
  newNonce: Uint8Array,
  serverNonce: Uint8Array,
): Uint8Array => {
  if (encrypted.length === 0 || encrypted.length % 16 !== 0 || serializedLength < 4) {
    throw new RangeError("Invalid encrypted DH inner data")
  }
  const { key, iv } = deriveTemporaryAes(newNonce, serverNonce)
  const plaintext = aesIgeDecrypt(encrypted, key, iv)
  const paddingLength = plaintext.length - 20 - serializedLength
  if (paddingLength < 0 || paddingLength > 15) throw new RangeError("Invalid DH inner padding")
  const serialized = plaintext.slice(20, 20 + serializedLength)
  if (!equalBytes(plaintext.slice(0, 20), sha1Digest(serialized))) throw new RangeError("Invalid DH inner hash")
  return serialized
}

export const authKeyAuxHash = (authKey: Uint8Array): Uint8Array => sha1Digest(authKey).slice(0, 8)

export const newNonceHash = (newNonce: Uint8Array, index: 1 | 2 | 3, authKey: Uint8Array): Uint8Array => {
  if (newNonce.length !== 32 || authKey.length !== 256) throw new RangeError("Invalid nonce or authorization key")
  return sha1Digest(newNonce, Uint8Array.of(index), authKeyAuxHash(authKey)).slice(4, 20)
}

export const serverDhFailureHash = (newNonce: Uint8Array): Uint8Array => {
  if (newNonce.length !== 32) throw new RangeError("new_nonce must be 32 bytes")
  return sha1Digest(newNonce).slice(4, 20)
}

export const initialServerSalt = (newNonce: Uint8Array, serverNonce: Uint8Array): bigint => {
  if (newNonce.length !== 32 || serverNonce.length !== 16) throw new RangeError("Invalid handshake nonce length")
  const mixed = xorBytes(newNonce.slice(0, 8), serverNonce.slice(0, 8))
  return new DataView(mixed.buffer, mixed.byteOffset, mixed.byteLength).getBigInt64(0, true)
}

export const deriveAuthKey = (publicValue: Uint8Array, secretExponent: Uint8Array, primeBytes: Uint8Array): Uint8Array => {
  if (secretExponent.length !== 256 || primeBytes.length !== 256) throw new RangeError("DH values must be 256 bytes")
  return bigIntToBigEndianBytes(modPow(bigEndianBytesToBigInt(publicValue), bigEndianBytesToBigInt(secretExponent), bigEndianBytesToBigInt(primeBytes)), 256)
}

const generatorMatchesPrime = (prime: bigint, generator: number): boolean => {
  switch (generator) {
    case 2: return prime % 8n === 7n
    case 3: return prime % 3n === 2n
    case 4: return true
    case 5: return prime % 5n === 1n || prime % 5n === 4n
    case 6: return prime % 24n === 19n || prime % 24n === 23n
    case 7: return [3n, 5n, 6n].includes(prime % 7n)
    default: return false
  }
}

const isProbablePrime = (value: bigint, randomBytes: RandomBytes, rounds: number): boolean => {
  if (value < 2n || (value & 1n) === 0n) return value === 2n
  let odd = value - 1n
  let power = 0
  while ((odd & 1n) === 0n) { odd >>= 1n; power += 1 }
  for (let round = 0; round < rounds; round += 1) {
    const baseRange = value - 3n
    let candidate: bigint
    do candidate = bigEndianBytesToBigInt(randomBytes(256))
    while (candidate >= baseRange)
    const base = candidate + 2n
    let witness = modPow(base, odd, value)
    if (witness === 1n || witness === value - 1n) continue
    let composite = true
    for (let exponent = 1; exponent < power; exponent += 1) {
      witness = witness * witness % value
      if (witness === value - 1n) { composite = false; break }
    }
    if (composite) return false
  }
  return true
}

export const validateDhParameters = (
  primeBytes: Uint8Array,
  generator: number,
  randomBytes: RandomBytes,
  rounds = 64,
): void => {
  if (primeBytes.length !== 256 || generator < 2 || generator > 7 || rounds < 15) throw new RangeError("Invalid DH parameters")
  const prime = bigEndianBytesToBigInt(primeBytes)
  if (prime <= (1n << 2047n) || prime >= (1n << 2048n) || !generatorMatchesPrime(prime, generator)) {
    throw new RangeError("Unsafe DH parameters")
  }
  if (!equalBytes(primeBytes, TELEGRAM_DH_PRIME)) {
    if (!isProbablePrime(prime, randomBytes, rounds) || !isProbablePrime((prime - 1n) / 2n, randomBytes, rounds)) {
      throw new RangeError("DH prime is not safe")
    }
  }
}

export const validateDhPublicValue = (valueBytes: Uint8Array, primeBytes: Uint8Array): void => {
  if (valueBytes.length === 0 || valueBytes.length > 256 || primeBytes.length !== 256) throw new RangeError("Invalid DH public value")
  const value = bigEndianBytesToBigInt(valueBytes)
  const prime = bigEndianBytesToBigInt(primeBytes)
  const margin = 1n << (2048n - 64n)
  if (value < margin || value > prime - margin) throw new RangeError("Unsafe DH public value")
}

export const bindRetryId = (authKey: Uint8Array): bigint =>
  new DataView(authKeyAuxHash(authKey).buffer).getBigInt64(0, true)

export const rsaPublicKeyFingerprint = (modulus: Uint8Array, exponent: Uint8Array): bigint => {
  const digest = sha1Digest(encodeTlBytes(modulus), encodeTlBytes(exponent))
  return new DataView(digest.buffer, digest.byteOffset + 12, 8).getBigInt64(0, true)
}

const greatestCommonDivisor = (left: bigint, right: bigint): bigint => {
  let a = left < 0n ? -left : left
  let b = right < 0n ? -right : right
  while (b !== 0n) [a, b] = [b, a % b]
  return a
}

const minimalBigEndian = (value: bigint): Uint8Array => {
  if (value === 0n) return Uint8Array.of(0)
  const length = Math.ceil(value.toString(2).length / 8)
  return bigIntToBigEndianBytes(value, length)
}

export const factorPq = (
  pqBytes: Uint8Array,
  randomBytes: RandomBytes,
  maximumAttempts = 32,
): { p: Uint8Array; q: Uint8Array } => {
  const value = bigEndianBytesToBigInt(pqBytes)
  if (value <= 3n || value >= (1n << 63n)) throw new RangeError("Invalid pq challenge")
  if ((value & 1n) === 0n) return { p: Uint8Array.of(2), q: minimalBigEndian(value / 2n) }
  for (let attempt = 0; attempt < maximumAttempts; attempt += 1) {
    let x = bigEndianBytesToBigInt(randomBytes(8)) % (value - 2n) + 2n
    let y = x
    const c = bigEndianBytesToBigInt(randomBytes(8)) % (value - 1n) + 1n
    let divisor = 1n
    for (let iteration = 0; divisor === 1n && iteration < 1_000_000; iteration += 1) {
      x = (x * x + c) % value
      y = (y * y + c) % value
      y = (y * y + c) % value
      divisor = greatestCommonDivisor(x - y, value)
    }
    if (divisor > 1n && divisor < value) {
      const other = value / divisor
      const [p, q] = divisor < other ? [divisor, other] : [other, divisor]
      return { p: minimalBigEndian(p), q: minimalBigEndian(q) }
    }
  }
  throw new RangeError("Unable to factor pq challenge")
}
