export const isValidEmail = (email: string | undefined | null): boolean => {
  if (!email) {
    return false
  }

  if (!/^\S+@\S+\.\S+$/.test(email)) {
    return false
  }

  return true
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

  if (timezone === "UTC" || timezone === "GMT") {
    return true
  }

  // Regex for most IANA time zone formats
  const validRegex =
    /^(Africa|America|Antarctica|Asia|Atlantic|Australia|Europe|Indian|Pacific)\/([A-Za-z_]+)(\/[A-Za-z_]+)?$/

  // Special regex for Etc timezones
  const etcRegex = /^Etc\/(GMT[+-]\d{1,2}|UTC|UCT|Greenwich|Universal|Zulu)$/

  return validRegex.test(timezone) || etcRegex.test(timezone)
}
