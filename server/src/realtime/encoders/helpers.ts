/** Convert's JS Date to Unix timestamp in BigInt */
export const encodeDate = (date: Date | undefined): bigint | undefined => {
  if (!date) return undefined
  return BigInt(Math.round(date.getTime() / 1000))
}

/** Convert's JS Date to Unix timestamp in BigInt */
export const encodeDateStrict = (date: Date): bigint => {
  return BigInt(Math.round(date.getTime() / 1000))
}
