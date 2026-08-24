import { describe, expect, spyOn, test } from "bun:test"
import { Log } from "@in/server/utils/log"
import { assertProviderAuthStartupConfiguration } from "./startup"

describe("provider authentication startup guard", () => {
  test("fatally logs configuration failures and refuses startup", () => {
    const failure = new Error("synthetic provider configuration failure")
    const fatal = spyOn(Log.shared, "fatal").mockImplementation(() => {})
    try {
      expect(() => assertProviderAuthStartupConfiguration(() => { throw failure })).toThrow(failure)
      expect(fatal).toHaveBeenCalledWith(
        "Required Apple and Google sign-in configuration is invalid; refusing to start the server.",
        failure,
      )
    } finally {
      fatal.mockRestore()
    }
  })
})
