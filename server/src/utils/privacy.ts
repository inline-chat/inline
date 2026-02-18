export function maskEmail(email: string): string {
  const normalized = email.trim()
  const atIndex = normalized.indexOf("@")
  if (atIndex <= 0 || atIndex === normalized.length - 1) {
    return "<redacted-email>"
  }

  const local = normalized.slice(0, atIndex)
  const domain = normalized.slice(atIndex + 1)

  const localMasked = local.length <= 2 ? `${local[0] ?? "*"}*` : `${local.slice(0, 2)}***`

  const [domainName, ...domainRest] = domain.split(".")
  const domainNameMasked =
    !domainName || domainName.length <= 2 ? `${domainName?.[0] ?? "*"}*` : `${domainName.slice(0, 2)}***`
  const domainSuffix = domainRest.length > 0 ? `.${domainRest.join(".")}` : ""

  return `${localMasked}@${domainNameMasked}${domainSuffix}`
}

export function maskPhoneNumber(phoneNumber: string): string {
  const digits = phoneNumber.replace(/\D/g, "")
  if (digits.length < 4) {
    return "<redacted-phone>"
  }

  return `***${digits.slice(-4)}`
}
