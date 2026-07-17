import { describe, expect, it } from "@effect/vitest"
import { Effect } from "effect"
import { InlineError } from "@in/server/types/errors"
import {
  BotOperationFailure,
  BotPublicError,
  makeBotOperations,
  type BotOperationHandlers,
} from "./operations.effect"

const unused = (): Promise<never> =>
  Promise.reject(new Error("unused Bot operation"))

const handlers = (
  getMe: BotOperationHandlers["getMe"],
): BotOperationHandlers => ({
  getMe,
  sendMessage: unused,
  getChat: unused,
  getChatHistory: unused,
  editMessageText: unused,
  deleteMessage: unused,
  sendReaction: unused,
  getMyCommands: unused,
  setMyCommands: unused,
  deleteMyCommands: unused,
})

describe("Bot operation error classification", () => {
  it.effect("keeps expected Inline errors public", () =>
    Effect.gen(function* () {
      const operations = makeBotOperations(
        handlers(() =>
          Promise.reject(
            new InlineError(InlineError.ApiError.BAD_REQUEST),
          ),
        ),
      )
      const failure = yield* Effect.flip(
        operations.getMe({
          currentUserId: 1,
          currentSessionId: 2,
          ip: undefined,
        }),
      )

      expect(failure).toBeInstanceOf(BotPublicError)
    }),
  )

  it.effect("reports server Inline errors while retaining their public envelope", () =>
    Effect.gen(function* () {
      const internal = new InlineError(
        InlineError.ApiError.INTERNAL,
      )
      const operations = makeBotOperations(
        handlers(() => Promise.reject(internal)),
      )
      const failure = yield* Effect.flip(
        operations.getMe({
          currentUserId: 1,
          currentSessionId: 2,
          ip: undefined,
        }),
      )

      expect(failure).toBeInstanceOf(BotOperationFailure)
      if (failure instanceof BotOperationFailure) {
        expect(failure.cause).toBe(internal)
        expect(failure.publicError).toMatchObject({
          error: "INTERNAL",
          errorCode: 500,
        })
      }
    }),
  )
})
