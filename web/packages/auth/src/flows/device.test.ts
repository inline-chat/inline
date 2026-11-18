import { describe, expect, it } from "vitest"
import { DEVICE_ID_STORAGE_KEY, createDeviceFacts, describeDevice, loadDeviceId } from "./device"
import { MemoryStorage } from "./test-support"

const ids = (...values: string[]) => {
  const queue = [...values]
  return () => queue.shift() ?? "exhausted-id-0000"
}

describe("loadDeviceId", () => {
  it("creates the ID once and keeps it", () => {
    const storage = new MemoryStorage()
    const randomId = ids("11111111-1111-4111-8111-111111111111", "22222222-2222-4222-8222-222222222222")
    const first = loadDeviceId({ storage, randomId })
    const second = loadDeviceId({ storage, randomId })
    expect(first).toEqual({ deviceId: "11111111-1111-4111-8111-111111111111", persisted: true })
    expect(second).toEqual(first)
    expect(storage.values.get(DEVICE_ID_STORAGE_KEY)).toBe(first.deviceId)
  })

  it("replaces a stored value that is not a device ID", () => {
    const storage = new MemoryStorage()
    storage.setItem(DEVICE_ID_STORAGE_KEY, "<script>")
    expect(loadDeviceId({ storage, randomId: ids("33333333-3333-4333-8333-333333333333") }).deviceId).toBe(
      "33333333-3333-4333-8333-333333333333",
    )
  })

  it("falls back to an unpersisted ID when storage fails", () => {
    const storage = new MemoryStorage()
    storage.failing = true
    expect(loadDeviceId({ storage, randomId: ids("44444444-4444-4444-8444-444444444444") })).toEqual({
      deviceId: "44444444-4444-4444-8444-444444444444",
      persisted: false,
    })
    expect(loadDeviceId({ storage: null, randomId: ids("55555555-5555-4555-8555-555555555555") }).persisted).toBe(
      false,
    )
  })
})

describe("describeDevice", () => {
  const cases: Array<[string, string]> = [
    [
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36",
      "Chrome on macOS",
    ],
    [
      "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Safari/605.1.15",
      "Safari on macOS",
    ],
    [
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Safari/537.36 Edg/131.0.0.0",
      "Edge on Windows",
    ],
    ["Mozilla/5.0 (X11; Linux x86_64; rv:133.0) Gecko/20100101 Firefox/133.0", "Firefox on Linux"],
    [
      "Mozilla/5.0 (iPhone; CPU iPhone OS 18_1 like Mac OS X) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/18.1 Mobile/15E148 Safari/604.1",
      "Safari on iOS",
    ],
    [
      "Mozilla/5.0 (Linux; Android 14; Pixel 8) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/131.0.0.0 Mobile Safari/537.36",
      "Chrome on Android",
    ],
    [
      "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Inline/0.1.0 Chrome/130.0.0.0 Electron/33.0.0 Safari/537.36",
      "Inline Desktop on Windows",
    ],
    ["curl/8.0", "Browser"],
  ]

  it.each(cases)("names %s", (userAgent, name) => {
    expect(describeDevice({ userAgent }).name).toBe(name)
  })

  it("prefers client hints where present", () => {
    expect(
      describeDevice({
        userAgent: "Mozilla/5.0 (X11; Linux x86_64) Chrome/131.0.0.0 Safari/537.36",
        userAgentData: {
          platform: "Chrome OS",
          brands: [{ brand: "Brave", version: "131" }, { brand: "Chromium", version: "131" }],
        },
      }).name,
    ).toBe("Brave on ChromeOS")
  })
})

describe("createDeviceFacts", () => {
  it("collects what the API client sends", () => {
    expect(
      createDeviceFacts({
        storage: new MemoryStorage(),
        randomId: ids("66666666-6666-4666-8666-666666666666"),
        environment: { userAgent: "Mozilla/5.0 (X11; Linux x86_64; rv:133.0) Gecko/20100101 Firefox/133.0" },
        clientVersion: "0.4.0",
        timeZone: "Asia/Tehran",
      }),
    ).toEqual({
      deviceId: "66666666-6666-4666-8666-666666666666",
      deviceIdPersisted: true,
      deviceName: "Firefox on Linux",
      clientVersion: "0.4.0",
      timeZone: "Asia/Tehran",
    })
  })
})
