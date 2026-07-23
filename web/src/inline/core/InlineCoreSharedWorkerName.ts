import { INLINE_CORE_PROTOCOL_VERSION } from "./InlineCoreProtocol"

const baseName = `inline-core-v${INLINE_CORE_PROTOCOL_VERSION}`

export const activeInlineCoreSharedWorkerName = () =>
  baseName

export const replacementInlineCoreSharedWorkerName = () => {
  const suffix =
    typeof crypto !== "undefined" && "randomUUID" in crypto
      ? crypto.randomUUID()
      : `${Date.now()}-${Math.random().toString(36).slice(2)}`
  return `${baseName}-replacement-${suffix}`
}
