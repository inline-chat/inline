import { describe, expect, it } from "vitest"
import {
  MessageListController,
  shouldFollowMessageListChange,
} from "./MessageListController"

describe("MessageListController", () => {
  it("does not mistake an intermediate imperative scroll for history browsing", () => {
    const controller = new MessageListController({
      startsAtBottom: false,
      hasNewer: false,
    })

    controller.requestBottom()
    controller.observePhysical({
      physicalBottom: false,
      hasNewer: false,
    })
    expect(controller.wantsBottom).toBe(true)
    expect(controller.logicalBottom).toBe(false)

    controller.settlePhysical({
      physicalBottom: true,
      hasNewer: false,
    })
    expect(controller.wantsBottom).toBe(true)
    expect(controller.logicalBottom).toBe(true)
  })

  it("lets explicit user navigation cancel pending bottom work", () => {
    const controller = new MessageListController({
      startsAtBottom: true,
      hasNewer: false,
    })
    const pendingEpoch = controller.requestBottom()

    controller.browseHistory()

    expect(controller.wantsBottom).toBe(false)
    expect(controller.logicalBottom).toBe(false)
    expect(controller.isCurrent(pendingEpoch)).toBe(false)
  })

  it("keeps restored bottom intent through a pre-measure scroll end", () => {
    const controller = new MessageListController({
      startsAtBottom: true,
      hasNewer: false,
    })
    controller.requestBottom()

    controller.settlePhysical({
      physicalBottom: false,
      hasNewer: false,
    })

    expect(controller.wantsBottom).toBe(true)
    expect(controller.logicalBottom).toBe(false)
  })

  it("keeps bottom intent when measured content grows after reaching the end", () => {
    const controller = new MessageListController({
      startsAtBottom: true,
      hasNewer: false,
    })
    controller.observePhysical({
      physicalBottom: true,
      hasNewer: false,
    })
    controller.observePhysical({
      physicalBottom: false,
      hasNewer: false,
    })

    expect(controller.wantsBottom).toBe(true)
    expect(controller.logicalBottom).toBe(false)
  })

  it("separates physical window end from the logical latest message", () => {
    const controller = new MessageListController({
      startsAtBottom: true,
      hasNewer: true,
    })

    controller.observePhysical({
      physicalBottom: true,
      hasNewer: true,
    })
    expect(controller.wantsBottom).toBe(true)
    expect(controller.logicalBottom).toBe(false)

    controller.setHasNewer(false)
    expect(controller.logicalBottom).toBe(true)
  })

  it("follows ambient appends only while attached and always follows a local send", () => {
    expect(shouldFollowMessageListChange({
      appended: true,
      outgoingSend: false,
      wantsBottom: true,
    })).toBe(true)
    expect(shouldFollowMessageListChange({
      appended: true,
      outgoingSend: false,
      wantsBottom: false,
    })).toBe(false)
    expect(shouldFollowMessageListChange({
      appended: false,
      outgoingSend: true,
      wantsBottom: false,
    })).toBe(true)
  })
})
