export const normalizeEmail = (email: string): string => {
  return email.trim().toLowerCase()
}

export const normalizeUsername = (username: string): string => {
  return username.trim() //.toLowerCase()
}

export const normalizePhoneNumber = (phoneNumber: string): string => {
  return phoneNumber.trim().replace(/\s+/g, "")
}
