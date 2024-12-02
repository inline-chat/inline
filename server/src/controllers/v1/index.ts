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
  handler as getUserHandler,
  Input as GetUserInput,
  Response as GetUserResponse,
} from "@in/server/methods/getUser"
import {
  handler as searchContactsHandler,
  Input as SearchContactsInput,
  Response as SearchContactsResponse,
} from "@in/server/methods/searchContacts"
import {
  handler as getChatHistoryHandler,
  Input as GetChatHistoryInput,
  Response as GetChatHistoryResponse,
} from "@in/server/methods/getChatHistory"
import {
  handler as sendMessageHandler,
  Input as SendMessageInput,
  Response as SendMessageResponse,
} from "@in/server/methods/sendMessage"
import {
  handler as createPrivateChatHandler,
  Input as CreatePrivateChatInput,
  Response as CreatePrivateChatResponse,
} from "@in/server/methods/createPrivateChat"
import {
  handler as deleteSpaceHandler,
  Input as DeleteSpaceInput,
  Response as DeleteSpaceResponse,
} from "@in/server/methods/deleteSpace"
import {
  handler as leaveSpaceHandler,
  Input as LeaveSpaceInput,
  Response as LeaveSpaceResponse,
} from "@in/server/methods/leaveSpace"
import {
  handler as getPrivateChatsHandler,
  Input as GetPrivateChatsInput,
  Response as GetPrivateChatsResponse,
} from "@in/server/methods/getPrivateChats"
import {
  handler as getSpaceMembersHandler,
  Input as GetSpaceMembersInput,
  Response as GetSpaceMembersResponse,
} from "@in/server/methods/getSpaceMembers"
import {
  handler as getDialogsHandler,
  Input as GetDialogsInput,
  Response as GetDialogsResponse,
} from "@in/server/methods/getDialogs"

import {
  handler as savePushNotificationHandler,
  Input as SavePushNotificationInput,
  Response as SavePushNotificationResponse,
} from "@in/server/methods/savePushNotification"

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
      .use(makeApiRoute("/getUser", GetUserInput, GetUserResponse, getUserHandler))
      .use(makeApiRoute("/searchContacts", SearchContactsInput, SearchContactsResponse, searchContactsHandler))
      .use(makeApiRoute("/getChatHistory", GetChatHistoryInput, GetChatHistoryResponse, getChatHistoryHandler))
      .use(makeApiRoute("/sendMessage", SendMessageInput, SendMessageResponse, sendMessageHandler))
      .use(
        makeApiRoute("/createPrivateChat", CreatePrivateChatInput, CreatePrivateChatResponse, createPrivateChatHandler),
      )
      .use(makeApiRoute("/deleteSpace", DeleteSpaceInput, DeleteSpaceResponse, deleteSpaceHandler))
      .use(makeApiRoute("/leaveSpace", LeaveSpaceInput, LeaveSpaceResponse, leaveSpaceHandler))
      .use(makeApiRoute("/getPrivateChats", GetPrivateChatsInput, GetPrivateChatsResponse, getPrivateChatsHandler))
      .use(makeApiRoute("/getSpaceMembers", GetSpaceMembersInput, GetSpaceMembersResponse, getSpaceMembersHandler))
      .use(makeApiRoute("/getDialogs", GetDialogsInput, GetDialogsResponse, getDialogsHandler))
      .use(
        makeApiRoute(
          "/savePushNotification",
          SavePushNotificationInput,
          SavePushNotificationResponse,
          savePushNotificationHandler,
        ),
      )
      .all("/*", () => {
        // fallback
        return { ok: false, errorCode: 404, description: "Method not found" }
      })
  })

  .use(handleError)
