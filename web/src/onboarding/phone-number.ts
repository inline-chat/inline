export const normalizeInternationalPhoneNumber = (value: string) => {
  const compact = value.trim().replaceAll(/[\s().-]/g, "")
  const international = compact.startsWith("00") ? `+${compact.slice(2)}` : compact
  return international.startsWith("+")
    ? `+${international.slice(1).replaceAll(/\D/g, "")}`
    : international.replaceAll(/\D/g, "")
}

export const isPlausibleInternationalPhoneNumber = (value: string) =>
  /^\+[1-9]\d{6,14}$/.test(value)
