import * as schema from "./schema"
import { defineRelations } from "drizzle-orm"
export { schema }

export const relations = defineRelations(
  {
    chats: schema.chats,
    chatParticipants: schema.chatParticipants,
    dialogs: schema.dialogs,
    messages: schema.messages,
    users: schema.users,
    integrations: schema.integrations,
    spaces: schema.spaces,
    files: schema.files,
    photos: schema.photos,
    videos: schema.videos,
    documents: schema.documents,
    reactions: schema.reactions,
    photoSizes: schema.photoSizes,
    messageAttachments: schema.messageAttachments,
    urlPreview: schema.urlPreview,
    externalTasks: schema.externalTasks,
    members: schema.members,
    translations: schema.translations,
    userSettings: schema.userSettings,
    updates: schema.updates,
  },
  (r) => ({
    users: {
      settings: r.one.userSettings({
        from: r.users.id,
        to: r.userSettings.userId,
        optional: true,
      }),

      photoFile: r.one.files({
        from: r.users.photoFileId,
        to: r.files.id,
        optional: true,
      }),
    },

    // Chat relations - core chat functionality
    chats: {
      // Space and message relations
      space: r.one.spaces({
        from: r.chats.spaceId,
        to: r.spaces.id,
        optional: true,
      }),
      lastMsg: r.one.messages({
        from: [r.chats.id, r.chats.lastMsgId],
        to: [r.messages.chatId, r.messages.messageId],
      }),

      // User relations for private chats
      minUser: r.one.users({
        from: r.chats.minUserId,
        to: r.users.id,
        optional: true,
      }),
      maxUser: r.one.users({
        from: r.chats.maxUserId,
        to: r.users.id,
        optional: true,
      }),

      dialogs: r.many.dialogs(),
      participants: r.many.chatParticipants(),
    },

    // Chat participants relations - handles chat membership
    chatParticipants: {
      chat: r.one.chats({
        from: r.chatParticipants.chatId,
        to: r.chats.id,
      }),
      user: r.one.users({
        from: r.chatParticipants.userId,
        to: r.users.id,
      }),
    },

    // Dialog relations - handles user's view of chats
    dialogs: {
      // Core relations
      chat: r.one.chats({
        from: r.dialogs.chatId,
        to: r.chats.id,
      }),
      user: r.one.users({
        from: r.dialogs.userId,
        to: r.users.id,
      }),

      // Optional relations
      space: r.one.spaces({
        from: r.dialogs.spaceId,
        to: r.spaces.id,
        optional: true,
      }),
      peerUser: r.one.users({
        from: r.dialogs.peerUserId,
        to: r.users.id,
        optional: true,
      }),
    },

    // Message relations - handles message content and metadata
    messages: {
      // Core message relations
      from: r.one.users({
        from: r.messages.fromId,
        to: r.users.id,
        optional: false,
      }),
      reactions: r.many.reactions(),
      messageAttachments: r.many.messageAttachments(),
      translations: r.many.translations(),

      // Media relations
      file: r.one.files({
        from: r.messages.fileId,
        to: r.files.id,
        optional: true,
      }),
      photo: r.one.photos({
        from: r.messages.photoId,
        to: r.photos.id,
        optional: true,
      }),
      video: r.one.videos({
        from: r.messages.videoId,
        to: r.videos.id,
        optional: true,
      }),
      document: r.one.documents({
        from: r.messages.documentId,
        to: r.documents.id,
        optional: true,
      }),
    },

    // Space relations - handles workspace functionality
    spaces: {
      creator: r.one.users({
        from: r.spaces.creatorId,
        to: r.users.id,
        optional: true,
      }),
      members: r.many.members(),
      chats: r.many.chats(),
    },

    // Member relations - handles space membership
    members: {
      user: r.one.users({
        from: r.members.userId,
        to: r.users.id,
      }),
      space: r.one.spaces({
        from: r.members.spaceId,
        to: r.spaces.id,
      }),
      invitedBy: r.one.users({
        from: r.members.invitedBy,
        to: r.users.id,
        optional: true,
      }),
    },

    // Message attachment relations - handles message attachments
    messageAttachments: {
      message: r.one.messages({
        from: r.messageAttachments.messageId,
        to: r.messages.globalId,
      }),
      externalTask: r.one.externalTasks({
        from: r.messageAttachments.externalTaskId,
        to: r.externalTasks.id,
        optional: true,
      }),
      linkEmbed: r.one.urlPreview({
        from: r.messageAttachments.urlPreviewId,
        to: r.urlPreview.id,
        optional: true,
      }),
    },

    // URL preview relations - handles link previews
    urlPreview: {
      photo: r.one.photos({
        from: r.urlPreview.photoId,
        to: r.photos.id,
        optional: true,
      }),
    },

    translations: {
      message: r.one.messages({
        from: [r.translations.chatId, r.translations.messageId],
        to: [r.messages.chatId, r.messages.messageId],
      }),
    },

    // External task relations - handles task integrations
    externalTasks: {
      assignedUser: r.one.users({
        from: r.externalTasks.assignedUserId,
        to: r.users.id,
        optional: true,
      }),
    },

    integrations: {
      user: r.one.users({
        from: r.integrations.userId,
        to: r.users.id,
        optional: true,
      }),
      space: r.one.spaces({
        from: r.integrations.spaceId,
        to: r.spaces.id,
        optional: true,
      }),
    },

    photos: {
      photoSizes: r.many.photoSizes(),
    },

    photoSizes: {
      photo: r.one.photos({
        from: r.photoSizes.photoId,
        to: r.photos.id,
      }),
      file: r.one.files({
        from: r.photoSizes.fileId,
        to: r.files.id,
        optional: true,
      }),
    },

    videos: {
      file: r.one.files({
        from: r.videos.fileId,
        to: r.files.id,
      }),

      photo: r.one.photos({
        from: r.videos.photoId,
        to: r.photos.id,
        optional: true,
      }),
    },

    documents: {
      file: r.one.files({
        from: r.documents.fileId,
        to: r.files.id,
      }),

      photo: r.one.photos({
        from: r.documents.photoId,
        to: r.photos.id,
        optional: true,
      }),
    },

    reactions: {
      message: r.one.messages({
        from: [r.reactions.chatId, r.reactions.messageId],
        to: [r.messages.chatId, r.messages.messageId],
      }),
    },
  }),
)
