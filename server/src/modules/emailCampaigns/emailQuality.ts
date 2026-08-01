import { normalizedCampaignEmail } from "./contactCrypto"

const OBVIOUS_DOMAIN_TYPOS = new Set([
  "gmai.com",
  "gmail.cm",
  "gmail.co",
  "gmail.cmo",
  "gmail.con",
  "gmial.com",
  "hotmai.com",
  "hotmail.con",
  "hotmial.com",
  "icloud.con",
  "outlok.com",
  "outlook.con",
  "protonmai.com",
  "yaho.com",
  "yahoo.con",
])

export type CampaignEmailQuality =
  | { readonly valid: true; readonly email: string }
  | { readonly valid: false; readonly email: string; readonly reason: "invalid" | "typo" }

const isStructurallyValid = (email: string): boolean => {
  const hasControlCharacter = [...email].some((character) => {
    const codePoint = character.codePointAt(0) ?? 0
    return codePoint <= 31 || codePoint === 127
  })
  if (email.length === 0 || email.length > 254 || /\s/.test(email) || hasControlCharacter) return false
  const at = email.indexOf("@")
  if (at <= 0 || at !== email.lastIndexOf("@")) return false
  const local = email.slice(0, at)
  const domain = email.slice(at + 1)
  if (
    local.length > 64 ||
    local.startsWith(".") ||
    local.endsWith(".") ||
    local.includes("..") ||
    !/^[A-Za-z0-9.!#$%&'*+/=?^_`{|}~-]+$/.test(local)
  ) return false
  if (domain.length > 253 || domain.startsWith("[") || domain.endsWith(".")) return false
  const labels = domain.split(".")
  if (labels.length < 2) return false
  if (labels.some((label) =>
    label.length === 0 ||
    label.length > 63 ||
    label.startsWith("-") ||
    label.endsWith("-") ||
    !/^[a-z0-9-]+$/i.test(label)
  )) return false
  const tld = labels.at(-1)!
  return /^[a-z]{2,63}$/i.test(tld) || /^xn--[a-z0-9-]{2,59}$/i.test(tld)
}

export const campaignEmailQuality = (value: string): CampaignEmailQuality => {
  const email = normalizedCampaignEmail(value)
  if (!isStructurallyValid(email)) return { valid: false, email, reason: "invalid" }
  const domain = email.slice(email.lastIndexOf("@") + 1)
  if (OBVIOUS_DOMAIN_TYPOS.has(domain)) return { valid: false, email, reason: "typo" }
  return { valid: true, email }
}
