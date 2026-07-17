import { Layer } from "effect"
import { handler as addMemberHandler } from "@in/server/methods/addMember"
import { handler as checkUsernameHandler } from "@in/server/methods/checkUsername"
import { handler as createSpaceHandler } from "@in/server/methods/createSpace"
import { handler as deleteSpaceHandler } from "@in/server/methods/deleteSpace"
import { handler as getInviteCodesHandler } from "@in/server/methods/getInviteCodes"
import { handler as getMeHandler } from "@in/server/methods/getMe"
import { handler as getSpaceHandler } from "@in/server/methods/getSpace"
import { handler as getSpaceMembersHandler } from "@in/server/methods/getSpaceMembers"
import { handler as getSpacesHandler } from "@in/server/methods/getSpaces"
import { handler as getUserHandler } from "@in/server/methods/getUser"
import { handler as leaveSpaceHandler } from "@in/server/methods/leaveSpace"
import { handler as savePushNotificationHandler } from "@in/server/methods/savePushNotification"
import { handler as searchContactsHandler } from "@in/server/methods/searchContacts"
import { handler as updateProfileHandler } from "@in/server/methods/updateProfile"
import { handler as updateProfilePhotoHandler } from "@in/server/methods/updateProfilePhoto"
import { handler as updateStatusHandler } from "@in/server/methods/updateStatus"
import { V1IdentitySpacesOperations } from "./v1IdentitySpacesOperations.effect"
import { makeV1IdentitySpacesOperations } from "./v1IdentitySpacesOperationsAdapter.effect"

export const V1IdentitySpacesOperationsLive = Layer.succeed(
  V1IdentitySpacesOperations,
  makeV1IdentitySpacesOperations({
    checkUsername: (input, context) => checkUsernameHandler({ ...input }, context),
    getMe: (input, context) => getMeHandler({ ...input }, context),
    getUser: (input, context) => getUserHandler({ ...input }, context),
    searchContacts: (input, context) => searchContactsHandler({ ...input }, context),
    updateProfile: (input, context) => updateProfileHandler({ ...input }, context),
    updateProfilePhoto: (input, context) => updateProfilePhotoHandler({ ...input }, context),
    updateStatus: (input, context) => updateStatusHandler({ ...input }, context),
    createSpace: (input, context) => createSpaceHandler({ ...input }, context),
    deleteSpace: (input, context) => deleteSpaceHandler({ ...input }, context),
    getSpaces: (_input, context) => getSpacesHandler(undefined, context),
    getSpace: (input, context) => getSpaceHandler({ ...input }, context),
    getInviteCodes: (input, context) => getInviteCodesHandler({ ...input }, context),
    addMember: (input, context) => addMemberHandler({ ...input }, context),
    leaveSpace: (input, context) => leaveSpaceHandler({ ...input }, context),
    getSpaceMembers: (input, context) => getSpaceMembersHandler({ ...input }, context),
    savePushNotification: (input, context) => savePushNotificationHandler({ ...input }, context),
  }),
)
