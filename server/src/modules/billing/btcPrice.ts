import { Log } from "@in/server/utils/log"

const log = new Log("billing.btcPrice")

/** Reject obviously broken quotes rather than charging from them. */
const plausible = (value: number) => Number.isFinite(value) && value >= 1_000 && value <= 10_000_000
const SPOT_TTL_MS = 5 * 60 * 1000

let spotCache: { value: number; at: number } | null = null
const dayCache = new Map<string, number>()
let override: ((date: Date | null) => number | null) | null = null

/** Tests only: replace the network with a fixed function (`null` restores it). */
export const setBtcUsdForTests = (fn: ((date: Date | null) => number | null) | null) => {
  override = fn
  spotCache = null
  dayCache.clear()
}

const getJson = async (url: string): Promise<unknown> => {
  const response = await fetch(url, { signal: AbortSignal.timeout(5_000), headers: { accept: "application/json" } })
  if (!response.ok) throw new Error(`price source ${response.status}`)
  return response.json()
}

const coinbase = async (date: string | null) => {
  const json = await getJson(`https://api.coinbase.com/v2/prices/BTC-USD/spot${date ? `?date=${date}` : ""}`) as { data?: { amount?: string } }
  return Number(json.data?.amount)
}

const kraken = async (date: string | null) => {
  if (!date) {
    const json = await getJson("https://api.kraken.com/0/public/Ticker?pair=XBTUSD") as { result?: Record<string, { c?: string[] }> }
    return Number(Object.values(json.result ?? {})[0]?.c?.[0])
  }
  const since = Math.floor(Date.parse(`${date}T00:00:00Z`) / 1000) - 1
  const json = await getJson(`https://api.kraken.com/0/public/OHLC?pair=XBTUSD&interval=1440&since=${since}`) as { result?: Record<string, unknown> }
  const rows = Object.entries(json.result ?? {}).find(([key]) => key !== "last")?.[1] as Array<[number, string, string, string, string]> | undefined
  const day = rows?.find((row) => new Date(row[0] * 1000).toISOString().slice(0, 10) === date)
  return Number(day?.[4])
}

const quote = async (date: string | null): Promise<number | null> => {
  for (const [name, source] of [["coinbase", coinbase], ["kraken", kraken]] as const) {
    try {
      const value = await source(date)
      if (plausible(value)) return value
      log.warn("btc price implausible", { source: name, date })
    } catch (error) {
      log.warn("btc price unavailable", { source: name, date, error })
    }
  }
  return null
}

/** Current BTC price in USD, cached for five minutes. Null when no source answers. */
export const btcUsdSpot = async (now = Date.now()): Promise<number | null> => {
  if (override) return override(null)
  if (spotCache && now - spotCache.at < SPOT_TTL_MS) return spotCache.value
  const value = await quote(null)
  if (value !== null) spotCache = { value, at: now }
  return value
}

/** BTC price in USD on a past UTC day. */
export const btcUsdOn = async (day: Date): Promise<number | null> => {
  if (override) return override(day)
  const key = day.toISOString().slice(0, 10)
  const cached = dayCache.get(key)
  if (cached !== undefined) return cached
  const value = await quote(key)
  if (value !== null) dayCache.set(key, value)
  return value
}

/**
 * The rate a credit period is charged at: the price on the day it started for periods
 * being caught up (more than a day old), otherwise the current price.
 */
export const btcUsdForPeriod = async (periodStart: Date, now: Date): Promise<number | null> =>
  periodStart.getTime() < now.getTime() - 24 * 60 * 60 * 1000 ? btcUsdOn(periodStart) : btcUsdSpot(now.getTime())
