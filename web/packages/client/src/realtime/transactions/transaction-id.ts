export type TransactionId = string

const generateUuid = () => {
  if (typeof crypto !== "undefined" && "randomUUID" in crypto) {
    return crypto.randomUUID()
  }
  return `${Date.now().toString(16)}-${Math.random().toString(16).slice(2)}`
}

export const TransactionId = {
  generate(): TransactionId {
    return generateUuid()
  },
}
