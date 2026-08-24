const MAX_EMAIL_BYTES = 254
const MAX_EMAIL_LOCAL_PART_BYTES = 64
const MAX_EMAIL_DOMAIN_BYTES = 253
const MAX_EMAIL_DOMAIN_LABEL_BYTES = 63
const EMAIL_LOCAL_PART_PATTERN = /^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+$/
const EMAIL_DOMAIN_LABEL_PATTERN = /^[A-Za-z0-9-]+$/
const EMAIL_TOP_LEVEL_DOMAIN_PATTERN = /^[A-Za-z]{2,63}$/
const EMAIL_PUNYCODE_TOP_LEVEL_DOMAIN_PATTERN = /^xn--[A-Za-z0-9-]{1,59}$/i

export const isValidEmail = (email: string | undefined | null): boolean => {
  if (!email || Buffer.byteLength(email, "utf8") > MAX_EMAIL_BYTES || email.includes("\0") || /\s/.test(email)) {
    return false
  }

  const addressParts = email.split("@")
  if (addressParts.length !== 2) return false
  const [localPart, domain] = addressParts

  if (
    !localPart ||
    Buffer.byteLength(localPart, "utf8") > MAX_EMAIL_LOCAL_PART_BYTES ||
    localPart.startsWith(".") ||
    localPart.endsWith(".") ||
    localPart.includes("..") ||
    !EMAIL_LOCAL_PART_PATTERN.test(localPart)
  ) {
    return false
  }

  if (!domain || Buffer.byteLength(domain, "utf8") > MAX_EMAIL_DOMAIN_BYTES) return false
  const domainLabels = domain.split(".")
  if (
    domainLabels.length < 2 ||
    domainLabels.some(
      (label) =>
        !label ||
        Buffer.byteLength(label, "utf8") > MAX_EMAIL_DOMAIN_LABEL_BYTES ||
        label.startsWith("-") ||
        label.endsWith("-") ||
        !EMAIL_DOMAIN_LABEL_PATTERN.test(label),
    )
  ) {
    return false
  }

  const topLevelDomain = domainLabels.at(-1)
  if (!topLevelDomain) return false

  return EMAIL_TOP_LEVEL_DOMAIN_PATTERN.test(topLevelDomain) ||
    EMAIL_PUNYCODE_TOP_LEVEL_DOMAIN_PATTERN.test(topLevelDomain)
}

export const isValidPhoneNumber = (phoneNumber: string | undefined | null): boolean => {
  if (!phoneNumber) {
    return false
  }

  // E.164 phone numbers
  // ref: https://www.twilio.com/docs/glossary/what-e164
  if (!/^\+[1-9]\d{1,14}$/.test(phoneNumber)) {
    return false
  }

  return true
}

export const isValid6DigitCode = (code: string | undefined | null): boolean => {
  if (!code) {
    return false
  }

  if (!/^\d{6}$/.test(code)) {
    return false
  }

  return true
}

export const validateUpToFourSegementSemver = (version: string): boolean => {
  if (!/^(0|[1-9]\d*)(\.(0|[1-9]\d*)){0,3}$/.test(version)) {
    return false
  }

  return true
}

export const validateIanaTimezone = (timezone: string): boolean => {
  if (!timezone) {
    return false
  }

  if (timezone.length > 64) {
    return false
  }

  try {
    Intl.DateTimeFormat(undefined, { timeZone: timezone })
    return true
  } catch {
    return false
  }
}

export const isValidSpaceId = (spaceId: number | string | undefined | null): boolean => {
  if (!spaceId) {
    return false
  }

  if (typeof spaceId === "string") {
    const id = Number(spaceId)
    if (isNaN(id) || id <= 0) {
      return false
    }
  }

  if (typeof spaceId === "number") {
    if (isNaN(spaceId) || spaceId <= 0) {
      return false
    }
  }

  return true
}
