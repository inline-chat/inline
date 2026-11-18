/**
 * Text helpers for the sign-in screen. Framework-free and pure, so they are
 * unit-tested in Node; the views only call them.
 */

/** Seconds as `m:ss`, for the resend countdown ("0:42", "1:05"). Never negative. */
export const formatCountdown = (seconds: number): string => {
  const whole = Number.isFinite(seconds) ? Math.max(0, Math.ceil(seconds)) : 0
  const minutes = Math.floor(whole / 60)
  const rest = whole % 60
  return `${minutes}:${rest.toString().padStart(2, "0")}`
}

/**
 * A wait in words, for a rate limit ("30 seconds", "1 minute", "3 minutes").
 * Minutes round up so the user is never told to retry too early.
 */
export const formatWait = (seconds: number): string => {
  const whole = Number.isFinite(seconds) ? Math.max(1, Math.ceil(seconds)) : 60
  if (whole < 60) return whole === 1 ? "1 second" : `${whole} seconds`
  const minutes = Math.ceil(whole / 60)
  return minutes === 1 ? "1 minute" : `${minutes} minutes`
}

// Decimal digits in the scripts a keyboard is likely to produce: Arabic-Indic,
// Extended Arabic-Indic (Persian, Urdu), Devanagari, Bengali, and full-width.
// The model keeps ASCII digits only, so these are mapped before it sees them.
const DIGIT_ZEROS = [0x0660, 0x06f0, 0x0966, 0x09e6, 0xff10]

const toAsciiDigit = (char: string): string => {
  const code = char.codePointAt(0) ?? 0
  for (const zero of DIGIT_ZEROS) {
    if (code >= zero && code <= zero + 9) return String(code - zero)
  }
  return char
}

/**
 * What the code field shows as the user types or pastes: digits only, with
 * other scripts' digits mapped to ASCII and spaces, dashes and any other
 * characters dropped ("123 456", "123-456", "Code: ١٢٣٤٥٦" all work).
 * With `maxLength`, extra digits are cut off.
 */
export const normalizeCodeInput = (raw: string, maxLength?: number): string => {
  let digits = ""
  for (const char of raw) {
    const ascii = toAsciiDigit(char)
    if (ascii >= "0" && ascii <= "9" && ascii.length === 1) digits += ascii
  }
  return maxLength !== undefined && maxLength > 0 ? digits.slice(0, maxLength) : digits
}

/**
 * What the invite field shows as the user types or pastes: upper-case
 * letters and digits, without spaces or dashes, cut to `maxLength`. The model
 * applies the same rule before it checks the code.
 */
export const normalizeInviteInput = (raw: string, maxLength: number): string => {
  let out = ""
  for (const char of raw.toUpperCase()) {
    const ascii = toAsciiDigit(char)
    if ((ascii >= "A" && ascii <= "Z") || (ascii >= "0" && ascii <= "9")) {
      if (ascii.length === 1) out += ascii
    }
  }
  return out.slice(0, maxLength)
}

/**
 * The text to start the email or phone field with when the user comes back to
 * it: the contact the model holds, but only when it is of that kind (the model
 * keeps the last contact even after the user switches method).
 */
export const prefillContact = (kind: "email" | "phone", contact: string | null): string => {
  if (!contact) return ""
  const looksLikeEmail = contact.includes("@")
  return (kind === "email") === looksLikeEmail ? contact : ""
}

/**
 * Whether a typed or pasted code is complete and should be sent without
 * pressing Enter. Only when the expected length is known.
 */
export const isCodeComplete = (code: string, expectedLength: number | undefined): boolean =>
  expectedLength !== undefined && expectedLength > 0 && code.length === expectedLength
