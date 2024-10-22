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
