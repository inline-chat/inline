// ipinfo.io/45.77.137.171?token=935ffb6dc94053

import { IPINFO_TOKEN } from "@in/server/env"

// response
// {
//   "ip": "45.77.137.171",
//   "hostname": "45.77.137.171.vultrusercontent.com",
//   "city": "Haarlem",
//   "region": "North Holland",
//   "country": "NL",
//   "loc": "52.3904,4.6573",
//   "org": "AS20473 The Constant Company, LLC",
//   "postal": "2031",
//   "timezone": "Europe/Amsterdam"
//   }
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
    console.warn("Cannot check IP. IPINFO_TOKEN is not defined.")
    return
  }

  // "Accept: application/json"
  let result = await fetch(`https://ipinfo.io/${ip}?token=${IPINFO_TOKEN}`, {
    headers: {
      Accept: "application/json",
    },
  })

  if (!result.ok) {
    console.warn(`Failed to get IP info for ${ip}.`)
    return
  }

  return result.json()
}
