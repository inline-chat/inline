import {
  afterEach,
  describe,
  expect,
  spyOn,
  test,
} from "bun:test"
import {
  publishBotPresenceHints,
} from "./bot.setPresenceState"
import { internalMessaging } from "@in/server/modules/internalMessaging/service"
import { outboundPublications } from "@in/server/modules/internalMessaging/outbound"

afterEach(async () => {
  await outboundPublications.drain()
  outboundPublications.start()
})

describe("bot presence broker fanout", () => {
  test("uses the bounded dispatcher and excludes the bot", async () => {
    let active = 0
    let maximumActive = 0
    const targets: number[] = []
    const release = Promise.withResolvers<void>()
    const saturated = Promise.withResolvers<void>()
    await outboundPublications.drain()
    outboundPublications.start()
    const publish = spyOn(internalMessaging, "publish").mockImplementation(async ({ target }) => {
      if (target.kind !== "user") throw new Error("expected user target")
      active += 1
      maximumActive = Math.max(maximumActive, active)
      targets.push(target.userId)
      if (active === 28) saturated.resolve()
      await release.promise
      active -= 1
      return { status: "published", subscribers: 1 }
    })

    try {
      publishBotPresenceHints({
        recipientUserIds: Array.from({ length: 49 }, (_, index) => index + 1),
        botUserId: 1,
        chatId: 2,
        activityId: "123e4567-e89b-42d3-a456-426614174000",
      })
      await saturated.promise

      expect(targets).toHaveLength(28)
      expect(targets).not.toContain(1)
      expect(maximumActive).toBe(28)

      release.resolve()
      await outboundPublications.drain()
      expect(targets).toHaveLength(48)
      expect(maximumActive).toBe(28)
    } finally {
      release.resolve()
      await outboundPublications.drain()
      publish.mockRestore()
    }
  })
})
