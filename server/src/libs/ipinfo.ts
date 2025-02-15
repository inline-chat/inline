import { IPINFO_TOKEN } from "@in/server/env"
import { Log } from "@in/server/utils/log"

interface IPInfoResponse {
  ip: string
  hostname: string
  city: string
  region: string
  timezone: string

  /** Country code */
  country: string

  /** Organization */
  org: string

  /** Postal code */
  postal: string

  /** Location (latitude, longitude) */
  loc: string
}

/** Check IP info if IPINFO_TOKEN is defined. */
export const ipinfo = async (ip: string): Promise<IPInfoResponse | undefined> => {
  if (!IPINFO_TOKEN) {
    Log.shared.warn("Cannot check IP. IPINFO_TOKEN is not defined.")
    return
  }

  const controller = new AbortController()
  const timeout = setTimeout(() => controller.abort(), 3000)

  try {
    let result = await fetch(`https://ipinfo.io/${ip}?token=${IPINFO_TOKEN}`, {
      headers: {
        Accept: "application/json",
      },
      signal: controller.signal,
    })

    if (!result.ok) {
      Log.shared.warn(`Failed to get IP info for ${ip}.`)
      return
    }

    return result.json()
  } catch (error) {
    Log.shared.warn(`Failed to get IP info for ${ip}.`)
    return
  } finally {
    clearTimeout(timeout)
  }
}
