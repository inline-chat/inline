import type { ChannelLike, PortLike, WorkerLike } from "@inline/link"
import { describe, expect, expectTypeOf, it } from "vitest"

describe("port types", () => {
  it("accept the browser's carriers", () => {
    expectTypeOf<MessagePort>().toExtend<PortLike>()
    expectTypeOf<BroadcastChannel>().toExtend<ChannelLike>()
    expectTypeOf<Worker>().toExtend<WorkerLike>()
    expectTypeOf<Worker>().toExtend<PortLike>()
    expect(true).toBe(true)
  })
})
