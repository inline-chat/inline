import { useEffect, useState } from "react"

export type EmailParts = readonly [user: string, domain: string]

export const SUPPORT_EMAIL: EmailParts = ["hey", "inline.chat"]

export function emailValue(email: EmailParts) {
  return `${email[0]}@${email[1]}`
}

export function emailFallback(email: EmailParts) {
  return `${email[0]} [at] ${email[1]}`
}

export function emailParts(value: string): EmailParts {
  const [user = "", domain = ""] = value.split("@", 2)
  return [user, domain]
}

export function useHydratedEmail(email: EmailParts) {
  const [hydrated, setHydrated] = useState(false)

  useEffect(() => {
    setHydrated(true)
  }, [])

  return {
    label: hydrated ? emailValue(email) : emailFallback(email),
    value: emailValue(email),
    href: hydrated ? `mailto:${emailValue(email)}` : undefined,
  }
}
