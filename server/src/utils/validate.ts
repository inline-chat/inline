const MAX_EMAIL_BYTES = 320

export const isValidEmail = (email: string | undefined | null): boolean => {
  if (
    !email ||
    Buffer.byteLength(email, "utf8") > MAX_EMAIL_BYTES ||
    email.includes("\0") ||
    email.includes("\r") ||
    email.includes("\n")
  ) {
    return false
  }

  const separatorIndex = email.lastIndexOf("@")
  return separatorIndex > 0 && separatorIndex < email.length - 1
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
