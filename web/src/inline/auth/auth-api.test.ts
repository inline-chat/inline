import { beforeEach, describe, expect, it, vi } from "vitest"
import { inlineAuthApi, InlineAuthError } from "./auth-api"

const response = (body: unknown, status = 200) =>
  new Response(JSON.stringify(body), {
    status,
    headers: { "Content-Type": "application/json" },
  })

describe("Inline auth API", () => {
  beforeEach(() => {
    window.localStorage.clear()
    vi.restoreAllMocks()
  })

  it("uses the real v1 email-code contract and persists a stable web device id", async () => {
    const fetchMock = vi
      .fn<typeof fetch>()
      .mockResolvedValue(
        response({
          ok: true,
          result: {
            existingUser: true,
            needsInviteCode: false,
            challengeToken: "challenge",
          },
        }),
      )
    vi.stubGlobal("fetch", fetchMock)

    await expect(inlineAuthApi.sendEmailCode("mo@example.com")).resolves.toEqual({
      existingUser: true,
      needsInviteCode: false,
      challengeToken: "challenge",
    })

    const [requestUrl, options] = fetchMock.mock.calls[0]!
    const url = new URL(String(requestUrl))
    expect(url.pathname).toBe("/v1/sendEmailCode")
    expect(url.searchParams.get("email")).toBe("mo@example.com")
    expect(url.searchParams.get("deviceId")).toBeTruthy()
    expect(url.searchParams.get("clientType")).toBe("web")
    expect(options?.method).toBe("GET")
    expect(window.localStorage.getItem("inline-web-device-id")).toBe(url.searchParams.get("deviceId"))
  })

  it("uses the real POST phone-code contracts with the same device identity", async () => {
    const fetchMock = vi
      .fn<typeof fetch>()
      .mockResolvedValueOnce(
        response({
          ok: true,
          result: {
            existingUser: true,
            needsInviteCode: false,
            phoneNumber: "+14155552671",
            formattedPhoneNumber: "+1 415-555-2671",
          },
        }),
      )
      .mockResolvedValueOnce(
        response({
          ok: true,
          result: {
            userId: "9007199254740993",
            token: "token",
            user: { id: "9007199254740993", firstName: "Mo" },
          },
        }),
      )
    vi.stubGlobal("fetch", fetchMock)

    await inlineAuthApi.sendSmsCode("+14155552671")
    await inlineAuthApi.verifySmsCode({ phoneNumber: "+14155552671", code: "123456" })

    const [sendUrl, sendOptions] = fetchMock.mock.calls[0]!
    const [verifyUrl, verifyOptions] = fetchMock.mock.calls[1]!
    expect(new URL(String(sendUrl)).pathname).toBe("/v1/sendSmsCode")
    expect(sendOptions?.method).toBe("POST")
    const sendBody = JSON.parse(String(sendOptions?.body))
    expect(sendBody).toMatchObject({ phoneNumber: "+14155552671", clientType: "web" })

    expect(new URL(String(verifyUrl)).pathname).toBe("/v1/verifySmsCode")
    expect(verifyOptions?.method).toBe("POST")
    expect(JSON.parse(String(verifyOptions?.body))).toMatchObject({
      phoneNumber: "+14155552671",
      code: "123456",
      deviceId: sendBody.deviceId,
      clientType: "web",
    })
  })

  it("passes the bearer session and native profile field names", async () => {
    const fetchMock = vi
      .fn<typeof fetch>()
      .mockResolvedValue(
        response({
          ok: true,
          result: {
            user: {
              id: 7,
              firstName: "Mo",
            },
          },
        }),
      )
    vi.stubGlobal("fetch", fetchMock)

    await inlineAuthApi.updateProfile(
      {
        firstName: "Mo",
        lastName: "R",
        username: "mo",
      },
      "session-token",
    )

    const [requestUrl, options] = fetchMock.mock.calls[0]!
    expect(new URL(String(requestUrl)).pathname).toBe("/v1/updateProfile")
    expect(new Headers(options?.headers).get("Authorization")).toBe("Bearer session-token")
    expect(JSON.parse(String(options?.body))).toMatchObject({
      firstName: "Mo",
      lastName: "R",
      username: "mo",
    })
  })

  it("preserves exact user IDs returned as decimal strings", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn<typeof fetch>().mockResolvedValue(
        response({
          ok: true,
          result: {
            userId: "9007199254740993",
            token: "token",
            user: {
              id: "9007199254740993",
              firstName: "Mo",
            },
          },
        }),
      ),
    )

    await expect(
      inlineAuthApi.verifyEmailCode({
        email: "mo@example.com",
        code: "123456",
      }),
    ).resolves.toMatchObject({
      userId: "9007199254740993",
      user: { id: "9007199254740993" },
    })
  })

  it("rejects mismatched or lossy authentication identities", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn<typeof fetch>().mockResolvedValue(
        response({
          ok: true,
          result: {
            userId: "9007199254740993",
            token: "token",
            user: {
              id: "9007199254740992",
            },
          },
        }),
      ),
    )

    await expect(
      inlineAuthApi.verifyEmailCode({
        email: "mo@example.com",
        code: "123456",
      }),
    ).rejects.toThrow("invalid authentication response")
  })

  it("keeps the server error code and user-facing description", async () => {
    vi.stubGlobal(
      "fetch",
      vi.fn<typeof fetch>().mockResolvedValue(
        response(
          {
            ok: false,
            error: "EMAIL_CODE_INVALID",
            errorCode: 400,
            description: "The confirmation code is invalid.",
          },
          400,
        ),
      ),
    )

    const error = await inlineAuthApi
      .verifyEmailCode({
        email: "mo@example.com",
        code: "123456",
      })
      .catch((cause: unknown) => cause)

    expect(error).toBeInstanceOf(InlineAuthError)
    expect(error).toMatchObject({
      message: "The confirmation code is invalid.",
      errorCode: 400,
      apiError: "EMAIL_CODE_INVALID",
    })
  })
})
