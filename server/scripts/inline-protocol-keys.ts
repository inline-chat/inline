import { chmod, readFile, writeFile } from "node:fs/promises"
import { basename, resolve } from "node:path"
import { generateKeyPairSync, randomBytes } from "node:crypto"
import { makeInlineProtocolRsaSigner } from "../src/modules/inlineProtocol/rsaSigner"
import { decodeInlineProtocolSecretKeyRing } from "../src/modules/inlineProtocol/keyCipher"

type SecretRing = { activeId: string; keys: Record<string, string> }
type KeyBundle = {
  version: 1
  rsaPrivateKeys: Array<{ privateKeyPem: string; advertise: boolean }>
  authKeyKekRing: SecretRing
  authCodePepperRing: SecretRing
}

const USAGE = `Inline Protocol key lifecycle

Usage:
  inline-protocol-keys init OUT
  inline-protocol-keys status IN
  inline-protocol-keys export-public-ring IN OUT
  inline-protocol-keys rotate-{rsa,kek,pepper} IN OUT
  inline-protocol-keys retire-{rsa,kek,pepper} IN OUT ID --confirmed-safe
  inline-protocol-keys copy-environment IN
  inline-protocol-keys copy-environment-value IN {rsa|kek|pepper}
  inline-protocol-keys run IN -- COMMAND [ARG...]
  inline-protocol-keys rewrap-auth-keys [LIMIT]
  inline-protocol-keys check-retirement {kek,pepper} ID

Bundle files are immutable mode-0600 files. Secret values are copied only to
the clipboard; status output contains public fingerprints and key IDs only.`

const keyId = (prefix: string, now = new Date()): string =>
  `${prefix}_${now.toISOString().slice(0, 10).replaceAll("-", "")}_${randomBytes(3).toString("hex")}`

const secretRing = (prefix: string): SecretRing => {
  const id = keyId(prefix)
  return { activeId: id, keys: { [id]: randomBytes(32).toString("base64") } }
}

const rsaPrivateKey = (): string => generateKeyPairSync("rsa", {
  modulusLength: 2048,
  publicExponent: 0x10001,
  privateKeyEncoding: { type: "pkcs8", format: "pem" },
  publicKeyEncoding: { type: "spki", format: "pem" },
}).privateKey

export const createInlineProtocolKeyBundle = (): KeyBundle => ({
  version: 1,
  rsaPrivateKeys: [
    { privateKeyPem: rsaPrivateKey(), advertise: true },
    { privateKeyPem: rsaPrivateKey(), advertise: true },
  ],
  authKeyKekRing: secretRing("kek"),
  authCodePepperRing: secretRing("pepper"),
})

const requireBundle = (value: unknown): KeyBundle => {
  if (typeof value !== "object" || value === null || (value as { version?: unknown }).version !== 1) {
    throw new Error("Unsupported Inline Protocol key bundle")
  }
  const bundle = value as KeyBundle
  makeInlineProtocolRsaSigner(JSON.stringify(bundle.rsaPrivateKeys))
  decodeInlineProtocolSecretKeyRing(JSON.stringify(bundle.authKeyKekRing), "bundle auth-key KEK")
  decodeInlineProtocolSecretKeyRing(JSON.stringify(bundle.authCodePepperRing), "bundle auth-code pepper")
  return bundle
}

const safeSecretPath = (path: string): string => {
  const absolute = resolve(path)
  if (basename(absolute).startsWith(".env")) throw new Error("Refusing to read or write a .env file")
  return absolute
}

const readBundle = async (path: string): Promise<KeyBundle> =>
  requireBundle(JSON.parse(await readFile(safeSecretPath(path), "utf8")))

const writeBundle = async (path: string, bundle: KeyBundle): Promise<void> => {
  const target = safeSecretPath(path)
  await writeFile(target, `${JSON.stringify(bundle, null, 2)}\n`, { mode: 0o600, flag: "wx" })
  await chmod(target, 0o600)
  console.log(`Wrote a mode-0600 Inline Protocol key bundle to ${target}`)
}

const rotate = (bundle: KeyBundle, kind: "rsa" | "kek" | "pepper"): KeyBundle => {
  if (kind === "rsa") {
    return { ...bundle, rsaPrivateKeys: [
      { privateKeyPem: rsaPrivateKey(), advertise: true },
      ...bundle.rsaPrivateKeys,
    ] }
  }
  const property = kind === "kek" ? "authKeyKekRing" : "authCodePepperRing"
  const ring = bundle[property]
  const id = keyId(kind)
  return { ...bundle, [property]: {
    activeId: id,
    keys: { ...ring.keys, [id]: randomBytes(32).toString("base64") },
  } }
}

const retireSecret = (bundle: KeyBundle, kind: "kek" | "pepper", id: string): KeyBundle => {
  const property = kind === "kek" ? "authKeyKekRing" : "authCodePepperRing"
  const ring = bundle[property]
  if (ring.activeId === id) throw new Error("Refusing to retire the active key")
  if (!ring.keys[id]) throw new Error(`Unknown ${kind} key ID`)
  const keys = { ...ring.keys }
  delete keys[id]
  return { ...bundle, [property]: { ...ring, keys } }
}

const rsaFingerprint = (privateKeyPem: string): string =>
  makeInlineProtocolRsaSigner(JSON.stringify([{ privateKeyPem }]), { requireOverlappingRing: false })
    .publicKeyRing[0]!.fingerprint

const retireRsa = (bundle: KeyBundle, fingerprint: string): KeyBundle => {
  const remaining = bundle.rsaPrivateKeys.filter((key) => rsaFingerprint(key.privateKeyPem) !== fingerprint)
  if (remaining.length === bundle.rsaPrivateKeys.length) throw new Error("Unknown RSA fingerprint")
  if (remaining.filter((key) => key.advertise).length < 2) {
    throw new Error("Refusing to retire RSA key: fewer than two advertised keys would remain")
  }
  return { ...bundle, rsaPrivateKeys: remaining }
}

const environmentPayload = (bundle: KeyBundle): string => [
  `INLINE_PROTOCOL_RSA_PRIVATE_KEYS_JSON=${JSON.stringify(bundle.rsaPrivateKeys)}`,
  `INLINE_PROTOCOL_AUTH_KEY_KEK_RING_JSON=${JSON.stringify(bundle.authKeyKekRing)}`,
  `INLINE_PROTOCOL_AUTH_CODE_PEPPER_RING_JSON=${JSON.stringify(bundle.authCodePepperRing)}`,
].join("\n")

const environmentVariables = (bundle: KeyBundle): Record<string, string> => ({
  INLINE_PROTOCOL_RSA_PRIVATE_KEYS_JSON: JSON.stringify(bundle.rsaPrivateKeys),
  INLINE_PROTOCOL_AUTH_KEY_KEK_RING_JSON: JSON.stringify(bundle.authKeyKekRing),
  INLINE_PROTOCOL_AUTH_CODE_PEPPER_RING_JSON: JSON.stringify(bundle.authCodePepperRing),
})

const copyToMacOSClipboard = async (payload: string): Promise<void> => {
  const clipboard = Bun.spawn([
    "osascript",
    "-e",
    "set the clipboard to (system attribute \"INLINE_PROTOCOL_CLIPBOARD_PAYLOAD\")",
  ], {
    env: { ...process.env, INLINE_PROTOCOL_CLIPBOARD_PAYLOAD: payload },
    stdout: "ignore",
    stderr: "inherit",
  })
  if (await clipboard.exited !== 0) throw new Error("macOS clipboard update failed")
}

const printPublicRing = (bundle: KeyBundle): void => {
  const signer = makeInlineProtocolRsaSigner(JSON.stringify(bundle.rsaPrivateKeys))
  console.log(JSON.stringify({ rsaPublicKeyRing: signer.publicKeyRing }, null, 2))
}

const writePublicRing = async (path: string, bundle: KeyBundle): Promise<void> => {
  const signer = makeInlineProtocolRsaSigner(JSON.stringify(bundle.rsaPrivateKeys))
  const target = safeSecretPath(path)
  await writeFile(target, `${JSON.stringify({ rsaPublicKeyRing: signer.publicKeyRing }, null, 2)}\n`, {
    mode: 0o644,
    flag: "wx",
  })
  console.log(`Wrote the public Inline Protocol RSA ring to ${target}`)
}

const printBundleStatus = (bundle: KeyBundle): void => {
  console.log(JSON.stringify({
    rsaKeys: bundle.rsaPrivateKeys.map((key) => ({
      fingerprint: rsaFingerprint(key.privateKeyPem),
      advertise: key.advertise,
    })),
    authKeyKekRing: {
      activeId: bundle.authKeyKekRing.activeId,
      keyIds: Object.keys(bundle.authKeyKekRing.keys),
    },
    authCodePepperRing: {
      activeId: bundle.authCodePepperRing.activeId,
      keyIds: Object.keys(bundle.authCodePepperRing.keys),
    },
  }, null, 2))
}

const main = async (): Promise<void> => {
  const [command, ...args] = Bun.argv.slice(2)
  if ((command === "help" || command === "--help" || command === "-h") && args.length === 0) {
    console.log(USAGE)
    return
  }
  if (command === "init" && args.length === 1) {
    const bundle = createInlineProtocolKeyBundle()
    await writeBundle(args[0]!, bundle)
    printPublicRing(bundle)
    return
  }
  if ((command === "rotate-rsa" || command === "rotate-kek" || command === "rotate-pepper") && args.length === 2) {
    const bundle = await readBundle(args[0]!)
    const kind = command.slice("rotate-".length) as "rsa" | "kek" | "pepper"
    const rotated = rotate(bundle, kind)
    await writeBundle(args[1]!, rotated)
    printPublicRing(rotated)
    return
  }
  if ((command === "retire-kek" || command === "retire-pepper") && args.length === 4 && args[3] === "--confirmed-safe") {
    const kind = command.slice("retire-".length) as "kek" | "pepper"
    await writeBundle(args[1]!, retireSecret(await readBundle(args[0]!), kind, args[2]!))
    return
  }
  if (command === "retire-rsa" && args.length === 4 && args[3] === "--confirmed-safe") {
    const rotated = retireRsa(await readBundle(args[0]!), args[2]!)
    await writeBundle(args[1]!, rotated)
    printPublicRing(rotated)
    return
  }
  if (command === "copy-environment" && args.length === 1) {
    const payload = environmentPayload(await readBundle(args[0]!))
    await copyToMacOSClipboard(payload)
    console.log("Copied three Inline Protocol credential values to the clipboard without printing them")
    return
  }
  if (command === "copy-environment-value" && args.length === 2) {
    const bundle = await readBundle(args[0]!)
    const values = {
      rsa: JSON.stringify(bundle.rsaPrivateKeys),
      kek: JSON.stringify(bundle.authKeyKekRing),
      pepper: JSON.stringify(bundle.authCodePepperRing),
    }
    const kind = args[1] as keyof typeof values
    const value = values[kind]
    if (value === undefined) throw new Error("Credential kind must be rsa, kek, or pepper")
    await copyToMacOSClipboard(value)
    console.log(`Copied only the ${kind} credential value to the clipboard without printing it`)
    return
  }
  if (command === "status" && args.length === 1) {
    printBundleStatus(await readBundle(args[0]!))
    return
  }
  if (command === "export-public-ring" && args.length === 2) {
    await writePublicRing(args[1]!, await readBundle(args[0]!))
    return
  }
  if (command === "run" && args.length >= 3 && args[1] === "--") {
    const bundle = await readBundle(args[0]!)
    const child = Bun.spawn(args.slice(2), {
      cwd: process.cwd(),
      env: { ...process.env, ...environmentVariables(bundle) },
      stdin: "inherit",
      stdout: "inherit",
      stderr: "inherit",
    })
    const exitCode = await child.exited
    if (exitCode !== 0) process.exit(exitCode)
    return
  }
  if (command === "rewrap-auth-keys" && args.length <= 1) {
    const [{ loadInlineProtocolConfiguration }, { makeAuthorizationKeyCipher }, { PermanentAuthorizationKeyRepository }] = await Promise.all([
      import("../src/modules/inlineProtocol/config"),
      import("../src/modules/inlineProtocol/keyCipher"),
      import("../src/db/models/inlineProtocol"),
    ])
    const configuration = loadInlineProtocolConfiguration()
    if (!configuration.enabled) throw new Error("Inline Protocol credentials are not configured")
    const repository = new PermanentAuthorizationKeyRepository(makeAuthorizationKeyCipher(configuration.authKeyKekRing))
    const limit = args[0] === undefined ? 100 : Number(args[0])
    if (!Number.isSafeInteger(limit) || limit < 1) throw new Error("Rewrap limit must be a positive integer")
    const result = await repository.rewrapBatch(limit)
    console.log(JSON.stringify(result))
    return
  }
  if (command === "check-retirement" && args.length === 2 && (args[0] === "kek" || args[0] === "pepper")) {
    const kind = args[0]
    const keyId = args[1]!
    if (kind === "kek") {
      const [{ loadInlineProtocolConfiguration }, { makeAuthorizationKeyCipher }, { PermanentAuthorizationKeyRepository }] = await Promise.all([
        import("../src/modules/inlineProtocol/config"),
        import("../src/modules/inlineProtocol/keyCipher"),
        import("../src/db/models/inlineProtocol"),
      ])
      const configuration = loadInlineProtocolConfiguration()
      if (!configuration.enabled) throw new Error("Inline Protocol credentials are not configured")
      const repository = new PermanentAuthorizationKeyRepository(makeAuthorizationKeyCipher(configuration.authKeyKekRing))
      const blockingRows = await repository.countUsingKeyEncryptionKey(keyId)
      console.log(JSON.stringify({ kind, keyId, blockingRows, safeToRetire: blockingRows === 0 }))
      return
    }
    const { countInlineProtocolChallengesBlockingPepperRetirement } = await import("../src/db/models/inlineProtocol")
    const blockingRows = await countInlineProtocolChallengesBlockingPepperRetirement(keyId)
    console.log(JSON.stringify({ kind, keyId, blockingRows, safeToRetire: blockingRows === 0 }))
    return
  }
  throw new Error(USAGE)
}

if (import.meta.main) await main()
