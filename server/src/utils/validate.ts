export const isValidEmail = (email: string | undefined | null): boolean => {
  if (!email) {
    return false
  }

  if (!/^\S+@\S+\.\S+$/.test(email)) {
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
