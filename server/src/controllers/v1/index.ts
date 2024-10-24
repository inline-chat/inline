import { Elysia } from "elysia"
import { setup } from "@in/server/setup"
import { handleError, makeApiRoute, makeUnauthApiRoute } from "@in/server/controllers/v1/helpers"
import {
  handler as sendEmailCodeHandler,
  Input as SendEmailCodeInput,
  Response as SendEmailCodeResponse,
} from "@in/server/methods/sendEmailCode"
import {
  handler as createSpaceHandler,
  Input as CreateSpaceInput,
  Response as CreateSpaceResponse,
} from "@in/server/methods/createSpace"
import {
  handler as getSpacesHandler,
  Input as GetSpacesInput,
  Response as GetSpacesResponse,
} from "@in/server/methods/getSpaces"
import {
  handler as getSpaceHandler,
  Input as GetSpaceInput,
  Response as GetSpaceResponse,
} from "@in/server/methods/getSpace"
import { handler as getMeHandler, Input as GetMeInput, Response as GetMeResponse } from "@in/server/methods/getMe"
import {
  handler as updateProfileHandler,
  Input as UpdateProfileInput,
  Response as UpdateProfileResponse,
} from "@in/server/methods/updateProfile"
import {
  handler as createThreadHandler,
  Input as CreateThreadInput,
  Response as CreateThreadResponse,
} from "@in/server/methods/createThread"
import {
  handler as verifyEmailCodeHandler,
  Input as VerifyEmailCodeInput,
  Response as VerifyEmailCodeResponse,
} from "@in/server/methods/verifyEmailCode"
import {
  handler as checkUsernameHandler,
  Input as CheckUsernameInput,
  Response as CheckUsernameResponse,
} from "@in/server/methods/checkUsername"
import {
  handler as sendSmsCodeHandler,
  Input as SendSmsCodeInput,
  Response as SendSmsCodeResponse,
} from "@in/server/methods/sendSmsCode"
import {
  handler as verifySmsCodeHandler,
  Input as VerifySmsCodeInput,
  Response as VerifySmsCodeResponse,
} from "@in/server/methods/verifySmsCode"
import {
  handler as findUserHandler,
  Input as FindUserInput,
  Response as FindUserResponse,
} from "@in/server/methods/findUser"

export const apiV1 = new Elysia({ name: "v1" })
  .group("v1", (app) => {
    return app
      .use(setup)
      .use(makeUnauthApiRoute("/sendSmsCode", SendSmsCodeInput, SendSmsCodeResponse, sendSmsCodeHandler))
      .use(makeUnauthApiRoute("/verifySmsCode", VerifySmsCodeInput, VerifySmsCodeResponse, verifySmsCodeHandler))
      .use(makeUnauthApiRoute("/sendEmailCode", SendEmailCodeInput, SendEmailCodeResponse, sendEmailCodeHandler))
      .use(
        makeUnauthApiRoute("/verifyEmailCode", VerifyEmailCodeInput, VerifyEmailCodeResponse, verifyEmailCodeHandler),
      )
      .use(makeApiRoute("/createSpace", CreateSpaceInput, CreateSpaceResponse, createSpaceHandler))
      .use(makeApiRoute("/updateProfile", UpdateProfileInput, UpdateProfileResponse, updateProfileHandler))
      .use(makeApiRoute("/getMe", GetMeInput, GetMeResponse, getMeHandler))
      .use(makeApiRoute("/getSpaces", GetSpacesInput, GetSpacesResponse, getSpacesHandler))
      .use(makeApiRoute("/getSpace", GetSpaceInput, GetSpaceResponse, getSpaceHandler))
      .use(makeApiRoute("/checkUsername", CheckUsernameInput, CheckUsernameResponse, checkUsernameHandler))
      .use(makeApiRoute("/createThread", CreateThreadInput, CreateThreadResponse, createThreadHandler))
      .use(makeApiRoute("/findUser", FindUserInput, FindUserResponse, findUserHandler))
      .all("/*", () => {
        // fallback
        return { ok: false, errorCode: 404, description: "Method not found" }
      })
  })
  .use(handleError)
